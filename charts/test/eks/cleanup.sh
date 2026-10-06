#!/usr/bin/env bash
#
# Removes everything the test created inside the cluster, and waits until the AWS resources the
# controllers made for it (the NLB, its target group and security groups, the EBS volume) are gone.
# Run before deleting the RDS stack and the cluster: `eksctl delete cluster` does not know about
# them, and an NLB left behind keeps its network interfaces in the subnets.
#
# The AWS Load Balancer Controller is the only thing that deletes its NLB and security groups, so it
# is uninstalled only after they are confirmed gone. A listing that fails (an expired session, a
# denied call) counts as "still there", never as "none left".
#
# Usage: charts/test/eks/cleanup.sh <env file>
set -uo pipefail

ENV_FILE="${1:?usage: cleanup.sh <env file>}"
# shellcheck source=/dev/null
. "$ENV_FILE"
export KUBECONFIG="$OUT_DIR/kubeconfig"
NS="bl-eks"
awsr() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

# A call the account's access policy gates, so an expired or missing session fails here, up front.
awsr resourcegroupstaggingapi get-resources --resources-per-page 1 >/dev/null \
  || { echo "AWS calls fail with profile $PROFILE; renew the session and re-run"; exit 2; }

# The controllers tag what they create (elbv2.k8s.aws/cluster, ebs.csi.aws.com/cluster) as well as
# with this run's tags. Matching on both leaves out the nodes' own volumes and eksctl's groups,
# which carry the run's tags too and go with the cluster.
wait_gone() {   # <what> <resource type filter> <controller tag filter>
  local left="" rc
  for _ in $(seq 1 40); do
    left="$(awsr resourcegroupstaggingapi get-resources --resource-type-filters "$2" \
      --tag-filters "Key=Project,Values=$PROJECT" "$3" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text)"
    rc=$?
    [ "$rc" != "0" ] && { echo "  $1: cannot list them (exit $rc); treating as still present"; return 1; }
    [ -z "$left" ] && { echo "  $1: none left"; return 0; }
    sleep 15
  done
  echo "  $1 STILL PRESENT: $left"; return 1
}

FAILED=0
echo "== uninstall BridgeLink, delete its claim (kept by uninstall on purpose) and the namespace"
if helm -n "$NS" status bl >/dev/null 2>&1; then
  helm -n "$NS" uninstall bl --wait --timeout 5m || { echo "  helm uninstall failed"; FAILED=1; }
else
  echo "  release bl not installed"
fi
kubectl -n "$NS" delete pod pgclient sender --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n "$NS" delete pvc --all --wait=true --timeout=5m 2>/dev/null || true
kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=5m || { echo "  namespace $NS did not go"; FAILED=1; }

echo "== waiting for the controllers to delete their AWS resources"
LBC="Key=elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME"
wait_gone "load balancers" elasticloadbalancing:loadbalancer "$LBC" || FAILED=1
wait_gone "target groups" elasticloadbalancing:targetgroup "$LBC" || FAILED=1
wait_gone "load balancer security groups" ec2:security-group "$LBC" || FAILED=1
wait_gone "EBS volumes" ec2:volume "Key=ebs.csi.aws.com/cluster,Values=true" || FAILED=1

if [ "$FAILED" != "0" ] || kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo
  echo "STOPPED: something the test created is still there, so the AWS Load Balancer Controller is"
  echo "left running; it is the only thing that will delete its NLB and groups. Find out why (its"
  echo "logs: kubectl -n kube-system logs deploy/aws-load-balancer-controller), then re-run this."
  exit 1
fi

echo "== uninstall the AWS Load Balancer Controller"
if helm -n kube-system status aws-load-balancer-controller >/dev/null 2>&1; then
  helm -n kube-system uninstall aws-load-balancer-controller --wait || { echo "  uninstall failed"; exit 1; }
else
  echo "  not installed"
fi
echo "in-cluster cleanup done. Next: delete the RDS stack, then the cluster (README, Teardown)."
