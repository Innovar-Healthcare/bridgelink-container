#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# BridgeLink private container registry — verification (IRT-1866)
#
# Checks the two properties that actually matter and are easy to get wrong:
#
#   1. The repositories are PRIVATE. An ECR repository with no repository policy
#      is reachable only via IAM identity policies. A repository policy is how
#      these would silently become public, so its absence is asserted.
#
#   2. The lifecycle policy will not orphan a live multi-arch image. buildx
#      pushes a manifest LIST whose per-architecture children are untagged; an
#      over-eager untagged rule deletes those children and leaves published
#      images unpullable on some platforms. This resolves each repository's
#      newest release tag to its child manifests and asserts none of them appear
#      in the lifecycle policy's dry-run expiry list.
#
# Read-only: uses start/get-lifecycle-policy-preview, which reports what a policy
# WOULD expire without deleting anything.
#
# Usage:
#   ./infra/verify-ecr.sh
# ---------------------------------------------------------------------------

: "${REGION:=us-east-2}"
: "${REPO_NAMESPACE:=innovarhealthcare}"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Missing required command: $cmd"; exit 1; }
done

# Deliberately a plain list, not an associative array — macOS ships bash 3.2,
# which has no `declare -A`.
REPOS="
$REPO_NAMESPACE/bridgelink
$REPO_NAMESPACE/bridgelink-dhi
$REPO_NAMESPACE/bridgelink-dhi-slim
"

FAILED=0
fail() { red "   x $*"; FAILED=1; }
pass() { green "   + $*"; }

FIRST_REPO="$(echo "$REPOS" | sed -n '2p')"
if ! aws ecr describe-repositories --repository-names "$FIRST_REPO" >/dev/null 2>&1; then
  red "Cannot describe $FIRST_REPO — the stack may not be deployed, or this"
  red "session is not MFA'd (Innovar-MFA-policy denies ECR without MFA)."
  exit 1
fi

for repo in $REPOS; do
  cyan ">> $repo"

  # --- 1. Private: no repository policy ------------------------------------
  if err="$(aws ecr get-repository-policy --repository-name "$repo" 2>&1 >/dev/null)"; then
    fail "HAS a repository policy — it may be publicly pullable. Review it:"
    red  "     aws ecr get-repository-policy --region $REGION --repository-name $repo"
  elif grep -q 'RepositoryPolicyNotFoundException' <<<"$err"; then
    pass "no repository policy (IAM-only)"
  else
    fail "could not determine repository policy state: $err"
  fi

  # --- 2. Lifecycle policy present -----------------------------------------
  policy=""
  if policy="$(aws ecr get-lifecycle-policy --repository-name "$repo" \
                --query lifecyclePolicyText --output text 2>/dev/null)"; then
    pass "lifecycle policy present ($(jq '.rules | length' <<<"$policy") rules)"
  else
    fail "NO lifecycle policy — storage will grow unbounded"
    continue
  fi

  # --- 3. Dry run preserves the newest release's child manifests ------------
  # Newest release tag by push time. Release tags start '26.'; rolling tags like
  # latest-dhi are excluded, matching the lifecycle policy's own prefix filter.
  newest="$(aws ecr describe-images --repository-name "$repo" \
    --query 'sort_by(imageDetails,&imagePushedAt)[].imageTags' --output json 2>/dev/null \
    | jq -r 'flatten | map(select(startswith("26."))) | last // empty')"

  if [[ -z "$newest" ]]; then
    yellow "   - no 26.* release tag yet — re-run after the first publish"
    continue
  fi

  manifest="$(aws ecr batch-get-image --repository-name "$repo" \
    --image-ids "imageTag=$newest" \
    --accepted-media-types \
      "application/vnd.docker.distribution.manifest.list.v2+json" \
      "application/vnd.oci.image.index.v1+json" \
    --query 'images[0].imageManifest' --output text 2>/dev/null || true)"

  children="$(jq -r '[.manifests[]?.digest] | join(" ")' <<<"$manifest" 2>/dev/null || true)"
  if [[ -z "$children" ]]; then
    yellow "   - $newest is not a manifest list (single-arch?) — no children to orphan"
    continue
  fi

  aws ecr start-lifecycle-policy-preview --repository-name "$repo" \
    --lifecycle-policy-text "$policy" >/dev/null 2>&1 || true

  status="UNKNOWN"
  for _ in $(seq 1 30); do
    status="$(aws ecr get-lifecycle-policy-preview --repository-name "$repo" \
      --query status --output text 2>/dev/null || echo FAILED)"
    [[ "$status" == "IN_PROGRESS" ]] || break
    sleep 2
  done

  if [[ "$status" != "COMPLETE" ]]; then
    fail "lifecycle preview did not complete (status=$status)"
    continue
  fi

  expiring="$(aws ecr get-lifecycle-policy-preview --repository-name "$repo" \
    --query 'previewResults[].imageDigest' --output json | jq -r '.[]?')"

  orphaned=""
  for child in $children; do
    if grep -qxF "$child" <<<"$expiring"; then
      orphaned="$orphaned $child"
    fi
  done

  n_children="$(wc -w <<<"$children" | tr -d ' ')"
  n_expiring="$(grep -c . <<<"$expiring" || true)"

  if [[ -n "$orphaned" ]]; then
    fail "the lifecycle policy would expire child manifests of the LIVE image"
    red  "     $newest, breaking per-platform pulls:$orphaned"
    red  "     Raise UntaggedRetentionDays — never set the untagged rule to 1 day."
  else
    pass "$newest — all $n_children child manifests preserved ($n_expiring images would expire)"
  fi
