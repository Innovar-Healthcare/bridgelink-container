#!/usr/bin/env bash
#
# Installs charts/bridgelink on a throwaway kind cluster and checks how it behaves at runtime.
# `helm template` in chart.yml checks what the chart renders; this checks what Kubernetes does with
# it: that BridgeLink becomes ready, that an upgrade never runs two BridgeLink pods at once, that a
# message stored encrypted stays readable after the pod is replaced (keystore on the claim, then from
# a Secret), that the bundled PostgreSQL really runs the config the chart ships, and that BridgeLink,
# with WebAdmin, runs in a namespace enforcing the "restricted" Pod Security Standard against an
# external database.
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
# Requires: docker, kind, kubectl, helm, git. Needs about 4 GB of memory for Docker.
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

# ---- BridgeLink REST API, through a port-forward to the release's Service ----------------------
# A port-forward follows one pod, so it is restarted after every pod replacement.
forward() {   # <release>; sets API
  local port="" i
  [ -n "${PF_PID:-}" ] && { kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; }
  k port-forward "svc/$1-bridgelink-bl" :8443 > "$WORK/pf.log" 2>&1 &
  PF_PID=$!
  for i in $(seq 1 30); do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$WORK/pf.log" | head -1)"
    [ -n "$port" ] && break
    sleep 1
  done
  API="https://127.0.0.1:${port:-0}/api"
}
api() {       # <method> <path> [curl args...]; the API rejects requests without X-Requested-With
  local method="$1" path="$2"; shift 2
  curl -sk -m 60 -b "$WORK/cookies" -c "$WORK/cookies" -H 'X-Requested-With: kind-test' \
    -X "$method" "$API$path" "$@"
}
login() {     # prints the HTTP status; admin/admin works on a fresh install
  rm -f "$WORK/cookies"
  api POST /users/_login --data-urlencode username=admin --data-urlencode password=admin \
    -o /dev/null -w '%{http_code}'
}

# Deletes the BridgeLink pod of release bl and waits for its replacement to be Ready. Prints
# "<old> -> <new>", or nothing if no replacement became Ready.
replace_pod() {
  local old new="" i
  old="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
  k delete pod "$old" --wait=true --timeout=3m >/dev/null
  for i in $(seq 1 60); do
    new="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [ -n "$new" ] && [ "$new" != "$old" ] && break
    sleep 2
  done
  [ -n "$new" ] && k wait --for=condition=Ready "pod/$new" --timeout="$TIMEOUT" >/dev/null && echo "$old -> $new"
}

# A channel that stores every message with encryption on. RAW in and out, so a message needs no
# parsing. Shape from bridgelink-mcp's create_channel skeleton.
channel_json() {   # <server version>
  local v="$1" rid='{"@class":"linked-hash-map","entry":{"string":["Default Resource","[Default Resource]"]}}'
  local raw='{"@class":"com.mirth.connect.plugins.datatypes.raw.RawDataTypeProperties","@version":"'"$v"'","batchProperties":{"@class":"com.mirth.connect.plugins.datatypes.raw.RawBatchProperties","@version":"'"$v"'","splitType":"JavaScript","batchScript":""}}'
  cat <<EOF
{"channel":{"@version":"$v","id":"$CHANNEL_ID","nextMetaDataId":2,"name":"kind-test-encrypted","description":"","revision":1,
 "sourceConnector":{"@version":"$v","metaDataId":0,"name":"sourceConnector",
  "properties":{"@class":"com.mirth.connect.connectors.vm.VmReceiverProperties","@version":"$v","pluginProperties":null,
   "sourceConnectorProperties":{"@version":"$v","responseVariable":"None","respondAfterProcessing":true,"processBatch":false,"firstResponse":false,"processingThreads":1,"resourceIds":$rid,"queueBufferSize":1000}},
  "transformer":{"@version":"$v","elements":null,"inboundTemplate":{"@encoding":"base64"},"outboundTemplate":{"@encoding":"base64"},"inboundDataType":"RAW","outboundDataType":"RAW","inboundProperties":$raw,"outboundProperties":$raw},
  "filter":{"@version":"$v","elements":null},"transportName":"Channel Reader","mode":"SOURCE","enabled":true,"waitForPrevious":true},
 "destinationConnectors":{"connector":{"@version":"$v","metaDataId":1,"name":"Destination 1",
  "properties":{"@class":"com.mirth.connect.connectors.vm.VmDispatcherProperties","@version":"$v","pluginProperties":null,
   "destinationConnectorProperties":{"@version":"$v","queueEnabled":false,"sendFirst":false,"retryIntervalMillis":10000,"regenerateTemplate":false,"retryCount":0,"rotate":false,"includeFilterTransformer":false,"threadCount":1,"threadAssignmentVariable":null,"validateResponse":false,"resourceIds":$rid,"queueBufferSize":1000,"reattachAttachments":true},
   "channelId":"none","channelTemplate":"\${message.encodedData}","mapVariables":null},
  "transformer":{"@version":"$v","elements":null,"inboundDataType":"RAW","outboundDataType":"RAW","inboundProperties":$raw,"outboundProperties":$raw},
  "responseTransformer":{"@version":"$v","elements":null,"inboundDataType":"RAW","outboundDataType":"RAW","inboundProperties":$raw,"outboundProperties":$raw},
  "filter":{"@version":"$v","elements":null},"transportName":"Channel Writer","mode":"DESTINATION","enabled":true,"waitForPrevious":true}},
 "preprocessingScript":"return message;","postprocessingScript":"return;","deployScript":"return;","undeployScript":"return;",
 "properties":{"@version":"$v","clearGlobalChannelMap":true,"messageStorageMode":"DEVELOPMENT","encryptData":true,"encryptAttachments":false,"encryptCustomMetaData":false,
  "removeContentOnCompletion":false,"removeOnlyFilteredOnCompletion":false,"removeAttachmentsOnCompletion":false,"initialState":"STARTED","storeAttachments":true,
  "metaDataColumns":null,"attachmentProperties":{"@version":"$v","type":"None","properties":null},"resourceIds":$rid},
 "exportData":{"metadata":{"enabled":true,"pruningSettings":{"archiveEnabled":true,"pruneErroredMessages":false}},"dependentIds":null,"dependencyIds":null,"channelTags":null}}}
EOF
}

