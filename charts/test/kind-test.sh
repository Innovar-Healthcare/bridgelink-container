#!/usr/bin/env bash
#
# Installs charts/bridgelink on a throwaway kind cluster and checks how it behaves at runtime.
# `helm template` in chart.yml checks what the chart renders; this checks what Kubernetes does with
# it: that BridgeLink becomes ready, that an upgrade never runs two BridgeLink pods at once, that a
# message stored encrypted stays readable after the pod is replaced (keystore on the claim, then from
# a Secret), that a channel listener on an extra port answers through the listener Service, that the
# bundled PostgreSQL really runs the config the chart ships, that no password is ever in a
# Deployment, that BridgeLink, with WebAdmin and the standard Kubernetes options set (service
# account, pull secret, passwords from a Secret of its own, extra volume), runs in a namespace
# enforcing the "restricted" Pod Security Standard against an external database,
# that the Services survive type changes on upgrade and print their load balancer
# hostname in the install notes, that a new install without a server ID is refused while an
# upgraded server keeps the ID it had, and that a plugin installs both from a download URL
# (EXTENSIONS_DOWNLOAD) and from a claim mounted at custom-extensions.
#
# Lives under charts/ rather than test/ on purpose: build-images.yml runs the full multi-arch image
# build for any change under test/**, and a chart-only change should not pay for that.
#
# Parameterized by env var:
#   KIND_CLUSTER   cluster name (default bl-chart-test). An existing cluster of that name is reused
#                  and left running; otherwise one is created and deleted at the end.
#   KEEP_CLUSTER   1 = leave a cluster this script created running, for inspection.
#   IMAGE_TAG      BridgeLink image tag to test (default: the chart's bridgelink.image.tag).
#   RUN_AS_UID     UID/GID to run BridgeLink as. Set 65532 with a -dhi IMAGE_TAG.
#   UPGRADE_FROM   git ref whose chart is installed first, then upgraded to this checkout, e.g.
#                  origin/main. Empty (default) installs this checkout and upgrades it to itself
#                  with a pod-template change, which still exercises the upgrade path.
#   UPGRADE_ARGS   extra arguments for the upgrade only, e.g. --server-side=false to follow the
#                  README's one-time step for a Helm 4 release created by a pre-Recreate chart.
#   PULL_IMAGES    1 = `docker pull` the images on the host first, so they load into kind from an
#                  authenticated host instead of being pulled anonymously by the node (CI sets it).
#
# Usage:
#   charts/test/kind-test.sh
#   UPGRADE_FROM=origin/main charts/test/kind-test.sh
#   IMAGE_TAG=26.9.0-dhi RUN_AS_UID=65532 charts/test/kind-test.sh
#
# Requires: docker, kind, kubectl, helm, git, zip. Needs about 4 GB of memory for Docker.
set -u

CLUSTER="${KIND_CLUSTER:-bl-chart-test}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
IMAGE_TAG="${IMAGE_TAG:-}"
RUN_AS_UID="${RUN_AS_UID:-}"
UPGRADE_FROM="${UPGRADE_FROM:-}"
UPGRADE_ARGS="${UPGRADE_ARGS:-}"
PULL_IMAGES="${PULL_IMAGES:-0}"
NS="bl-chart-test"
NS_R="bl-chart-test-restricted"   # labelled pod-security.kubernetes.io/enforce=restricted
TIMEOUT="10m"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHART="$REPO_ROOT/charts/bridgelink"
WORK="$(mktemp -d)"
CREATED=0
PASS=0 FAIL=0

