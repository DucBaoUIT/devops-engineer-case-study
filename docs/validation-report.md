# Validation Report & Acceptance Checklist

Date: 2026-10-13 (UTC)
Target host: `ubuntu` — Ubuntu 24.04.3 LTS, 8 vCPU, 11 GiB RAM, 64 GiB free
Repository: `~/devops-case-study` @ `main` (base commit `cc5480d`)
Working image tag: `devops-demo-web:cc5480ddbf9e-w53253e69`

> Every row below was produced by an actual command on the target host.
> Raw outputs live in `docs/evidence/`. Nothing is inferred, estimated or
> copied from documentation.

## 1. Acceptance checklist

| # | Item | Status | Evidence |
| --- | --- | --- | --- |
| A1 | Unit tests pass | **PASS** | `docs/evidence/final-state.md` §"Unit tests" — 2 tests, exit 0 |
| A2 | Docker image builds successfully | **PASS** | `docs/evidence/phase6-measurements.md` §2 — warm 1.17 s, cold 15.07 s |
| A3 | Container runs and `/health` returns 200 | **PASS** | `docs/evidence/phase4-kind-deploy.md` — HTTP 200, 2–4 ms |
| A4 | Container runs as non-root | **PASS** | `docker inspect` shows `User=10001`; `readlink /proc/1/exe` → `/usr/bin/tini` |
| A5 | Graceful shutdown on SIGTERM | **PASS** | `docker stop` 0.22 s, exit 143 (was 10.22 s, exit 137) |
| A6 | kind cluster Ready | **PASS** | `kind get clusters` → `devops-demo`; node `devops-demo-control-plane` Ready |
| A7 | Kubernetes Deployment Available | **PASS** | `kubectl -n devops-demo get deploy demo-web` → `2/2 AVAILABLE` |
| A8 | All pods Ready, 0 restarts | **PASS** | `docs/evidence/final-state.md` §"Namespace devops-demo" |
| A9 | Service reachable (loopback) | **PASS** | `kubectl port-forward --address 127.0.0.1 svc/demo-web 8082:80` + `curl /health` → 200 |
| A10 | Readiness, liveness **and** startup probes configured | **PASS** | `kubectl describe deploy/demo-web` shows all three; startupProbe added by overlay |
| A11 | CPU/memory requests and limits set | **PASS** | requests 100m/64Mi, limits 500m/256Mi |
| A12 | Rolling update with `maxUnavailable=0` keeps service up during a bad rollout | **PASS** | `docs/evidence/phase7-rollback-drill.md` Drill 1 — old pods kept serving while new pod was in `ImagePullBackOff` |
| A13 | Rollback verified | **PASS** | `scripts/rollback.sh` restored image; `/health` returned 200 immediately after |
| A14 | Readiness failure drains endpoints without restarting the pod | **PASS** | `docs/evidence/phase7-rollback-drill.md` Drill 2 — pod moved to `notReadyAddresses`, liveness never fired |
| A15 | Unit-test failure halts the pipeline before build | **PASS** (simulated) | Drill 3 — exit code 1 from a deliberately failing test |
| A16 | Image tag is immutable and traceable to a git commit | **PASS** | Tag format `<git-sha-12>-w<worktree-hash>`; Jenkinsfile uses `env.GIT_COMMIT.take(12)` |
| A17 | No secrets in repository, image or logs | **PASS** | `.gitignore` + `.dockerignore` block `.env*`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `kubeconfig*`, `credentials*`, `secrets/`; Jenkinsfile references credentials by ID only |
| A18 | Jenkins pipeline completes successfully | **PASS** | Multibranch `devops-case-study/main` build **#3 `SUCCESS` (~118 s)** on agent `linux-docker-agent`, running the repo's authoritative `Jenkinsfile` @ `9b93e21`: Checkout → Validate → Unit tests (2 pass) ‖ Docker build (BuildKit/buildx, 186 MB) → Publish (real push) → Deploy (rollout 2/2) → Smoke (`/health` 200). `docs/evidence/phase5-jenkins-ci.md` §5. |
| A19 | Image pushed to Docker Hub | **PASS** | Build #3: `docker login` → `Login Succeeded`, pushed `21520623/devops-demo-web:9b93e2104bec` + `:latest`, digest `sha256:dc269a5a…6150`. kind then **pulled the same digest** back (running pods' `imageID` matches), proving the round-trip. `dockerhub-creds` (user `21520623` + access token) added by operator. `docs/evidence/phase5-jenkins-ci.md` §5/§5.1. |
| A20 | Deployment uses the expected image tag | **PASS** | After build #3: `kubectl get deploy demo-web -o jsonpath='{..image}'` → `21520623/devops-demo-web:9b93e2104bec` (the CI-pushed Hub tag); pods' `imageID` = `docker.io/21520623/devops-demo-web@sha256:dc269a5a…6150` |
| A21 | Smoke test passes | **PASS** | `/health` 200, `/` returns `{"service":"demo-web","version":"k8s","message":"Hello from Kubernetes"}` |
| A22 | Documentation reflects the real state | **PASS** | This file + `docs/architecture.md`, `docs/deployment-guide.md`, `docs/troubleshooting.md`, `docs/pipeline-optimization.md`, `docs/environment-audit.md` |

