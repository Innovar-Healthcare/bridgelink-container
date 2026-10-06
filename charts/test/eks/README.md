# Chart test on Amazon EKS

Installs the published chart on a throwaway EKS cluster against Amazon RDS for PostgreSQL, using
[`examples/eks-values.yaml`](../../bridgelink/examples/eks-values.yaml), and checks what
[`kind-test.sh`](../kind-test.sh) cannot:
- the AWS Load Balancer Controller's internal NLB carrying MLLP to a channel
- appdata (the keystore) on EBS through a pod deletion and a node drain
- an EBS volume staying in its availability zone
- TLS to RDS
- the "restricted" Pod Security Standard on EKS
- `helm upgrade` never running two BridgeLink pods

**It costs money until it is torn down**: about USD 0.40 an hour (control plane, three t3.large
nodes, a db.t4g.micro, an NLB), or about USD 300 a month if forgotten. Run it in one sitting, and
finish with [Teardown](#teardown) and `strays.sh`.

## What it builds, and what it deliberately does not

`cluster.yaml` (eksctl) and `rds.yaml` (CloudFormation) are templates. `render.sh` fills them from an
env file kept **outside the repository**, so no account, network or address detail is committed.

- **The network is an existing VPC and two existing subnets** in different zones. Nothing creates
  a VPC, subnet, NAT gateway or route, and nothing modifies the subnets. The NLB's subnets are
  named by annotation rather than discovered through subnet tags for that reason.
- **Nodes are self-managed and carry a public IP, for egress only.** The design assumes subnets
  with an internet gateway but no NAT, which do not assign public IPs themselves; managed node
  groups refuse such subnets. eksctl's launch template for self-managed nodes does not request an
  address either, so `node-egress.sh` adds a launch template version that does and replaces the
  nodes.
- **Volumes name their KMS key** (`EBS_KMS_KEY_ARN`). An account whose default EBS encryption key
  is customer-managed may not let Auto Scaling or the EBS CSI driver use it; nodes then die at
  boot with `Client.InvalidKMSKey.InvalidState`. The AWS-managed key (`alias/aws/ebs`) avoids that. No security group in the cluster admits traffic from outside the
  VPC, apart from the private endpoint's one rule for the operator's network.
- **The API endpoint is private.** eksctl needs a public endpoint while it creates the cluster,
  so it is created limited to the operator's /32 and switched to private straight afterwards.
  From then on `kubectl` reaches the private endpoint over the network routed into the VPC (a
  VPN). Its hostname resolves publicly to the private addresses.
- **RDS joins the security group the nodes already share**, so it needs no new group.
- **Everything is tagged** `Owner`, `Ticket`, `Project` and `Ephemeral`: the cluster, nodes,
  volumes, RDS, and what the controllers create.

## Prerequisites

- `aws`, `eksctl` (0.231 or later), `kubectl`, `helm` (3.x or 4.x), `jq`, `openssl`, `nc`,
  `envsubst`.
- A live AWS session in the profile the env file names.
- A network route from this machine to the VPC, for the private endpoint.
- To install the published chart while its package is private:
  `gh auth refresh -s read:packages`, then
  `gh auth token | helm registry login ghcr.io -u <github user> --password-stdin`.
  Without that, run the test with `CHART_SOURCE=checkout`, and say so in the results.

## Run

All commands take the env file; `E` below is its path. Copy [`env.example`](env.example)
outside the repo and fill it in.

1. Render, and check the cluster config without creating anything:

   ```bash
   charts/test/eks/render.sh "$E"
   . "$E"; eksctl create cluster -f "$OUT_DIR/cluster.yaml" --profile "$PROFILE" --dry-run
   ```

2. Create the cluster (about 20 minutes), give the nodes their egress address, then make the
   endpoint private. eksctl ends with "failed to create addons" (CoreDNS and the EBS driver
   `DEGRADED`) when the nodes have no address yet; that clears once `node-egress.sh` has replaced
   them.

   ```bash
   eksctl create cluster -f "$OUT_DIR/cluster.yaml" --profile "$PROFILE" --kubeconfig "$OUT_DIR/kubeconfig"
   charts/test/eks/node-egress.sh "$E"
   eksctl utils update-cluster-vpc-config --cluster "$CLUSTER_NAME" --region "$REGION" --profile "$PROFILE" \
     --private-access=true --public-access=false --approve
   KUBECONFIG="$OUT_DIR/kubeconfig" kubectl get nodes -L topology.kubernetes.io/zone
   ```

3. Create RDS (about 10 minutes). The security group is eksctl's shared node group:

   ```bash
   SG="$(aws --profile "$PROFILE" --region "$REGION" cloudformation describe-stacks \
     --stack-name "eksctl-$CLUSTER_NAME-cluster" \
     --query "Stacks[0].Outputs[?OutputKey=='SharedNodeSecurityGroup'].OutputValue" --output text)"
   aws --profile "$PROFILE" --region "$REGION" cloudformation deploy --stack-name "$RDS_STACK" \
     --template-file charts/test/eks/rds.yaml \
     --parameter-overrides "SubnetIds=$SUBNET_A,$SUBNET_B" "SecurityGroupId=$SG" \
       "Owner=$OWNER" "Ticket=$TICKET" "Project=$PROJECT" \
     --tags "Owner=$OWNER" "Ticket=$TICKET" "Project=$PROJECT" "Ephemeral=true"
   ```

4. Prepare the cluster, then run the test:

   ```bash
   charts/test/eks/setup.sh "$E"
   charts/test/eks/eks-test.sh "$E"
   ```

   The test leaves the release installed for inspection. Reach the admin API with
   `kubectl -n bl-eks port-forward svc/bl-bridgelink-bl 8443`.

## Teardown

In this order. Each step needs the one before it to have finished.

```bash
charts/test/eks/cleanup.sh "$E"     # waits until the NLB, its groups and the EBS volume are gone
aws --profile "$PROFILE" --region "$REGION" cloudformation delete-stack --stack-name "$RDS_STACK"
aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-delete-complete --stack-name "$RDS_STACK"
eksctl delete cluster -f "$OUT_DIR/cluster.yaml" --profile "$PROFILE" --wait --disable-nodegroup-eviction
charts/test/eks/strays.sh "$E"      # read-only; exits non-zero if anything is left
helm registry logout ghcr.io
```

`--disable-nodegroup-eviction` is not optional. Without it eksctl cordons every node at once and then
drains them, the CoreDNS and EBS controller disruption budgets allow no eviction once their pods
have nowhere to go, and the delete waits forever without deleting anything.

`eksctl delete cluster` removes only what eksctl created. **A load balancer or volume the
controllers made outlives it**, and an NLB left behind keeps network interfaces in the subnets.
That is why `cleanup.sh` runs first and waits.

## Troubleshooting

- **The NLB target never turns healthy.** The target is unhealthy until a deployed channel listens
  on 6661. The controller also has to add a rule letting the NLB's group reach the pod. It adds
  that rule to the one node group tagged `kubernetes.io/cluster/<name>`, and it fails with "expected
  exactly one security group" if a node's interface has none tagged or several. Check
  `kubectl -n kube-system logs deploy/aws-load-balancer-controller`.
- **`kubectl` hangs after the endpoint went private.** The machine has no route into the VPC, or
  the network it comes from is not `OPERATOR_PRIVATE_CIDR`.
- **The controller logs `AccessDenied`.** eksctl's built-in policy for it
  (`wellKnownPolicies.awsLoadBalancerController`) can lag a new controller release. Attach the
  controller's own `iam_policy.json` for the pinned version to its role.
- **`eksctl delete cluster` cannot reach the cluster.** With the endpoint private it has to come
  from inside the VPC or the network routed to it, like `kubectl`. Otherwise re-enable the public
  endpoint, limited to your /32, with `eksctl utils update-cluster-vpc-config` first (by
  `--cluster` and `--region`: it refuses `-f` together with the access flags).
- **A node never joins.** It has no public IP, so no egress, and cannot reach the images or the
  API. Check the subnet has a route to an internet gateway.
