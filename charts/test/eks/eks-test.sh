#!/usr/bin/env bash
#
# Installs the published BridgeLink chart on the EKS test cluster with examples/eks-values.yaml and
# checks what kind cannot: that the install is admitted in a namespace enforcing the "restricted" Pod
# Security Standard, that BridgeLink runs against RDS over TLS, that an MLLP message sent through an
# internal NLB reaches a channel, that a message stored encrypted stays readable after the pod is
# deleted and after its node is drained, that the EBS volume holding the keystore cannot follow the
# pod to another availability zone, and that `helm upgrade` never runs two BridgeLink pods at once.
#
# Run after setup.sh (see the README). Creates AWS resources through the cluster's controllers: an
# internal NLB with its target group and security groups, and an EBS volume. The release is left
# installed for inspection; cleanup.sh removes it and waits until those resources are gone.
#
# Parameterized by env var:
#   CHART_SOURCE   oci (default) installs oci://ghcr.io/innovar-healthcare/charts/bridgelink at
#                  CHART_VERSION, which needs `helm registry login ghcr.io` while the package is
#                  private. checkout installs charts/bridgelink from this checkout instead; say so
#                  in the results.
#
# Usage: charts/test/eks/eks-test.sh <env file>
# Requires: aws, kubectl, helm, curl, nc, and the cluster and RDS stack from the README.
set -u

ENV_FILE="${1:?usage: eks-test.sh <env file>}"
# shellcheck source=/dev/null
. "$ENV_FILE"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE="$REPO_ROOT/charts/bridgelink/examples/eks-values.yaml"
CHART_SOURCE="${CHART_SOURCE:-oci}"
export KUBECONFIG="$OUT_DIR/kubeconfig"
NS="bl-eks"
REL="bl"
TIMEOUT="15m"
WORK="$(mktemp -d)"
PASS=0 FAIL=0

if [ "$CHART_SOURCE" = "checkout" ]; then
  CHART_REF="$REPO_ROOT/charts/bridgelink" CHART_ARGS=()
else
  CHART_REF="oci://ghcr.io/innovar-healthcare/charts/bridgelink" CHART_ARGS=(--version "$CHART_VERSION")
fi

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }
note() { echo "  NOTE: $1"; }
k()    { kubectl -n "$NS" "$@"; }
h()    { helm -n "$NS" "$@"; }
awsr() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

