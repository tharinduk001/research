#!/usr/bin/env bash
# Run one full deployment cycle and record it as a dataset row.
#
#   ./scripts/run-deployment.sh <label> [notes]
#
#   <label>  dataset label — "clean" for a no-fault deploy, otherwise the fault name
#            (e.g. bad_migration, memory_leak, cpu_hot_loop)
#   [notes]  optional free text
#
# Writes one row to data/deployments.csv. Timestamps are UTC epoch seconds and are the
# whole point of this file: Prometheus only retains 10 days, so the exact rollout
# window must be recorded now to slice features from later.
#
# Assumes the working tree already contains whatever change is being deployed
# (for a clean run the script bumps a build marker itself).

set -euo pipefail

REPO="tharinduk001/research"
NS="dev"
CSV="data/deployments.csv"
LABEL="${1:?usage: run-deployment.sh <label> [notes]}"
NOTES="${2:-}"

mkdir -p data
if [ ! -f "$CSV" ]; then
  echo "deploy_id,label,image_tag,ci_run_id,cd_run_id,start_ts,end_ts,duration_s,outcome,notes" > "$CSV"
fi
DEPLOY_ID=$(( $(wc -l < "$CSV") ))

# A clean run needs *some* file change so CI produces a new image.
if [ "$LABEL" = "clean" ]; then
  echo "baseline run $DEPLOY_ID at $(date -u +%FT%TZ)" > demo-application/BUILD_MARKER
  git add demo-application/BUILD_MARKER
  git commit -q -m "Baseline deployment $DEPLOY_ID (no-fault)"
  git push -q origin main
fi

echo "[$(date -u +%T)] building..."
gh workflow run ci.yaml --repo "$REPO"
sleep 8
CI_RUN=$(gh run list --repo "$REPO" --workflow=ci.yaml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$CI_RUN" --repo "$REPO" --exit-status >/dev/null
TAG=$(gh run view "$CI_RUN" --repo "$REPO" --json number -q .number)
echo "[$(date -u +%T)] image tag $TAG"

START=$(date -u +%s)
gh workflow run cd.yaml --repo "$REPO" -f image_tag="$TAG" -f namespace="$NS"
sleep 8
CD_RUN=$(gh run list --repo "$REPO" --workflow=cd.yaml --limit 1 --json databaseId -q '.[0].databaseId')
echo "[$(date -u +%T)] rollout $CD_RUN started"

# Do not abort on a failed rollout — a failure is a valid dataset outcome.
set +e
gh run watch "$CD_RUN" --repo "$REPO" --exit-status >/dev/null
set -e
END=$(date -u +%s)
OUTCOME=$(gh run view "$CD_RUN" --repo "$REPO" --json conclusion -q .conclusion)

echo "$DEPLOY_ID,$LABEL,$TAG,$CI_RUN,$CD_RUN,$START,$END,$((END-START)),$OUTCOME,\"$NOTES\"" >> "$CSV"
echo "[$(date -u +%T)] done: $OUTCOME in $((END-START))s -> $CSV"
