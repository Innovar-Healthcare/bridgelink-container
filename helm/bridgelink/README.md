# BridgeLink Helm Chart

This Helm chart deploys BridgeLink 4.5.4 and its required PostgreSQL database in Kubernetes.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- PV provisioner support in the underlying infrastructure (if persistence is enabled)

## Installing the Chart

To install the chart with the release name `bridgelink`:

```bash
helm install bridgelink ./helm/bridgelink
```

## Configuration

The following table lists the configurable parameters of the BridgeLink chart and their default values.

### BridgeLink Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `bridgelink.image.repository` | BridgeLink image repository | `innovarhealthcare/bridgelink` |
| `bridgelink.image.tag` | BridgeLink image tag | `4.5.4` |
| `bridgelink.service.type` | Service type | `ClusterIP` |
| `bridgelink.service.port` | Service port | `8443` |
| `bridgelink.resources` | CPU/Memory resource requests/limits | See values.yaml |
| `bridgelink.environment` | Environment variables for BridgeLink | See values.yaml |

### PostgreSQL Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `postgres.enabled` | Deploy PostgreSQL | `true` |
| `postgres.image.repository` | PostgreSQL image repository | `postgres` |
| `postgres.image.tag` | PostgreSQL image tag | `14-alpine` |
| `postgres.persistence.enabled` | Enable persistence for PostgreSQL | `true` |
| `postgres.persistence.size` | PVC size for PostgreSQL | `10Gi` |
| `postgres.credentials` | PostgreSQL credentials | See values.yaml |

## Usage

1. Modify the values.yaml file to suit your environment
2. Install the chart:
   ```bash
   helm install bridgelink ./helm/bridgelink
   ```
3. Access BridgeLink at https://your-cluster:8443

## Persistence

The PostgreSQL database can be persisted by enabling persistence in values.yaml. This will create a PVC for the database.