# ---- helpers ----------------------------------------------------------------------------------
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }
k()    { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
h()    { helm --kube-context "kind-$CLUSTER" -n "$NS" "$@"; }

cleanup() {
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null
  [ -d "$WORK/from" ] && git -C "$REPO_ROOT" worktree remove --force "$WORK/from" >/dev/null 2>&1
  if [ "$CREATED" = "1" ] && [ "$KEEP_CLUSTER" != "1" ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  elif [ "$KEEP_CLUSTER" != "1" ]; then
    kubectl --context "kind-$CLUSTER" delete namespace "$NS" "$NS_R" --wait=false >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

kr()   { kubectl --context "kind-$CLUSTER" -n "$NS_R" "$@"; }
hr()   { helm --kube-context "kind-$CLUSTER" -n "$NS_R" "$@"; }

# Everything a failed run needs to be diagnosed without re-running it.
dump() {
  local ns p
  for ns in "$NS" "$NS_R"; do
    echo "---- pods in $ns"; kubectl --context "kind-$CLUSTER" -n "$ns" get pods -o wide 2>&1
    echo "---- events in $ns"
    kubectl --context "kind-$CLUSTER" -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -25
    for p in $(kubectl --context "kind-$CLUSTER" -n "$ns" get pods -o name 2>/dev/null); do
      echo "---- $p"; kubectl --context "kind-$CLUSTER" -n "$ns" logs "$p" --all-containers --tail=30 2>&1
    done
  done
}

# ---- BridgeLink REST API: forward, api, login, channel_json, message_readable ------------------
BL_NS="$NS"
BL_KUBE_CONTEXT="kind-$CLUSTER"
# shellcheck source-path=SCRIPTDIR source=lib/bl-api.sh
. "$SCRIPT_DIR/lib/bl-api.sh"

# Runs a command in a long-lived client pod, to reach the database over the pod network. Not
# `kubectl run --rm -i`: a pod that exits before kubectl attaches loses its output, which made a
# refused connection and a silent success look the same.
client() {   # <command...>
  k exec pgclient -- "$@" 2>&1
}

# A plugin with metadata only: BridgeLink lists it in /api/extensions/plugins once installed, with no
# code to run. BridgeLink loads a plugin only when its mirthVersion is the server's own version, so
# it is built for the server under test.
plugin_zip() {   # <server version> <path> <name>; writes $WORK/plugins/<path>.zip
  mkdir -p "$WORK/plugins/$2"
  cat > "$WORK/plugins/$2/plugin.xml" <<EOF
<pluginMetaData path="$2">
  <name>$3</name>
  <author>chart test</author>
  <mirthVersion>$(echo "$1" | cut -d. -f1-3)</mirthVersion>
  <pluginVersion>1.0.0</pluginVersion>
  <url></url>
  <description>Metadata-only plugin used to test plugin installation.</description>
  <serverClasses/>
  <clientClasses/>
  <libraries/>
  <apiProviders/>
</pluginMetaData>
EOF
  (cd "$WORK/plugins" && rm -f "$2.zip" && zip -qr "$2.zip" "$2")
}

for tool in docker kind kubectl helm git zip; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool"; exit 2; }
done

# Values shared by every release. The exec probes are enabled (the default image carries the probe),
# so Ready means BridgeLink reported status 0, not merely that the JVM started. ClusterIP because a
# LoadBalancer never gets an address on kind and `helm --wait` would wait for one forever. It is the
# chart default now, but older charts installed through UPGRADE_FROM default to LoadBalancer.
PROBE='["java","-XX:TieredStopAtLevel=1","-XX:+UseSerialGC","-XX:-UsePerfData","-Xmx32m","-cp","/opt/bridgelink/bootstrap","BridgeLinkHealthcheck"]'
cat > "$WORK/common.yaml" <<EOF
bridgelink:
  service:
    type: ClusterIP
  resources:
    requests:
      cpu: 250m
      memory: 1Gi
  startupProbe:
    exec:
      command: $PROBE
    periodSeconds: 10
    failureThreshold: 30
    timeoutSeconds: 5
  readinessProbe:
    exec:
      command: $PROBE
    periodSeconds: 15
    timeoutSeconds: 5
    failureThreshold: 3
EOF
SETS=()
[ -n "$IMAGE_TAG" ] && SETS+=(--set-string "bridgelink.image.tag=$IMAGE_TAG")
[ -n "$RUN_AS_UID" ] && SETS+=(--set "bridgelink.runAsUser=$RUN_AS_UID" --set "bridgelink.runAsGroup=$RUN_AS_UID")

# ---- cluster ----------------------------------------------------------------------------------
info "cluster $CLUSTER"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "  reusing existing cluster (it will be left running)"
else
  CREATED=1   # before the create, so a half-built cluster is deleted rather than reused next time
  kind create cluster --name "$CLUSTER" --wait 3m || { echo "kind create cluster failed"; exit 2; }
fi
kubectl --context "kind-$CLUSTER" delete namespace "$NS" "$NS_R" --ignore-not-found --wait=true --timeout=3m >/dev/null \
  || { echo "namespace $NS or $NS_R is stuck terminating on cluster $CLUSTER; delete it or the cluster"; exit 2; }
kubectl --context "kind-$CLUSTER" create namespace "$NS" >/dev/null
kubectl --context "kind-$CLUSTER" create namespace "$NS_R" >/dev/null
kubectl --context "kind-$CLUSTER" label namespace "$NS_R" >/dev/null \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
k run pgclient --image=postgres:16-alpine --restart=Never --command -- sleep 7200 >/dev/null

# Preload images the host already has, so the run does not depend on Docker Hub rate limits. Best
# effort: kind cannot load some multi-platform images from Docker Desktop's image store, and the
# node then pulls them itself.
# The first `    tag:` inside the top-level bridgelink: block, so a reordered values.yaml cannot
# silently preload another component's image.
BL_TAG="${IMAGE_TAG:-$(awk '/^[^ #]/ { sect = $1 } sect == "bridgelink:" && /^    tag:/ { gsub(/"/, "", $2); print $2; exit }' "$CHART/values.yaml")}"
WA_TAG="$(awk '/^[^ #]/ { sect = $1 } sect == "webadmin:" && /^    tag:/ { gsub(/"/, "", $2); print $2; exit }' "$CHART/values.yaml")"
HELPER_IMAGE="$(awk '/^  [^ #]/ { sub_ = $1 } sub_ == "helperImage:" && /^    repository:/ { r = $2 }
  sub_ == "helperImage:" && /^    tag:/ { gsub(/"/, "", $2); t = $2 } END { print r ":" t }' "$CHART/values.yaml")"
for img in "innovarhealthcare/bridgelink:$BL_TAG" "innovarhealthcare/bridgelink-webadmin:$WA_TAG" \
           postgres:16-alpine "$HELPER_IMAGE"; do
  [ "$PULL_IMAGES" = "1" ] && { docker pull -q "$img" >/dev/null || echo "  could not pull $img"; }
  if docker image inspect "$img" >/dev/null 2>&1; then
    kind load docker-image --name "$CLUSTER" "$img" >/dev/null 2>&1 \
      && echo "  preloaded $img" || echo "  could not preload $img; the node will pull it"
  fi
done

# ---- 1. install -------------------------------------------------------------------------------
FROM_CHART="$CHART"
if [ -n "$UPGRADE_FROM" ]; then
  git -C "$REPO_ROOT" worktree add --detach "$WORK/from" "$UPGRADE_FROM" >/dev/null 2>&1 \
    || { echo "cannot check out UPGRADE_FROM=$UPGRADE_FROM"; exit 2; }
  FROM_CHART="$WORK/from/charts/bridgelink"
fi
# A chart that still ships a default server ID (before 0.9.0) is installed and upgraded with none,
# the path an existing release takes, and the server must keep that default. A chart that requires
# an ID gets a fixed test ID on the install and on every upgrade of release bl.
LEGACY_ID="7d760af2-680a-4a19-b9a2-c4685df61ebc"
if helm template bl "$FROM_CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} >/dev/null 2>"$WORK/from.err"; then
  BL_ID="$LEGACY_ID" ID_SETS=()
elif grep -q "bridgelink.environment.SERVER_ID" "$WORK/from.err"; then
  BL_ID="0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d" ID_SETS=(--set-string "bridgelink.environment.SERVER_ID=$BL_ID")
else
  echo "the chart from ${UPGRADE_FROM:-this checkout} does not render:"; cat "$WORK/from.err"; exit 2
fi
info "1. install ${UPGRADE_FROM:-this checkout} with the bundled PostgreSQL"
# This checkout refuses a new release with no server ID, through `helm install` and through
# `helm upgrade --install` alike, before anything is created.
for cmd in install "upgrade --install"; do
  # shellcheck disable=SC2086  # cmd is a subcommand and its flag
  if h $cmd noid "$CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} >/dev/null 2>"$WORK/noid.err"; then
    bad "helm $cmd of a new release with no server ID succeeded"; h uninstall noid >/dev/null 2>&1
  elif grep -q "bridgelink.environment.SERVER_ID" "$WORK/noid.err" && ! h status noid >/dev/null 2>&1; then
    ok "helm $cmd of a new release with no server ID is refused, naming SERVER_ID, and records no release"
  else
    bad "helm $cmd with no server ID failed, but not as expected: $(head -c 400 "$WORK/noid.err")"
  fi
done
if h install bl "$FROM_CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} ${ID_SETS[@]+"${ID_SETS[@]}"} \
     --wait --timeout "$TIMEOUT" >/dev/null; then
  ok "release installed and BridgeLink Ready (status 0)"
else
  bad "install did not become ready"; dump; exit 1
fi

# ---- 2. upgrade -------------------------------------------------------------------------------
info "2. upgrade to this checkout, with a BridgeLink pod-template change"
# Sample BridgeLink pods and their phases twice a second for the whole upgrade. With Recreate the old
# pod reaches a terminal phase (Succeeded/Failed: every container has exited) before the new one is
# created, so at most one pod may ever be in any other phase. A Terminating pod whose phase is still
# Running counts: its JVM is shutting down and can still hold the database and poll. A terminal pod
# does not, even though its object can linger for a moment after the new pod appears.
BL_SELECTOR="app=bl,app.kubernetes.io/instance=bl"
OLD_POD="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
( while :; do
    k get pods -l "$BL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null
    echo; sleep 0.5
  done ) > "$WORK/pods.log" &
WATCH_PID=$!
# shellcheck disable=SC2086  # UPGRADE_ARGS is a list of flags
if h upgrade bl "$CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} ${ID_SETS[@]+"${ID_SETS[@]}"} $UPGRADE_ARGS \
     --set-string bridgelink.resources.requests.cpu=251m --wait --timeout "$TIMEOUT" >/dev/null; then
  ok "upgrade completed and BridgeLink Ready"
else
  bad "upgrade did not become ready"; dump
fi
kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""
NEW_POD="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
MAX="$(awk '{ n = 0; for (i = 1; i <= NF; i++) if ($i !~ /=(Succeeded|Failed)$/) n++; if (n > m) m = n } END { print m + 0 }' "$WORK/pods.log")"
LINGER="$(grep -cE '=(Succeeded|Failed)' "$WORK/pods.log")"
if [ "$NEW_POD" = "$OLD_POD" ]; then
  bad "the upgrade did not replace the BridgeLink pod, so the overlap check proves nothing"
elif [ "$MAX" -le 1 ]; then
  ok "never more than one live BridgeLink pod during the upgrade ($OLD_POD -> $NEW_POD; old pod seen terminal in $LINGER samples)"
else
  bad "$MAX live BridgeLink pods existed at once during the upgrade"; grep ' .* ' "$WORK/pods.log" | head -5
fi
# Every password reaches the pod from the chart's Secret. An upgrade from a chart that set them as
# plain values must carry them over unchanged, or the server could not open its own keystore and the
# upgrade above would not have become Ready.
REFS=""
for v in MP_DATABASE_PASSWORD MP_KEYSTORE_STOREPASS MP_KEYSTORE_KEYPASS; do
  REFS="$REFS$(k get deploy bl-bridgelink-bl -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$v\")].valueFrom.secretKeyRef.name}") "
done
[ "$REFS" = "bl-bridgelink-credentials bl-bridgelink-credentials bl-bridgelink-credentials " ] \
  && ok "the database and keystore passwords come from Secret bl-bridgelink-credentials" \
  || bad "the passwords do not all come from the chart's Secret: '$REFS'"
k get deploy -o yaml | grep -qE 'bridgelinkKeystore|bridgelinkKeypass' \
  && bad "a keystore password is in plain text in a Deployment" || ok "no keystore password in any Deployment"

# ---- 3. encrypted content survives pod replacement --------------------------------------------
info "3. a message stored encrypted is still readable after the BridgeLink pod is replaced"
# The data-encryption key exists only in appdata/keystore.jks. If appdata does not survive the pod,
# the replacement generates a new key and the message below can no longer be decrypted.
k wait --for=condition=Ready pod/pgclient --timeout=2m >/dev/null || bad "client pod not ready"
PG_DEPLOY="bl-bridgelink-postgres"
SQL_BL() { client env PGPASSWORD=bridgelinktest psql -h "$PG_DEPLOY" -U bridgelinktest -d bridgelinkdb -tAc "$1"; }
CHANNEL_ID="5f0c6a8e-3b7d-4e21-9a4c-6d2e8b1f0a77"
MARKER="kind-test-payload-$RANDOM$RANDOM"
MSG_ID=""
forward bl
CODE="$(login)"
[ "$CODE" = "200" ] && ok "logged in to the BridgeLink API" || bad "API login returned HTTP $CODE"
# After the upgrade. BridgeLink sends only queued messages stamped with its own server ID, so an
# upgrade must never change it.
GOT_ID="$(api GET /server/id | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1)"
[ "$GOT_ID" = "$BL_ID" ] && ok "the upgraded server still reports server ID $BL_ID" \
  || bad "the upgraded server reports server ID '$GOT_ID', want $BL_ID"
VERSION="$(api GET /server/version)"
channel_json "$VERSION" "$CHANNEL_ID" kind-test-encrypted > "$WORK/channel.json"
CODE="$(api POST /channels -H 'Content-Type: application/json' --data-binary @"$WORK/channel.json" -o "$WORK/out" -w '%{http_code}')"
[ "$CODE" = "200" ] || { bad "creating the channel returned HTTP $CODE"; cat "$WORK/out"; }
CODE="$(api POST "/channels/$CHANNEL_ID/_deploy" -o "$WORK/out" -w '%{http_code}')"
[ "$CODE" = "204" ] || { bad "deploying the channel returned HTTP $CODE"; cat "$WORK/out"; }
MSG_ID="$(api POST "/channels/$CHANNEL_ID/messages" -H 'Content-Type: text/plain' -H 'Accept: application/json' \
  --data-binary "$MARKER" | grep -o '[0-9][0-9]*' | head -1)"
LOCAL_ID="$(SQL_BL "select local_channel_id from d_channels where channel_id='$CHANNEL_ID'")"
if [ -z "$MSG_ID" ] || [ -z "$LOCAL_ID" ]; then
  bad "no message stored (message id '$MSG_ID', local channel id '$LOCAL_ID')"; dump
else
  # Proves the content really is encrypted at rest, so readability below depends on the key.
  ENC="$(SQL_BL "select count(*) from d_mc$LOCAL_ID where message_id=$MSG_ID and is_encrypted")"
  PLAIN="$(SQL_BL "select count(*) from d_mc$LOCAL_ID where message_id=$MSG_ID and content like '%$MARKER%'")"
  [ "${ENC:-0}" -gt 0 ] 2>/dev/null && [ "$PLAIN" = "0" ] \
    && ok "message $MSG_ID is stored encrypted ($ENC content rows, none in plain text)" \
    || bad "message $MSG_ID is not stored encrypted (encrypted rows: $ENC, plain-text rows: $PLAIN)"
  [ "$(message_readable)" -ge 1 ] && ok "message $MSG_ID reads back decrypted" \
    || bad "message $MSG_ID does not read back before any pod replacement"
fi
APPDATA="$(k get deploy bl-bridgelink-bl -o jsonpath='{.spec.template.spec.volumes[?(@.name=="appdata")].persistentVolumeClaim.claimName}')"
[ "$APPDATA" = "bl-bridgelink-appdata" ] && ok "appdata is on the claim $APPDATA" \
  || bad "appdata is not on the chart's claim (claimName '$APPDATA')"
REPLACED="$(replace_pod)"
if [ -n "$REPLACED" ]; then
  forward bl; login >/dev/null
  [ "$(message_readable)" -ge 1 ] && ok "message still readable after the pod was replaced ($REPLACED)" \
    || bad "message unreadable after the pod was replaced ($REPLACED): the keystore did not survive"
else
  bad "the BridgeLink pod was not replaced"; dump
fi

# ---- 4. keystore from a Secret ----------------------------------------------------------------
info "4. keystore supplied from a Secret, appdata back on an emptyDir"
# Read the keystore off the claim the way the README's "Keystore and appdata" section does, which
# works for both images (the DHI image has no shell or cat) and under "restricted". Keep the two in
# step: this is what tests the documented command.
NODE="$(k get pod -l "$BL_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}')"
k run ksread --image="$HELPER_IMAGE" --restart=Never --overrides='{"spec":{
  "nodeName":"'"$NODE"'",
  "securityContext":{"runAsNonRoot":true,"runAsUser":'"${RUN_AS_UID:-1000}"',"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"appdata","persistentVolumeClaim":{"claimName":"bl-bridgelink-appdata"}}],
  "containers":[{"name":"ksread","image":"'"$HELPER_IMAGE"'","command":["sleep","600"],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
    "volumeMounts":[{"name":"appdata","mountPath":"/appdata","readOnly":true}]}]}}' >/dev/null
