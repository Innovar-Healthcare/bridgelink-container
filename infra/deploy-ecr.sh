#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# BridgeLink private container registry — deploy (IRT-1866)
#
# Creates/updates the private ECR repositories that CI publishes release images
# to, their lifecycle policies, and the ECR push policy attached to the GitHub
# Actions OIDC role.
#
# Usage:
#   ./infra/deploy-ecr.sh
#
# On a first run this transparently imports the pre-existing
# innovarhealthcare/bridgelink repository (created by hand in 2026-04) into the
# stack before applying the full template — a new-stack CloudFormation import
# only accepts a template containing the resources being imported, so it is two
# steps. Subsequent runs are a plain stack update.
#
# Configure via env vars; the defaults are the real deployment.
# ---------------------------------------------------------------------------

: "${STACK_NAME:=bridgelink-ecr}"
: "${REGION:=us-east-2}"
# Existing GitHub Actions OIDC role that CI assumes (vars.AWS_ROLE_ARN). The
# stack attaches the ECR push policy to it. Set empty to skip that attachment.
: "${PUBLISH_ROLE_NAME:=github-bridgelink-release-read}"
: "${REPO_NAMESPACE:=innovarhealthcare}"

# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/infra/ecr-stack.yaml"
IMPORT_TEMPLATE="$ROOT/infra/ecr-stack-import.yaml"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Sanity checks -------------------------------------------------------------

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Missing required command: $cmd"; exit 1; }
done

[[ -f "$TEMPLATE" ]] || { red "Template not found: $TEMPLATE"; exit 1; }

aws sts get-caller-identity >/dev/null 2>&1 || {
  red "AWS CLI is not authenticated. Run 'aws configure' or set AWS_PROFILE."
  exit 1
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
cyan ">> Account: $ACCOUNT_ID  Region: $REGION  Stack: $STACK_NAME"

# get-caller-identity succeeds without MFA, but Innovar-MFA-policy denies almost
# everything this script does unless the session is MFA'd. Prove real access with
# a call that policy actually gates, so we fail here with a clear message rather
# than deep inside a change set.
if ! aws cloudformation list-stacks >/dev/null 2>&1; then
  red "Authenticated, but this session cannot call CloudFormation — it is almost"
  red "certainly not MFA'd (Innovar-MFA-policy denies most actions without MFA),"
  red "or the session has expired. Refresh an MFA session and set AWS_PROFILE."
  exit 1
fi

stack_exists() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1
}

repo_exists() {
  aws ecr describe-repositories --repository-names "$1" >/dev/null 2>&1
}

# 1. One-time import of the pre-existing repository -------------------------

STANDARD_REPO="$REPO_NAMESPACE/bridgelink"

if stack_exists; then
  cyan ">> [1/2] Stack exists — skipping import step."
elif repo_exists "$STANDARD_REPO"; then
  cyan ">> [1/2] Stack does not exist but $STANDARD_REPO does — importing it."
  yellow "   The repository is imported, never recreated: it holds published"
  yellow "   release images and both this and the full template mark it Retain."

  RESOURCES_TO_IMPORT="$(mktemp)"
  trap 'rm -f "$RESOURCES_TO_IMPORT"' EXIT
  jq -n --arg name "$STANDARD_REPO" '[{
    ResourceType: "AWS::ECR::Repository",
    LogicalResourceId: "StandardRepository",
    ResourceIdentifier: { RepositoryName: $name }
  }]' > "$RESOURCES_TO_IMPORT"

  CHANGE_SET_NAME="import-standard-repo-$(date -u +%Y%m%d%H%M%S)"
  aws cloudformation create-change-set \
    --stack-name "$STACK_NAME" \
    --change-set-name "$CHANGE_SET_NAME" \
    --change-set-type IMPORT \
    --template-body "file://$IMPORT_TEMPLATE" \
    --parameters "ParameterKey=RepoNamespace,ParameterValue=$REPO_NAMESPACE" \
    --resources-to-import "file://$RESOURCES_TO_IMPORT" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null

  aws cloudformation wait change-set-create-complete \
    --stack-name "$STACK_NAME" --change-set-name "$CHANGE_SET_NAME"

  aws cloudformation execute-change-set \
    --stack-name "$STACK_NAME" --change-set-name "$CHANGE_SET_NAME"

  aws cloudformation wait stack-import-complete --stack-name "$STACK_NAME"
  green "   ✓ Imported $STANDARD_REPO into $STACK_NAME"
