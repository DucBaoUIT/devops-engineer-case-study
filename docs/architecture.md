# Architecture & CI/CD Flow

## 1. Component diagram

```
                          ┌────────────────────────────┐
                          │   GitHub (origin/main)     │
                          │  DucBaoUIT/devops-engineer │
                          │      -case-study           │
                          └──────────────┬─────────────┘
                                         │ webhook / SCM poll
                                         ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │                    Jenkins controller (container)                │
   │  jenkins/jenkins:lts-jdk17 — bound to 127.0.0.1:8080 (SSH tun.)  │
   └──────────────┬───────────────────────────────────────────────────┘
                  │ dispatches to
                  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │           Jenkins agent  (label: linux-docker-agent)             │
   │  git · python3.12 + venv · docker CLI + socket · kubectl · curl  │
   │  Workspace caches: .pip-cache/, .buildkit-cache/                 │
   └──────────────┬───────────────────────────────────────────────────┘
                  │
   ┌──────────────┴────────────────────────────────────────────────────────┐
   │ Stages:                                                               │
   │  1. Checkout            (git)                                         │
   │  2. Validate repo       (files present, no tracked secrets, USER set) │
   │  3. Test & Build (parallel):                                          │
   │       3a. Unit tests    (python -m unittest discover -s app/tests)    │
   │       3b. Build image   (docker buildx + cache mounts, tag=$GIT_SHA)  │
   │  4. Publish image       (docker push → Docker Hub, only on main)      │
   │  5. Deploy              (kubectl apply -k, kubectl set image,         │
   │                          kubectl rollout status --timeout=180s)       │
   │  6. Smoke test          (kubectl port-forward 127.0.0.1:18082,        │
   │                          curl /health + /)                            │
   └──────────────┬────────────────────────────────────────────────────────┘
                  │
                  ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │      Kubernetes — kind/devops-demo (local lab, single node)      │
   │                                                                  │
   │  Namespace: devops-demo                                          │
   │  ├─ Deployment/demo-web  (2 replicas, RollingUpdate              │
   │  │                        maxSurge=1, maxUnavailable=0)          │
   │  │   ├─ image: <hub>/devops-demo-web:<git-sha>                  │
   │  │   ├─ probes: startup(/health, 30×2s)                         │
   │  │   │          readiness(/health, 5s period)                   │
   │  │   │          liveness(/health, 10s period)                   │
   │  │   ├─ resources: 100m/64Mi req · 500m/256Mi lim               │
   │  │   └─ securityContext: runAsNonRoot, uid 10001,               │
   │  │                       readOnlyRootFilesystem, drop ALL caps  │
   │  ├─ ReplicaSet/demo-web-<hash>                                   │
   │  ├─ Pod × 2  (Flask app behind tini as PID 1)                    │
   │  └─ Service/demo-web  ClusterIP  :80 → :8080                     │
   │                                                                  │
   │  Access: kubectl port-forward --address 127.0.0.1 svc/demo-web   │
   │          (loopback only — no LoadBalancer, no NodePort, no       │
   │           ingress, no firewall change)                           │
   └──────────────────────────────────────────────────────────────────┘

   Separate demo runtime (unchanged by the pipeline):
   ┌──────────────────────────────────────────────────────────────────┐
   │  docker compose: app service                                     │
   │    devops-case-study-app-1  →  0.0.0.0:8081 (LAN) → :8080        │
   │    image devops-demo-web:local (built from same Dockerfile)      │
   └──────────────────────────────────────────────────────────────────┘
```

## 2. Environments

| Environment | Purpose | Deploy trigger | Access |
| --- | --- | --- | --- |
| **Local compose** (`app` service) | Developer quick-check on the host | `docker compose up -d app` | `http://<host>:8081` (LAN) |
| **kind lab** (`devops-demo` cluster) | Case-study target — behaves like a real Kubernetes cluster | `scripts/deploy.sh` or Jenkins pipeline on `main` | `kubectl port-forward --address 127.0.0.1 svc/demo-web 8082:80` (loopback only) |
| **Docker Hub** | Public image registry, source of truth for image tags | `docker push` from Jenkins after successful tests + build | Pull by any Kubernetes cluster |

## 3. Image tagging policy

| Tag shape | Where it comes from | Purpose |
| --- | --- | --- |
| `<git-sha-12>` | Jenkinsfile: `env.GIT_COMMIT.take(12)` | **Deploy target.** Immutable, traceable to a commit. |
| `latest` | Pushed alongside the SHA tag | Convenience for humans pulling manually; **never** referenced by a Deployment. |
| `<git-sha-12>-w<worktree-hash>` | Local `scripts/deploy.sh` on a dirty tree | Distinguishes local experiments from CI-built images. |
| `local` | `docker-compose.yml` | Only for the compose demo; not pushed anywhere. |