done

# --- 4. Customer read policy covers every repository ------------------------
#
# Owned by IRT-1865, checked here because this is where the repositories are
# created: a customer whose policy predates the -dhi / -dhi-slim repositories can
# authenticate and pull the standard image, then get a bare "not authorized" on the
# hardened ones. That failure looks like a broken image, not a missing grant, so it
# is worth catching at publish time rather than in a support ticket.
READ_POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/bridgelink-ecr-readOnly"

cyan ">> customer read policy ($(basename "$READ_POLICY_ARN"))"
version="$(aws iam get-policy --policy-arn "$READ_POLICY_ARN" \
  --query Policy.DefaultVersionId --output text 2>/dev/null || true)"

if [[ -z "$version" || "$version" == "None" ]]; then
  yellow "   - cannot read it (missing, or this session lacks iam:GetPolicy)."
  yellow "     Not fatal here — scope is IRT-1865's to own — but confirm it covers"
  yellow "     all three repositories before telling a customer the images are ready."
else
  # Only Resources from statements that actually grant PULL. Flattening every
  # Resource in the document would treat the Resource:"*" of the
  # ecr:GetAuthorizationToken statement as a blanket grant and pass everything.
  resources="$(aws iam get-policy-version --policy-arn "$READ_POLICY_ARN" \
    --version-id "$version" --query PolicyVersion.Document --output json 2>/dev/null \
    | jq -r '
        [ .Statement[]?
          | select((.Effect // "Allow") == "Allow")
          | select(
              ((.Action // []) | if type == "array" then . else [.] end)
              | any(. == "ecr:BatchGetImage" or . == "ecr:GetDownloadUrlForLayer"
                    or . == "ecr:*" or . == "*"))
          | .Resource ]
        | flatten | .[]?' || true)"

  # Compare on the "repository/<name>" tail so region/account wildcards in the ARN
  # do not matter. A resource ending in * covers every repository it prefixes.
  for repo in $REPOS; do
    covered=0
    while IFS= read -r res; do
      [[ -n "$res" ]] || continue
      tail_pat="${res##*:repository/}"
      [[ "$tail_pat" == "$res" && "$res" != "*" ]] && continue   # not a repository ARN
      if [[ "$res" == "*" || "$tail_pat" == "$repo" ]]; then
        covered=1; break
      fi
      if [[ "$tail_pat" == *"*" && "$repo" == ${tail_pat%\*}* ]]; then
        covered=1; break
      fi
    done <<<"$resources"

    if [[ "$covered" -eq 1 ]]; then
      pass "$repo is pullable by customers"
    else
      fail "$repo is NOT in the customer read policy — customers get 'not authorized'"
    fi
  done
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  green "All checks passed."
else
  red "One or more checks FAILED — see above."
  exit 1
fi
