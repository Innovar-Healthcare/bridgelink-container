# BridgeLink Helm Chart

![BridgeLink Icon](https://avatars.githubusercontent.com/u/116584698)

A Helm chart for deploying BridgeLink on Kubernetes.

## Repository Structure

```
.
├── charts/bridgelink/     # Main Helm chart (see charts/bridgelink/README.md for details)
├── scripts/              # Test and deployment scripts
│   └── deploy-minikube.sh # Minikube test deployment script
└── minikube-values.yaml  # Default values for Minikube testing
```

## Local Testing with Minikube

The repository includes a test deployment script for Minikube that:
- Validates the Helm chart works correctly
- Sets up required Kubernetes components
- Provides a working test environment

### Prerequisites

- Minikube v1.32.0+
- Helm v3.0.0+
- kubectl

### Quick Start

```bash
./scripts/deploy-minikube.sh
```

The script will:
1. Start Minikube if not running
2. Enable and configure required addons:
   - Ingress controller
   - MetalLB load balancer
3. Deploy BridgeLink using the Helm chart
4. Wait for all components to be ready
5. Display access URLs

### Configuration

The script uses `minikube-values.yaml` for configuration. See [charts/bridgelink/README.md](charts/bridgelink/README.md) for detailed configuration options.

### Troubleshooting Test Deployment

Common issues:

1. **Pods not starting**
   ```bash
   # Check pod status
   kubectl get pods -n bridgelink
   # View pod details
   kubectl describe pod -l app.kubernetes.io/instance=bridgelink -n bridgelink
   ```

2. **No external access**
   ```bash
   # Verify MetalLB configuration
   kubectl get svc -n bridgelink
   kubectl describe svc bridgelink-bl -n bridgelink
   ```

3. **Database issues**
   ```bash
   # Check PostgreSQL status
   kubectl logs -l app.kubernetes.io/instance=bridgelink -c postgres -n bridgelink
   ```

## Production Deployment

For production deployments and configuration options, see [charts/bridgelink/README.md](charts/bridgelink/README.md).

## License

This project is licensed under the Mozilla Public License 2.0.