k wait --for=condition=Ready pod/ksread --timeout=2m >/dev/null
k exec ksread -- cat /appdata/keystore.jks > "$WORK/keystore.jks"
k delete pod ksread --wait=false >/dev/null
SECRET_OF() { k get secret bl-bridgelink-credentials -o jsonpath="{.data.${1//./\\.}}" | base64 -d; }
STOREPASS="$(SECRET_OF keystore.storepass)" KEYPASS="$(SECRET_OF keystore.keypass)"
[ -n "$STOREPASS" ] && [ -n "$KEYPASS" ] || bad "could not read the keystore passwords from Secret bl-bridgelink-credentials"
k create secret generic bl-keystore >/dev/null --from-file=keystore.jks="$WORK/keystore.jks" \
  --from-literal=keystore.storepass="$STOREPASS" --from-literal=keystore.keypass="$KEYPASS"
# Step 7 uses the same keystore in the restricted namespace, with wrong passwords on purpose: the
# right ones come from credentials.existingSecret there, which must take precedence.
kr create secret generic bl-keystore >/dev/null --from-file=keystore.jks="$WORK/keystore.jks" \
  --from-literal=keystore.storepass=wrong-on-purpose --from-literal=keystore.keypass=wrong-on-purpose
[ -s "$WORK/keystore.jks" ] && ok "copied the keystore off the claim into Secret bl-keystore ($(wc -c < "$WORK/keystore.jks" | tr -d ' ') bytes)" \
  || bad "could not read the keystore off the claim"