cleanup() {
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null
  [ -n "${DRAINED_NODE:-}" ] && kubectl uncordon "$DRAINED_NODE" >/dev/null 2>&1
  [ -n "${CORDONED_ZONE:-}" ] && kubectl uncordon -l "topology.kubernetes.io/zone=$CORDONED_ZONE" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

dump() {
  echo "---- nodes"; kubectl get nodes -L topology.kubernetes.io/zone 2>&1
  echo "---- pods in $NS"; k get pods -o wide 2>&1
  echo "---- events in $NS"; k get events --sort-by=.lastTimestamp 2>&1 | tail -25
  for p in $(k get pods -l "$BL_SELECTOR" -o name 2>/dev/null); do
    echo "---- $p"; k logs "$p" --all-containers --tail=40 2>&1
  done
}

BL_NS="$NS"
BL_KUBE_CONTEXT=""
BL_SELECTOR="app=bl,app.kubernetes.io/instance=$REL"
# shellcheck source-path=SCRIPTDIR source=../lib/bl-api.sh
. "$SCRIPT_DIR/../lib/bl-api.sh"

for tool in aws kubectl helm curl nc; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool"; exit 2; }
done

# ---- preflight --------------------------------------------------------------------------------
info "preflight"
[ "$(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)" = "restricted" ] \
  || { echo "namespace $NS is missing or does not enforce restricted; run setup.sh"; exit 2; }
for s in bridgelink-db bridgelink-keystore-passwords; do
  k get secret "$s" >/dev/null 2>&1 || { echo "Secret $s is missing in $NS; run setup.sh"; exit 2; }
done
RDS_HOST="$(awsr cloudformation describe-stacks --stack-name "$RDS_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Endpoint'].OutputValue" --output text)"
[ -n "$RDS_HOST" ] && [ "$RDS_HOST" != "None" ] || { echo "no Endpoint output on stack $RDS_STACK"; exit 2; }
# One server ID for the life of this test cluster, so a re-run or an upgrade keeps it.
[ -s "$OUT_DIR/server-id" ] || uuidgen | tr '[:upper:]' '[:lower:]' > "$OUT_DIR/server-id"
SERVER_ID="$(cat "$OUT_DIR/server-id")"
echo "  chart $CHART_SOURCE ${CHART_ARGS[*]:-}, RDS $RDS_HOST, server ID $SERVER_ID"

# What the example leaves as placeholders, plus a preference for zone A so the pod starts where the
# two-node group is: the drain in step 6 then has a node in the same zone to move to.
SOURCES="\"$VPC_CIDR\"${SENDER_CIDR:+, \"$SENDER_CIDR\"}"
cat > "$WORK/overlay.yaml" <<EOF
bridgelink:
  environment:
    SERVER_ID: "$SERVER_ID"
    MP_DATABASE_URL: "jdbc:postgresql://$RDS_HOST:5432/bridgelinkdb?sslmode=require"
  listenerService:
    loadBalancerSourceRanges: [$SOURCES]
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-subnets: "$SUBNET_A,$SUBNET_B"
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - {key: topology.kubernetes.io/zone, operator: In, values: ["$AZ_A"]}
EOF

# ---- 1. install, admitted under restricted ----------------------------------------------------
info "1. install in $NS, which enforces the restricted Pod Security Standard"
if h install "$REL" "$CHART_REF" ${CHART_ARGS[@]+"${CHART_ARGS[@]}"} -f "$EXAMPLE" -f "$WORK/overlay.yaml" \
     --wait --timeout "$TIMEOUT" > "$WORK/install.out" 2> "$WORK/install.err"; then
  ok "release installed and BridgeLink Ready (startup and readiness probes passed)"
else
  bad "install did not become ready: $(head -c 400 "$WORK/install.err")"; dump; exit 1
fi
if grep -qi "podsecurity\|would violate" "$WORK/install.err"; then
  bad "Pod Security warnings during install: $(grep -i "podsecurity\|would violate" "$WORK/install.err" | head -3)"
else
  ok "no Pod Security warnings during install"
fi
FORBIDDEN="$(k get events --field-selector reason=FailedCreate -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -c forbidden)"
[ "$FORBIDDEN" = "0" ] && ok "no pod creation was forbidden" || bad "$FORBIDDEN FailedCreate events say forbidden"

# A client that reaches RDS with the same Secret BridgeLink uses, and itself passes restricted.
cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: pgclient}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: pgclient
      image: postgres:16-alpine
      command: ["sleep", "14400"]
      env:
        - {name: PGHOST, value: "$RDS_HOST"}
        - {name: PGUSER, value: bridgelink}
        - {name: PGDATABASE, value: bridgelinkdb}
        - {name: PGSSLMODE, value: require}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: bridgelink-db, key: password}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
---
apiVersion: v1
kind: Pod
metadata: {name: sender}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: sender
      image: busybox:1.37.0
      command: ["sleep", "14400"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
EOF
k wait --for=condition=Ready pod/pgclient pod/sender --timeout=3m >/dev/null || bad "client pods not ready"
SQL() { k exec pgclient -- psql -tAc "$1" 2>&1; }

# ---- 2. RDS -----------------------------------------------------------------------------------
info "2. BridgeLink runs against RDS, over TLS"
forward "$REL"
CODE="$(login)"
[ "$CODE" = "200" ] && ok "logged in to the BridgeLink API" || bad "API login returned HTTP $CODE"
GOT_ID="$(api GET /server/id | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
[ "$GOT_ID" = "$SERVER_ID" ] && ok "server reports the server ID it was installed with" \
  || bad "server reports server ID '$GOT_ID', want $SERVER_ID"
TABLES="$(SQL "select count(*) from information_schema.tables where table_name='d_channels'")"
[ "$TABLES" = "1" ] && ok "BridgeLink created its schema in RDS" || bad "no d_channels table in RDS: $TABLES"
TLS="$(SQL "select count(*) from pg_stat_ssl s join pg_stat_activity a using (pid)
            where a.usename='bridgelink' and a.application_name <> 'psql' and s.ssl")"
PLAIN_CONN="$(SQL "select count(*) from pg_stat_ssl s join pg_stat_activity a using (pid)
                  where a.usename='bridgelink' and a.application_name <> 'psql' and not s.ssl")"
[ "${TLS:-0}" -gt 0 ] 2>/dev/null && [ "$PLAIN_CONN" = "0" ] \
  && ok "all $TLS BridgeLink connections to RDS use TLS" \
  || bad "BridgeLink connections to RDS: $TLS with TLS, $PLAIN_CONN without"

# ---- 3 and 4. MLLP through the internal NLB ---------------------------------------------------
info "3. the listener Service is an internal NLB"
LB_SVC="$(bl_service "$REL" | sed 's/-bl$/-listeners/')"
LB_HOST=""
for _ in $(seq 1 60); do
  LB_HOST="$(k get svc "$LB_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  [ -n "$LB_HOST" ] && break
  sleep 10
done
if [ -z "$LB_HOST" ]; then
  bad "the listener Service got no load balancer hostname"; k describe svc "$LB_SVC" | tail -15
else
  LB="$(awsr elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$LB_HOST'].[LoadBalancerArn,Scheme,Type]" --output text)"
  LB_ARN="$(echo "$LB" | cut -f1)"
  [ "$(echo "$LB" | cut -f2-3)" = "$(printf 'internal\tnetwork')" ] \
    && ok "listener Service is an internal NLB ($LB_HOST)" || bad "load balancer is not an internal NLB: $LB"
