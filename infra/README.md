# `infra/` — private container registry (IRT-1866)

CloudFormation for the private AWS ECR repositories that CI publishes BridgeLink
release images to, from 26.9 onward. Mirrors the layout of `innovar-portal`
(`infra/<name>-stack.yaml` + a deploy script with an MFA guard).

| File | Purpose |
|---|---|
| `ecr-stack.yaml` | The stack: three private repositories, lifecycle policies, and the ECR push policy attached to the CI OIDC role. |
| `ecr-stack-import.yaml` | One-time-use template for importing the pre-existing `innovarhealthcare/bridgelink` repository. Inert once the stack exists. |
| `deploy-ecr.sh` | Deploy/update. Performs the import automatically on a first run. |
| `verify-ecr.sh` | Read-only checks: repositories are IAM-only, and the lifecycle policy will not orphan a live multi-arch image. |

## Deploy

Needs an **MFA'd** AWS session — `Innovar-MFA-policy` denies CloudFormation, ECR
and IAM without one, and `aws sts get-caller-identity` succeeds anyway, so both
scripts probe with a call the policy actually gates and fail early with a clear
message.

```bash
./infra/deploy-ecr.sh      # region us-east-2, stack bridgelink-ecr
./infra/verify-ecr.sh      # confirm private + lifecycle-safe
```

Then hand the `RepositoryArns` output to **IRT-1865**. As of 2026-08-18 the
existing `bridgelink-ecr-readOnly` managed policy grants pull on exactly one ARN —
`repository/innovarhealthcare/bridgelink` — so a customer holding it can pull the
standard image and **silently cannot pull `-dhi` or `-dhi-slim`**. That policy
needs the two new ARNs (or a `bridgelink*` wildcard) before the hardened variants
are sellable.

## Two things that look like mistakes but are not

**Tags are `MUTABLE`.** IRT-1866 preferred immutable release tags, but
`build-images.yml` re-pushes `<version>-dhi` every Monday after Docker repatches
the hardened base — that repatch is the entire value of the DHI variant, and
immutable version tags would block it from the second Monday after release. The
immutable release identity is therefore the **manifest digest**, recorded per
release; customers who need an unchanging reference pin by digest.

**The untagged lifecycle rule is not what protects multi-arch images — ECR is.**
buildx pushes a manifest list whose per-architecture children (and attestations)
are untagged permanently, so an untagged rule selects them for the whole life of
the image. ECR's lifecycle evaluation is manifest-list aware and does not expire a
child whose index is not itself expiring; verified 2026-08-18 against the live
26.3.1 index in `innovarhealthcare/bridgelink`, whose four untagged children were
~12 weeks old and still previewed as 0 expiring. The tagged count rule is what
bounds storage; the untagged rule only reaps manifests genuinely orphaned once
their index expires. `verify-ecr.sh` re-runs that preview check, so a change in
ECR's behaviour shows up as a failed verification rather than a broken release.

## Deliberately not here

* **Customer IAM users and the read policy** — IRT-1865, in `innovar-portal`.
* **Anything in the portal's CloudFormation stack.** Image infrastructure must
  not share the portal stack's lifecycle; these are separate stacks on purpose.
