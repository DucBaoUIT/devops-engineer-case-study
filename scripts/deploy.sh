#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE:?Set IMAGE to a versioned image reference}"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl set image deployment/demo-web demo-web="$IMAGE" -n devops-demo
kubectl rollout status deployment/demo-web -n devops-demo --timeout=120s