fi

info "4. an MLLP message sent through the NLB reaches a channel"
CHANNEL_ID="7c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f"
MARKER="eks-test-payload-$RANDOM$RANDOM"
VERSION="$(api GET /server/version)"
channel_json "$VERSION" "$CHANNEL_ID" eks-test-mllp 6661 mllp > "$WORK/channel.json"
CODE="$(api POST /channels -H 'Content-Type: application/json' --data-binary @"$WORK/channel.json" -o "$WORK/out" -w '%{http_code}')"
[ "$CODE" = "200" ] || { bad "creating the MLLP channel returned HTTP $CODE"; cat "$WORK/out"; }
CODE="$(api POST "/channels/$CHANNEL_ID/_deploy" -o "$WORK/out" -w '%{http_code}')"
[ "$CODE" = "204" ] && ok "MLLP channel deployed, listening on 6661" || { bad "deploying the channel returned HTTP $CODE"; cat "$WORK/out"; }
# The NLB sends nothing until its target passes the TCP health check on 6661, which needs the
# channel listening.
HEALTH=""
if [ -n "${LB_ARN:-}" ]; then
  TG_ARN="$(awsr elbv2 describe-target-groups --load-balancer-arn "$LB_ARN" --query 'TargetGroups[0].TargetGroupArn' --output text)"
  for _ in $(seq 1 40); do
    HEALTH="$(awsr elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
    [ "$HEALTH" = "healthy" ] && break
    sleep 15
  done
  [ "$HEALTH" = "healthy" ] && ok "the NLB target (the BridgeLink pod) is healthy" || bad "NLB target health: '$HEALTH'"
fi
BODY="MSH|^~\\&|EKSTEST|CHART|BL|BL|$(date -u +%Y%m%d%H%M%S)||ADT^A01|$MARKER|P|2.5"$'\r'"PID|1||$MARKER"$'\r'
send_mllp_from_pod() {   # through the NLB's hostname, from a pod: traffic from inside the VPC
  k exec sender -- sh -c 'printf "\013%s\034\015" "$1" | nc -w 10 "$2" 6661' sh "$BODY" "$LB_HOST" >/dev/null 2>&1
}
message_count() {
  api GET "/channels/$CHANNEL_ID/messages/count" -H 'Accept: application/json' | grep -o '[0-9][0-9]*' | head -1
}
send_mllp_from_pod
MSG_ID=1
GOT=0
for _ in $(seq 1 20); do
  GOT="$(message_readable)"
  [ "${GOT:-0}" -ge 1 ] && break
  sleep 3
done
[ "${GOT:-0}" -ge 1 ] && ok "the MLLP message sent through the NLB reached the channel and reads back" \
  || bad "no message with the marker reached the channel (messages: $(message_count))"

if [ -n "${SENDER_CIDR:-}" ] && [ -n "$LB_HOST" ]; then
  # From this machine, over the network routed to the VPC (the VPN), never a public endpoint.
  printf '\013%s\034\015' "$BODY" | nc -w 10 "$LB_HOST" 6661 >/dev/null 2>&1
  sleep 5
  N="$(message_count)"
  [ "${N:-0}" -ge 2 ] && ok "an MLLP message from this machine through the NLB reached the channel ($N messages)" \
    || bad "the MLLP message from this machine did not arrive (messages: $N)"