`imagePullPolicy`:
- Base manifest (`k8s/deployment.yaml`): `Always` — assumes a registry-backed image.
- Kind overlay (`k8s/overlays/kind/kustomization.yaml`): `IfNotPresent` — required when the image was pre-loaded via `kind load docker-image` and does not exist in any registry.

## 4. Secret handling

| Secret | Where it lives | How it is used |
| --- | --- | --- |
| Docker Hub user + access token | Jenkins credential `dockerhub-creds` (username/password kind) | `withCredentials` in the Publish stage → `docker login --password-stdin` |
| Docker Hub username (public part only) | Jenkins credential `dockerhub-username` (text kind) | Injected into `env.DOCKERHUB_USERNAME` so the image name is not hard-coded |
| Kubernetes access | Jenkins credential `kubeconfig-dev` (file kind) — a kubeconfig scoped to namespace `devops-demo` | `withCredentials([file(...)])` in Deploy + Smoke stages, exported as `KUBECONFIG` |

Nothing above appears in the repository, in image labels, or in build logs.
`.gitignore` blocks `.env`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`,
`kubeconfig*`, `credentials*`, `secrets/`. `.dockerignore` blocks the same
set from the build context, so secrets cannot be baked into an image layer
even by accident.

## 5. Rollout & rollback flow

**Rollout** (rolling update, `maxSurge=1 maxUnavailable=0`):
1. `kubectl set image` (or `kubectl apply`) creates a new ReplicaSet.
2. New pod is scheduled → `startupProbe` (up to 60 s) → `readinessProbe` passes.
3. Only after the new pod is Ready does the old pod receive SIGTERM.
4. `tini` (PID 1) forwards SIGTERM to Flask; process exits in ~200 ms with
   code 143; `terminationGracePeriodSeconds=30` is never hit.
5. `kubectl rollout status --timeout=180s` returns success.

**Rollback**:
```
kubectl rollout undo deployment/demo-web -n devops-demo
# or, pinned to a specific revision:
kubectl rollout undo deployment/demo-web -n devops-demo --to-revision=3
# or, via the wrapper script:
scripts/rollback.sh
REVISION=3 scripts/rollback.sh
DRY_RUN=1 scripts/rollback.sh
```

`revisionHistoryLimit: 5` keeps the last 5 ReplicaSets for rollback.

## 6. Failure modes covered by design

| Failure | Detection | Reaction |
| --- | --- | --- |
| Unit test fails | Jenkins `Unit tests` stage exit code ≠ 0 | Pipeline aborts. No image built, nothing pushed, nothing deployed. |
| Image build fails | Jenkins `Build image` stage | Pipeline aborts. |
| Docker Hub push fails (bad creds, network) | `docker push` non-zero | Pipeline aborts before Deploy stage. |
| Bad image tag deployed (typo, deleted tag) | New pod → `ErrImagePull` → `ImagePullBackOff`. Old ReplicaSet still has 2 Ready pods (`maxUnavailable=0`). | Service stays up. Operator runs `scripts/rollback.sh`. Verified in `docs/evidence/phase7-rollback-drill.md`. |
| App starts but `/health` returns non-200 | `startupProbe` fails 30× → container restarted by kubelet; if still failing, pod is NotReady and never receives traffic. Endpoints removed. | Old ReplicaSet keeps serving. Rollback via `scripts/rollback.sh`. |
| App passes probes but returns bad data | Smoke test in Jenkins stage 6 (`curl /health` + `curl /`) fails | Pipeline marked FAILURE. Manual rollback (deliberate — auto-rollback is a policy decision, not a technical one). |
| Node under memory pressure | Pod `limits.memory=256Mi` → OOMKilled → kubelet restarts | If restarts exceed `restartPolicy` thresholds, Deployment marks pod NotReady. Old RS still serves. |

## 7. Non-goals of this architecture (explicitly)

- No public ingress / LoadBalancer / NodePort. Access is loopback-only
  through `kubectl port-forward`. Adding a public ingress would require a
  firewall policy decision by the operator.
- No Helm. Kustomize is enough for two overlays and keeps the manifests
  readable during an interview walkthrough.
- No service mesh, no Istio, no mTLS. Out of scope for a single-service
  case study.
- No auto-rollback on smoke-test failure. Automatic rollback in production
  needs an SLO-based signal (error rate, latency p99), not a single curl.
- No Prometheus/Grafana stack. Metrics-server is not installed on the kind
  cluster, so `kubectl top` returns "Metrics API not available" — this is
  documented, not hidden.
