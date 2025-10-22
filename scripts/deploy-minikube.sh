#!/bin/bash
set -e

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Set namespace and release name
NAMESPACE="bridgelink"
RELEASE_NAME="bridgelink-$(date +%s)"

echo -e "${GREEN}=== BridgeLink Minikube Deployment Script ===${NC}"
echo -e "${GREEN}Release Name: ${RELEASE_NAME}${NC}"

# Check if minikube is installed
if ! command -v minikube &> /dev/null; then
    echo -e "${RED}Error: minikube is not installed${NC}"
    echo "Please install minikube first: https://minikube.sigs.k8s.io/docs/start/"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm is not installed${NC}"
    echo "Please install helm first: https://helm.sh/docs/intro/install/"
    exit 1
fi

# Check minikube status and start if not running
if ! minikube status | grep -q "Running"; then
    echo -e "${YELLOW}Minikube is not running. Starting minikube...${NC}"
    minikube start --memory=4096 --cpus=2
else
    echo -e "${GREEN}Minikube is already running${NC}"
fi

# Initialize MetalLB first
echo -e "${YELLOW}Configuring MetalLB...${NC}"
if ! minikube addons list | grep "metallb" | grep -q "enabled"; then
    echo -e "${YELLOW}Enabling MetalLB addon...${NC}"
    minikube addons enable metallb

    # Wait for MetalLB controller and speaker pods to be created
    echo -e "${YELLOW}Waiting for MetalLB pods to be created...${NC}"
    sleep 10
fi

# Get minikube IP and calculate IP range for MetalLB
MINIKUBE_IP=$(minikube ip)
IP_BASE=$(echo $MINIKUBE_IP | cut -d"." -f1-3)

# Configure MetalLB with IP range
echo -e "${YELLOW}Configuring MetalLB IP range...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${IP_BASE}.200-${IP_BASE}.250
EOF

# Wait for MetalLB pods to be ready and verify configuration
echo -e "${YELLOW}Waiting for MetalLB to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=metallb -n metallb-system --timeout=120s || true
kubectl wait --for=condition=ready pod -l component=speaker -n metallb-system --timeout=120s || true
kubectl wait --for=condition=ready pod -l component=controller -n metallb-system --timeout=120s || true

# Verify MetalLB configuration
echo -e "${YELLOW}Verifying MetalLB configuration...${NC}"
if ! kubectl get configmap -n metallb-system config >/dev/null 2>&1; then
    echo -e "${RED}MetalLB configuration not found. Retrying configuration...${NC}"
    sleep 5
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${IP_BASE}.200-${IP_BASE}.250
EOF
fi

# Enable other addons after MetalLB is ready
if ! minikube addons list | grep "ingress" | grep -q "enabled"; then
    echo -e "${YELLOW}Enabling ingress addon...${NC}"
    minikube addons enable ingress
fi

# Create bridgelink namespace if it doesn't exist
echo -e "${YELLOW}Creating bridgelink namespace...${NC}"
kubectl create namespace bridgelink --dry-run=client -o yaml | kubectl apply -f -

# Clean up existing resources
echo -e "${YELLOW}Cleaning up existing resources...${NC}"

# Delete specific services first to avoid ownership conflicts
echo -e "${YELLOW}Removing existing PostgreSQL service...${NC}"
kubectl delete service -n ${NAMESPACE} -l "app=postgres" --ignore-not-found=true

# List of resource types to clean up
RESOURCES="deployment,configmap,secret,pvc,pv"

# Find and delete resources with any helm release label
echo -e "${YELLOW}Finding and removing old Helm releases...${NC}"
for resource in $(kubectl get ${RESOURCES} -n ${NAMESPACE} -l "app.kubernetes.io/managed-by=Helm" -o name); do
    echo -e "${YELLOW}Deleting ${resource}...${NC}"
    kubectl delete ${resource} -n ${NAMESPACE} --ignore-not-found=true --timeout=60s
done

# Additional cleanup for any resources with postgres label
echo -e "${YELLOW}Cleaning up PostgreSQL resources...${NC}"
kubectl delete all -n ${NAMESPACE} -l "app=postgres" --ignore-not-found=true --timeout=60s