fi

# ---- 5. stored encrypted ----------------------------------------------------------------------
info "5. the message is stored encrypted in RDS"
LOCAL_ID="$(SQL "select local_channel_id from d_channels where channel_id='$CHANNEL_ID'")"
ENC="$(SQL "select count(*) from d_mc$LOCAL_ID where message_id=$MSG_ID and is_encrypted")"
PLAIN="$(SQL "select count(*) from d_mc$LOCAL_ID where message_id=$MSG_ID and content like '%$MARKER%'")"
[ "${ENC:-0}" -gt 0 ] 2>/dev/null && [ "$PLAIN" = "0" ] \
  && ok "message $MSG_ID is stored encrypted ($ENC content rows, none in plain text)" \
  || bad "message $MSG_ID is not stored encrypted (encrypted rows: $ENC, plain-text rows: $PLAIN)"

pod_where() {   # prints "<pod> <node> <zone>"
  local p n
  p="$(k get pods -l "$BL_SELECTOR" --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{.items[0].metadata.name}')"
  n="$(k get pod "$p" -o jsonpath='{.spec.nodeName}')"
  echo "$p $n $(kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)"
}
PVC="$(k get deploy -l "$BL_SELECTOR" -o jsonpath='{.items[0].spec.template.spec.volumes[?(@.name=="appdata")].persistentVolumeClaim.claimName}')"
PV="$(k get pvc "$PVC" -o jsonpath='{.spec.volumeName}')"
VOLUME="$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')"
VOLUME_ZONE="$(awsr ec2 describe-volumes --volume-ids "$VOLUME" --query 'Volumes[0].AvailabilityZone' --output text)"
read -r POD NODE ZONE <<< "$(pod_where)"
note "appdata is claim $PVC, EBS volume $VOLUME in $VOLUME_ZONE; pod $POD on $NODE in $ZONE"

# ---- 6. pod deleted ---------------------------------------------------------------------------
info "6. the message is still readable after the pod is deleted"
REPLACED="$(replace_pod)"
if [ -n "$REPLACED" ]; then
  forward "$REL"; login >/dev/null
  [ "$(message_readable)" -ge 1 ] && ok "message still readable after the pod was deleted ($REPLACED)" \
    || bad "message unreadable after the pod was deleted ($REPLACED): the keystore did not survive"
else
  bad "the BridgeLink pod was not replaced"; dump
fi

# ---- 7. node drained --------------------------------------------------------------------------
info "7. the message is still readable after the pod's node is drained"
read -r POD NODE ZONE <<< "$(pod_where)"
DRAINED_NODE="$NODE"
if kubectl drain "$NODE" --pod-selector="$BL_SELECTOR" --ignore-daemonsets --delete-emptydir-data \
     --timeout=10m >/dev/null 2>"$WORK/drain.err"; then
  NEW=""
  for _ in $(seq 1 90); do
    NEW="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | grep -vx "$POD" | head -1)"
    [ -n "$NEW" ] && k wait --for=condition=Ready "pod/$NEW" --timeout=20s >/dev/null 2>&1 && break
    NEW=""; sleep 5
  done
  if [ -n "$NEW" ]; then
    read -r _ NODE2 ZONE2 <<< "$(pod_where)"
    [ "$NODE2" != "$NODE" ] && [ "$ZONE2" = "$VOLUME_ZONE" ] \
      && ok "pod moved from $NODE to $NODE2, in the volume's zone $ZONE2" \
      || bad "after the drain the pod is on $NODE2 in $ZONE2 (was $NODE; volume in $VOLUME_ZONE)"
    forward "$REL"; login >/dev/null
    [ "$(message_readable)" -ge 1 ] && ok "message still readable after the node drain" \
      || bad "message unreadable after the node drain"
  else
    bad "no replacement pod became Ready after draining $NODE"; dump
  fi
else
  bad "drain of $NODE failed: $(head -c 300 "$WORK/drain.err")"
fi
kubectl uncordon "$NODE" >/dev/null
DRAINED_NODE=""