**Overall: 22 PASS, 0 BLOCKED, 0 FAIL.**

## 2. Evidence index

| File | Contents |
| --- | --- |
| `docs/evidence/final-state.md` | Snapshot of host, cluster, deployment, images, unit tests, git status at the end of the run |
| `docs/evidence/phase4-kind-deploy.md` | kind cluster creation, deployment apply, rollout status, smoke tests via port-forward |
| `docs/evidence/phase6-measurements.md` | Baseline vs optimised build/stop/deploy timings |
| `docs/evidence/phase7-rollback-drill.md` | Three failure drills: bad image tag, failing readiness probe, failing unit test |
| `docs/evidence/phase5-jenkins-ci.md` | Jenkins provisioning (controller, 71 plugins, agent node, credentials) + build #1 FAILURE (buildx), build #2 harness SUCCESS, and **build #3 authoritative end-to-end** (real push → deploy → smoke, digest round-trip proof) |

No evidence file contains a token, password, private key or kubeconfig
content. Docker Hub credentials appear only as masked `****` in console excerpts
(and by credential ID); the pushed image digest is public registry metadata, not
a secret.

## 3. Status of the two items that were BLOCKED after Phase 4 (both now RESOLVED)

### A18 — Jenkins pipeline — RESOLVED (verification build green)

Jenkins is running (loopback-only), fully provisioned, and executed a real
pipeline build to **SUCCESS**:

- Controller `jenkins/jenkins:lts-jdk17` **2.541.3** on `127.0.0.1:8080/50000`;
  setup wizard completed headlessly; **71 plugins** installed (git,
  workflow-aggregator, pipeline-model-definition, credentials-binding,
  plain-credentials, junit, timestamper, ws-cleanup, …).
- Dedicated inbound agent `linux-docker-agent` (image
  `devops-case-study-jenkins-agent:latest`) with Docker CLI **27.5.1 + buildx
  v0.38.0**, kubectl v1.34.0, kind v0.30.0, python3-venv, git — online, 2
  executors, on the `kind` network, Docker socket mounted.
- Credentials created: `dockerhub-username` (text = `21520623`) and
  `kubeconfig-dev` (file = kind **internal** kubeconfig).
- Job `devops-demo-web` build **#2 = SUCCESS (16 s)**: Validate → Unit tests
  (2 pass) → Docker build (BuildKit) → read-only `kubeconfig-dev` cluster check
  (`demo-web 2/2 READY`). Evidence: `docs/evidence/phase5-jenkins-ci.md`.

**Source strategy (updated).** Build #2 above used a read-only bind-mount harness
while the tree was uncommitted. The tree is now committed (approved: *commit
locally, no remote push*; `HEAD = 9b93e21`), so the authoritative multibranch job
`devops-case-study` runs the repo's real `Jenkinsfile` via `checkout scm` from
`file:///repo-src` (repo mounted read-only into the controller). Its build **#3**
is the full end-to-end run recorded in A19 below and
`docs/evidence/phase5-jenkins-ci.md` §5.

### A19 — Docker Hub push — RESOLVED (real push verified)

The namespace (`21520623`) replaced the `DOCKERHUB_USERNAME` placeholder in
`k8s/deployment.yaml`, the kind overlay, `README.md` and the `Jenkinsfile`, and is
stored as the `dockerhub-username` Jenkins credential. The operator then added the
`dockerhub-creds` *Username with password* credential (Docker Hub user `21520623`
+ **access token**, never the account password); its auto-generated UUID ID was
normalized to `dockerhub-creds` — the ID the `Jenkinsfile` references.

Multibranch build **#3** (`devops-case-study/main` @ `9b93e21`) then ran the
Publish stage for real:

    docker login --username **** --password-stdin   → Login Succeeded
    docker push ****/devops-demo-web:9b93e2104bec   → digest sha256:dc269a5a…6150 size 856
    docker push ****/devops-demo-web:latest         → digest sha256:dc269a5a…6150

**Round-trip proof.** The Deploy stage set the kind deployment to that Hub tag;
because the tag was never `kind load`ed, the node pulled it from Docker Hub, and
the running pods' `imageID` is
`docker.io/21520623/devops-demo-web@sha256:dc269a5a…6150` — identical to the
pushed digest. Evidence: `docs/evidence/phase5-jenkins-ci.md` §5 / §5.1.

Optional next step (not required for acceptance): the kind overlay can switch
`imagePullPolicy` back to `Always` and drop the `kind load` step now that images
are published to Docker Hub.

