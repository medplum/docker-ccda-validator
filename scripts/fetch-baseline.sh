#!/usr/bin/env bash
# Find the most recently pushed image in ECR and its active Inspector findings,
# for scripts/remediate-vulnerabilities.sh to compare against and act on.
#
#   scripts/fetch-baseline.sh OUTPUT_DIR
#
# Writes OUTPUT_DIR/inspector.json and prints `image=<ref>` and
# `inspector=<path>` lines (appended to $GITHUB_OUTPUT when set). Logs in to
# ECR so the image can be pulled. Needs AWS credentials with
# ecr:DescribeImages, ecr:GetAuthorizationToken, ecr:BatchGetImage,
# ecr:GetDownloadUrlForLayer and inspector2:ListFindings.
set -euo pipefail

OUT="${1:?usage: fetch-baseline.sh OUTPUT_DIR}"
REPOSITORY="${ECR_REPOSITORY:-medplum/ccda-validator}"
mkdir -p "$OUT"

registry="$(aws ecr describe-repositories --repository-names "$REPOSITORY" \
  --query 'repositories[0].repositoryUri' --output text | cut -d/ -f1)"
tag="$(aws ecr describe-images --repository-name "$REPOSITORY" --filter tagStatus=TAGGED \
  --query 'reverse(sort_by(imageDetails, &imagePushedAt))[].imageTags[]' --output json \
  | jq -r '[.[] | select(startswith("v"))][0] // empty')"
if [[ -z "$tag" ]]; then
  echo "no v* tag found in $REPOSITORY" >&2
  exit 1
fi
image="$registry/$REPOSITORY:$tag"

aws ecr get-login-password | docker login --username AWS --password-stdin "$registry" >/dev/null

criteria="$(jq -n --arg repo "$REPOSITORY" --arg tag "$tag" '{
  ecrImageRepositoryName: [{comparison: "EQUALS", value: $repo}],
  ecrImageTags: [{comparison: "EQUALS", value: $tag}],
  findingStatus: [{comparison: "EQUALS", value: "ACTIVE"}]
}')"
aws inspector2 list-findings --filter-criteria "$criteria" --output json > "$OUT/inspector.json"
echo "Inspector: $(jq '.findings | length' "$OUT/inspector.json") active finding(s) on $tag" >&2

{
  echo "image=$image"
  echo "inspector=$OUT/inspector.json"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
