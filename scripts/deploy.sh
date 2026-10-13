#!/usr/bin/env bash
# Deploy the demo-web application to the local kind cluster.
#
# Usage:
#   IMAGE=devops-demo-web:<tag> scripts/deploy.sh
#   # or, if IMAGE is unset, the image tag baked into the kustomize overlay
#   # at k8s/overlays/kind/kustomization.yaml is used.
#
# Behaviour:
#   1. Renders k8s/overlays/kind via `kubectl kustomize` (load-restrictor off,
#      because the overlay references manifests in ../..).
#   2. Applies namespace, deployment and service.
#   3. If IMAGE is provided, patches the Deployment image and waits for rollout.
#   4. Prints rollout status, pods, and a loopback-only port-forward hint.
#
# Safety:
#   - Uses --address 127.0.0.1 for port-forward examples in the printed hint;
#     this script does NOT open any public port.
#   - Never deletes namespaces, PVCs, or resources outside devops-demo.

set -euo pipefail

NAMESPACE="${NAMESPACE:-devops-demo}"
DEPLOYMENT="${DEPLOYMENT:-demo-web}"
OVERLAY="${OVERLAY:-k8s/overlays/kind}"
TIMEOUT="${TIMEOUT:-180s}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo ">>> Rendering overlay: $OVERLAY"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
kubectl kustomize "$OVERLAY" --load-restrictor LoadRestrictionsNone > "$RENDERED"

echo ">>> Applying to namespace $NAMESPACE"
kubectl apply -f "$RENDERED"

if [[ -n "${IMAGE:-}" ]]; then
  echo ">>> Setting image to $IMAGE"
  kubectl -n "$NAMESPACE" set image "deployment/$DEPLOYMENT" "demo-web=$IMAGE"
fi

echo ">>> Waiting for rollout (timeout=$TIMEOUT)"
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout="$TIMEOUT"

echo
kubectl -n "$NAMESPACE" get deploy,rs,pods -o wide
echo
echo "Smoke test hint (loopback only):"
echo "  kubectl -n $NAMESPACE port-forward --address 127.0.0.1 svc/$DEPLOYMENT 8082:80 &"
echo "  curl -sS http://127.0.0.1:8082/health"
