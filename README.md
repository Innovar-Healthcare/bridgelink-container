# BridgeLink Container & Helm Chart

![BridgeLink Icon](https://avatars.githubusercontent.com/u/116584698)

This repository contains both the Helm chart for deploying BridgeLink and its associated Docker container configuration.

## Repository Structure

```
.
├── charts/                 # Helm charts directory
│   └── bridgelink/        # Main BridgeLink Helm chart
│       ├── Chart.yaml     # Chart metadata
│       ├── values.yaml    # Default configuration values
│       ├── values.schema.json # JSON schema for validating values
│       └── templates/     # Kubernetes manifest templates
│           ├── _helpers.tpl
│           ├── bl-secret.yaml
│           ├── configmap.yaml
│           ├── deployment.yaml
│           ├── postgres-deployment.yaml
│           ├── postgres-pvc.yaml
│           ├── postgres-service.yaml
│           └── service.yaml
├── docker/                # Docker container configuration
│   ├── Dockerfile
│   └── docker-compose.yml
├── scripts/              # Deployment and utility scripts
│   └── deploy-minikube.sh # Minikube deployment script
├── docs/                # Documentation
│   └── development.md
└── minikube-values.yaml # Minikube-specific configuration values
```

## Quick Start

### Local Development with Minikube

Deploy to Minikube:
```bash
./scripts/deploy-minikube.sh
```

The script will:
1. Check for required dependencies (minikube, helm)
2. Start Minikube if not running
3. Enable required addons (ingress, metallb)
4. Create or use existing `minikube-values.yaml`
5. Deploy BridgeLink using Helm
6. Configure load balancing
7. Display access URLs when ready

### Production Deployment

Install using Helm:
```bash
helm install bridgelink ./charts/bridgelink -f /path/to/your/values.yaml
```

## Development

The repository follows standard Helm development practices:

1. Helm chart is located in `charts/bridgelink/`
2. Docker configuration is in `docker/`
3. Deployment scripts are in `scripts/`
4. Documentation is in `docs/`

### Testing Changes

Test chart changes locally:
```bash
# Validate chart syntax
helm lint ./charts/bridgelink

# Validate values against schema
helm lint ./charts/bridgelink -f minikube-values.yaml

# Preview rendered templates
helm template ./charts/bridgelink -f minikube-values.yaml
```

## Configuration

The chart supports various configuration options through values files:

- Default values: [charts/bridgelink/values.yaml](charts/bridgelink/values.yaml)
- Minikube values: [minikube-values.yaml](minikube-values.yaml)

Values are validated against the JSON schema at [charts/bridgelink/values.schema.json](charts/bridgelink/values.schema.json).

### Key Configuration Options

```yaml
bridgelink:
  service:
    type: LoadBalancer  # Service type (LoadBalancer, ClusterIP, NodePort)
  resources:           # Container resource limits and requests
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

postgres:
  persistence:
    enabled: true     # Enable persistent storage for PostgreSQL
    size: 1Gi        # Size of persistent volume
```

## License

This project is licensed under the Mozilla Public License 2.0.