else
  cyan ">> [1/2] Neither the stack nor $STANDARD_REPO exists — nothing to import."
  yellow "   The full template below will create all three repositories."
fi

# 1b. Clear orphaned repositories left by a rolled-back update ---------------
#
# The repositories are DeletionPolicy: Retain, which also applies when a rollback
# unwinds one that the same update had just created. So a failed update leaves the
# new repositories present in ECR but absent from the stack, and every later attempt
# dies in AWS::EarlyValidation::ResourceExistenceCheck because the template asks to
# create what already exists.
#
# Discarding such an orphan is only safe while it is empty, so that is the only case
# handled here. delete-repository is called WITHOUT --force, so ECR itself refuses if
# an image appeared in the meantime — the safety does not rest on the check above.
for variant in bridgelink-dhi bridgelink-dhi-slim; do
  repo="$REPO_NAMESPACE/$variant"
  repo_exists "$repo" || continue
  if aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" \
       --query 'StackResources[].PhysicalResourceId' --output text 2>/dev/null \
       | tr '\t' '\n' | grep -qxF "$repo"; then
    continue   # already managed by the stack — nothing to do
  fi

  count="$(aws ecr describe-images --repository-name "$repo" \
    --query 'length(imageDetails)' --output text 2>/dev/null || echo unknown)"

  if [[ "$count" == "0" ]]; then
    yellow ">> $repo exists but is not in the stack, and is empty — most likely left"
    yellow "   behind by a rolled-back update. Deleting it so the stack can own it."
    aws ecr delete-repository --repository-name "$repo" >/dev/null
    green "   ✓ Removed orphaned empty $repo"
  else
    red "$repo exists outside the stack and holds $count image(s)."
    red "Refusing to touch it. Import it into $STACK_NAME instead, the way the"
    red "standard repository was imported, then re-run this script."
    exit 1
  fi
done

# 2. Apply the full template ------------------------------------------------

cyan ">> [2/2] Deploying ${STACK_NAME}…"

aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "RepoNamespace=$REPO_NAMESPACE" \
    "PublishRoleName=$PUBLISH_ROLE_NAME" \
  --no-fail-on-empty-changeset

green "   ✓ Stack deployed"

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

REGISTRY_URL="$(get_output RegistryUrl)"
REPO_ARNS="$(get_output RepositoryArns)"

cat <<EOF

════════════════════════════════════════════════════════════════
$(green "Private registry deployed.")

Registry:   $(yellow "$REGISTRY_URL")
Repos:      $REPO_NAMESPACE/bridgelink
            $REPO_NAMESPACE/bridgelink-dhi
            $REPO_NAMESPACE/bridgelink-dhi-slim

NEXT STEPS:
  1. Verify the registry is private and the lifecycle policy is safe:

       ./infra/verify-ecr.sh

  2. Hand these repository ARNs to IRT-1865 for the customer read policy
     (bridgelink-ecr-readOnly) scope — that ticket is blocked until you do:

       $REPO_ARNS

     As of 2026-08-18 it covers ONLY the standard repository, so a customer
     holding it cannot pull -dhi or -dhi-slim. verify-ecr.sh checks this.

  3. Confirm CI can now push (the push policy is attached to
     $PUBLISH_ROLE_NAME), then land the workflow changes.

NOTE: tags in these repositories are MUTABLE by design — the weekly DHI rebuild
      re-pushes <version>-dhi after Docker repatches the hardened base. The
      immutable release identity is the manifest DIGEST; record it per release.
════════════════════════════════════════════════════════════════
EOF