if h upgrade bl "$CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} ${ID_SETS[@]+"${ID_SETS[@]}"} \
     --set-string bridgelink.resources.requests.cpu=251m \
     --set bridgelink.persistence.enabled=false --set bridgelink.keystore.existingSecret=bl-keystore \
     --wait --timeout "$TIMEOUT" >/dev/null; then
  ok "upgraded to keystore.existingSecret with persistence off, and BridgeLink Ready"
else
  bad "upgrade to keystore.existingSecret did not become ready"; dump
fi
EMPTY="$(k get deploy bl-bridgelink-bl -o jsonpath='{.spec.template.spec.volumes[?(@.name=="appdata")].emptyDir}')"
[ -n "$EMPTY" ] && ok "appdata is an emptyDir" || bad "appdata is not an emptyDir with persistence off"
k get pvc bl-bridgelink-appdata >/dev/null 2>&1 && ok "the appdata claim was kept when persistence was turned off" \
  || bad "the appdata claim was deleted when persistence was turned off"
POD="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
k logs "$POD" -c keystore 2>&1 | grep -q "Copied keystore.jks" && ok "the init container copied the keystore from the Secret" \
  || bad "the init container did not copy the keystore"
forward bl; login >/dev/null
[ "$(message_readable)" -ge 1 ] && ok "message readable with the keystore from the Secret" \
  || bad "message unreadable with the keystore from the Secret"
