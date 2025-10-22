# BridgeLink Container & Helm Chart

![BridgeLink Icon](https://avatars.githubusercontent.com/u/116584698)

This repository contains both the Helm chart for deploying BridgeLink and its associated Docker container configuration.

## Repository Structure

```
.
├── charts/                 # Helm charts directory
│   └── bridgelink/        # Main BridgeLink Helm chart
│       ├── Chart.yaml     # Chart metadata
│       ├── values.yaml    # Default configuration
│       └── templates/     # Kubernetes manifest templates
├── docker/                # Docker container configuration
│   ├── Dockerfile
│   └── docker-compose.yml
├── scripts/              # Deployment and utility scripts
│   └── deploy-minikube.sh
└── docs/                # Documentation
    └── development.md
```

## Quick Start

### Local Development

Deploy to Minikube:
```bash
./scripts/deploy-minikube.sh
```

### Production Deployment

Install using Helm:
```bash
helm install bridgelink ./charts/bridgelink
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
helm template ./charts/bridgelink
helm lint ./charts/bridgelink
```

## Configuration

See [charts/bridgelink/values.yaml](charts/bridgelink/values.yaml) for all available configuration options.

## License

This project is licensed under the Mozilla Public License 2.0.