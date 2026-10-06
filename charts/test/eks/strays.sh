#!/usr/bin/env bash
#
# Read-only check, after teardown, that nothing from the test is left in the account. Lists what it
# finds and exits non-zero if anything is. Changes nothing.
#
# Usage: charts/test/eks/strays.sh <env file>
set -uo pipefail

ENV_FILE="${1:?usage: strays.sh <env file>}"
# shellcheck source=/dev/null
. "$ENV_FILE"
awsr() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
FOUND=0
# A listing that fails (an expired session, a denied call) is reported and fails the check: an empty
# answer from a failed call is not evidence that nothing is left.
check() {   # <what> <command...>
  local what="$1" out rc; shift
  out="$("$@" 2>"$TMP_ERR")"; rc=$?
  if [ "$rc" != "0" ]; then echo "UNKNOWN: $what (exit $rc: $(head -c 200 "$TMP_ERR"))"; FOUND=1
  elif [ -n "$out" ] && [ "$out" != "None" ]; then echo "LEFT: $what"; echo "$out" | sed 's/^/    /'; FOUND=1
  else echo "none: $what"; fi
}
oidc_providers() {   # the OIDC provider eksctl made for this cluster, found by its tag
  local arns arn tags
  arns="$(aws --profile "$PROFILE" iam list-open-id-connect-providers \
    --query 'OpenIDConnectProviderList[].Arn' --output text)" || return 1
  for arn in $arns; do
    tags="$(aws --profile "$PROFILE" iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" \
      --query "Tags[?Key=='alpha.eksctl.io/cluster-name'].Value" --output text)" || return 1
    [ "$tags" = "$CLUSTER_NAME" ] && echo "$arn"
  done
  return 0
}
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_ERR"' EXIT

check "resources tagged Project=$PROJECT" awsr resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=$PROJECT" --query 'ResourceTagMappingList[].ResourceARN' --output text
check "resources tagged Ticket=$TICKET" awsr resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Ticket,Values=$TICKET" --query 'ResourceTagMappingList[].ResourceARN' --output text
check "EKS cluster $CLUSTER_NAME" awsr eks list-clusters --query "clusters[?@=='$CLUSTER_NAME']" --output text
check "CloudFormation stacks" awsr cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE CREATE_IN_PROGRESS DELETE_IN_PROGRESS DELETE_FAILED ROLLBACK_COMPLETE \
  --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER_NAME') || StackName=='$RDS_STACK'].[StackName,StackStatus]" --output text
check "instances" awsr ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "instances (alpha.eksctl.io tag)" awsr ec2 describe-instances \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "security groups for the cluster" awsr ec2 describe-security-groups \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" --query 'SecurityGroups[].GroupId' --output text
check "network interfaces in the VPC mentioning the cluster" awsr ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[?contains(Description,'$CLUSTER_NAME') || contains(Description,'k8s-bleks')].[NetworkInterfaceId,Description]" --output text
check "EBS volumes for the cluster" awsr ec2 describe-volumes \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" --query 'Volumes[].VolumeId' --output text
check "RDS instances from the stack" awsr rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier,'$RDS_STACK')].DBInstanceIdentifier" --output text
check "IAM roles" aws --profile "$PROFILE" iam list-roles \
  --query "Roles[?starts_with(RoleName,'eksctl-$CLUSTER_NAME')].RoleName" --output text
check "OIDC providers" oidc_providers
check "log group" awsr logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
  --query 'logGroups[].logGroupName' --output text
check "subnet tags naming the cluster" awsr ec2 describe-subnets --subnet-ids "$SUBNET_A" "$SUBNET_B" \
  --query "Subnets[].Tags[?contains(Key,'$CLUSTER_NAME')].Key[]" --output text

if [ "$FOUND" = "0" ]; then echo "nothing left"; else echo "something is left or unknown; see above"; exit 1; fi
