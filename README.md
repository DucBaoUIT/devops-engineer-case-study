# DevOps Engineer Case Study

End-to-end DevOps walkthrough for a small Flask service: containerisation,
a local Kubernetes lab on `kind`, a Jenkins CI/CD pipeline, image
publishing to Docker Hub, rollout/rollback, pipeline optimisation, and the
evidence to prove all of it actually ran.

> **Interview-ready status.** 21 of 22 acceptance items PASS with recorded
> evidence, including a **green Jenkins CI build** (controller + agent +
> credentials + pipeline — see
> [`docs/evidence/phase5-jenkins-ci.md`](docs/evidence/phase5-jenkins-ci.md)).
> The one BLOCKED item — Docker Hub **push** — needs the operator to add the
> `dockerhub-creds` access token (documented in
> [`docs/validation-report.md`](docs/validation-report.md) §3); it is not a
> technical failure.

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
│   ├── deployment.yaml        2 replicas, rolling update, 3 probes,
│   │                          requests/limits, non-root securityContext
│   ├── service.yaml           ClusterIP :80 → :8080
│   └── overlays/kind/         kustomize overlay for the local kind lab
│                              (image rewrite, IfNotPresent, startupProbe)
├── scripts/
│   ├── deploy.sh              render overlay → apply → set image → rollout status
│   └── rollback.sh            guarded rollout undo (REVISION=, DRY_RUN=, FORCE=)
├── docs/
│   ├── environment-audit.md   Phase 1 host & tooling audit
│   ├── architecture.md        component diagram, tagging policy, failure modes
│   ├── deployment-guide.md    every command, per environment
│   ├── troubleshooting.md     13 real issues hit during the run, with fixes
│   ├── pipeline-optimization.md  baseline vs optimised, measured
│   ├── validation-report.md   acceptance checklist (21 PASS / 1 BLOCKED)
│   ├── evidence/              raw command output, no secrets
│   ├── SLIDE_NOTES.md         (pre-existing)
│   └── DevOps_CaseStudy_Report.pdf  (pre-existing)
├── slides/DevOps_CaseStudy_Presentation.pptx  (pre-existing)
├── Dockerfile                 python:3.12-slim + tini + BuildKit cache mounts
├── .dockerignore              30 entries, blocks every secret-like pattern
├── docker-compose.yml         app (0.0.0.0:8081) + jenkins (127.0.0.1, profile-gated)
└── Jenkinsfile                6 stages, parallel test+build, smoke test
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
`docker compose --profile jenkins up -d`). See
[`docs/deployment-guide.md`](docs/deployment-guide.md) §5.

## Jenkins CI/CD

**Deployed and verified.** A Jenkins controller (`2.541.3`, loopback-only)
with a dedicated inbound agent `linux-docker-agent` (Docker CLI + buildx +
`kubectl` + `kind` + `python3-venv` + `git`, Docker socket mounted) ran the
`devops-demo-web` job to **SUCCESS** (build #2, 16.09 s): Validate → Unit
tests (2 pass) → Build image (BuildKit) → read-only cluster check. Because
the repo tree is uncommitted, that job builds the **current** working tree
via a read-only bind mount and skips Publish/Deploy/Smoke; the authoritative
SCM-driven pipeline is the [`Jenkinsfile`](Jenkinsfile). Evidence:
[`docs/evidence/phase5-jenkins-ci.md`](docs/evidence/phase5-jenkins-ci.md).

Credentials in Jenkins:

| ID | Kind | Contents | Status |
| --- | --- | --- | --- |
| `dockerhub-username` | Secret text | Docker Hub namespace (`21520623`) | created |
| `kubeconfig-dev` | Secret file | kind internal kubeconfig (`devops-demo`) | created |
| `dockerhub-creds` | Username with password | Docker Hub user + **access token** | **BLOCKED** — operator adds via UI |

To run the full SCM-driven pipeline (Publish → Deploy → Smoke), commit the
tree, point the job at `Jenkinsfile`, and add `dockerhub-creds`. Full setup
steps — including how to generate a namespace-scoped kubeconfig with a
limited Role/RoleBinding — are in
[`docs/deployment-guide.md`](docs/deployment-guide.md) §5.

Pipeline stages:

```
Checkout → Validate repo → [Unit tests ‖ Build image] → Publish image
        → Deploy to Kubernetes → Smoke test
```

`Publish`, `Deploy` and `Smoke test` only run on `main` **and** only when
the build actually happened (docs-only commits skip it via `changeset`).

## Kubernetes manifests

The base manifests under `k8s/*.yaml` are production-shaped: they reference
`21520623/devops-demo-web:latest` with `imagePullPolicy: Always`. Change
the namespace in `k8s/deployment.yaml` (and the matching `images:` entry in
the overlay) if you fork this into your own Docker Hub account.

For the local kind lab, the overlay at `k8s/overlays/kind/` rewrites the
image to the locally-built tag, switches `imagePullPolicy` to
`IfNotPresent`, and adds a `startupProbe` and
`terminationGracePeriodSeconds: 30`. The base files are never edited.

Deployment guarantees (base + overlay):

- 2 replicas, `RollingUpdate` with `maxSurge=1 maxUnavailable=0` — a bad
  rollout never takes the service down (verified in
  [`docs/evidence/phase7-rollback-drill.md`](docs/evidence/phase7-rollback-drill.md)).
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

Details, raw timings and the reproduction script:
[`docs/pipeline-optimization.md`](docs/pipeline-optimization.md).

## Troubleshooting

Thirteen real issues were hit and fixed during this run, each with the
symptom, the diagnostic command, the root cause and the fix:
[`docs/troubleshooting.md`](docs/troubleshooting.md).

Highlights:
- T1 — Flask ignores SIGTERM as PID 1 → fixed with `tini`.
- T2 — kustomize `--load-restrictor` blocks `../../` refs → use `LoadRestrictionsNone`.
- T3 — `kubectl port-forward` address syntax.
- T4 — `ImagePullBackOff` after `kind load` was forgotten.
- T6 — a benchmark script that silently measured a build *failure*.
- T13 — BuildKit needs `buildx`, which the static Docker CLI tarball omits.

## Security posture

- No secret is committed, printed, logged or baked into an image.
  `.gitignore` and `.dockerignore` both block `.env*`, `*.pem`, `*.key`,
  `id_rsa`, `id_ed25519`, `kubeconfig*`, `credentials*`, `secrets/`.
- The Jenkinsfile references credentials **by ID only**; the Docker Hub
  username itself is a Jenkins text credential, not a literal in the repo.
- Jenkins is bound to `127.0.0.1` and gated behind a compose profile.
- Smoke tests use `kubectl port-forward --address 127.0.0.1`. No
  LoadBalancer, NodePort, ingress or firewall change is made anywhere.
- The container runs as uid 10001 with a read-only root filesystem and
  all capabilities dropped.
- The Docker socket is **not** exposed on TCP and is **not** mounted into
  the Jenkins controller. The provisioned `linux-docker-agent` mounts it
  (the controller does not) and is treated as trusted — any job there is
  effectively host-root, so only trusted pipelines run on it.

## Status

See [`docs/validation-report.md`](docs/validation-report.md) for the full
22-item acceptance checklist with per-item evidence links.
