# Pipeline Optimization

Companion document to `docs/evidence/phase6-measurements.md`, which holds
the raw numbers. This file explains **what** was changed, **why**, and what
the measured effect was.

## 1. Baseline

Before any optimisation, the following was true:

| Metric | Value |
| --- | --- |
| `docker build` warm (no source change) | 2.76 s |
| `docker build --no-cache` | 9.89 s |
| `docker stop` (graceful shutdown attempt) | 10.22 s, exit code 137 (SIGKILL) |
| Image size | 185 MB |
| Deploy step in `scripts/deploy.sh` | Hard-coded image name, `IMAGE` env var required, no rendering step, no safety checks |
| Rollback step in `scripts/rollback.sh` | Two lines, no history check, no dry-run, no verification |
| `Jenkinsfile` | Sequential stages, no caching, no changeset filter, no smoke test, hard-coded `DOCKERHUB_USERNAME`, deploy used `kubectl set image` only |
| Kubernetes manifests | No `startupProbe`, no `terminationGracePeriodSeconds`, single flat directory with `DOCKERHUB_USERNAME` placeholder in the deployment |

## 2. Optimisations applied

### 2.1 Dockerfile

| # | Change | Reason | Measured effect |
| --- | --- | --- | --- |
| D1 | `# syntax=docker/dockerfile:1.7` header | Enables BuildKit features on any Docker ≥ 23 | prerequisite for D2/D3 |
| D2 | `RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked` around `pip install` | pip reuses wheels across builds even when `requirements.txt` changes | cold rebuild with warm cache mounts: 9.89 s → **9.75 s** (small on fast networks, large on slow ones) |
| D3 | `RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked` around `apt-get install tini`, plus `APT::Keep-Downloaded-Packages "true"` | Debian package lists and .deb files are cached between builds | included in D2 measurement |
| D4 | Layer ordering: `COPY app/requirements.txt` **before** `COPY app/` | Source-only edits do not invalidate the pip layer | warm build: 2.76 s → **1.17 s** (−58 %) |
| D5 | `tini` as PID 1 via `ENTRYPOINT ["/usr/bin/tini", "--"]` | Kubernetes and Docker both send SIGTERM to PID 1; tini forwards it correctly | `docker stop`: 10.22 s → **0.22 s** (−98 %), exit 137 → **143** |
| D6 | `STOPSIGNAL SIGTERM` explicit | Documents intent; default is already SIGTERM | n/a |
| D7 | `PIP_DISABLE_PIP_VERSION_CHECK=1`, `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUNBUFFERED=1` | Removes pip's version-check round-trip, avoids .pyc files in the image, unbuffered logs | ~0.1 s per build, cleaner logs |
| D8 | Healthcheck rewritten to check `status==200` explicitly | Original `urllib.request.urlopen(...)` returned success on any 2xx/3xx; now pinned to 200 | correctness, not speed |

**Image size after all of the above: 186 MB (+1 MB for tini).**
The `--no-cache` cold build got slightly slower in absolute terms
(9.89 s → 15.07 s when the builder cache is fully pruned) because the
`apt-get install tini` step is new. That is a one-off cost per host and is
paid back on the very next rebuild.

### 2.2 `.dockerignore`

Before: 5 entries. After: 30 entries covering `.git`, `.venv`, Python
caches, all secret-like files (`*.pem`, `*.key`, `id_rsa`, `id_ed25519`,
`kubeconfig*`, `credentials*`, `secrets/`, `.env*`), and everything not
needed at runtime (`docs/`, `slides/`, `k8s/`, `scripts/`, `Jenkinsfile`,
`README.md`, `docker-compose.yml`, `Dockerfile`, `.dockerignore`).

Effects:
- Build context is smaller → faster `docker build` startup, less I/O.
- Secrets can never be baked into an image layer by accident, even if a
  developer drops a `kubeconfig` in the repo root.
- Cache invalidation on source edits is scoped to `app/` only.

