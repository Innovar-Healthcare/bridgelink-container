#!/usr/bin/env bash
#
# Installs charts/bridgelink on a throwaway kind cluster and checks how it behaves at runtime.
# `helm template` in chart.yml checks what the chart renders; this checks what Kubernetes does with
# it: that BridgeLink becomes ready, that an upgrade never runs two BridgeLink pods at once, that the
# bundled PostgreSQL really runs the config the chart ships, and that an external database works.
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
  [ -d "$WORK/from" ] && git -C "$REPO_ROOT" worktree remove --force "$WORK/from" >/dev/null 2>&1
  if [ "$CREATED" = "1" ] && [ "$KEEP_CLUSTER" != "1" ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  elif [ "$KEEP_CLUSTER" != "1" ]; then
    kubectl --context "kind-$CLUSTER" delete namespace "$NS" --wait=false >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Everything a failed run needs to be diagnosed without re-running it.
dump() {
  echo "---- pods"; k get pods -o wide 2>&1
  echo "---- events"; k get events --sort-by=.lastTimestamp 2>&1 | tail -25
  local p
  for p in $(k get pods -o name 2>/dev/null); do
    echo "---- $p"; k logs "$p" --all-containers --tail=30 2>&1
  done
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
kubectl --context "kind-$CLUSTER" delete namespace "$NS" --ignore-not-found --wait=true --timeout=3m >/dev/null \
  || { echo "namespace $NS is stuck terminating on cluster $CLUSTER; delete it or the cluster"; exit 2; }
kubectl --context "kind-$CLUSTER" create namespace "$NS" >/dev/null
k run pgclient --image=postgres:16-alpine --restart=Never --command -- sleep 7200 >/dev/null

# Preload images the host already has, so the run does not depend on Docker Hub rate limits. Best
# effort: kind cannot load some multi-platform images from Docker Desktop's image store, and the
# node then pulls them itself.
# The first `    tag:` inside the top-level bridgelink: block, so a reordered values.yaml cannot
# silently preload another component's image.
BL_TAG="${IMAGE_TAG:-$(awk '/^[^ #]/ { sect = $1 } sect == "bridgelink:" && /^    tag:/ { gsub(/"/, "", $2); print $2; exit }' "$CHART/values.yaml")}"
for img in "innovarhealthcare/bridgelink:$BL_TAG" postgres:16-alpine busybox:latest; do
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

# ---- 3. bundled PostgreSQL --------------------------------------------------------------------
info "3. bundled PostgreSQL"
k wait --for=condition=Ready pod/pgclient --timeout=2m >/dev/null || bad "client pod not ready"
PG_DEPLOY="bl-bridgelink-postgres"
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

# ---- 4. external database ---------------------------------------------------------------------
info "4. external database (a separate PostgreSQL standing in for RDS)"
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
cat > "$WORK/external.yaml" <<'EOF'
postgres:
  enabled: false
bridgelink:
  environment:
    MP_DATABASE: postgres
    MP_DATABASE_URL: "jdbc:postgresql://rds-standin:5432/blext?ApplicationName=bl-chart-test"
    MP_DATABASE_USERNAME: blext
    MP_DATABASE_PASSWORD: "p@ss,w0rd #1"
EOF
if h install ext "$CHART" -f "$WORK/common.yaml" -f "$WORK/external.yaml" ${SETS[@]+"${SETS[@]}"} \
     --wait --timeout "$TIMEOUT" >/dev/null; then
  ok "BridgeLink Ready against the external database"
else
  bad "BridgeLink did not become ready against the external database"; dump
fi
PG_OBJS="$(k get deploy,svc,pvc,configmap -l app.kubernetes.io/instance=ext -o name | grep -c postgres)"
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
