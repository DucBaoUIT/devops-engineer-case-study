# Phase 5 — Jenkins CI/CD: provisioning + real build evidence

Date: 2026-10-13 (UTC) · Host: `ubuntu` (Ubuntu 24.04.3, 8 vCPU / 11 GiB)
Jenkins: `jenkins/jenkins:lts-jdk17`, version **2.541.3**, bound to **127.0.0.1:8080 / 127.0.0.1:50000** (loopback only).
Agent: `devops-case-study-jenkins-agent:latest` (inbound JNLP), label `linux-docker-agent`.

> All secret values are masked by Jenkins as `****` in the logs below. No token,
> password, kubeconfig content, or JNLP secret appears in this file. The raw
> console logs live in the gitignored `.jenkins-setup/build{1,2}-console.log`.

## 1. What was provisioned (all verified by command)

| Component | State | How it was verified |
| --- | --- | --- |
| Controller | Up, loopback-only, HTTP 200, wizard complete | `curl 127.0.0.1:8080/login` → 200; Groovy `setupComplete=true` |
| Plugins | **71** installed & active | Groovy plugin enumeration (see §2) |
| Agent node `linux-docker-agent` | Online, 2 executors, labels `linux-docker-agent docker kind` | Groovy `isOnline=true`, channel `JNLP4-connect` |
| Agent container | Up on networks `[default, kind]`, Docker socket mounted | `docker ps`; agent logs "Connected" |
| Agent toolchain | docker 27.5.1 (→ host daemon 29.9.0), **buildx v0.38.0**, kubectl v1.34.0, kind v0.30.0, python 3.13.5, git 2.47.3 | `docker exec` version checks |
| Agent → kind API | Reachable & authenticated | `/version` → k8s v1.34.0; in-build `kubectl cluster-info` (see §4) |
| Credential `dockerhub-username` | String/text credential (namespace `21520623`) | Groovy credential listing |
| Credential `kubeconfig-dev` | File credential (kind **internal** kubeconfig, 5640 bytes) | Groovy credential listing; used in build #2 |
| Credential `dockerhub-creds` | **ABSENT — BLOCKED** (operator must add Docker Hub token via UI) | Groovy `dockerhub-creds present: false` |
| Job `devops-demo-web` | Pipeline, buildable | REST `createItem` → HTTP 200 |

Plugins installed (the ones the `Jenkinsfile` depends on):
`git`, `git-client`, `workflow-aggregator`, `pipeline-model-definition`,
`workflow-cps`, `workflow-durable-task-step`, `pipeline-stage-step`,
`credentials`, `credentials-binding`, `plain-credentials`, `ssh-credentials`,
`junit`, `timestamper`, `ws-cleanup`, `scm-api`, `branch-api`, `structs`,
`script-security`, `matrix-project`, `cloudbees-folder` (+ their API deps).

## 2. Job source strategy (important caveat)

