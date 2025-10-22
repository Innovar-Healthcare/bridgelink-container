#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== BridgeLink Minikube Deployment Script ===${NC}"

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

# Enable required addons
if ! minikube addons list | grep "ingress" | grep -q "enabled"; then
    echo -e "${YELLOW}Enabling ingress addon...${NC}"
    minikube addons enable ingress
fi

if ! minikube addons list | grep "metallb" | grep -q "enabled"; then
    echo -e "${YELLOW}Enabling MetalLB addon...${NC}"
    minikube addons enable metallb
    
    # Get minikube IP and calculate IP range for MetalLB
    MINIKUBE_IP=$(minikube ip)
    IP_BASE=$(echo $MINIKUBE_IP | cut -d"." -f1-3)
    
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
    
    # Wait for MetalLB pods to be ready
    echo -e "${YELLOW}Waiting for MetalLB to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app=metallb -n metallb-system --timeout=300s
fi

# Create bridgelink namespace if it doesn't exist
echo -e "${YELLOW}Creating bridgelink namespace...${NC}"
kubectl create namespace bridgelink --dry-run=client -o yaml | kubectl apply -f -

# Clean up existing deployments to handle selector changes
echo -e "${YELLOW}Cleaning up existing deployments...${NC}"
kubectl delete deployment -n bridgelink bridgelink-bl --ignore-not-found=true
kubectl delete deployment -n bridgelink bridgelink-postgres --ignore-not-found=true

# Create values file for minikube
cat > minikube-values.yaml << EOL
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

# Deploy BridgeLink using Helm
echo -e "${GREEN}Deploying BridgeLink to Minikube in bridgelink namespace...${NC}"
helm upgrade --install bridgelink ./charts/bridgelink -f minikube-values.yaml -n bridgelink --create-namespace

# Wait for pods to be ready
echo -e "${YELLOW}Waiting for pods to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=bl --timeout=300s -n bridgelink
kubectl wait --for=condition=ready pod -l app=postgres --timeout=300s -n bridgelink

# Wait for external IP to be assigned
echo -e "${YELLOW}Waiting for external IP assignment...${NC}"
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get svc bridgelink-bl -n bridgelink -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ]; then
        break
    fi
    sleep 2
done

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