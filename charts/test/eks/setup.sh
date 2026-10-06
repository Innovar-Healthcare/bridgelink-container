#!/usr/bin/env bash
#
# Prepares the test cluster for BridgeLink, after `eksctl create cluster` and the RDS stack (see the
# README): the gp3 StorageClass, the AWS Load Balancer Controller, the namespace that enforces the
# "restricted" Pod Security Standard, and the two Secrets the example values read. Safe to re-run.
#
# Passwords never reach a command line or the terminal: the database password goes from Secrets
# Manager straight into the Secret, and the keystore passwords are generated into it.
#
# Usage: charts/test/eks/setup.sh <env file>
# Requires: aws, kubectl, helm, jq, openssl, and the files render.sh wrote into OUT_DIR.
set -euo pipefail

ENV_FILE="${1:?usage: setup.sh <env file>}"
# shellcheck source=/dev/null
. "$ENV_FILE"
export KUBECONFIG="$OUT_DIR/kubeconfig"
NS="bl-eks"
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

echo "== Secret bridgelink-db, from the RDS-managed password"
SECRET_ARN="$(stack_output MasterUserSecretArn)"
[ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ] || { echo "no MasterUserSecretArn on stack $RDS_STACK"; exit 1; }
awsr secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text \
  | jq -j .password \
  | kubectl -n "$NS" create secret generic bridgelink-db --from-file=password=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -

echo "== Secret bridgelink-keystore-passwords (generated once, kept on re-runs)"
if ! kubectl -n "$NS" get secret bridgelink-keystore-passwords >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic bridgelink-keystore-passwords \
    --from-file=storepass=<(openssl rand -hex 24 | tr -d '\n') \
    --from-file=keypass=<(openssl rand -hex 24 | tr -d '\n')
fi

echo "setup done"
