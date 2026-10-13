#!/usr/bin/env bash
set -euo pipefail
kubectl rollout undo deployment/demo-web -n devops-demo
kubectl rollout status deployment/demo-web -n devops-demo
