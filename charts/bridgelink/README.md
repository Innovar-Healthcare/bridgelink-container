# bridgelink

![Version: 0.5.0](https://img.shields.io/badge/Version-0.5.0-informational?style=flat-square)
![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)
![AppVersion: 26.9.0](https://img.shields.io/badge/AppVersion-26.9.0-informational?style=flat-square)

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

> Using a WebAdmin-only (`-slim`) image? It has no bundled Swing Administrator — manage the instance
> with WebAdmin instead of the launcher below. The chart can deploy it for you, pointed at this
> release's BridgeLink service:
>
> ```bash
> helm install bridgelink bridgelink/bridgelink \
>   --set webadmin.enabled=true --set webadmin.acceptLicense=true
> ```
>
> `webadmin.acceptLicense` records that you have read and accept the WebAdmin license (Business
> Source License 1.1 plus the BridgeLink WebAdmin Supplemental Terms). The chart will not set it for
> you, and refuses to install WebAdmin without it. WebAdmin then listens on port 8444; the install
> notes print its URL.

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

## Replicas and upgrades

The chart runs **one** BridgeLink pod. `bridgelink.replicaCount` accepts only `0` or `1`: more than one
active node needs the Channel Coordinator plugin and a separate server ID per pod, which this chart
does not set up.

Both the BridgeLink and the bundled PostgreSQL Deployments use `strategy: Recreate`, so `helm upgrade`
stops the old pod before starting the new one. Expect a short outage during an upgrade. That is
deliberate: a rolling update would briefly run two engines against the same database, and polling
channels (File, Database and SFTP readers) could process the same work twice.

## Database

The bundled PostgreSQL (`postgres.enabled: true`, the default) is for **evaluation only**. It runs as a
single pod on one zone-bound volume with no backups. For production, set `postgres.enabled: false` and
use an external database such as Amazon RDS. The bundled instance requires a password for every TCP
connection (`scram-sha-256`).

To use an external database, disable the bundled one and set the connection under
`bridgelink.environment`. The URL is passed to BridgeLink unchanged, so any JDBC scheme, port and
parameters work. The one exception is a value containing `{{`, which is rendered as a Helm template:

```yaml
postgres:
  enabled: false
bridgelink:
  environment:
    MP_DATABASE: postgres
    MP_DATABASE_URL: "jdbc:postgresql://<rds-endpoint>:5432/bridgelinkdb?sslmode=require"
    MP_DATABASE_USERNAME: bridgelink
    MP_DATABASE_PASSWORD: "<password>"
```

With `postgres.enabled: false` and no `MP_DATABASE_URL`, the install fails with a message saying so.
For the embedded Derby database instead, set `MP_DATABASE: derby` and `postgres.enabled: false`.

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

## Upgrading

**Chart 0.5.0** changes four things an existing release can notice:

- **Database settings in `bridgelink.environment` are now used.** Earlier versions ignored
  `MP_DATABASE_URL`, `MP_DATABASE_USERNAME` and `MP_DATABASE_PASSWORD` and always connected to the
  bundled PostgreSQL. If you set them to an external database, BridgeLink now connects there on
  upgrade, and the bundled PostgreSQL holding your existing data keeps running untouched. Remove the
  three keys to stay on the bundled database. A values file copied from an older `values.yaml` still
  carries the old `{{ ... }}` placeholder defaults; those keep resolving to the bundled
  database, but you can delete them.
- **The bundled PostgreSQL requires a password for TCP connections.** The upgrade restarts it once so
  the new rule takes effect. PostgreSQL applies
  `postgres.credentials.password` only when it first creates its data volume. If you changed that
  value after installing, the database still has the original password, and BridgeLink is now refused.
  Set the database password to match your values (the local socket needs no password):
  `kubectl exec $(kubectl get pod -l app=postgres,app.kubernetes.io/instance=<release> -o name) -- psql -U <username> -d <database> -c "ALTER USER <username> PASSWORD '<password>'"`
- **`bridgelink.replicaCount` must be the integer `0` or `1`.** Higher values, and quoted strings such
  as `"1"`, are rejected by the schema.
- **Upgrades use `strategy: Recreate`**, so expect a short outage while the old pod stops and the new
  one starts.

**Bundled PostgreSQL default moved from `14-alpine` to `16-alpine` (chart 0.2.0).** PostgreSQL does
not upgrade its on-disk data directory across major versions automatically, so an existing release
that used the bundled PostgreSQL 14 will **crash-loop** if simply upgraded to the 16 image against the
old PVC (`FATAL: database files are incompatible with server`). For existing installs, either:

- **Stay on 14** — pin the old image: `--set postgres.image.tag=14-alpine`, or
- **Migrate the data** — `pg_dumpall` from 14, then restore into a fresh 16 volume, then upgrade.

Fresh installs are unaffected. If you use an external database (`postgres.enabled=false`), this does
not apply.

## Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| bridgelink.affinity | object | `{}` | Pod affinity for BridgeLink |
| bridgelink.environment.MP_CONFIGURATIONMAP_LOCATION | string | `"database"` | Configuration map location |
| bridgelink.environment.MP_DATABASE | string | `"postgres"` | Database type (postgres, mysql, oracle, sqlserver) |
| bridgelink.environment.MP_DATABASE_PASSWORD | string | `""` | Database password. Leave empty to use `postgres.credentials.password` with the bundled PostgreSQL. |
| bridgelink.environment.MP_DATABASE_URL | string | `""` | JDBC URL of the database, passed through unchanged, so any scheme, port and parameters work (for Amazon RDS, e.g. `jdbc:postgresql://<endpoint>:5432/bridgelinkdb?sslmode=require`). A value containing `{{` is rendered as a Helm template, as are the username and password below. Leave empty to use the bundled PostgreSQL. Required when `postgres.enabled` is false. For the embedded Derby database instead, set `MP_DATABASE: derby` and `postgres.enabled: false` and leave this empty. |
| bridgelink.environment.MP_DATABASE_USERNAME | string | `""` | Database username. Leave empty to use `postgres.credentials.username` with the bundled PostgreSQL. |
| bridgelink.environment.MP_KEYSTORE_KEYPASS | string | `"bridgelinkKeystore"` | Keystore key password |
| bridgelink.environment.MP_KEYSTORE_STOREPASS | string | `"bridgelinkKeypass"` | Keystore store password |
| bridgelink.environment.SERVER_ID | string | `"7d760af2-680a-4a19-b9a2-c4685df61ebc"` | Unique server identifier |
| bridgelink.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| bridgelink.image.repository | string | `"innovarhealthcare/bridgelink"` | BridgeLink container image repository |
| bridgelink.image.tag | string | `"26.9.0"` | BridgeLink container image tag. Defaults to the Rocky image. For the hardened (DHI) image set `tag: 26.9.0-dhi` and `runAsUser: 65532` / `runAsGroup: 65532` (see below). |
| bridgelink.livenessProbe | object | `{"failureThreshold":3,"httpGet":{"httpHeaders":[{"name":"X-Requested-With","value":"kube-probe"}],"path":"/api/server/version","port":"https","scheme":"HTTPS"},"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe. Enabled by default: it is a plain HTTPS GET and works against any image. Restarts the pod only when the API stops answering at all.  Deliberately /api/server/version, NOT /api/server/status. When the database goes away, getStatus() calls isDatabaseRunning() -> testDatabase(), which blocks on the connection pool, so /status does not return UNAVAILABLE — it HANGS (measured: no response in 10s, while /version answered 200 in 73ms on the same server; tracked as a Core defect). A liveness probe pointed at /status would therefore time out and restart the pod after failureThreshold x periodSeconds of any database outage, which is exactly what liveness must not do: a restart does not fix a database. /version reads an in-memory value and needs no authentication (@DontCheckAuthorized), so it answers iff the JVM and Jetty are actually serving.  kubelet does not verify the certificate on an HTTPS probe, so the self-signed keystore needs no configuration. The X-Requested-With header is required (server.api.require-requested-with, default true) — without it the endpoint returns HTTP 400 even though it needs no authentication. |
| bridgelink.nodeSelector | object | `{}` | Node selector for BridgeLink pods |
| bridgelink.readinessProbe | string | `nil` | Readiness probe. Disabled by default for the same reason as startupProbe; see above. Note that until you enable it, a pod is considered Ready as soon as its container is running, which means Service traffic can reach BridgeLink while the engine is still deploying channels. |
| bridgelink.replicaCount | int | `1` | Number of BridgeLink pods: 0 or 1. The schema rejects anything higher, because more than one active node needs the Channel Coordinator plugin and a server ID per pod, which this chart does not set up. Upgrades stop the old pod before starting the new one (`strategy: Recreate`). |
| bridgelink.resources.limits.cpu | string | `"2000m"` | CPU limit for BridgeLink pods |
| bridgelink.resources.limits.memory | string | `"2Gi"` | Memory limit for BridgeLink pods |
| bridgelink.resources.requests.cpu | string | `"500m"` | CPU request for BridgeLink pods |
| bridgelink.resources.requests.memory | string | `"1Gi"` | Memory request for BridgeLink pods |
| bridgelink.runAsGroup | int | `1000` | Non-root GID the container runs as (see runAsUser). 1000 for Rocky, 65532 for DHI. |
| bridgelink.runAsUser | int | `1000` | Non-root UID the container runs as. Use 1000 for the Rocky image, 65532 for the hardened (DHI) image. Must match the image so mounted appdata/custom-extensions are writable. |
| bridgelink.service.ports.http | int | `8080` | HTTP port for web interface |
| bridgelink.service.ports.https | int | `8443` | HTTPS port for secure web interface |
| bridgelink.service.type | string | `"LoadBalancer"` | Service type for BridgeLink (LoadBalancer, ClusterIP, NodePort) |
| bridgelink.startupProbe | string | `nil` | Startup probe. Disabled by default because it needs an image carrying the probe binary — see the block above for the values to paste in once it does. |
| bridgelink.tolerations | list | `[]` | Pod tolerations for BridgeLink |
| fullnameOverride | string | `""` | Provide a name to substitute for the full names of resources |
| nameOverride | string | `""` | Override the name of the chart |
| postgres.credentials.database | string | `"bridgelinkdb"` | PostgreSQL database name |
| postgres.credentials.password | string | `"bridgelinktest"` | PostgreSQL password |
| postgres.credentials.username | string | `"bridgelinktest"` | PostgreSQL username |
| postgres.enabled | bool | `true` | Deploy a bundled PostgreSQL for evaluation. It is a single pod on one zone-bound volume with no backups, so it is not suitable for production. For production set this to false and point BridgeLink at an external database such as Amazon RDS. TCP connections require a password. |
| postgres.image.pullPolicy | string | `"IfNotPresent"` | PostgreSQL image pull policy |
| postgres.image.repository | string | `"postgres"` | PostgreSQL image repository |
| postgres.image.tag | string | `"16-alpine"` | PostgreSQL image tag (kept in sync with docker-compose.yml) |
| postgres.persistence.enabled | bool | `true` | Enable PostgreSQL persistence |
| postgres.persistence.size | string | `"10Gi"` | PostgreSQL storage size |
| postgres.persistence.storageClass | string | `""` | Storage class for PostgreSQL (empty uses cluster default) |
| postgres.resources.limits.cpu | string | `"1000m"` | PostgreSQL CPU limit |
| postgres.resources.limits.memory | string | `"1Gi"` | PostgreSQL memory limit |
| postgres.resources.requests.cpu | string | `"200m"` | PostgreSQL CPU request |
| postgres.resources.requests.memory | string | `"256Mi"` | PostgreSQL memory request |
| postgres.service.port | int | `5432` | PostgreSQL port number |
| webadmin.acceptLicense | bool | `false` | Accept the WebAdmin license: the Business Source License 1.1 plus the BridgeLink WebAdmin Supplemental Terms. Read them with `docker run --rm --entrypoint cat <image> /app/LICENSE /app/SUPPLEMENTAL-TERMS.md`, using the image set under `image:` below; the install error prints the exact command. The chart never accepts them for you: with `enabled: true` and this left false, `helm install` fails with an explanation instead of starting a container that would exit without running. |
| webadmin.affinity | object | `{}` | Pod affinity for WebAdmin |
| webadmin.containerPort | int | `8444` | Port WebAdmin listens on (HTTPS). 8444 is WebAdmin's documented default. It is passed to the container as `PORT`, because the image's built-in config still says 3000. |
| webadmin.enabled | bool | `false` | Deploy WebAdmin, the browser-based administrator, alongside BridgeLink. It is pointed at this release's BridgeLink Service automatically. Requires `acceptLicense` as well. |
| webadmin.env | object | `{}` | Extra environment variables for WebAdmin, e.g. `BRIDGELINK_PUBLIC_HOST` or `COOKIE_SECURE`. `BRIDGELINK_SERVER_URL`, `PORT` and `BL_ACCEPT_LICENSE` are set by the chart and ignored here. |
| webadmin.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| webadmin.image.repository | string | `"innovarhealthcare/bridgelink-webadmin"` | WebAdmin container image repository |
| webadmin.image.tag | string | `"26.9.0"` | WebAdmin container image tag. WebAdmin is released separately from BridgeLink, and 26.9.0 is the newest WebAdmin release for the 26.9 line. Bump it together with `bridgelink.image.tag`. |
| webadmin.livenessProbe | object | `{"failureThreshold":3,"periodSeconds":20,"tcpSocket":{"port":"https"},"timeoutSeconds":5}` | Liveness probe for WebAdmin. The image has no health endpoint, so this checks the port. |
| webadmin.nodeSelector | object | `{}` | Node selector for WebAdmin pods |
| webadmin.readinessProbe | object | `{"failureThreshold":3,"initialDelaySeconds":5,"periodSeconds":10,"tcpSocket":{"port":"https"},"timeoutSeconds":5}` | Readiness probe for WebAdmin. The image has no health endpoint, so this checks the port. |
| webadmin.resources.limits.cpu | string | `"500m"` | CPU limit for WebAdmin pods |
| webadmin.resources.limits.memory | string | `"512Mi"` | Memory limit for WebAdmin pods |
| webadmin.resources.requests.cpu | string | `"100m"` | CPU request for WebAdmin pods |
| webadmin.resources.requests.memory | string | `"256Mi"` | Memory request for WebAdmin pods |
| webadmin.service.port | int | `8444` | Service port for WebAdmin |
| webadmin.service.type | string | `"LoadBalancer"` | Service type for WebAdmin (LoadBalancer, ClusterIP, NodePort) |
| webadmin.tolerations | list | `[]` | Pod tolerations for WebAdmin |

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