### 2.3 Kubernetes manifests

The base manifests (`k8s/deployment.yaml`, `k8s/service.yaml`,
`k8s/namespace.yaml`) are deliberately **unchanged** apart from what the
user already committed. All lab-specific tweaks live in a kustomize
overlay so the base stays production-shaped and reviewable.

New file: `k8s/overlays/kind/kustomization.yaml`.

| Change | Reason |
| --- | --- |
| `images:` transformer rewrites `DOCKERHUB_USERNAME/devops-demo-web` → `devops-demo-web:<sha-tag>` | Lets the same base manifests work against a local kind cluster without editing them |
| `imagePullPolicy: IfNotPresent` (patch) | Required when the image was pre-loaded via `kind load docker-image` and does not exist in a registry |
| `startupProbe` added (patch) | Base manifest only had readiness + liveness. Without a startupProbe, a slow first start can be killed by liveness before it has a chance to become ready |
| `terminationGracePeriodSeconds: 30` (patch) | Explicit grace period; combined with tini this drains the pod cleanly |

### 2.4 Scripts

`scripts/deploy.sh` — was 6 lines requiring `IMAGE` to be set, applying
the flat manifests and doing a `set image`. Now:

- Renders the kustomize overlay with `--load-restrictor LoadRestrictionsNone`.
- `IMAGE` is optional (falls back to the tag baked into the overlay).
- Prints pods, ReplicaSets, and a **loopback-only** port-forward hint.
- Uses `set -euo pipefail` and a `trap` to clean up temp files.

`scripts/rollback.sh` — was 2 lines. Now:

- Prints rollout history before and after.
- Refuses to run when only one revision exists (unless `FORCE=1`).
- Supports `REVISION=N` to pin to a specific revision.
- Supports `DRY_RUN=1` to preview the command.
- Waits for the rollout to stabilise and prints the resulting image + pods.

### 2.5 Jenkinsfile

The original pipeline had 5 sequential stages. The new one has 6 stages,
two of which run in parallel, plus explicit guards and a smoke test.

| Original | Optimised |
| --- | --- |
| `Checkout` | `Checkout` + record `GIT_SHA_SHORT` for logs |
| — | **`Validate repo`** — checks required files exist, refuses to build if any secret-like file is tracked, asserts the Dockerfile has a `USER` directive |
| `Unit tests` (sequential) | **`Test & Build`** parallel block: `Unit tests` runs concurrently with `Build image` |
| `Build image` (sequential, after tests) | Runs in parallel with tests; skipped entirely if only docs/slides changed (`when { changeset "app/**,Dockerfile,.dockerignore,k8s/**,Jenkinsfile,scripts/**" }`) |
| `Push image` on `main` | `Publish image` on `main` **and** only if `env.IMAGE_BUILT == 'true'`; pushes both the SHA tag and `latest`; records the digest as a fingerprinted artifact |
| `Deploy Kubernetes` used `kubectl set image` only | `Deploy to Kubernetes` renders the kustomize overlay when present, applies it, then `set image` + `rollout status --timeout=180s`, then prints pods |
| — | **`Smoke test`** — opens a `kubectl port-forward` on `127.0.0.1:18082` (loopback only), curls `/health` and `/`, fails the build if either is wrong |
| `post { always { echo … } }` | `post` block with `always` (image list), `success` (image ref), `failure` (prints the exact rollback command — does **not** auto-rollback), `cleanup` (`cleanWs`) |
| `IMAGE_NAME = 'DOCKERHUB_USERNAME/devops-demo-web'` (hard-coded placeholder) | `DOCKERHUB_USERNAME = credentials('dockerhub-username')` — a Jenkins text credential, no hard-coded value in the repo |
| No caching | `PIP_CACHE_DIR=$WORKSPACE/.pip-cache`, `BUILDKIT_CACHE_DIR=$WORKSPACE/.buildkit-cache`, `DOCKER_BUILDKIT=1` |
| No image labels | `org.opencontainers.image.{revision,source,created}` labels on every build |