REPLACED="$(replace_pod)"
if [ -n "$REPLACED" ]; then
  forward bl; login >/dev/null
  [ "$(message_readable)" -ge 1 ] && ok "message still readable after the pod was replaced again ($REPLACED)" \
    || bad "message unreadable after replacing a pod whose keystore comes from the Secret ($REPLACED)"
else
  bad "the BridgeLink pod was not replaced"; dump
fi

# ---- 5. channel listener on an extra port ------------------------------------------------------
info "5. a channel listener on an extra port answers through the listener Service"
# An HTTP Listener channel, reached from another pod through the listener Service. A response proves
# the port is on the container and on that Service, and that the Service selects the BridgeLink pod.
LISTENER_ID="8b3e1f5a-2c4d-4e6f-9a1b-3c5d7e9f0b2d"
LISTEN_PORT=6661
LISTENER_SVC="bl-bridgelink-listeners"
if h upgrade bl "$CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} ${ID_SETS[@]+"${ID_SETS[@]}"} \
     --set-string bridgelink.resources.requests.cpu=251m \
     --set bridgelink.persistence.enabled=false --set bridgelink.keystore.existingSecret=bl-keystore \
     --set-json "bridgelink.extraPorts=[{\"name\":\"http-listen\",\"containerPort\":$LISTEN_PORT}]" \
     --set bridgelink.listenerService.enabled=true --wait --timeout "$TIMEOUT" >/dev/null; then
  ok "upgraded with an extra port on a listener Service, and BridgeLink Ready"
else
  bad "the upgrade adding an extra port did not become ready"; dump
fi
CPORTS="$(k get deploy bl-bridgelink-bl -o jsonpath='{.spec.template.spec.containers[0].ports[*].containerPort}')"
LPORTS="$(k get svc "$LISTENER_SVC" -o jsonpath='{.spec.ports[*].port}' 2>&1)"
MPORTS="$(k get svc bl-bridgelink-bl -o jsonpath='{.spec.ports[*].port}')"
[[ " $CPORTS " == *" $LISTEN_PORT "* ]] && [ "$LPORTS" = "$LISTEN_PORT" ] && [[ " $MPORTS " != *" $LISTEN_PORT "* ]] \
  && ok "port $LISTEN_PORT is on the container and on the listener Service, not the BridgeLink Service" \
  || bad "port $LISTEN_PORT: container [$CPORTS], listener Service [$LPORTS], BridgeLink Service [$MPORTS]"
forward bl; login >/dev/null
channel_json "$VERSION" "$LISTENER_ID" kind-test-listener "$LISTEN_PORT" > "$WORK/listener.json"
CODE="$(api POST /channels -H 'Content-Type: application/json' --data-binary @"$WORK/listener.json" -o "$WORK/out" -w '%{http_code}')"
[ "$CODE" = "200" ] || { bad "creating the listener channel returned HTTP $CODE"; cat "$WORK/out"; }
CODE="$(api POST "/channels/$LISTENER_ID/_deploy" -o "$WORK/out" -w '%{http_code}')"
[ "$CODE" = "204" ] || { bad "deploying the listener channel returned HTTP $CODE"; cat "$WORK/out"; }
LMARK="kind-test-listener-$RANDOM$RANDOM"
for i in $(seq 1 15); do   # the listener can start a moment after the deploy call returns
  OUT="$(client wget -S -O /dev/null --post-data="$LMARK" --header='Content-Type: text/plain' "http://$LISTENER_SVC:$LISTEN_PORT/")"
  case "$OUT" in *"HTTP/1.1 200"*) break ;; esac
  sleep 2
done
case "$OUT" in
  *"HTTP/1.1 200"*) ok "the listener answered HTTP 200 through $LISTENER_SVC:$LISTEN_PORT" ;;
  *) bad "no HTTP 200 from the listener through $LISTENER_SVC:$LISTEN_PORT: $OUT" ;;
esac
# By id, as message_readable does: the channel stores content encrypted and the search endpoint does
# not return it decrypted. The first message on a new channel is 1.
GOT="$(api GET "/channels/$LISTENER_ID/messages/1" -H 'Accept: application/json' | grep -c "$LMARK")"
[ "${GOT:-0}" -ge 1 ] && ok "the listener channel received the message" \
  || bad "the message sent through the listener Service is not in the channel"
kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; PF_PID=""

# ---- 6. bundled PostgreSQL --------------------------------------------------------------------
info "6. bundled PostgreSQL"
APP_LABEL="$(k get deploy "$PG_DEPLOY" -o jsonpath='{.metadata.labels.app}')"
[ "$APP_LABEL" = "postgres" ] && ok "Postgres Deployment is labelled app=postgres" \
  || bad "Postgres Deployment is labelled app=$APP_LABEL"
# The config files are subPath mounts, which a running container never refreshes. What matters is
# what the running Postgres reads, so compare the file in the container with the ConfigMap.
LIVE="$(k exec "deploy/$PG_DEPLOY" -- cat /etc/postgresql/pg_hba.conf 2>&1)"
WANT="$(k get configmap bl-bridgelink-postgres-config -o jsonpath='{.data.pg_hba\.conf}')"
[ "$LIVE" = "$WANT" ] && ok "running Postgres uses the pg_hba.conf the chart ships" \
  || { bad "running Postgres pg_hba.conf differs from the ConfigMap"; echo "$LIVE"; }
OUT="$(client psql -w -h "$PG_DEPLOY" -U bridgelinktest -d bridgelinkdb -tAc 'select 1')"
case "$OUT" in
  *"no password supplied"*|*"password authentication failed"*) ok "connection without a password is refused" ;;
  *) bad "connection without a password was not refused: $OUT" ;;
