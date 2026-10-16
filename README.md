# DevOps Engineer Case Study

End-to-end DevOps walkthrough for a small Flask service: containerisation,
a local Kubernetes lab on `kind`, a Jenkins CI/CD pipeline, image
publishing to Docker Hub, rollout/rollback, pipeline optimisation, and the
evidence to prove all of it actually ran.

## Repository layout

```
.
├── app/                       Flask service + unit tests
│   ├── app.py                 /, /health, /slow
│   ├── requirements.txt       Flask==3.1.0 (pinned)
│   ├── requirements-dev.txt
│   └── tests/test_app.py
├── k8s/
│   ├── namespace.yaml         devops-demo
│   ├── deployment.yaml        2 replicas, rolling update, readiness+liveness,
│   │                          requests/limits, non-root securityContext
│   ├── service.yaml           NodePort :80 → :8080 (nodePort 30080)
│   └── overlays/kind/         kustomize overlay for the local kind lab
│                              (image rewrite, IfNotPresent, startupProbe)
├── scripts/
│   ├── deploy.sh              render overlay → apply → set image → rollout status
│   └── rollback.sh            guarded rollout undo (REVISION=, DRY_RUN=, FORCE=)
├── docs/                          gitignored — local-only (see Status below)
│   ├── report/
│   │   ├── DevOps_CaseStudy_Report.md   narrative report (source of truth)
│   │   ├── build_report_vi.py           Markdown → PDF renderer
│   │   └── images/                      diagrams + real screenshots
│   ├── evidence/                        timestamped command output, no secrets
│   │   ├── phase4-kind-deploy.md        kind deploy + smoke test
│   │   ├── phase5-jenkins-ci.md         CI build → push → pull → deploy
│   │   ├── phase6-measurements.md       optimisation timings
│   │   ├── phase7-rollback-drill.md     bad-rollout survival + rollback
│   │   └── final-state.md               cluster + Jenkins snapshot
│   ├── slides/                          7-slide deck, speaker notes, build script
│   └── DevOps_CaseStudy_Report.pdf      compiled report (PDF)
├── Dockerfile                 python:3.12-slim + tini + BuildKit cache mounts
├── jenkins-agent.Dockerfile   CI agent image: docker+buildx, kubectl, kind, python, git
├── .dockerignore              blocks every secret-like pattern + non-runtime paths
├── docker-compose.yml         app (0.0.0.0:8081) + jenkins/agent (127.0.0.1, profile-gated)
└── Jenkinsfile                7 stages, parallel test+build, smoke test
```

## Quick start (local, no Jenkins, no Docker Hub)

```bash
# 1. Tests
python3 -m venv .venv && . .venv/bin/activate
pip install -r app/requirements-dev.txt
python -m unittest discover -s app/tests -v          # 2 tests, exit 0

# 2. Image with an immutable tag
GIT_SHA=$(git rev-parse --short=12 HEAD)
docker build -t "devops-demo-web:${GIT_SHA}" .

# 3. Verify graceful shutdown (tini as PID 1)
docker run -d --name smoke "devops-demo-web:${GIT_SHA}"
sleep 2 && time docker stop smoke                    # ~0.2 s, exit 143
docker rm smoke

# 4. kind cluster + deploy
kind create cluster --name devops-demo --wait 120s
kind load docker-image "devops-demo-web:${GIT_SHA}" --name devops-demo
# point the overlay at your tag:
sed -i "s|newTag: .*|newTag: ${GIT_SHA}|" k8s/overlays/kind/kustomization.yaml
IMAGE="devops-demo-web:${GIT_SHA}" scripts/deploy.sh

# 5. Smoke test — loopback only, no public port opened
kubectl -n devops-demo port-forward --address 127.0.0.1 svc/demo-web 8082:80 &
sleep 2
curl -sS http://127.0.0.1:8082/health                # {"status":"ok"}
curl -sS http://127.0.0.1:8082/
kill %1

# 6. Rollback drill
kubectl -n devops-demo set image deployment/demo-web demo-web=devops-demo-web:does-not-exist
sleep 6 && kubectl -n devops-demo get pods           # old pods still Running
scripts/rollback.sh
```

Total wall time on an 8 vCPU / 11 GiB host: under 3 minutes.

## Docker Compose demo (unchanged from the original repo)

```bash
docker compose up --build -d app
curl http://localhost:8081/health
docker compose down
```

The `jenkins` and `jenkins-agent` services are behind a compose profile and
the controller is bound to `127.0.0.1`, so a plain `docker compose up` does
**not** start them. They are currently **deployed** loopback-only (start with
`docker compose --profile jenkins up -d`).

## Jenkins CI/CD

Credentials in Jenkins:

| ID | Kind | Contents | Status |
| --- | --- | --- | --- |
| `dockerhub-username` | Secret text | Docker Hub namespace (`21520623`) | created |
| `kubeconfig-dev` | Secret file | kind internal kubeconfig (`devops-demo`) | created |
| `dockerhub-creds` | Username with password | Docker Hub user + **access token** | created (operator-added); used by build #3 push |

The full SCM-driven pipeline (Publish → Deploy → Smoke) has been run for real
against `main` (build #3).

Pipeline stages:

```
Checkout → Validate repo → [Unit tests ‖ Build image] → Publish image
        → Deploy to Kubernetes → Smoke test
```

`Publish`, `Deploy` and `Smoke test` only run on `main` **and** only when the
image was actually built. `Build image` is gated by a `git diff HEAD~1 HEAD`
change-check — not a declarative `changeset`, which `cleanWs` defeated (T14) —
so docs-only commits skip Build/Publish/Deploy/Smoke.

## Kubernetes manifests

The base manifests under `k8s/*.yaml` are production-shaped: they reference
`21520623/devops-demo-web:latest` with `imagePullPolicy: Always`, and expose the
app as a **NodePort** Service (`demo-web`, `80:30080` → container `8080`). Change
the image namespace in `k8s/deployment.yaml` (and the matching `images:` entry in
the overlay) if you fork this into your own Docker Hub account.

For the local kind lab, the overlay at `k8s/overlays/kind/` rewrites the
image to the locally-built tag, switches `imagePullPolicy` to
`IfNotPresent`, and adds a `startupProbe` and
`terminationGracePeriodSeconds: 30`. The base files are never edited.

Deployment guarantees (base + overlay):

- 2 replicas, `RollingUpdate` with `maxSurge=1 maxUnavailable=0`
- `startupProbe` (30 × 2 s), `readinessProbe` (5 s), `livenessProbe` (10 s),
  all on `/health`.
- `resources.requests` 100m CPU / 64 Mi, `resources.limits` 500m CPU / 256 Mi.
- `securityContext`: `runAsNonRoot`, uid 10001, `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.
- `revisionHistoryLimit: 5` so `kubectl rollout undo --to-revision=N` works.

## Pipeline optimisation — measured

| Metric | Before | After |
| --- | --- | --- |
| `docker build` warm | 2.76 s | **1.17 s** (−58 %) |
| `docker stop` | 10.22 s, exit 137 (SIGKILL) | **0.22 s, exit 143** (SIGTERM) |
| Image size | 185 MB | 186 MB (+tini) |
| End-to-end deploy | manual, error-prone | one command, ~9 s warm |