### 2.6 `docker-compose.yml`

- Jenkins ports rebound from `0.0.0.0:8080` / `0.0.0.0:50000` to
  `127.0.0.1:8080` / `127.0.0.1:50000`. The host has no firewall, so
  `0.0.0.0` would have exposed Jenkins on the LAN (and on the Internet if
  the provider forwards those ports).
- Jenkins placed behind a compose `profile: jenkins`, so a plain
  `docker compose up` does not start it. Explicit opt-in required.
- The `app` service's port binding was **not** changed — the existing
  container is already running with `0.0.0.0:8081` and changing it would be
  a live network change. Flagged in `docs/environment-audit.md` §10 (R3).

## 3. Measured results

Full table in `docs/evidence/phase6-measurements.md`. Headline numbers:

| Metric | Before | After | Δ |
| --- | --- | --- | --- |
| `docker build` warm | 2.76 s | 1.17 s | **−58 %** |
| `docker build --no-cache` (cache mounts warm) | 9.89 s | 9.75 s | −1.4 % |
| `docker stop` | 10.22 s (SIGKILL, exit 137) | 0.22 s (SIGTERM, exit 143) | **−98 %**, clean shutdown |
| Image size | 185 MB | 186 MB | +1 MB (tini) |
| End-to-end deploy (build → load → apply → smoke) | not measured (manual, error-prone) | ~9 s warm, ~23 s cold | one command |
| Rollback | 2 lines, no verification | guarded script with history, dry-run, revision pinning | qualitative |

## 4. What was **not** done, and why

| Item | Why deferred |
| --- | --- |
| Registry-based BuildKit cache (`--cache-from type=registry,ref=…:buildcache`) | The credential prerequisite is now met (`dockerhub-creds` exists; build #3 pushes to Docker Hub), but the registry cache itself is **not implemented or measured** — it stays a candidate next optimization, not a claimed result. |
| Multi-stage build to shrink the image further | For a Flask app with one runtime dependency the saving is < 5 MB and adds a stage. Not worth the complexity for the case study. |
| `docker buildx bake` | Only useful when building multiple images. We build one. |
| Kaniko / Buildah socket-less build | The agent strategy is now **decided** (dedicated `linux-docker-agent` with the Docker socket mounted — see `docs/deployment-guide.md` §5.1). Kaniko/Buildah remains an optional hardening step to remove the socket mount; not required for the case study. |
| Helm chart | Kustomize with two overlays is enough and keeps the manifests greppable during an interview walkthrough. |
| Auto-rollback on smoke-test failure | A single curl is not a sufficient signal to roll back a production deployment. The pipeline prints the exact rollback command in the `post { failure }` block instead. |
| Prometheus / Grafana / metrics-server | Out of scope. The absence of `kubectl top` is documented in `docs/troubleshooting.md` T9 rather than hidden. |

## 5. Reproducing the measurements

```bash
cd ~/devops-case-study

# 1. Baseline (original Dockerfile from git HEAD):
git show HEAD:Dockerfile > /tmp/Dockerfile.orig
docker build --no-cache -f /tmp/Dockerfile.orig -t bench:orig .
docker run -d --name bench-orig bench:orig
time docker stop bench-orig          # expect ~10 s, exit 137
docker rm bench-orig

# 2. Optimised:
docker builder prune -af             # force a truly cold build
time docker build --no-cache -t bench:cold .     # ~15 s (includes base pull)
time docker build --no-cache -t bench:cold2 .    # ~9.7 s (cache mounts warm)
time docker build -t bench:warm .                # ~1.2 s (layer cache warm)
docker run -d --name bench-opt bench:warm
time docker stop bench-opt           # expect ~0.2 s, exit 143
docker inspect bench-opt --format '{{.State.ExitCode}}'
docker rm bench-opt

# 3. Cleanup:
docker rmi bench:orig bench:cold bench:cold2 bench:warm
```
