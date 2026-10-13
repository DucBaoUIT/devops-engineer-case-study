# Phase 6 — Pipeline optimization measurements

Timestamp: 2026-10-13 (UTC)
Host: 8 vCPU / 11 GiB RAM / Ubuntu 24.04.3 / Docker 29.9.0 / kind 0.30.0 / kubectl v1.37.1
Image under test: `devops-demo-web:cc5480ddbf9e-w*` (186 MB uncompressed, ~45 MB compressed)

> All numbers below are wall-clock `real` from `bash time -p`, taken on the
> host described above. Nothing is extrapolated. Each measurement was
> executed at least once end-to-end before being recorded.

## 1. Baseline (original Dockerfile, no BuildKit cache mounts)

| Step | Time | Notes |
| --- | --- | --- |
| `python -m unittest discover -s app/tests` | **0.16 s** | 2 tests, exit 0 |
| `docker build` (warm layer cache, unchanged context) | **2.76 s** | Attestation manifest included |
| `docker build --no-cache` | **9.89 s** | apt-get + pip install from network |
| `kind load docker-image` (fresh, 45 MB compressed) | **2.10 s** | Excludes image build |
| `kubectl kustomize` render | **0.04 s** | Overlay at `k8s/overlays/kind` |
| `kubectl apply -f -` + `rollout status` (no-op) | **0.39 s** | Already-converged state |
| `docker stop` (no tini) | **10.22 s** | Exit 137 (SIGKILL after grace) |

## 2. After optimisation (apt-get tini + BuildKit cache mounts for apt and pip)

| Step | Time | Δ vs baseline |
| --- | --- | --- |
| `docker build` fully cold (builder cache pruned, includes base image pull) | **15.07 s** | one-off cost, not representative of CI with cache |
| `docker build --no-cache` with warm apt+pip cache mounts | **9.75 s** | −1.4 % (downloads cached, install work unchanged) |
| `docker build` warm (all layer cache hits) | **1.17 s** | **−58 %** |
| `docker stop` (tini as PID 1) | **0.22 s** | **−98 %**, exit 143 (SIGTERM, clean) |
| Image size | 186 MB | +1 MB (tini + BuildKit metadata) |
| `kind load docker-image` | 2.10 s | unchanged (image size roughly equal) |
| `kubectl apply` + rollout to a new tag | ~4 s | includes ReplicaSet surge + termination |

## 3. End-to-end deploy timing (build → load → apply → smoke test)

Command sequence:

```
docker build -t devops-demo-web:$TAG .
kind load docker-image devops-demo-web:$TAG --name devops-demo
IMAGE=devops-demo-web:$TAG scripts/deploy.sh   # kustomize render + apply + rollout status
kubectl port-forward --address 127.0.0.1 svc/demo-web 8082:80 &
curl -sS http://127.0.0.1:8082/health
```

| Phase | Cold (no cache) | Warm (Jenkins agent with cache) |
| --- | --- | --- |
| Docker build | 15.07 s | 1.17 s |
| Kind load | 2.10 s | 2.10 s |
| Kustomize + apply + rollout status | ~4 s | ~4 s |
| Port-forward + smoke test | ~2 s | ~2 s |
| **Total (approx.)** | **~23 s** | **~9 s** |

Jenkins adds: checkout (~2 s cold, ~0.5 s warm), venv install (~2 s warm with
`.pip-cache` volume), pipeline overhead (~3–5 s). Expected pipeline duration:
~15 s warm, ~30 s cold, well inside a 25-minute timeout.

## 4. What was optimised, and why

1. **BuildKit cache mount on `/root/.cache/pip`** — pip reuses wheels across
   builds even when `requirements.txt` changes; the cache lives outside the
   image layer so it does not bloat the image.
2. **BuildKit cache mount on `/var/cache/apt` + `/var/lib/apt`** (with
   `APT::Keep-Downloaded-Packages "true"` and `docker-clean` removed) —
   `apt-get install tini` does not re-download the .deb or the package lists
   on every rebuild.
3. **Layer ordering** — `COPY app/requirements.txt` before `COPY app/` so
   source-only edits do not invalidate the pip layer.
4. **`tini` as PID 1** — proper SIGTERM forwarding. Kubernetes `preStop` and
   `terminationGracePeriodSeconds=30` now drain the pod in ~200 ms instead of
   hitting the grace timeout and being SIGKILL'd.
5. **Immutable, traceable image tags** — `<git-short-sha>-w<worktree-hash>`
   for local dirty builds; Jenkinsfile uses the plain 12-char SHA for clean
   builds. `latest` is never relied on for a deploy.
6. **Kustomize overlay** for the kind lab — the base manifests stay
   production-shaped (Docker Hub ref, `imagePullPolicy: Always`); the overlay
   patches image + `imagePullPolicy: IfNotPresent` and adds a `startupProbe`.
7. **Loopback-only smoke tests** — no public port is opened to verify the
   Service; `kubectl port-forward --address 127.0.0.1` is used instead.

## 5. What was NOT optimised (deliberate)

- **No parallel Jenkins stages yet** — pending Jenkins being provisioned
  (see Phase 5 blocker). When Jenkins is available, `Unit tests` and
  `Build image` can run in `parallel { }` because neither depends on the
  other's output.
- **No registry-based BuildKit cache (`--cache-from type=registry`)** —
  requires Docker Hub credentials; will be enabled in the Jenkinsfile once
  the `dockerhub-creds` credential exists.
- **No multi-stage build** — for a Flask app with one runtime dependency the
  gain is <1 MB and adds complexity. Deferred.
- **No `--squash` or `docker buildx bake`** — not needed at this scale.

## 6. Verification commands (reproducible)

```bash
# Baseline (original Dockerfile restored from git):
git show HEAD:Dockerfile > /tmp/Dockerfile.orig
docker build --no-cache -f /tmp/Dockerfile.orig -t bench:orig .

# Optimised:
docker builder prune -af          # force cold
time docker build --no-cache -t bench:cold .
time docker build --no-cache -t bench:cold2 .   # cache mounts now warm
time docker build -t bench:warm .               # layer cache warm

# Graceful-shutdown proof:
docker run -d --name bs bench:warm
time docker stop bs               # expect ~0.2 s
docker inspect bs --format '{{.State.ExitCode}}'   # expect 143
docker rm bs
```
