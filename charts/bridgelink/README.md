# bridgelink

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square)
![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)
![AppVersion: 4.5.4](https://img.shields.io/badge/AppVersion-4.5.4-informational?style=flat-square)

A Helm chart for BridgeLink deployment

**Homepage:** <https://github.com/Innovar-Healthcare/bridgelink-container>

## Overview

BridgeLink is a healthcare integration platform that facilitates seamless communication between various healthcare systems. This Helm chart provides a production-ready Kubernetes deployment of BridgeLink.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| InnovaCare Healthcare |  |  |

## Source Code

* <https://github.com/Innovar-Healthcare/bridgelink-container>

## Prerequisites

* Kubernetes 1.19+
* Helm 3.0+
* PV provisioner support in the underlying infrastructure (for PostgreSQL persistence)
* TLS certificates for secure communication (optional)

## Installing the Chart

To install the chart with the release name `bridgelink`:

```bash
# Add the BridgeLink Helm repository
helm repo add bridgelink https://innovar-healthcare.github.io/bridgelink-helm-charts
helm repo update

# Install the chart
helm install bridgelink bridgelink/bridgelink
```

For a custom configuration using a values file:

```bash
helm install bridgelink bridgelink/bridgelink -f values.yaml
```

## Uninstalling the Chart

To uninstall/delete the `bridgelink` deployment:

```bash
helm uninstall bridgelink
```

## Testing the Deployment

1. Download and install [BridgeLink Administrator Launcher](https://www.innovarhealthcare.com/bridgelink-downloads#comp-mg0zikp4)

2. Once the deployment is complete, get the service URL:
   ```bash
   kubectl get svc -n <namespace> bridgelink-bl
   ```

3. Launch the BridgeLink Administrator and configure:
   - Server URL: Use HTTPS with the external IP (e.g., https://EXTERNAL-IP:8443)
   - Username: `admin` (default)
   - Password: See instructions below for obtaining the initial password

   ```bash
   # Get the initial admin password
   kubectl get secret -n <namespace> bridgelink-secret -o jsonpath="{.data.ADMIN_PASSWORD}" | base64 -d
   ```

## Security Considerations

1. **TLS Configuration**: By default, the chart generates self-signed certificates. For production, provide your own certificates:
   ```yaml
   tls:
     enabled: true
     secretName: your-tls-secret
   ```

2. **Database Security**:
   - Use strong passwords
   - Enable SSL for database connections
   - Consider using external secrets management

3. **Pod Security**:
   - The deployment runs with a non-root user
   - Security contexts are properly configured
   - Network policies are available for configuration

## Architecture

This chart deploys BridgeLink with the following components:
- BridgeLink application server
- PostgreSQL database (optional)
- Persistent storage for data and configurations
- Service accounts and RBAC resources
- Ingress resources (optional)
- Monitoring and metrics endpoints (optional)

## High Availability

For production deployments, consider:
1. Setting up multiple replicas
2. Configuring pod anti-affinity
3. Using node selectors or taints/tolerations
4. Implementing proper backup strategies

```yaml
replicaCount: 3
podAntiAffinity:
  enabled: true
```

## Persistence

The chart supports different types of persistence:

1. **PostgreSQL Data**:
   ```yaml
   postgres:
     persistence:
       enabled: true
       size: 10Gi
       storageClass: "standard"
   ```

2. **Application Data**:
   ```yaml
   persistence:
     enabled: true
     size: 5Gi
     storageClass: "standard"
   ```

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| bridgelink.affinity | object | `{}` | Pod affinity for BridgeLink |
| bridgelink.environment.MP_CONFIGURATIONMAP_LOCATION | string | `"database"` | Configuration map location |
| bridgelink.environment.MP_DATABASE | string | `"postgres"` | Database type (postgres, mysql, oracle, sqlserver) |
| bridgelink.environment.MP_DATABASE_PASSWORD | string | `"bridgelinktest"` | Database password |
| bridgelink.environment.MP_DATABASE_URL | string | `"jdbc:postgresql://bridgelink-postgres:5432/bridgelinkdb"` | Database connection URL |
| bridgelink.environment.MP_DATABASE_USERNAME | string | `"bridgelinktest"` | Database username |
| bridgelink.environment.MP_KEYSTORE_KEYPASS | string | `"bridgelinkKeystore"` | Keystore key password |
| bridgelink.environment.MP_KEYSTORE_STOREPASS | string | `"bridgelinkKeypass"` | Keystore store password |
| bridgelink.environment.SERVER_ID | string | `"7d760af2-680a-4a19-b9a2-c4685df61ebc"` | Unique server identifier |
| bridgelink.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| bridgelink.image.repository | string | `"innovarhealthcare/bridgelink"` | BridgeLink container image repository |
| bridgelink.image.tag | string | `"4.5.4"` | BridgeLink container image tag |
| bridgelink.nodeSelector | object | `{}` | Node selector for BridgeLink pods |
| bridgelink.replicaCount | int | `1` | Number of BridgeLink replicas to deploy |
| bridgelink.resources.limits.cpu | string | `"2000m"` | CPU limit for BridgeLink pods |
| bridgelink.resources.limits.memory | string | `"2Gi"` | Memory limit for BridgeLink pods |
| bridgelink.resources.requests.cpu | string | `"500m"` | CPU request for BridgeLink pods |
| bridgelink.resources.requests.memory | string | `"1Gi"` | Memory request for BridgeLink pods |
| bridgelink.service.ports.http | int | `8080` | HTTP port for web interface |
| bridgelink.service.ports.https | int | `8443` | HTTPS port for secure web interface |
| bridgelink.service.type | string | `"LoadBalancer"` | Service type for BridgeLink (LoadBalancer, ClusterIP, NodePort) |
| bridgelink.tolerations | list | `[]` | Pod tolerations for BridgeLink |
| fullnameOverride | string | `""` | Provide a name to substitute for the full names of resources |
| nameOverride | string | `""` | Override the name of the chart |
| postgres.credentials.database | string | `"bridgelinkdb"` | PostgreSQL database name |
| postgres.credentials.password | string | `"bridgelinktest"` | PostgreSQL password |
| postgres.credentials.username | string | `"bridgelinktest"` | PostgreSQL username |
| postgres.enabled | bool | `true` | Enable PostgreSQL deployment (set to false to use external database) |
| postgres.image.pullPolicy | string | `"IfNotPresent"` | PostgreSQL image pull policy |
| postgres.image.repository | string | `"postgres"` | PostgreSQL image repository |
| postgres.image.tag | string | `"14-alpine"` | PostgreSQL image tag |
| postgres.persistence.enabled | bool | `true` | Enable PostgreSQL persistence |
| postgres.persistence.size | string | `"10Gi"` | PostgreSQL storage size |
| postgres.persistence.storageClass | string | `""` | Storage class for PostgreSQL (empty uses cluster default) |
| postgres.resources.limits.cpu | string | `"1000m"` | PostgreSQL CPU limit |
| postgres.resources.limits.memory | string | `"1Gi"` | PostgreSQL memory limit |
| postgres.resources.requests.cpu | string | `"200m"` | PostgreSQL CPU request |
| postgres.resources.requests.memory | string | `"256Mi"` | PostgreSQL memory request |
| postgres.service.port | int | `5432` | PostgreSQL port number |

## Environment Variables

The BridgeLink application can be configured using environment variables:

### Core Configuration
- `MP_DATABASE`: Database type (default: postgres)
- `MP_DATABASE_URL`: Database connection URL
- `MP_DATABASE_USERNAME`: Database username
- `MP_DATABASE_PASSWORD`: Database password
- `SERVER_ID`: Unique server identifier

### Advanced Configuration
- `JAVA_OPTS`: JVM options
- `MAX_HEAP_SIZE`: Maximum heap size
- `MIN_HEAP_SIZE`: Minimum heap size
- `DEBUG_PORT`: Remote debugging port (if enabled)
- `ENABLE_JMX`: Enable JMX monitoring
- `JMX_PORT`: JMX port number

## Monitoring

The chart can expose metrics for Prometheus:

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

## Troubleshooting

1. **Pod not starting**:
   ```bash
   kubectl describe pod -n <namespace> <pod-name>
   kubectl logs -n <namespace> <pod-name>
   ```

2. **Database connection issues**:
   - Verify credentials in the secret
   - Check network policies
   - Validate database URL

3. **Memory issues**:
   - Review JVM settings
   - Check container resource limits
   - Monitor heap usage

## Support

For support and documentation, visit:
- [Official Documentation](https://docs.innovarhealthcare.com/bridgelink)
- [GitHub Issues](https://github.com/Innovar-Healthcare/bridgelink-container/issues)
- [Community Forums](https://community.innovarhealthcare.com)

----------------------------------------------
Autogenerated from chart metadata using [helm-docs](https://github.com/norwoodj/helm-docs)