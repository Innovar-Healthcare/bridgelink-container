# bridgelink

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 4.5.4](https://img.shields.io/badge/AppVersion-4.5.4-informational?style=flat-square)

A Helm chart for BridgeLink deployment

**Homepage:** <https://github.com/Innovar-Healthcare/bridgelink-container>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| InnovaCare Healthcare |  |  |

## Source Code

* <https://github.com/Innovar-Healthcare/bridgelink-container>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| bridgelink | object | `{"affinity":{},"environment":{"MP_CONFIGURATIONMAP_LOCATION":"database","MP_DATABASE":"postgres","MP_DATABASE_PASSWORD":"bridgelinktest","MP_DATABASE_URL":"jdbc:postgresql://postgres:5432/bridgelinkdb","MP_DATABASE_USERNAME":"bridgelinktest","MP_KEYSTORE_KEYPASS":"bridgelinkKeystore","MP_KEYSTORE_STOREPASS":"bridgelinkKeypass","SERVER_ID":"7d760af2-680a-4a19-b9a2-c4685df61ebc"},"image":{"pullPolicy":"IfNotPresent","repository":"innovarhealthcare/bridgelink","tag":"4.5.4"},"nodeSelector":{},"replicaCount":1,"resources":{"limits":{"cpu":"2000m","memory":"2Gi"},"requests":{"cpu":"500m","memory":"1Gi"}},"service":{"ports":{"http":8080,"https":8443},"type":"LoadBalancer"},"tolerations":[]}` | BridgeLink Helm chart configuration @section Global Settings |
| bridgelink.affinity | object | `{}` | Affinity for pod assignment |
| bridgelink.environment | object | See below | Environment variables for BridgeLink configuration |
| bridgelink.environment.MP_CONFIGURATIONMAP_LOCATION | string | `"database"` | Configuration map storage location |
| bridgelink.environment.MP_DATABASE | string | `"postgres"` | Database type to use (postgres, mysql, oracle, sqlserver) |
| bridgelink.environment.MP_DATABASE_PASSWORD | string | `"bridgelinktest"` | Database password for authentication |
| bridgelink.environment.MP_DATABASE_URL | string | `"jdbc:postgresql://postgres:5432/bridgelinkdb"` | JDBC URL for database connection |
| bridgelink.environment.MP_DATABASE_USERNAME | string | `"bridgelinktest"` | Database username for authentication |
| bridgelink.environment.MP_KEYSTORE_KEYPASS | string | `"bridgelinkKeystore"` | Keystore key password for TLS |
| bridgelink.environment.MP_KEYSTORE_STOREPASS | string | `"bridgelinkKeypass"` | Keystore store password for TLS |
| bridgelink.environment.SERVER_ID | string | `"7d760af2-680a-4a19-b9a2-c4685df61ebc"` | Unique server identifier |
| bridgelink.image.pullPolicy | string | `IfNotPresent` | Image pull policy |
| bridgelink.image.repository | string | `innovarhealthcare/bridgelink` | BridgeLink container image repository |
| bridgelink.image.tag | string | Chart appVersion | BridgeLink container image tag |
| bridgelink.nodeSelector | object | `{}` | Node labels for pod assignment |
| bridgelink.replicaCount | int | `1` | Number of BridgeLink pods to run |
| bridgelink.resources | object | See below | Resource limits and requests for the BridgeLink container |
| bridgelink.resources.limits.cpu | string | `"2000m"` | CPU limit for BridgeLink container |
| bridgelink.resources.limits.memory | string | `"2Gi"` | Memory limit for BridgeLink container |
| bridgelink.resources.requests.cpu | string | `"500m"` | CPU request for BridgeLink container |
| bridgelink.resources.requests.memory | string | `"1Gi"` | Memory request for BridgeLink container |
| bridgelink.service.ports.http | int | 8080 | HTTP port for BridgeLink web interface |
| bridgelink.service.ports.https | int | 8443 | HTTPS port for BridgeLink secure web interface |
| bridgelink.service.type | string | `LoadBalancer` | Kubernetes Service type |
| bridgelink.tolerations | list | `[]` | Tolerations for pod assignment |
| fullnameOverride | string | `""` | Provide a name to substitute for the full names of resources |
| nameOverride | string | `""` | Override the name of the chart |
| postgres.credentials | object | `{"database":"bridgelinkdb","password":"bridgelinktest","username":"bridgelinktest"}` | PostgreSQL database credentials |
| postgres.credentials.database | string | `"bridgelinkdb"` | PostgreSQL database name |
| postgres.credentials.password | string | `"bridgelinktest"` | PostgreSQL password |
| postgres.credentials.username | string | `"bridgelinktest"` | PostgreSQL username |
| postgres.enabled | bool | `true` | Enable bundled PostgreSQL deployment Set to false to use external database |
| postgres.image.pullPolicy | string | `"IfNotPresent"` | PostgreSQL image pull policy |
| postgres.image.repository | string | `"postgres"` | PostgreSQL container image repository |
| postgres.image.tag | string | `"14-alpine"` | PostgreSQL container image tag |
| postgres.persistence.enabled | bool | `true` | Enable persistent storage for PostgreSQL data |
| postgres.persistence.size | string | `"10Gi"` | Size of the persistent volume claim |
| postgres.persistence.storageClass | string | "" (use default storage class) | Storage class for PostgreSQL PVC |
| postgres.resources | object | `{"limits":{"cpu":"1000m","memory":"1Gi"},"requests":{"cpu":"200m","memory":"256Mi"}}` | Resource limits and requests for PostgreSQL container |
| postgres.resources.limits.cpu | string | `"1000m"` | CPU limit for PostgreSQL container |
| postgres.resources.limits.memory | string | `"1Gi"` | Memory limit for PostgreSQL container |
| postgres.resources.requests.cpu | string | `"200m"` | CPU request for PostgreSQL container |
| postgres.resources.requests.memory | string | `"256Mi"` | Memory request for PostgreSQL container |
| postgres.service.port | int | `5432` | PostgreSQL service port number |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