# Wait for resources to be deleted
echo -e "${YELLOW}Waiting for resources to be deleted...${NC}"
kubectl wait --for=delete pod -l "app.kubernetes.io/managed-by=Helm" -n ${NAMESPACE} --timeout=120s || true
kubectl wait --for=delete pod -l "app=postgres" -n ${NAMESPACE} --timeout=120s || true

# Clean up Helm releases
echo -e "${YELLOW}Cleaning up Helm releases...${NC}"
helm list -n ${NAMESPACE} -q | while read release; do
    if [ ! -z "$release" ]; then
        echo -e "${YELLOW}Uninstalling Helm release: ${release}${NC}"
        helm uninstall ${release} -n ${NAMESPACE} --timeout 60s
    fi
done

# Final verification of cleanup
echo -e "${YELLOW}Verifying cleanup...${NC}"
kubectl delete service -n ${NAMESPACE} bridgelink-postgres --ignore-not-found=true

# Wait for old pods to terminate
echo -e "${YELLOW}Waiting for old pods to terminate...${NC}"
kubectl wait --for=delete pod -l "app.kubernetes.io/name=bridgelink" -n bridgelink --timeout=60s || true

# Check for existing minikube-values.yaml
MINIKUBE_VALUES="$PROJECT_ROOT/minikube-values.yaml"
if [ ! -f "$MINIKUBE_VALUES" ]; then
    echo -e "${YELLOW}Creating default minikube-values.yaml...${NC}"
    # Create values file for minikube
    cat > "$MINIKUBE_VALUES" << EOL
bridgelink:
  service:
    type: LoadBalancer
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

postgres:
  persistence:
    enabled: true
    size: 1Gi
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
EOL
else
    echo -e "${GREEN}Using existing minikube-values.yaml${NC}"
fi

# Deploy BridgeLink using Helm
echo -e "${GREEN}Deploying BridgeLink to Minikube in ${NAMESPACE} namespace...${NC}"
helm upgrade --install ${RELEASE_NAME} "$PROJECT_ROOT/charts/bridgelink" \
    -f "$MINIKUBE_VALUES" \
    -n ${NAMESPACE} \
    --create-namespace \
    --wait \
    --timeout 10m

# Wait longer for LoadBalancer IP assignment
echo -e "${YELLOW}Waiting for external IP assignment...${NC}"
for i in {1..60}; do
    EXTERNAL_IP=$(kubectl get svc ${RELEASE_NAME}-bl -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ]; then
        break
    fi
    echo -e "${YELLOW}Waiting for LoadBalancer IP (attempt $i/60)...${NC}"
    sleep 5
done

# If still no external IP, check MetalLB status
if [ -z "$EXTERNAL_IP" ]; then
    echo -e "${YELLOW}Checking MetalLB status...${NC}"
    echo -e "MetalLB pods:"
    kubectl get pods -n metallb-system
    echo -e "\nMetalLB configuration:"
    kubectl get configmap -n metallb-system config -o yaml
    echo -e "\nService status:"
    kubectl get svc ${RELEASE_NAME}-bl -n ${NAMESPACE} -o yaml
fi

echo -e "${GREEN}=== BridgeLink Deployment Complete ===${NC}"
if [ ! -z "$EXTERNAL_IP" ]; then
    echo -e "\n${GREEN}BridgeLink is available at:${NC}"
    echo -e "HTTP:  ${GREEN}http://$EXTERNAL_IP:8080${NC}"
    echo -e "HTTPS: ${GREEN}https://$EXTERNAL_IP:8443${NC}"
else
    echo -e "\n${YELLOW}External IP not yet assigned. You can still access BridgeLink using port-forward:${NC}"
    echo -e "HTTP:  ${YELLOW}kubectl port-forward svc/bridgelink-bl -n bridgelink 8080:8080${NC}"
    echo -e "HTTPS: ${YELLOW}kubectl port-forward svc/bridgelink-bl -n bridgelink 8443:8443${NC}"
    echo -e "\nThen access at:"
    echo -e "HTTP:  ${GREEN}http://localhost:8080${NC}"
    echo -e "HTTPS: ${GREEN}https://localhost:8443${NC}"
fi
echo -e "${YELLOW}Note: The HTTPS connection will show as insecure due to self-signed certificates${NC}"

# Print namespace information
echo -e "\n${GREEN}Deployment Status:${NC}"
kubectl get pods -n bridgelink
echo -e "\n${GREEN}Services:${NC}"
kubectl get svc -n bridgelink