The repository working tree is **uncommitted** (`HEAD = cc5480d`, "Initial DevOps
case study"). A git-based `checkout scm` therefore only sees `cc5480d`, whose
`Jenkinsfile` is the older draft (placeholder `DOCKERHUB_USERNAME`, flat
manifests, no kustomize overlay). Committing to the user's repo was **not** done
(requires explicit approval).

To produce real evidence against the **current** code without committing, the job
`devops-demo-web` uses a bind-mounted, read-only view of the working tree
(`/repo-src`) and runs the *same* Validate → Unit tests → Build stages as the
authoritative `Jenkinsfile`, plus a **read-only** `kubeconfig-dev` cluster check.
The `.jenkins-setup/` directory (which holds setup secrets) and `.venv/` are
excluded from the copy, so no secret enters the workspace.

`Publish → Deploy → Smoke` are intentionally **SKIPPED**: they require the
`dockerhub-creds` token (push) and a committed/pushed tree. To run the full
SCM-driven pipeline, see `docs/deployment-guide.md` §5.4.

## 3. Build #1 — FAILURE (root cause: missing buildx)

Duration 15.06 s, `result: FAILURE`. Stages Sync/Validate/Unit tests passed;
Build image failed:

```
+ docker build --tag ****/devops-demo-web:ci-1 --label ... .
ERROR: BuildKit is enabled but the buildx component is missing or broken.
       Install the buildx component to build images with BuildKit
```

Cause: the static Docker CLI tarball does not bundle `buildx`, but the app
`Dockerfile` requires BuildKit (`# syntax=docker/dockerfile:1.7` + `--mount=type=cache`).
Fix: added buildx **v0.38.0** (matches host) to `jenkins-agent.Dockerfile` at
`/usr/local/libexec/docker/cli-plugins/docker-buildx`, rebuilt the agent image.
Recorded as troubleshooting item **T13**.

## 4. Build #2 — SUCCESS (16.09 s)

```
Started by user admin
Running on linux-docker-agent in /home/jenkins/agent/workspace/devops-demo-web
```

Sync source (bind mount):
```
+ git rev-parse --short=12 HEAD
cc5480ddbf9e
```

Validate repo:
```
ok: Dockerfile ... ok: k8s/namespace.yaml
--- no accidental secrets tracked ---      (git ls-files | grep -Ei secret patterns → none)
--- dockerfile sanity (non-root USER) ---
validation ok
```

Unit tests:
```
Successfully installed Flask-3.1.0 Jinja2-3.1.6 MarkupSafe-3.0.4 Werkzeug-3.1.9 blinker-1.9.0 click-8.5.0 itsdangerous-2.2.0
+ python -m unittest discover -s app/tests -v
test_health (test_app.AppTests.test_health) ... ok
test_home (test_app.AppTests.test_home) ... ok
Ran 2 tests in 0.014s
OK
```

Build image (BuildKit via buildx, namespace masked as `****`):
```
+ docker build --tag ****/devops-demo-web:ci-2 --label org.opencontainers.image.revision=cc5480ddbf9e... .
#0 building with "default" instance using docker driver
#2 resolve image config for docker-image://docker.io/docker/dockerfile:1.7  DONE 1.5s
#8 [stage-0 2/7] RUN --mount=type=cache,... apt-get install ... tini=0.19.*   CACHED
#11 [stage-0 5/7] RUN --mount=type=cache,target=/root/.cache/pip ... pip install  CACHED
#14 naming to docker.io/****/devops-demo-web:ci-2 done
built image id=sha256:a55ba3da6fbd... size=186398778
```

Verify cluster access (`kubeconfig-dev`, read-only — credential masked):
```
+ export KUBECONFIG=****
+ kubectl cluster-info | head -2
Kubernetes control plane is running at https://devops-demo-control-plane:6443
CoreDNS is running at https://devops-demo-control-plane:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
+ kubectl -n devops-demo get deploy demo-web -o wide
NAME       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                                   SELECTOR
demo-web   2/2     2            2           55m   demo-web     devops-demo-web:cc5480ddbf9e-w53253e69   app=demo-web
+ kubectl -n devops-demo get pods -l app=demo-web -o wide
demo-web-6cb55b7f6-7z9ph   1/1   Running   0   46m   10.244.0.10   devops-demo-control-plane
demo-web-6cb55b7f6-dcjjx   1/1   Running   0   46m   10.244.0.11   devops-demo-control-plane
devops-demo-web:cc5480ddbf9e-w53253e69
```

Skipped stages (policy, not failure):
```
(Publish image (SKIPPED))  SKIPPED: dockerhub-creds ... not configured ... No push performed.
(Deploy to Kubernetes (SKIPPED))  SKIPPED: depends on Publish ... cluster already runs ...w53253e69 (2/2 Ready).
(Smoke test (SKIPPED))  SKIPPED: ... kubectl port-forward --address 127.0.0.1 + curl /health (loopback only).
```

Post + result:
```
Build result: SUCCESS
[WS-CLEANUP] done
Finished: SUCCESS
```

## 5. Security notes observed in this run

- Credential values were masked in every `sh` invocation (`****/devops-demo-web:ci-2`,
  `export KUBECONFIG=****`). Jenkins also warned that `withEnv` received a secret
  via Groovy interpolation — expected for the `environment { credentials(...) }`
  pattern and non-leaking (value stays masked).
- The controller is loopback-only; the agent reaches it over the internal compose
  network. No port was opened to the LAN/Internet.
- The agent holds the host Docker socket (documented: any job here is effectively
  host-root). Only trusted pipelines run here.

## 6. Remaining blockers for a full end-to-end (push) run

1. **`dockerhub-creds`** — a Jenkins *Username with password* credential holding
   the Docker Hub user `21520623` + an **access token** (never the account
   password). Operator must add it via the UI (I cannot receive secrets).
2. **Committed source** — for `checkout scm` to build the *current* pipeline, the
   working tree must be committed (and pushed if the SCM is GitHub). Requires
   explicit approval; not done unilaterally.

Once both exist, the authoritative `Jenkinsfile` runs Publish → Deploy → Smoke
unchanged, pushing `21520623/devops-demo-web:<git-sha>` and `:latest`.
