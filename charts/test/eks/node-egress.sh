#!/usr/bin/env bash
#
# Gives the test cluster's nodes a public IP, for egress only. Run once, right after
# `eksctl create cluster` (or `eksctl create nodegroup`).
#
# Why: the subnets have an internet gateway but no NAT and do not assign public IPs, and eksctl's
# launch template for self-managed nodes sets only the security groups, never
# AssociatePublicIpAddress (eksctl warns "nodes won't get public IP addresses"). Without an address
# the nodes reach nothing outside the VPC, cannot pull images, and never become Ready.
#
# What it changes, all inside this cluster's own node group stacks: a new launch template version
# with AssociatePublicIpAddress=true, the Auto Scaling group pointed at it, and the running nodes
# replaced. The security groups are untouched; none admits traffic from outside the VPC. The
# template, its versions and the groups are deleted with the cluster.
#
# Usage: charts/test/eks/node-egress.sh <env file>
set -euo pipefail

ENV_FILE="${1:?usage: node-egress.sh <env file>}"
# shellcheck source=/dev/null
. "$ENV_FILE"
awsr() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

for ng in ng-a ng-b; do
  stack="eksctl-$CLUSTER_NAME-nodegroup-$ng"
  lt="$(awsr cloudformation describe-stack-resources --stack-name "$stack" \
    --query "StackResources[?ResourceType=='AWS::EC2::LaunchTemplate'].PhysicalResourceId" --output text)"
  asg="$(awsr cloudformation describe-stack-resources --stack-name "$stack" \
    --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" --output text)"
  [ -n "$lt" ] && [ -n "$asg" ] || { echo "$ng: no launch template or group in $stack"; exit 1; }

  # Keep the interface as eksctl wrote it (security groups included), adding only the public IP.
  # shellcheck disable=SC2016  # $Latest is the literal version name, not a shell variable
  nic="$(awsr ec2 describe-launch-template-versions --launch-template-id "$lt" --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.NetworkInterfaces[0]' --output json)"
  data="$(jq -c '{NetworkInterfaces: [. + {AssociatePublicIpAddress: true}]}' <<< "$nic")"
  # shellcheck disable=SC2016
  version="$(awsr ec2 create-launch-template-version --launch-template-id "$lt" --source-version '$Latest' \
    --version-description "public IP for egress" --launch-template-data "$data" \
    --query 'LaunchTemplateVersion.VersionNumber' --output text)"
  awsr autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg" \
    --launch-template "LaunchTemplateId=$lt,Version=$version"
  echo "$ng: launch template $lt version $version, group $asg"

  for id in $(awsr autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
      --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text); do
    awsr autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" \
      --no-should-decrement-desired-capacity >/dev/null
    echo "  replacing $id"
  done
done
echo "nodes are being replaced; watch with: kubectl get nodes -w"