esac
OUT="$(client env PGPASSWORD=bridgelinktest psql -h "$PG_DEPLOY" -U bridgelinktest -d bridgelinkdb -tAc 'select 42')"
case "$OUT" in
  *42*) ok "connection with the password succeeds" ;;
  *) bad "connection with the password failed: $OUT" ;;
esac

# Free the memory before the next release: kind shares the Docker VM with everything else.
h uninstall bl --wait --timeout 5m >/dev/null 2>&1
k delete pvc -l app.kubernetes.io/instance=bl --ignore-not-found >/dev/null 2>&1

# ---- 7. restricted namespace, external database -----------------------------------------------
info "7. restricted Pod Security Standard, with WebAdmin and an external database standing in for RDS"
cat <<'EOF' | k apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rds-standin
spec:
  selector:
    matchLabels: {app: rds-standin}
  template:
    metadata:
      labels: {app: rds-standin}
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - {name: POSTGRES_USER, value: blext}
            - {name: POSTGRES_PASSWORD, value: "p@ss,w0rd #1"}
            - {name: POSTGRES_DB, value: blext}
          readinessProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-U", "blext"]
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: rds-standin
spec:
  selector: {app: rds-standin}
  ports:
    - port: 5432
EOF
k rollout status deploy/rds-standin --timeout=3m >/dev/null || { bad "stand-in database not ready"; dump; }
# ApplicationName is a URL parameter BridgeLink knows nothing about. Finding it on the server's
# connections proves the URL reached the JDBC driver unchanged, parameters included.
# Installed in the restricted namespace with every pod shape the chart has: the keystore init
# container (keystore.existingSecret), the appdata claim, and WebAdmin. The bundled PostgreSQL is not
# restricted-compliant and is documented as such. The test accepts the WebAdmin license for itself.
# It also carries the standard Kubernetes options. Every password comes from ext-credentials, under
# key names of the test's choosing. The database password in `environment` and the keystore
# passwords in bl-keystore are wrong on purpose, so a working database connection and a server that
# opens its keystore prove credentials.existingSecret took precedence over both. The pull secret
# names a registry no image comes from, so it is never used for a pull.
EXT_DB_PW="p@ss,w0rd #1"
kr create secret generic ext-credentials --from-literal=db="$EXT_DB_PW" \
  --from-literal=store="$STOREPASS" --from-literal=key="$KEYPASS" >/dev/null
kr create secret docker-registry ext-pull --docker-server=registry.example.com \
  --docker-username=unused --docker-password=unused >/dev/null
# Plugins, both ways the README documents, one plugin each so the API shows which way worked.
# Download: a web server in the cluster stands in for S3, so the test needs no outside host. The URL
# carries a presigned URL's query string: the Rocky image names the downloaded file after the URL.
# Claim: loaded with the README's commands, then mounted read-only at custom-extensions. Keep the
# two in step: this is what tests the documented commands.
plugin_zip "$VERSION" kind-test-download "Kind Test Download"
plugin_zip "$VERSION" kind-test-claim "Kind Test Claim"
kr create configmap ext-download --from-file="$WORK/plugins/kind-test-download.zip" >/dev/null
kr run ext-web --image="$HELPER_IMAGE" --restart=Never --labels=app=ext-web --overrides='{"spec":{
  "securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"www","configMap":{"name":"ext-download"}}],
  "containers":[{"name":"ext-web","image":"'"$HELPER_IMAGE"'","command":["httpd","-f","-p","8080","-h","/www"],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
    "volumeMounts":[{"name":"www","mountPath":"/www"}]}]}}' >/dev/null
kr expose pod ext-web --port=8080 >/dev/null
cat <<'EOF' | kr apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: bridgelink-plugins}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
EOF
NODE="$(kubectl --context "kind-$CLUSTER" get nodes -o jsonpath='{.items[0].metadata.name}')"
# nodeSelector, not nodeName: nodeName skips the scheduler, and a storage class that waits for the
# first pod (kind's, and EBS on EKS) then never creates the volume.
kr run plugin-copy --image="$HELPER_IMAGE" --restart=Never --overrides='{"spec":{
  "nodeSelector":{"kubernetes.io/hostname":"'"$NODE"'"},
  "securityContext":{"runAsNonRoot":true,"runAsUser":'"${RUN_AS_UID:-1000}"',"fsGroup":'"${RUN_AS_UID:-1000}"',"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"plugins","persistentVolumeClaim":{"claimName":"bridgelink-plugins"}}],
  "containers":[{"name":"copy","image":"'"$HELPER_IMAGE"'","command":["sleep","300"],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},
    "volumeMounts":[{"name":"plugins","mountPath":"/plugins"}]}]}}' >/dev/null
kr wait --for=condition=Ready pod/plugin-copy --timeout=2m >/dev/null \
  && kr cp "$WORK/plugins/kind-test-claim.zip" plugin-copy:/plugins/kind-test-claim.zip \
  || bad "could not copy the plugin onto claim bridgelink-plugins"
kr delete pod plugin-copy --wait=false >/dev/null
kr wait --for=condition=Ready pod/ext-web --timeout=2m >/dev/null || bad "the in-cluster web server for the download is not ready"
cat > "$WORK/external.yaml" <<EOF
postgres:
  enabled: false