# ---- 8. the volume cannot follow the pod to another zone ---------------------------------------
info "8. with no node left in the volume's zone, the pod waits rather than moving to another zone"
# kind has one zone, so this is the first place it can be shown. Expected, not a defect: an EBS
# volume attaches only in its own zone.
CORDONED_ZONE="$VOLUME_ZONE"
kubectl cordon -l "topology.kubernetes.io/zone=$CORDONED_ZONE" >/dev/null
read -r POD _ _ <<< "$(pod_where)"
k delete pod "$POD" --wait=true --timeout=3m >/dev/null
sleep 60
PENDING="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].status.phase}')"
REASON="$(k get events --field-selector reason=FailedScheduling -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -c "volume node affinity conflict")"
[ "$PENDING" = "Pending" ] && [ "${REASON:-0}" -ge 1 ] \
  && ok "pod stays Pending with \"volume node affinity conflict\" while the other zone has a free node" \
  || bad "expected a Pending pod with a volume node affinity conflict; phase $PENDING, matching events $REASON"
kubectl uncordon -l "topology.kubernetes.io/zone=$CORDONED_ZONE" >/dev/null
CORDONED_ZONE=""
k wait --for=condition=Ready pod -l "$BL_SELECTOR" --timeout="$TIMEOUT" >/dev/null \
  && ok "pod started once its zone had a schedulable node again" || { bad "pod did not recover after uncordon"; dump; }

# ---- 9. upgrade -------------------------------------------------------------------------------
info "9. helm upgrade with a pod-template change never runs two BridgeLink pods"
# The same watcher as kind-test.sh: a pod in a terminal phase does not count; a Terminating pod
# whose phase is still Running does, because its JVM can still hold the database.
OLD_POD="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
( while :; do
    k get pods -l "$BL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null
    echo; sleep 0.5
  done ) > "$WORK/pods.log" &
WATCH_PID=$!
if h upgrade "$REL" "$CHART_REF" ${CHART_ARGS[@]+"${CHART_ARGS[@]}"} -f "$EXAMPLE" -f "$WORK/overlay.yaml" \
     --set-string bridgelink.resources.requests.cpu=501m --wait --timeout "$TIMEOUT" >/dev/null 2>"$WORK/upgrade.err"; then
  ok "upgrade completed and BridgeLink Ready"
else
  bad "upgrade did not become ready: $(head -c 300 "$WORK/upgrade.err")"; dump
fi
kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""
NEW_POD="$(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
MAX="$(awk '{ n = 0; for (i = 1; i <= NF; i++) if ($i !~ /=(Succeeded|Failed)$/) n++; if (n > m) m = n } END { print m + 0 }' "$WORK/pods.log")"
if [ "$NEW_POD" = "$OLD_POD" ]; then
  bad "the upgrade did not replace the BridgeLink pod, so the overlap check proves nothing"
elif [ "$MAX" -le 1 ]; then
  ok "never more than one live BridgeLink pod during the upgrade ($OLD_POD -> $NEW_POD)"
else
  bad "$MAX live BridgeLink pods existed at once during the upgrade"
fi
MULTI="$(k get events --field-selector reason=FailedAttachVolume -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -c Multi-Attach)"
[ "$MULTI" = "0" ] && ok "no Multi-Attach errors on the EBS volume" || bad "$MULTI Multi-Attach errors on the EBS volume"
forward "$REL"; login >/dev/null
[ "$(message_readable)" -ge 1 ] && ok "message still readable after the upgrade" || bad "message unreadable after the upgrade"

# ---- recorded, not asserted -------------------------------------------------------------------
info "recorded for the results"
note "IRSA: the controller's role is $(kubectl -n kube-system get sa aws-load-balancer-controller -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' | sed 's/.*:role\//role\//')"
note "IRSA: the EBS CSI controller's role is $(kubectl -n kube-system get sa ebs-csi-controller-sa -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' | sed 's/.*:role\//role\//')"
if [ -n "${LB_ARN:-}" ]; then
  LISTENER="$(awsr elbv2 describe-listeners --load-balancer-arn "$LB_ARN" --query 'Listeners[0].ListenerArn' --output text)"
  note "NLB listener idle timeout: $(awsr elbv2 describe-listener-attributes --listener-arn "$LISTENER" \
    --query "Attributes[?Key=='tcp.idle_timeout.seconds'].Value" --output text 2>&1)s"
fi
note "chart: $CHART_SOURCE ${CHART_ARGS[*]:-}; images: $(k get pods -l "$BL_SELECTOR" -o jsonpath='{.items[0].spec.containers[*].image}')"

echo
echo "passed $PASS, failed $FAIL. The release is still installed; run cleanup.sh to remove it."
[ "$FAIL" = "0" ]
