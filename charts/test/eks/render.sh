#!/usr/bin/env bash
#
# Renders the templates in this directory into OUT_DIR from an env file kept outside the repo.
# Creates nothing in AWS or Kubernetes.
#
# Usage: charts/test/eks/render.sh <env file>
set -eu

ENV_FILE="${1:?usage: render.sh <env file>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$ENV_FILE"

VARS="PROFILE REGION VPC_ID VPC_CIDR AZ_A SUBNET_A AZ_B SUBNET_B OPERATOR_PUBLIC_CIDR
      OPERATOR_PRIVATE_CIDR OWNER TICKET PROJECT CLUSTER_NAME K8S_VERSION RDS_STACK
      LBC_CHART_VERSION CHART_VERSION OUT_DIR"
missing=""
for v in $VARS; do [ -n "${!v:-}" ] || missing="$missing $v"; done
[ -z "$missing" ] || { echo "unset in $ENV_FILE:$missing"; exit 2; }

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
case "$(cd "$OUT_DIR" 2>/dev/null && pwd -P || echo "$OUT_DIR")/" in
  "$REPO_ROOT"/*) echo "OUT_DIR must be outside the repository: $OUT_DIR"; exit 2 ;;
esac
mkdir -p "$OUT_DIR"

# Only the listed variables are substituted, so nothing else in a template that looks like
# ${...} is touched.
# shellcheck disable=SC2016  # the literal ${NAME} list envsubst expects
SHELL_FORMAT="$(for v in $VARS; do printf '${%s} ' "$v"; done)"
# shellcheck disable=SC2163  # exporting the variable named by v
for v in $VARS; do export "$v"; done
for f in cluster.yaml storageclass.yaml lbc-values.yaml; do
  envsubst "$SHELL_FORMAT" < "$SCRIPT_DIR/$f" > "$OUT_DIR/$f"
done
echo "rendered cluster.yaml, storageclass.yaml and lbc-values.yaml into $OUT_DIR"