imagePullSecrets: [{name: ext-pull}]
serviceAccount:
  create: true
  annotations: {eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/kind-test"}
bridgelink:
  keystore:
    existingSecret: bl-keystore
  credentials:
    existingSecret: ext-credentials
    keys: {databasePassword: db, keystoreStorepass: store, keystoreKeypass: key}
  podLabels: {team: kind-test}
  podAnnotations: {example.com/test: "true"}
  extraVolumes: [{name: plugins, persistentVolumeClaim: {claimName: bridgelink-plugins, readOnly: true}}]
  extraVolumeMounts: [{name: plugins, mountPath: /opt/bridgelink/custom-extensions, readOnly: true}]
  nodeSelector: {kubernetes.io/os: linux}
  tolerations: [{key: example.com/dedicated, operator: Exists, effect: NoSchedule}]
  environment:
    MP_DATABASE: postgres
    MP_DATABASE_URL: "jdbc:postgresql://rds-standin.$NS.svc:5432/blext?ApplicationName=bl-chart-test"
    MP_DATABASE_USERNAME: blext
    MP_DATABASE_PASSWORD: "wrong-on-purpose"
    MP_DATABASE_MAX__CONNECTIONS: "15"
    EXTENSIONS_DOWNLOAD: "http://ext-web:8080/kind-test-download.zip?X-Amz-Expires=300&X-Amz-Signature=ab%2Fcd"
webadmin:
  enabled: true
  acceptLicense: true
  service:
    type: ClusterIP
EOF
if hr install ext "$CHART" -f "$WORK/common.yaml" -f "$WORK/external.yaml" ${SETS[@]+"${SETS[@]}"} \
     --set-string bridgelink.environment.SERVER_ID=1b2c3d4e-5f6a-4b7c-9d8e-0f1a2b3c4d5e \
     --wait --timeout "$TIMEOUT" >/dev/null 2>"$WORK/ext.err"; then
  ok "BridgeLink and WebAdmin admitted and Ready in a namespace enforcing restricted"
else
  bad "the release did not become ready in the restricted namespace"; cat "$WORK/ext.err"; dump
fi
if grep -q "PodSecurity" "$WORK/ext.err"; then
  bad "the API server warned about the restricted policy:"; grep "PodSecurity" "$WORK/ext.err"
else
  ok "no Pod Security warnings for any pod template"
fi
UIDS="$(kr get pods -o jsonpath='{range .items[*]}{.metadata.labels.app}={.spec.securityContext.runAsUser} {end}')"
echo "  pods running as: $UIDS"
EXT_POD="$(kr get pods -l app=bl,app.kubernetes.io/instance=ext -o jsonpath='{.items[0].metadata.name}')"
GOT="$(kr get pod "$EXT_POD" -o jsonpath='{.spec.serviceAccountName}|{.metadata.labels.team}|{.spec.imagePullSecrets[0].name}|{.spec.nodeSelector.kubernetes\.io/os}')"
[ "$GOT" = "ext-bridgelink|kind-test|ext-pull|linux" ] \
  && ok "service account, pod labels, pull secret and node selector reached the pod" \
  || bad "pod options did not all reach the pod: $GOT"
MOUNTED="$(kr get pod "$EXT_POD" -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="plugins")].mountPath}')"
[ "$MOUNTED" = "/opt/bridgelink/custom-extensions" ] && ok "extra volume mounted at $MOUNTED" \
  || bad "extra volume not mounted: '$MOUNTED'"
PG_OBJS="$(kr get deploy,svc,pvc,configmap -l app.kubernetes.io/instance=ext -o name | grep -c postgres)"
[ "$PG_OBJS" = "0" ] && ok "no bundled PostgreSQL deployed with postgres.enabled=false" \
  || bad "$PG_OBJS bundled PostgreSQL objects deployed with postgres.enabled=false"
SQL() { k exec deploy/rds-standin -- psql -U blext -d blext -tAc "$1" 2>&1; }
# The schema exists only if BridgeLink logged in, which only the password from ext-credentials allows.
TABLES="$(SQL "select count(*) from information_schema.tables where table_schema='public'")"
[ "${TABLES:-0}" -gt 0 ] 2>/dev/null && ok "BridgeLink logged in with the password from credentials.existingSecret and created its schema ($TABLES tables)" \
  || bad "no BridgeLink tables in the external database: $TABLES"
APPS="$(SQL "select count(*) from pg_stat_activity where application_name='bl-chart-test'")"
[ "${APPS:-0}" -gt 0 ] 2>/dev/null && ok "URL parameters reached the driver unchanged ($APPS connections named bl-chart-test)" \
  || bad "no connections carry the ApplicationName from the URL: $APPS"
LEAKED=""
OBJS="$(kr get deploy,configmap -l app.kubernetes.io/instance=ext -o yaml)"
for pw in "$EXT_DB_PW" "$STOREPASS" "$KEYPASS"; do
  printf '%s' "$OBJS" | grep -qF -- "$pw" && LEAKED="$LEAKED ${pw:0:3}..."
done
[ -z "$LEAKED" ] && ok "no password in any Deployment or ConfigMap of release ext" \
  || bad "passwords in plain text in a Deployment or ConfigMap:$LEAKED"
kr get secret ext-bridgelink-credentials >/dev/null 2>&1 \
  && bad "the chart created its own Secret although credentials.existingSecret supplies every password" \
  || ok "no chart Secret: credentials.existingSecret supplies every password"
# Installed as the restricted policy requires: non-root, all capabilities dropped, claim read-only.
forward ext "$NS_R"
CODE="$(login)"
[ "$CODE" = "200" ] || bad "API login to release ext returned HTTP $CODE"
api GET /extensions/plugins -H 'Accept: application/json' > "$WORK/plugins.json"
PLUGIN_FAIL=0
grep -q '"name":"Kind Test Download"' "$WORK/plugins.json" && ok "the plugin from EXTENSIONS_DOWNLOAD is loaded" \
  || { bad "the plugin from EXTENSIONS_DOWNLOAD is not in /api/extensions/plugins"; PLUGIN_FAIL=1; }
grep -q '"name":"Kind Test Claim"' "$WORK/plugins.json" && ok "the plugin from the claim at custom-extensions is loaded" \
  || { bad "the plugin from the claim at custom-extensions is not in /api/extensions/plugins"; PLUGIN_FAIL=1; }
[ "$PLUGIN_FAIL" = "1" ] && kr logs "$EXT_POD" -c bridgelink 2>&1 | grep -iE "kind-test|custom extension|Problem with|not compatible"
kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; PF_PID=""

# ---- 8. Service types across upgrades --------------------------------------------------------
info "8. Service type, load balancer settings and install notes across upgrades"
# Only the Services matter here, so the release runs no BridgeLink pod and no database. No --wait: a
# LoadBalancer never gets an address on kind.
SVC_SETS=(--set bridgelink.replicaCount=0 --set postgres.enabled=false --set bridgelink.environment.MP_DATABASE=derby
  --set bridgelink.persistence.enabled=false --set webadmin.enabled=true --set webadmin.acceptLicense=true
  --set-string bridgelink.environment.SERVER_ID=2c3d4e5f-6a7b-4c8d-ae9f-1a2b3c4d5e6f)
svc_state() { k get svc "$1" -o jsonpath='{.spec.type} nodePorts=[{.spec.ports[*].nodePort}] etp={.spec.externalTrafficPolicy}' 2>&1; }
# LoadBalancer was the default before ClusterIP. The API server gives such a Service node ports and an
# externalTrafficPolicy the chart never set, and switching the type has to clear them: under
# server-side apply (Helm 4) nobody owns those fields, so the upgrade itself cannot remove them.
if h install svc "$FROM_CHART" "${SVC_SETS[@]}" --set bridgelink.service.type=LoadBalancer \
     --set webadmin.service.type=LoadBalancer >/dev/null 2>"$WORK/svc.err"; then
  GOT="$(svc_state svc-bridgelink-bl)"
  [[ "$GOT" == "LoadBalancer nodePorts=["[0-9]* ]] && ok "installed ${UPGRADE_FROM:-this checkout} as LoadBalancer, node ports allocated ($GOT)" \
    || bad "the LoadBalancer install has no node ports, so the switch below proves nothing: $GOT"
else
  bad "installing the LoadBalancer release failed"; cat "$WORK/svc.err"
fi
if h upgrade svc "$CHART" "${SVC_SETS[@]}" >/dev/null 2>"$WORK/svc.err"; then
  ok "upgraded to this checkout's default Service type"
else
  bad "the upgrade from LoadBalancer to the default type failed"; cat "$WORK/svc.err"
fi
for s in svc-bridgelink-bl svc-bridgelink-webadmin; do
  GOT="$(svc_state "$s")"
  [ "$GOT" = "ClusterIP nodePorts=[] etp=" ] && ok "$s is ClusterIP, nothing left over from LoadBalancer" \
    || bad "$s after the upgrade: $GOT"
done
cat > "$WORK/lb.yaml" <<'EOF'
bridgelink:
  service:
    type: LoadBalancer
    annotations: {service.beta.kubernetes.io/aws-load-balancer-scheme: internal}
    loadBalancerSourceRanges: [10.0.0.0/8]
    loadBalancerClass: example.com/kind-test
    ports: {http: null}
  extraPorts:
    - {name: mllp, containerPort: 6661}
    - {name: syslog, containerPort: 5514, port: 514, protocol: UDP}
  listenerService:
    enabled: true
    type: LoadBalancer
    loadBalancerSourceRanges: [192.168.0.0/16]
EOF
if h upgrade svc "$CHART" "${SVC_SETS[@]}" -f "$WORK/lb.yaml" >/dev/null 2>"$WORK/svc.err"; then
  ok "upgraded to LoadBalancer with annotations, source ranges, a class, no HTTP and a listener Service"
else
  bad "the upgrade to the load balancer settings failed"; cat "$WORK/svc.err"
fi
GOT="$(k get svc svc-bridgelink-bl -o jsonpath='{.spec.type}|{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme}|{.spec.loadBalancerSourceRanges[*]}|{.spec.loadBalancerClass}|{.spec.ports[*].name}' 2>&1)"
[ "$GOT" = "LoadBalancer|internal|10.0.0.0/8|example.com/kind-test|https" ] \
  && ok "BridgeLink Service has the annotation, source range and class, and HTTP is off it" \
  || bad "BridgeLink Service load balancer settings: $GOT"
GOT="$(k get svc svc-bridgelink-listeners -o jsonpath='{.spec.type}|{.spec.loadBalancerSourceRanges[*]}|{range .spec.ports[*]}{.name}:{.port}/{.protocol} {end}' 2>&1)"
[ "$GOT" = "LoadBalancer|192.168.0.0/16|mllp:6661/TCP syslog:514/UDP " ] \
  && ok "listener Service carries the extra ports with its own source range" || bad "listener Service: $GOT"
# AWS reports a load balancer hostname, not an IP. Give the Service one and run the notes' command.
k patch svc svc-bridgelink-bl --subresource=status --type=merge \
  -p '{"status":{"loadBalancer":{"ingress":[{"hostname":"internal-bl-kind-test.elb.us-east-1.amazonaws.com"}]}}}' >/dev/null
LINE="$(h get notes svc | grep 'export SERVICE_HOST=')"
GOT="$( [ -n "$LINE" ] && eval "${LINE/kubectl /kubectl --context kind-$CLUSTER }" && echo "${SERVICE_HOST:-}" )"
[ "$GOT" = "internal-bl-kind-test.elb.us-east-1.amazonaws.com" ] && ok "the install notes print the load balancer hostname" \
  || bad "the install notes print '$GOT' for a load balancer with a hostname (notes line: ${LINE:-none})"
if h upgrade svc "$CHART" "${SVC_SETS[@]}" >/dev/null 2>"$WORK/svc.err"; then
  ok "upgraded back to the defaults"
else
  bad "the upgrade back to the defaults failed"; cat "$WORK/svc.err"
fi
GOT="$(svc_state svc-bridgelink-bl)|$(k get svc svc-bridgelink-bl -o jsonpath='{.spec.loadBalancerClass}{.spec.loadBalancerSourceRanges}{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme}')"
[ "$GOT" = "ClusterIP nodePorts=[] etp=|" ] && ok "BridgeLink Service is ClusterIP again with no load balancer settings" \
  || bad "BridgeLink Service after returning to the defaults: $GOT"
k get svc svc-bridgelink-listeners >/dev/null 2>&1 && bad "the listener Service was not removed" \
  || ok "the listener Service was removed"
h uninstall svc --wait --timeout 2m >/dev/null 2>&1

# ---- summary ----------------------------------------------------------------------------------
echo
echo "==================== RESULT: $PASS passed, $FAIL failed ===================="
[ "$FAIL" -eq 0 ]
