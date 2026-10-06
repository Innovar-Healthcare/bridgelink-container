#!/usr/bin/env bash
#
# Prepares the test cluster for BridgeLink, after `eksctl create cluster` and the RDS stack (see the
# README): the gp3 StorageClass, the AWS Load Balancer Controller, the namespace that enforces the
# "restricted" Pod Security Standard, and the two Secrets the example values read. Safe to re-run.
#
# Passwords never reach a command line or the terminal: the RDS master password goes from Secrets
# Manager straight into a Secret, and BridgeLink's database password and the keystore passwords are
# generated into theirs.
#
# Usage: charts/test/eks/setup.sh <env file>
# Requires: aws, kubectl, helm, jq, openssl, and the files render.sh wrote into OUT_DIR.
set -euo pipefail

ENV_FILE="${1:?usage: setup.sh <env file>}"
# shellcheck source=/dev/null
. "$ENV_FILE"
export KUBECONFIG="$OUT_DIR/kubeconfig"
NS="bl-eks"
DB_USER="bridgelink_app"
awsr() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
stack_output() {
  awsr cloudformation describe-stacks --stack-name "$RDS_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

echo "== gp3 StorageClass"
kubectl apply -f "$OUT_DIR/storageclass.yaml"

echo "== AWS Load Balancer Controller $LBC_CHART_VERSION"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$LBC_CHART_VERSION" -n kube-system -f "$OUT_DIR/lbc-values.yaml" --wait --timeout 5m

echo "== namespace $NS, enforcing the restricted Pod Security Standard"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted

echo "== Secret rds-master, from the RDS-managed master password"
SECRET_ARN="$(stack_output MasterUserSecretArn)"
RDS_HOST="$(stack_output Endpoint)"
[ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ] || { echo "no MasterUserSecretArn on stack $RDS_STACK"; exit 1; }
awsr secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text \
  | jq -j .password \
  | kubectl -n "$NS" create secret generic rds-master --from-file=password=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -

# BridgeLink connects as its own user, not the master: the usual practice, and it keeps the
# RDS-generated master password (which can contain any punctuation) out of BridgeLink. Rocky images
# built before the entrypoint escaped "|" drop any MP_* value containing one.
echo "== database user $DB_USER, and Secret bridgelink-db with its generated password"
if ! kubectl -n "$NS" get secret bridgelink-db >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic bridgelink-db \
    --from-file=password=<(openssl rand -hex 24 | tr -d '\n')
fi
kubectl -n "$NS" delete pod dbinit --ignore-not-found --wait=true >/dev/null
cat <<EOF | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: dbinit}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: psql
      image: postgres:16-alpine
      env:
        - {name: PGHOST, value: "$RDS_HOST"}
        - {name: PGUSER, value: bridgelink}
        - {name: PGDATABASE, value: bridgelinkdb}
        - {name: PGSSLMODE, value: require}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: rds-master, key: password}}
        - name: APP_PASSWORD
          valueFrom: {secretKeyRef: {name: bridgelink-db, key: password}}
      command:
        - sh
        - -c
        - |
          psql -v ON_ERROR_STOP=1 <<'SQL'
          \set pw \`printf %s "\$APP_PASSWORD"\`
          SELECT 'CREATE ROLE $DB_USER LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') \gexec
          ALTER ROLE $DB_USER WITH LOGIN PASSWORD :'pw';
          GRANT $DB_USER TO bridgelink;
          ALTER DATABASE bridgelinkdb OWNER TO $DB_USER;
          SQL
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
EOF
phase=""
for _ in $(seq 1 100); do   # up to 5 minutes, for a first image pull on fresh nodes
  phase="$(kubectl -n "$NS" get pod dbinit -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in Succeeded|Failed) break ;; esac
  sleep 3
done
kubectl -n "$NS" logs dbinit || true
kubectl -n "$NS" delete pod dbinit --wait=false >/dev/null || true
[ "$phase" = "Succeeded" ] || { echo "creating database user $DB_USER failed"; exit 1; }

echo "== Secret bridgelink-keystore-passwords (generated once, kept on re-runs)"
if ! kubectl -n "$NS" get secret bridgelink-keystore-passwords >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic bridgelink-keystore-passwords \
    --from-file=storepass=<(openssl rand -hex 24 | tr -d '\n') \
    --from-file=keypass=<(openssl rand -hex 24 | tr -d '\n')
fi

echo "setup done"
