#!/usr/bin/env bash
# Rollback the demo-web Deployment.
#
# Usage:
#   scripts/rollback.sh                  # undo to previous revision
#   REVISION=2 scripts/rollback.sh       # undo to a specific revision
#   DRY_RUN=1 scripts/rollback.sh        # show what would happen, don't undo

set -euo pipefail

NAMESPACE="${NAMESPACE:-devops-demo}"
DEPLOYMENT="${DEPLOYMENT:-demo-web}"
TIMEOUT="${TIMEOUT:-120s}"

echo ">>> Rollout history before rollback:"
kubectl -n "$NAMESPACE" rollout history "deployment/$DEPLOYMENT"

HISTORY_LINES=$(kubectl -n "$NAMESPACE" rollout history "deployment/$DEPLOYMENT" | tail -n +3 | wc -l)
if [[ "$HISTORY_LINES" -lt 2 && "${FORCE:-0}" != "1" ]]; then
  echo "Only one revision in history; nothing to undo. Set FORCE=1 to override." >&2
  exit 1
fi

ARGS=(--namespace "$NAMESPACE" "deployment/$DEPLOYMENT")
if [[ -n "${REVISION:-}" ]]; then
  ARGS+=(--to-revision="$REVISION")
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ">>> DRY_RUN=1 — would execute: kubectl rollout undo ${ARGS[*]}"
  exit 0
fi

echo ">>> Executing: kubectl rollout undo ${ARGS[*]}"
kubectl rollout undo "${ARGS[@]}"

echo ">>> Waiting for rollout to stabilise (timeout=$TIMEOUT)"
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout="$TIMEOUT"

echo
echo ">>> Rollout history after rollback:"
kubectl -n "$NAMESPACE" rollout history "deployment/$DEPLOYMENT"
echo
echo ">>> Current image and pods:"
kubectl -n "$NAMESPACE" get "deployment/$DEPLOYMENT" \
  -o jsonpath='image={.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n "$NAMESPACE" get pods -l app="$DEPLOYMENT" -o wide
