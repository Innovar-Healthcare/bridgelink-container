# bridgelink

![Version: 0.9.2](https://img.shields.io/badge/Version-0.9.2-informational?style=flat-square)
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
* Helm 3.8+ (the first release with OCI registry support turned on by default)
* PV provisioner support in the underlying infrastructure (for appdata and PostgreSQL persistence)
* TLS certificates for secure communication (optional)

## Installing the Chart

The chart is published as an OCI package on GitHub Container Registry. To install it with the
release name `bridgelink`:

```bash
# Generate a server ID once, and record it: BridgeLink licenses are issued against it
SERVER_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "$SERVER_ID"

# Install the chart
helm install bridgelink oci://ghcr.io/innovar-healthcare/charts/bridgelink --version 0.9.2 \
  --set-string bridgelink.environment.SERVER_ID="$SERVER_ID"
```

There is no `helm repo add` step: Helm pulls an OCI chart directly by its reference. Always pass
`--version`, on upgrades too, so a release changes only when you choose to move it. In Argo CD or
Flux, pin the same version. Published versions are never replaced, and the available versions are
listed on the package's page on GitHub.

A new install without `bridgelink.environment.SERVER_ID` fails, and the error prints a freshly
generated ID you can use. See [Server ID](#server-id) before choosing one.

For a custom configuration, keep the ID in your values file with the rest of the settings, so every
later `helm upgrade` passes it again:

```yaml
bridgelink:
  environment:
    SERVER_ID: "<your server ID>"
```

```bash
helm install bridgelink oci://ghcr.io/innovar-healthcare/charts/bridgelink --version 0.9.2 -f values.yaml
```

### From a checkout

To install the chart from a clone of this repository, for example to test a change to it, use the
chart directory in place of the OCI reference:

```bash
helm install bridgelink charts/bridgelink --set-string bridgelink.environment.SERVER_ID="$SERVER_ID"
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
> helm install bridgelink oci://ghcr.io/innovar-healthcare/charts/bridgelink --version 0.9.2 \
>   --set-string bridgelink.environment.SERVER_ID="$SERVER_ID" \
>   --set webadmin.enabled=true --set webadmin.acceptLicense=true
> ```
>
> `webadmin.acceptLicense` records that you have read and accept the WebAdmin license (Business
> Source License 1.1 plus the BridgeLink WebAdmin Supplemental Terms). The chart will not set it for
> you, and refuses to install WebAdmin without it. WebAdmin then listens on port 8444; the install
> notes print its URL.

1. Download and install [BridgeLink Administrator Launcher](https://www.innovarhealthcare.com/bridgelink-downloads#comp-mg0zikp4)

2. Once the deployment is complete, reach the server. The Service is `ClusterIP` by default, so
   forward a local port to it (or see [Exposing BridgeLink](#exposing-bridgelink) for a load
   balancer):
   ```bash
   kubectl port-forward -n <namespace> svc/bridgelink-bl 8443:8443
   ```

3. Launch the BridgeLink Administrator and configure:
   - Server URL: `https://127.0.0.1:8443`, or the load balancer address if you set one
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

3. **Pod Security**: BridgeLink and WebAdmin meet the Kubernetes "restricted" Pod Security
   Standard. See [Pod Security](#pod-security).

4. **Network exposure**: the BridgeLink and WebAdmin Services are `ClusterIP` by default, so the
   admin API is not reachable from outside the cluster until you choose how. See
   [Exposing BridgeLink](#exposing-bridgelink).

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

## Exposing BridgeLink

The BridgeLink Service (`<release>-bridgelink-bl`, ports 8443 and 8080) and the WebAdmin Service
are `ClusterIP` by default: reachable inside the cluster and through `kubectl port-forward`, not
from outside. A plain `type: LoadBalancer` on EKS without the AWS Load Balancer Controller creates
an internet-facing Classic ELB, so choose the load balancer deliberately.

An internal Network Load Balancer on EKS, with the
[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
installed:

```yaml
bridgelink:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-scheme: internal
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    loadBalancerSourceRanges: [10.0.0.0/8]
    ports:
      http: null   # leave plain HTTP off the load balancer
```

`loadBalancerSourceRanges` limits which client addresses may connect. `loadBalancerClass` (for
example `service.k8s.aws/nlb`) is the other way to hand the Service to the controller. Both are used
only when `type` is `LoadBalancer`. Kubernetes accepts `loadBalancerClass` only when the load
balancer is created: on a Service that is already a `LoadBalancer`, adding or changing it fails the
upgrade with `may not change once set`. Upgrade once with `type: ClusterIP`, which deletes the load
balancer and its address, then set the class with `type: LoadBalancer`. The `webadmin.service` block takes the same settings. The
install notes print the load balancer address; AWS reports a hostname rather than an IP.

### Channel listener ports

A channel that listens for inbound traffic (MLLP, HTTP, TCP) needs its port on the container and on
a Service. List them in `bridgelink.extraPorts`:

```yaml
bridgelink:
  extraPorts:
    - name: mllp-adt        # lowercase, at most 15 characters
      containerPort: 6661   # the port the channel listens on
    - name: http-orders
      containerPort: 8090
      port: 80              # Service port, if different
```

They are added to the BridgeLink Service. To put them behind a different load balancer from the
admin API, for example an internal NLB for MLLP while 8443 stays `ClusterIP`, turn on the listener
Service. The ports then move to `<release>-bridgelink-listeners`:

```yaml
bridgelink:
  listenerService:
    enabled: true
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    loadBalancerSourceRanges: [10.20.0.0/16]
```

**Adding, changing or removing an extra port restarts BridgeLink**, because the ports are declared on
the pod. With `strategy: Recreate` that is a short outage, so batch port changes. A port answers only
while a deployed channel listens on it.

## Server ID

Every BridgeLink server has a server ID, set by `bridgelink.environment.SERVER_ID`. The chart has no
default: a new install without one fails, and the error prints a freshly generated ID to use.

- **Record the ID and send it to us when you request a license.** BridgeLink licenses are issued
  against the server ID.
- **Keep it for the life of the server.** Messages waiting in a queue are stored under the server ID,
  and BridgeLink recovers and sends only the ones stamped with its own ID. A server that comes back
  under a different ID leaves its queued messages unsent, and its license no longer matches.
- **Reuse it when you replace the same server**: a restore, a migration to another cluster, or a
  reinstall against the same database. Use a new ID only for a new server.
- **Never run two live servers with the same ID against one database.** Both would treat the other's
  queued messages as their own, so the same messages can be sent twice.

To keep the ID out of values, read it from a Secret with `extraEnv`, which replaces the chart's
variable of the same name:

```yaml
bridgelink:
  extraEnv:
    - name: SERVER_ID
      valueFrom:
        secretKeyRef: {name: bridgelink-server-id, key: id}
```

Before chart 0.9.0, every install shared the default ID `7d760af2-680a-4a19-b9a2-c4685df61ebc`. A
`helm upgrade` of a release that does not set an ID keeps that one, because the server already runs
as it. See [Upgrading](#upgrading).

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

To keep the password, or the whole URL, out of values, read it from a Secret with `extraEnv`. An
`extraEnv` entry replaces the variable of the same name the chart would set:

```yaml
bridgelink:
  extraEnv:
    - name: MP_DATABASE_PASSWORD
      valueFrom:
        secretKeyRef: {name: bridgelink-db, key: password}
```

`bridgelink.environment` accepts any variable the image reads, not only the ones listed in
`values.yaml`. An `MP_` variable sets the matching `mirth.properties` key (`MP_FOO_BAR` sets
`foo.bar`). Quote numbers.

With `postgres.enabled: false` and no `MP_DATABASE_URL`, the install fails with a message saying so.
For the embedded Derby database instead, set `MP_DATABASE: derby` and `postgres.enabled: false`.

## Keystore and appdata

`appdata/keystore.jks` holds the server's **data-encryption key** and its TLS certificate. A channel
with encryption on stores message content encrypted with that key, so if the keystore is lost, that
content can no longer be read. Choose one of two ways to keep it:

- **On a volume** (`bridgelink.persistence.enabled: true`, the default). appdata is a
  PersistentVolumeClaim named `<release>-bridgelink-appdata`. On EKS the default storage class gives
  an EBS volume, which is tied to one availability zone; for a volume that follows the pod across
  zones, use an EFS storage class and set its `uid` and `gid` to `bridgelink.runAsUser` and
  `runAsGroup`, because EFS ignores `fsGroup`. `existingClaim` uses a claim you created yourself.
  `helm uninstall` leaves the claim in place, so the key outlives the release; delete it yourself
  when you are sure.
- **From a Secret** (`bridgelink.keystore.existingSecret`). The Secret holds `keystore.jks`,
  `keystore.storepass` and `keystore.keypass`. An init container copies the keystore into appdata on
  every start, so the Secret always wins over what is on the volume, and it works with persistence
  off. The passwords replace `MP_KEYSTORE_STOREPASS` and `MP_KEYSTORE_KEYPASS`.
  The keystore must be one a BridgeLink server created, taken from its appdata (see below), so that
  it already holds the data-encryption key. A keystore you built with only a TLS certificate does
  not: the server adds a new key at every start, and encrypted content does not survive a restart.
  For the same reason, changes the server makes to the keystore, such as a certificate replaced from
  the Administrator, are overwritten at the next start; update the Secret instead.

With persistence off and no Secret, appdata is an emptyDir and every replaced pod starts with a new
key. The install notes warn about this.

**Back up the keystore and its passwords together.** One is useless without the other. The
passwords are `bridgelink.environment.MP_KEYSTORE_STOREPASS` and `MP_KEYSTORE_KEYPASS`, or the
Secret's. If you set both of those to empty, the image generates passwords on first start and saves
them next to the keystore in `appdata/keystore-passwords.properties`; back that file up too. Do not
change the passwords after the first start: the server cannot open its keystore with new ones.

For the volume, a snapshot (EBS snapshots or AWS Backup) captures the keystore. To copy the file
itself, which is also how you seed a Secret, read it through a pod that mounts the claim. This works
with both images and in a namespace enforcing "restricted". Use `65532` as the user for the DHI image:

```bash
NODE=$(kubectl get pod -l app=bl,app.kubernetes.io/instance=<release> -o jsonpath='{.items[0].spec.nodeName}')
kubectl run keystore-copy --image=busybox:1.37.0 --restart=Never --overrides='{"spec":{
  "nodeName":"'"$NODE"'",
  "securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"appdata","persistentVolumeClaim":{"claimName":"<release>-bridgelink-appdata"}}],
  "containers":[{"name":"copy","image":"busybox:1.37.0","command":["sleep","300"],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
    "volumeMounts":[{"name":"appdata","mountPath":"/appdata","readOnly":true}]}]}}'
kubectl wait --for=condition=Ready pod/keystore-copy
kubectl exec keystore-copy -- cat /appdata/keystore.jks > keystore.jks
kubectl delete pod keystore-copy
kubectl create secret generic bridgelink-keystore --from-file=keystore.jks \
  --from-literal=keystore.storepass='<storepass>' --from-literal=keystore.keypass='<keypass>'
```

`nodeName` places the pod next to BridgeLink, because an EBS volume attaches to one node at a time.

## Plugins

Plugins come as extension zips. At every start, the image unpacks the zips you give it into
`/opt/bridgelink/extensions`. The chart has two ways to give them, both set in values, and they can
be combined. Plugin licenses are checked against the server ID, so set it before you request a
license (see [Server ID](#server-id)).

Each zip must be built for the BridgeLink version the image runs. A zip built for another version
unpacks, then is not loaded, and the log says
`Extension "<name>" is not compatible with this version of BridgeLink and was not loaded`.

### From a download URL

List one or more URLs, separated by commas, in `EXTENSIONS_DOWNLOAD`:

```yaml
bridgelink:
  environment:
    EXTENSIONS_DOWNLOAD: "https://my-bucket.s3.amazonaws.com/my-plugin.zip?X-Amz-...,https://my-bucket.s3.amazonaws.com/other-plugin.zip?X-Amz-..."
```

- **The pod downloads the zips again at every start.** It needs outbound access to the host. From
  private EKS subnets, that means a NAT gateway, or an S3 VPC endpoint.
- **A presigned S3 URL expires.** A pod that starts after that, after a node replacement for
  example, cannot download the zip. The server still starts, without the plugin. The log line is
  `Problem with extensions download from <url>` (Rocky image) or
  `Problem with download/extract from <url>` (DHI image). To avoid this, serve the zips from a
  host you control whose URLs do not expire, or use a claim.
- `ALLOW_INSECURE: "true"` skips certificate checks for a host with a self-signed certificate. It
  applies to every download the image makes, not just plugins.

### From a claim

Put the zips on a PersistentVolumeClaim and mount it read-only at
`/opt/bridgelink/custom-extensions`:

```yaml
bridgelink:
  extraVolumes:
    - name: plugins
      persistentVolumeClaim: {claimName: bridgelink-plugins, readOnly: true}
  extraVolumeMounts:
    - name: plugins
      mountPath: /opt/bridgelink/custom-extensions
      readOnly: true
```

To create the claim and copy zips onto it, use a pod that mounts it. This works with both images
and in a namespace enforcing "restricted". Use `65532` as the user for the DHI image:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: bridgelink-plugins}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
EOF
NODE=$(kubectl get pod -l app=bl,app.kubernetes.io/instance=<release> -o jsonpath='{.items[0].spec.nodeName}')
kubectl run plugin-copy --image=busybox:1.37.0 --restart=Never --overrides='{"spec":{
  "nodeSelector":{"kubernetes.io/hostname":"'"$NODE"'"},
  "securityContext":{"runAsNonRoot":true,"runAsUser":1000,"fsGroup":1000,"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"plugins","persistentVolumeClaim":{"claimName":"bridgelink-plugins"}}],
  "containers":[{"name":"copy","image":"busybox:1.37.0","command":["sleep","300"],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
    "volumeMounts":[{"name":"plugins","mountPath":"/plugins"}]}]}}'
kubectl wait --for=condition=Ready pod/plugin-copy --timeout=3m
kubectl cp my-plugin.zip plugin-copy:/plugins/my-plugin.zip
kubectl cp other-plugin.zip plugin-copy:/plugins/other-plugin.zip
kubectl delete pod plugin-copy
```

- **A ReadWriteOnce claim lands on one node.** On EKS the default storage class gives an EBS volume,
  which is also tied to one availability zone. The pod can only run where both this claim and the
  appdata claim are. `nodeSelector` makes the copy pod create the volume next to BridgeLink, in
  appdata's zone. Use it rather than `nodeName`, which skips the scheduler, so a storage class
  that waits for the first pod (as EBS does) never creates the volume. On a new install, with no
  BridgeLink pod yet, leave `nodeSelector` out. The keystore copy pod above can use `nodeName`
  because the appdata claim already exists.
- An EFS storage class with `ReadWriteMany` avoids both limits, and lets you change the zips from
  any node. Set its `uid` and `gid` to `bridgelink.runAsUser` and `runAsGroup`, because EFS ignores
  `fsGroup`.
- **After changing the zips, restart the pod:**
  `kubectl rollout restart deployment/<release>-bridgelink-bl`. Every container starts from the
  image, so files from a removed or older zip do not stay behind.

### Checking a plugin is installed

The REST API lists every plugin the server loaded:

```bash
curl -k -u admin:<password> -H 'X-Requested-With: XMLHttpRequest' -H 'Accept: application/json' \
  https://<host>:8443/api/extensions/plugins
```

## Pod Security

The BridgeLink and WebAdmin pods meet the Kubernetes "restricted" Pod Security Standard with both
BridgeLink images (Rocky, UID 1000, and DHI, UID 65532). They run as non-root with all capabilities
dropped, no privilege escalation, and the runtime's default seccomp profile. appdata is made writable
through `fsGroup` rather than a root init container. The only helper image, used to copy a keystore
from a Secret, is pinned and set with `bridgelink.helperImage`, for example to an Amazon ECR mirror.

Each pod's security context is set in values (`podSecurityContext`, `containerSecurityContext` under
`bridgelink` and `webadmin`), so a stricter policy such as Kyverno or OPA Gatekeeper can be met
without editing templates. `readOnlyRootFilesystem` cannot be enabled: both images write their
configuration at startup.

The bundled PostgreSQL does **not** meet "restricted": the official image starts as root. It is for
evaluation only; in a restricted namespace, use an external database.

## Upgrading

**Chart 0.9.0** stops shipping a default server ID:

- **A new install must set `bridgelink.environment.SERVER_ID`.** Without it the install fails, and the
  error prints a freshly generated ID. Update install commands, scripts and GitOps applications that
  install the chart. See [Server ID](#server-id).
- **`helm upgrade` of an existing release that sets no ID keeps `7d760af2-680a-4a19-b9a2-c4685df61ebc`**,
  the default every earlier install shared. Nothing restarts. Set that ID explicitly in your values
  when convenient, so it no longer depends on how the chart is run.
- **Argo CD, and anything else that renders the chart with `helm template`, fails until the ID is
  set**, because a template render always looks like a new install. For a release that was on the
  old default, set `bridgelink.environment.SERVER_ID: 7d760af2-680a-4a19-b9a2-c4685df61ebc` in the
  application's values once. Until then the sync fails at render time and nothing in the cluster
  changes. Do not give an existing server a new ID: it strands the server's queued messages.
- **Pass the ID on every upgrade.** `helm upgrade` without `--reuse-values` resets every value you do
  not pass again. A release installed with `--set bridgelink.environment.SERVER_ID=...` and later
  upgraded without it falls back to the old default ID, and its queued messages are no longer sent.
  Keep the ID in a values file. If it happens, upgrade again with the right ID; the install notes
  print the ID each upgrade used.

**Chart 0.8.0** changes the default Service type:

- **The BridgeLink and WebAdmin Services default to `ClusterIP`**, not `LoadBalancer`. If your release
  relied on the old default, the upgrade deletes its cloud load balancer and the address goes with
  it. To keep it, set the type before upgrading:
  `--set bridgelink.service.type=LoadBalancer` (and `--set webadmin.service.type=LoadBalancer` if
  WebAdmin is on). A release that already sets the type is unaffected. No pod restarts either way,
  and the switch needs no manual step with Helm 3 or Helm 4: Kubernetes drops the node ports it had
  allocated for the load balancer.
- `bridgelink.service.type` and `webadmin.service.type` must be `ClusterIP`, `NodePort` or
  `LoadBalancer`, and `bridgelink.service.ports.http` and `https` must be unquoted numbers; the
  schema now rejects other values, such as `https: "8443"`.

**Chart 0.6.0** changes how appdata is stored and how the pods run:

- **appdata moves to a PersistentVolumeClaim** (`<release>-bridgelink-appdata`, 1Gi, default storage
  class), so the keystore now survives pod replacement. The upgrade itself still replaces the pod,
  and the keystore on the old emptyDir goes with it, as on every earlier pod replacement. To keep
  content encrypted before the upgrade readable, copy the keystore out first, put it in a Secret (see
  [Keystore and appdata](#keystore-and-appdata)), and upgrade with `keystore.existingSecret` set. On
  the Rocky image: `kubectl exec deploy/<release>-bridgelink-bl -- cat /opt/bridgelink/appdata/keystore.jks > keystore.jks`.
  To keep the old behavior, set `bridgelink.persistence.enabled: false`.
- **The pods meet the "restricted" Pod Security Standard.** The init container that ran as root from
  an unpinned `busybox` is gone; `fsGroup` makes appdata writable instead. A namespace that enforces
  "restricted" now admits BridgeLink and WebAdmin.
- **The `<release>-bridgelink-config` ConfigMap is removed.** Its `extension.properties` enabled
  extensions that are enabled by default anyway, and its copy of the keystore passwords was never
  read. Enabling or disabling an extension in the Administrator now lasts across restarts.

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
  one starts. If this upgrade fails with `spec.strategy.rollingUpdate: Forbidden: may not be specified
  when strategy type is 'Recreate'`, your tool applied it server-side: Helm 4 for a release it
  installed, Argo CD with `ServerSideApply=true`, or `kubectl apply --server-side`. Server-side apply
  cannot remove the rolling-update settings Kubernetes added to the old Deployments. Nothing restarts
  when it fails. Switch each Deployment the error names once (this restarts nothing either), then run
  the upgrade again:
  `kubectl patch deployment <name> --type=json -p='[{"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}}]'`
  With Helm you can instead rerun the upgrade with `--server-side=false`; Helm then keeps managing that
  release client-side, and `--server-side=true` once switches it back. Helm 3 and plain `kubectl apply`
  upgrade without either step.

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
| bridgelink.containerSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Security context for the BridgeLink container and the keystore init container. The defaults meet the "restricted" Pod Security Standard. `readOnlyRootFilesystem` cannot be enabled: the image writes its configuration under /opt/bridgelink at startup. |
| bridgelink.environment.MP_CONFIGURATIONMAP_LOCATION | string | `"database"` | Configuration map location |
| bridgelink.environment.MP_DATABASE | string | `"postgres"` | Database type (postgres, mysql, oracle, sqlserver) |
| bridgelink.environment.MP_DATABASE_PASSWORD | string | `""` | Database password. Leave empty to use `postgres.credentials.password` with the bundled PostgreSQL. |
| bridgelink.environment.MP_DATABASE_URL | string | `""` | JDBC URL of the database, passed through unchanged, so any scheme, port and parameters work (for Amazon RDS, e.g. `jdbc:postgresql://<endpoint>:5432/bridgelinkdb?sslmode=require`). A value containing `{{` is rendered as a Helm template, as are the username and password below. Leave empty to use the bundled PostgreSQL. Required when `postgres.enabled` is false. For the embedded Derby database instead, set `MP_DATABASE: derby` and `postgres.enabled: false` and leave this empty. |
| bridgelink.environment.MP_DATABASE_USERNAME | string | `""` | Database username. Leave empty to use `postgres.credentials.username` with the bundled PostgreSQL. |
| bridgelink.environment.MP_KEYSTORE_KEYPASS | string | `"bridgelinkKeystore"` | Keystore key password |
| bridgelink.environment.MP_KEYSTORE_STOREPASS | string | `"bridgelinkKeypass"` | Keystore store password |
| bridgelink.environment.SERVER_ID | string | `""` | Server ID, a UUID. Required on a new install: the install fails without it and prints a freshly generated one to use. Record it: BridgeLink licenses are issued against it. Keep it for the life of the server, since queued messages are recovered only under the ID that stored them, and never run two servers with the same ID against one database. An upgrade that leaves it empty keeps `7d760af2-680a-4a19-b9a2-c4685df61ebc`, the ID every install shared before chart 0.9.0. See the README's "Server ID" section. |
| bridgelink.extraEnv | list | `[]` | Extra environment variables for the BridgeLink container, as Kubernetes EnvVar entries, so `valueFrom` works (for example a password from a Secret). An entry here replaces any variable of the same name the chart sets, including `environment` and the database settings. |
| bridgelink.extraPorts | list | `[]` | Extra ports for channel listeners (MLLP, HTTP, TCP), declared on the BridgeLink container and added to the BridgeLink Service, or to the listener Service when `listenerService.enabled`. Each entry: `name` (lowercase, at most 15 characters), `containerPort` (the port the channel listens on), and optionally `port` (the Service port, default `containerPort`) and `protocol` (default TCP). Adding, changing or removing an entry changes the pod, so BridgeLink restarts on upgrade. |
| bridgelink.extraVolumeMounts | list | `[]` | Extra volume mounts for the BridgeLink container. Plugin zips are installed from `/opt/bridgelink/custom-extensions` |
| bridgelink.extraVolumes | list | `[]` | Extra volumes for the BridgeLink pod, e.g. an EFS claim for file-based channels, or a claim holding plugin zips (see Plugins in the README) |
| bridgelink.helperImage.pullPolicy | string | `"IfNotPresent"` | Helper image pull policy |
| bridgelink.helperImage.repository | string | `"busybox"` | Helper image repository. Needs `/bin/sh`, `cp` and `mv`. |
| bridgelink.helperImage.tag | string | `"1.37.0"` | Helper image tag. Pinned: a moving tag would change what runs without a chart change. |
| bridgelink.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| bridgelink.image.repository | string | `"innovarhealthcare/bridgelink"` | BridgeLink container image repository |
| bridgelink.image.tag | string | `"26.9.0"` | BridgeLink container image tag. Defaults to the Rocky image. For the hardened (DHI) image set `tag: 26.9.0-dhi` and `runAsUser: 65532` / `runAsGroup: 65532` (see below). |
| bridgelink.keystore.existingSecret | string | `""` | Name of a Secret holding a keystore and its passwords, under the keys `keystore.jks`, `keystore.storepass` and `keystore.keypass`. When set, the keystore is copied into appdata at every start (the Secret wins over what is on the volume) and the passwords replace `MP_KEYSTORE_STOREPASS` and `MP_KEYSTORE_KEYPASS`. Works with or without `persistence`. The keystore must come from a BridgeLink server's appdata, so it already holds the data-encryption key: one with only a TLS certificate gets a new key at every start. See the README. |
| bridgelink.listenerService.annotations | object | `{}` | Annotations for the listener Service (see `service.annotations`) |
| bridgelink.listenerService.enabled | bool | `false` | Create the `<release>-bridgelink-listeners` Service and move `extraPorts` onto it, off the BridgeLink Service. Requires at least one `extraPorts` entry. |
| bridgelink.listenerService.loadBalancerClass | string | `""` | Load balancer class for the listener Service. Used only when `type` is LoadBalancer. |
| bridgelink.listenerService.loadBalancerSourceRanges | list | `[]` | Client CIDRs allowed to reach the listener load balancer. Used only when `type` is LoadBalancer. |
| bridgelink.listenerService.type | string | `"ClusterIP"` | Service type for the listener Service: ClusterIP, NodePort or LoadBalancer |
| bridgelink.livenessProbe | object | `{"failureThreshold":3,"httpGet":{"httpHeaders":[{"name":"X-Requested-With","value":"kube-probe"}],"path":"/api/server/version","port":"https","scheme":"HTTPS"},"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe. Enabled by default: it is a plain HTTPS GET and works against any image. Restarts the pod only when the API stops answering at all.  Deliberately /api/server/version, NOT /api/server/status. When the database goes away, getStatus() calls isDatabaseRunning() -> testDatabase(), which blocks on the connection pool, so /status does not return UNAVAILABLE — it HANGS (measured: no response in 10s, while /version answered 200 in 73ms on the same server; tracked as a Core defect). A liveness probe pointed at /status would therefore time out and restart the pod after failureThreshold x periodSeconds of any database outage, which is exactly what liveness must not do: a restart does not fix a database. /version reads an in-memory value and needs no authentication (@DontCheckAuthorized), so it answers iff the JVM and Jetty are actually serving.  kubelet does not verify the certificate on an HTTPS probe, so the self-signed keystore needs no configuration. The X-Requested-With header is required (server.api.require-requested-with, default true) — without it the endpoint returns HTTP 400 even though it needs no authentication. |
| bridgelink.nodeSelector | object | `{}` | Node selector for BridgeLink pods |
| bridgelink.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes for the claim. `ReadWriteOnce` suits EBS; EFS also allows `ReadWriteMany`. |
| bridgelink.persistence.enabled | bool | `true` | Keep appdata on a PersistentVolumeClaim, so the keystore survives pod replacement (node drains, upgrades, Karpenter consolidation). With `false`, appdata is an emptyDir and a replaced pod starts with a new key unless `keystore.existingSecret` is set. |
| bridgelink.persistence.existingClaim | string | `""` | Use this existing PersistentVolumeClaim instead of creating one, e.g. one bound to a statically provisioned EFS volume. Used only while `enabled` is true. |
| bridgelink.persistence.size | string | `"1Gi"` | Size of the claim. The keystore is small; the embedded Derby database (`MP_DATABASE: derby`) also lives in appdata and needs more. |
| bridgelink.persistence.storageClass | string | `""` | Storage class for the claim. Empty uses the cluster default (EBS on EKS). For EFS, name an EFS storage class whose `uid` and `gid` match `runAsUser` and `runAsGroup`, since EFS ignores `fsGroup`. |
| bridgelink.podAnnotations | object | `{}` | Extra annotations for the BridgeLink pod |
| bridgelink.podLabels | object | `{}` | Extra labels for the BridgeLink pod. The chart's selector labels (`app`, `app.kubernetes.io/name`, `app.kubernetes.io/instance`) cannot be changed and are ignored here. |
| bridgelink.podSecurityContext | object | `{"fsGroupChangePolicy":"OnRootMismatch","runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. `runAsUser`, `runAsGroup` and `fsGroup` default to the two values above and can be overridden here. The defaults meet the Kubernetes "restricted" Pod Security Standard; set one of the keys below to `null` to remove it. |
| bridgelink.readinessProbe | string | `nil` | Readiness probe. Disabled by default for the same reason as startupProbe; see above. Note that until you enable it, a pod is considered Ready as soon as its container is running, which means Service traffic can reach BridgeLink while the engine is still deploying channels. |
| bridgelink.replicaCount | int | `1` | Number of BridgeLink pods: 0 or 1. The schema rejects anything higher, because more than one active node needs the Channel Coordinator plugin and a server ID per pod, which this chart does not set up. Upgrades stop the old pod before starting the new one (`strategy: Recreate`). |
| bridgelink.resources.limits.cpu | string | `"2000m"` | CPU limit for BridgeLink pods |
| bridgelink.resources.limits.memory | string | `"2Gi"` | Memory limit for BridgeLink pods |
| bridgelink.resources.requests.cpu | string | `"500m"` | CPU request for BridgeLink pods |
| bridgelink.resources.requests.memory | string | `"1Gi"` | Memory request for BridgeLink pods |
| bridgelink.runAsGroup | int | `1000` | Non-root GID the container runs as (see runAsUser). 1000 for Rocky, 65532 for DHI. Also the default `fsGroup`, which makes appdata writable without a root init container. |
| bridgelink.runAsUser | int | `1000` | Non-root UID the container runs as. Use 1000 for the Rocky image, 65532 for the hardened (DHI) image. Must match the image so mounted appdata/custom-extensions are writable. |
| bridgelink.service.annotations | object | `{}` | Annotations for the BridgeLink Service, e.g. for the AWS Load Balancer Controller: `service.beta.kubernetes.io/aws-load-balancer-type: external`, `service.beta.kubernetes.io/aws-load-balancer-scheme: internal`, `service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip`. |
| bridgelink.service.loadBalancerClass | string | `""` | Load balancer class, e.g. `service.k8s.aws/nlb` for the AWS Load Balancer Controller. Empty uses the cluster default. Used only when `type` is LoadBalancer. Kubernetes accepts it only when the load balancer is created; see the README to add or change it later. |
| bridgelink.service.loadBalancerSourceRanges | list | `[]` | Client CIDRs allowed to reach the load balancer. Used only when `type` is LoadBalancer. |
| bridgelink.service.ports.http | int | `8080` | Service port for plain HTTP. `null` leaves HTTP off the Service; the container keeps listening on 8080. |
| bridgelink.service.ports.https | int | `8443` | Service port for HTTPS (the API and the web interface) |
| bridgelink.service.type | string | `"ClusterIP"` | Service type for BridgeLink: ClusterIP, NodePort or LoadBalancer. ClusterIP keeps the admin API inside the cluster. A plain LoadBalancer on EKS without the AWS Load Balancer Controller is an internet-facing Classic ELB; see the README's "Exposing BridgeLink" section for an internal NLB. |
| bridgelink.startupProbe | string | `nil` | Startup probe. Disabled by default because it needs an image carrying the probe binary — see the block above for the values to paste in once it does. |
| bridgelink.tolerations | list | `[]` | Pod tolerations for BridgeLink |
| fullnameOverride | string | `""` | Provide a name to substitute for the full names of resources |
| imagePullSecrets | list | `[]` | Image pull secrets for every pod the chart creates (BridgeLink, WebAdmin, PostgreSQL), as a list of `{name: <secret>}`, e.g. for a private registry mirror. |
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
| serviceAccount.annotations | object | `{}` | Annotations for the created ServiceAccount, e.g. `eks.amazonaws.com/role-arn` to give BridgeLink an IAM role through IRSA. |
| serviceAccount.create | bool | `false` | Create a ServiceAccount for the BridgeLink pod. With `create: false` and no `name`, the pod uses the namespace's default ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount for the BridgeLink pod: the name to create, or an existing one to use. Empty with `create: true` uses the release's full name. |
| webadmin.acceptLicense | bool | `false` | Accept the WebAdmin license: the Business Source License 1.1 plus the BridgeLink WebAdmin Supplemental Terms. Read them with `docker run --rm --entrypoint cat <image> /app/LICENSE /app/SUPPLEMENTAL-TERMS.md`, using the image set under `image:` below; the install error prints the exact command. The chart never accepts them for you: with `enabled: true` and this left false, `helm install` fails with an explanation instead of starting a container that would exit without running. |
| webadmin.affinity | object | `{}` | Pod affinity for WebAdmin |
| webadmin.containerPort | int | `8444` | Port WebAdmin listens on (HTTPS). 8444 is WebAdmin's documented default. It is passed to the container as `PORT`, because the image's built-in config still says 3000. |
| webadmin.containerSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Security context for the WebAdmin container. `readOnlyRootFilesystem` cannot be enabled: the image writes webadmin.conf and a self-signed TLS certificate under /app at startup. |
| webadmin.enabled | bool | `false` | Deploy WebAdmin, the browser-based administrator, alongside BridgeLink. It is pointed at this release's BridgeLink Service automatically. Requires `acceptLicense` as well. |
| webadmin.env | object | `{}` | Extra environment variables for WebAdmin, e.g. `BRIDGELINK_PUBLIC_HOST` or `COOKIE_SECURE`. `BRIDGELINK_SERVER_URL`, `PORT` and `BL_ACCEPT_LICENSE` are set by the chart and ignored here. |
| webadmin.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy |
| webadmin.image.repository | string | `"innovarhealthcare/bridgelink-webadmin"` | WebAdmin container image repository |
| webadmin.image.tag | string | `"26.9.0"` | WebAdmin container image tag. WebAdmin is released separately from BridgeLink, and 26.9.0 is the newest WebAdmin release for the 26.9 line. Bump it together with `bridgelink.image.tag`. |
| webadmin.livenessProbe | object | `{"failureThreshold":3,"periodSeconds":20,"tcpSocket":{"port":"https"},"timeoutSeconds":5}` | Liveness probe for WebAdmin. The image has no health endpoint, so this checks the port. |
| webadmin.nodeSelector | object | `{}` | Node selector for WebAdmin pods |
| webadmin.podSecurityContext | object | `{"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context for WebAdmin. 1000 is the image's `node` user. The defaults meet the "restricted" Pod Security Standard. |
| webadmin.readinessProbe | object | `{"failureThreshold":3,"initialDelaySeconds":5,"periodSeconds":10,"tcpSocket":{"port":"https"},"timeoutSeconds":5}` | Readiness probe for WebAdmin. The image has no health endpoint, so this checks the port. |
| webadmin.resources.limits.cpu | string | `"500m"` | CPU limit for WebAdmin pods |
| webadmin.resources.limits.memory | string | `"512Mi"` | Memory limit for WebAdmin pods |
| webadmin.resources.requests.cpu | string | `"100m"` | CPU request for WebAdmin pods |
| webadmin.resources.requests.memory | string | `"256Mi"` | Memory request for WebAdmin pods |
| webadmin.service.annotations | object | `{}` | Annotations for the WebAdmin Service (see `bridgelink.service.annotations`) |
| webadmin.service.loadBalancerClass | string | `""` | Load balancer class for the WebAdmin Service. Used only when `type` is LoadBalancer. |
| webadmin.service.loadBalancerSourceRanges | list | `[]` | Client CIDRs allowed to reach the WebAdmin load balancer. Used only when `type` is LoadBalancer. |
| webadmin.service.port | int | `8444` | Service port for WebAdmin |
| webadmin.service.type | string | `"ClusterIP"` | Service type for WebAdmin: ClusterIP, NodePort or LoadBalancer |
| webadmin.tolerations | list | `[]` | Pod tolerations for WebAdmin |

## Environment Variables

The BridgeLink application can be configured using environment variables:

### Core Configuration
- `MP_DATABASE`: Database type (default: postgres)
- `MP_DATABASE_URL`: Database connection URL
- `MP_DATABASE_USERNAME`: Database username
- `MP_DATABASE_PASSWORD`: Database password
- `SERVER_ID`: Server ID, required on a new install; see [Server ID](#server-id)
- `EXTENSIONS_DOWNLOAD`: Comma-separated URLs of plugin zips to install at every start; see [Plugins](#plugins)

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