## 4. What was deliberately **not** changed

| Item | Reason |
| --- | --- |
| `app/app.py`, `app/tests/test_app.py`, `app/requirements*.txt` | Application behaviour is correct and tests pass. The graceful-shutdown issue was fixed in the image (tini), not in the app. |
| `k8s/namespace.yaml`, `k8s/deployment.yaml`, `k8s/service.yaml` | Base manifests stay production-shaped. All lab-specific tweaks live in `k8s/overlays/kind/`. |
| `docs/DevOps_CaseStudy_Report.pdf`, `slides/DevOps_CaseStudy_Presentation.pptx`, `docs/SLIDE_NOTES.md` | Existing artefacts. Not overwritten. The slide notes already contain the line "Do not claim measured improvements until you have collected before/after data" — that data now exists in `docs/pipeline-optimization.md`. |
| The running `devops-case-study-app-1` container | Left untouched. Still healthy after 54 minutes, still bound to `0.0.0.0:8081`. |
| SSH, firewall, network configuration | No changes. `ufw` is not installed and was not installed. |
| The `app` service port binding in `docker-compose.yml` | Changing `0.0.0.0:8081` to `127.0.0.1:8081` would be a live network change on a running service. Flagged in `docs/environment-audit.md` R3, not applied. |

## 5. Files added or modified in this run

**Modified (6):**
- `Dockerfile` — tini, BuildKit cache mounts, explicit STOPSIGNAL, stricter healthcheck
- `.dockerignore` — 5 → 30 entries, all secret-like patterns blocked
- `docker-compose.yml` — Jenkins rebound to 127.0.0.1 and placed behind a profile
- `Jenkinsfile` — rewritten (6 stages, parallel test+build, smoke test, no hard-coded username)
- `scripts/deploy.sh` — kustomize rendering, optional IMAGE, safety checks
- `scripts/rollback.sh` — history check, REVISION pinning, DRY_RUN, verification

**Added (9):**
- `docs/environment-audit.md`
- `docs/architecture.md`
- `docs/deployment-guide.md`
- `docs/troubleshooting.md`
- `docs/pipeline-optimization.md`
- `docs/validation-report.md` (this file)
- `docs/evidence/final-state.md`
- `docs/evidence/phase4-kind-deploy.md`
- `docs/evidence/phase6-measurements.md`
- `docs/evidence/phase7-rollback-drill.md`
- `k8s/overlays/kind/kustomization.yaml`

**Phase 5 (Jenkins) — additionally:**
- `jenkins-agent.Dockerfile` — NEW inbound agent: docker CLI 27.5.1 + **buildx v0.38.0**, kubectl v1.34.0, kind v0.30.0, python3-venv, git
- `docker-compose.yml` — added `jenkins-agent` service (Docker socket, `kind` network, read-only `/repo-src` bind mount) + `kind` external network
- `k8s/deployment.yaml`, `k8s/overlays/kind/kustomization.yaml`, `README.md`, `Jenkinsfile` — `DOCKERHUB_USERNAME` → `21520623`
- `docs/evidence/phase5-jenkins-ci.md` — NEW: provisioning + build #1 (FAILURE) / #2 (SUCCESS) logs
- `.jenkins-setup/` — NEW (gitignored, never committed): headless setup Groovy, admin creds, agent JNLP secret, raw console logs

**Deleted: none.** No existing file, image, container, volume or cluster
was removed.

## 6. Reproduction

A reviewer can reproduce the whole run from a clean checkout with:

```bash
git clone git@github.com:DucBaoUIT/devops-engineer-case-study.git
cd devops-case-study

# 1. Tests
python3 -m venv .venv && . .venv/bin/activate
pip install -r app/requirements-dev.txt
python -m unittest discover -s app/tests -v

# 2. Image
GIT_SHA=$(git rev-parse --short=12 HEAD)
docker build -t "devops-demo-web:${GIT_SHA}" .

# 3. kind cluster
kind create cluster --name devops-demo --wait 120s
kind load docker-image "devops-demo-web:${GIT_SHA}" --name devops-demo

# 4. Deploy (edit k8s/overlays/kind/kustomization.yaml newTag first)
IMAGE="devops-demo-web:${GIT_SHA}" scripts/deploy.sh

# 5. Smoke test (loopback only)
kubectl -n devops-demo port-forward --address 127.0.0.1 svc/demo-web 8082:80 &
sleep 2
curl -sS http://127.0.0.1:8082/health
curl -sS http://127.0.0.1:8082/
kill %1

# 6. Rollback drill
kubectl -n devops-demo set image deployment/demo-web demo-web=devops-demo-web:does-not-exist
sleep 6 && kubectl -n devops-demo get pods
scripts/rollback.sh
```

Expected total wall time on comparable hardware: under 3 minutes.