# Prints 1 if the stored message comes back decrypted (its content contains MARKER), else 0.
message_readable() {
  api GET "/channels/$CHANNEL_ID/messages/$MSG_ID" -H 'Accept: application/json' | grep -c "$MARKER"
}

# Runs a command in a long-lived client pod, to reach the database over the pod network. Not
# `kubectl run --rm -i`: a pod that exits before kubectl attaches loses its output, which made a
# refused connection and a silent success look the same.
client() {   # <command...>
  k exec pgclient -- "$@" 2>&1
}

for tool in docker kind kubectl helm git; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool"; exit 2; }
done

# Values shared by every release. The exec probes are enabled (the default image carries the probe),
# so Ready means BridgeLink reported status 0, not merely that the JVM started. ClusterIP because a
# LoadBalancer never gets an address on kind and `helm --wait` would wait for one forever.
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
info "1. install ${UPGRADE_FROM:-this checkout} with the bundled PostgreSQL"
if h install bl "$FROM_CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} --wait --timeout "$TIMEOUT" >/dev/null; then
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
if h upgrade bl "$CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} $UPGRADE_ARGS \
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
VERSION="$(api GET /server/version)"
channel_json "$VERSION" > "$WORK/channel.json"
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
ENV_OF() { k get deploy bl-bridgelink-bl -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"; }
STOREPASS="$(ENV_OF MP_KEYSTORE_STOREPASS)" KEYPASS="$(ENV_OF MP_KEYSTORE_KEYPASS)"
for ns in "$NS" "$NS_R"; do   # step 6 uses it in the restricted namespace
  kubectl --context "kind-$CLUSTER" -n "$ns" create secret generic bl-keystore >/dev/null \
    --from-file=keystore.jks="$WORK/keystore.jks" \
    --from-literal=keystore.storepass="$STOREPASS" --from-literal=keystore.keypass="$KEYPASS"
done
[ -s "$WORK/keystore.jks" ] && ok "copied the keystore off the claim into Secret bl-keystore ($(wc -c < "$WORK/keystore.jks" | tr -d ' ') bytes)" \
  || bad "could not read the keystore off the claim"
if h upgrade bl "$CHART" -f "$WORK/common.yaml" ${SETS[@]+"${SETS[@]}"} --set-string bridgelink.resources.requests.cpu=251m \
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
kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; PF_PID=""

# ---- 5. bundled PostgreSQL --------------------------------------------------------------------
info "5. bundled PostgreSQL"
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

# ---- 6. restricted namespace, external database -----------------------------------------------
info "6. restricted Pod Security Standard, with WebAdmin and an external database standing in for RDS"
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
cat > "$WORK/external.yaml" <<EOF
postgres:
  enabled: false
bridgelink:
  keystore:
    existingSecret: bl-keystore
  environment:
    MP_DATABASE: postgres
    MP_DATABASE_URL: "jdbc:postgresql://rds-standin.$NS.svc:5432/blext?ApplicationName=bl-chart-test"
    MP_DATABASE_USERNAME: blext
    MP_DATABASE_PASSWORD: "p@ss,w0rd #1"
webadmin:
  enabled: true
  acceptLicense: true
  service:
    type: ClusterIP
EOF
if hr install ext "$CHART" -f "$WORK/common.yaml" -f "$WORK/external.yaml" ${SETS[@]+"${SETS[@]}"} \
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
PG_OBJS="$(kr get deploy,svc,pvc,configmap -l app.kubernetes.io/instance=ext -o name | grep -c postgres)"
[ "$PG_OBJS" = "0" ] && ok "no bundled PostgreSQL deployed with postgres.enabled=false" \
  || bad "$PG_OBJS bundled PostgreSQL objects deployed with postgres.enabled=false"
SQL() { k exec deploy/rds-standin -- psql -U blext -d blext -tAc "$1" 2>&1; }
TABLES="$(SQL "select count(*) from information_schema.tables where table_schema='public'")"
[ "${TABLES:-0}" -gt 0 ] 2>/dev/null && ok "BridgeLink created its schema in the external database ($TABLES tables)" \
  || bad "no BridgeLink tables in the external database: $TABLES"
APPS="$(SQL "select count(*) from pg_stat_activity where application_name='bl-chart-test'")"
[ "${APPS:-0}" -gt 0 ] 2>/dev/null && ok "URL parameters reached the driver unchanged ($APPS connections named bl-chart-test)" \
  || bad "no connections carry the ApplicationName from the URL: $APPS"

# ---- summary ----------------------------------------------------------------------------------
echo
echo "==================== RESULT: $PASS passed, $FAIL failed ===================="
[ "$FAIL" -eq 0 ]
