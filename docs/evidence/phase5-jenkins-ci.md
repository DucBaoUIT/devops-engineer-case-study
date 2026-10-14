# Phase 5 — Jenkins CI/CD: provisioning + real build evidence

Date: 2026-10-13 (UTC) · Host: `ubuntu` (Ubuntu 24.04.3, 8 vCPU / 11 GiB)
Jenkins: `jenkins/jenkins:lts-jdk17`, version **2.541.3**, bound to **127.0.0.1:8080 / 127.0.0.1:50000** (loopback only).
Agent: `devops-case-study-jenkins-agent:latest` (inbound JNLP), label `linux-docker-agent`.

> **Authoritative result (updated 2026-10-14):** the multibranch job
> `devops-case-study` ran the repository `Jenkinsfile` end-to-end on `main`
> @ `9b93e21` — **build #3 SUCCESS in ~118 s**. Unit tests passed (2/2), image
> built (186 MB, digest `sha256:dc269a5a…6150`), **pushed to Docker Hub**
> (`21520623/devops-demo-web:9b93e2104bec` + `:latest`), deployed to kind
> (2/2 Ready) which **pulled the same digest back from the registry**, and the
> smoke test returned **HTTP 200** on `/health` and `/`. Full evidence in **§5**.
>
> §3–§4 below are the earlier read-only CI-harness runs (job `devops-demo-web`)
> kept as historical record; **§5 is the authoritative end-to-end run.**

> All secret values are masked by Jenkins as `****` in the logs below. No token,
> password, kubeconfig content, or JNLP secret appears in this file. The raw
> console logs live in the gitignored `.jenkins-setup/` dir
> (`build1-console.log`, `build2-console.log`, `build-scm-3.log`).

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
| Credential `dockerhub-creds` | **PRESENT** — Username/password: user `21520623` + Docker Hub **access token** (operator-added via UI, ID normalized to `dockerhub-creds`) | Groovy `dockerhub-creds present: true`; build #3 `docker login` → `Login Succeeded` |
| Job `devops-demo-web` | Pipeline (read-only CI harness; builds #1–#2, §3–§4) | REST `createItem` → HTTP 200 |
| Job `devops-case-study` | **Multibranch Pipeline**; source **migrated to GitHub** (`https://github.com/DucBaoUIT/devops-engineer-case-study.git`, anonymous HTTPS, 5-min poll) during the final audit — originally `file:///repo-src`; discovers `main`; runs the authoritative `Jenkinsfile` | build **#3 SUCCESS** (file://, real push + deploy, §5); build **#5 SUCCESS** (GitHub-sourced, §8) |

Plugins installed (the ones the `Jenkinsfile` depends on):
`git`, `git-client`, `workflow-aggregator`, `pipeline-model-definition`,
`workflow-cps`, `workflow-durable-task-step`, `pipeline-stage-step`,
`credentials`, `credentials-binding`, `plain-credentials`, `ssh-credentials`,
`junit`, `timestamper`, `ws-cleanup`, `scm-api`, `branch-api`, `structs`,
`script-security`, `matrix-project`, `cloudbees-folder` (+ their API deps).

## 2. Job source strategy (two jobs, and why)

Two Jenkins jobs exist, reflecting how the work progressed:

1. **`devops-demo-web`** (Pipeline, §3–§4) — an early **read-only CI harness**,
   used while the working tree was still uncommitted and `dockerhub-creds` was
   not yet available. It bind-mounts the tree at `/repo-src` and runs
   Validate → Unit tests → Build (plus a read-only cluster check); Publish /
   Deploy / Smoke were intentionally **skipped** at that time. Kept for history.

2. **`devops-case-study`** (Multibranch Pipeline, §5) — the **authoritative**
   job. The tree is committed **and published to GitHub** (`main` = `703d0ed`,
   in sync with `origin/main`). During the final audit the multibranch source was
   **migrated from `file:///repo-src` to GitHub**
   (`https://github.com/DucBaoUIT/devops-engineer-case-study.git`, public →
   anonymous HTTPS) with a 5-min `PeriodicFolderTrigger`; it discovers `main` and
   runs the repository's real `Jenkinsfile` via `checkout scm` — with
   `BRANCH_NAME=main` set, which the declarative `when { branch 'main' }` guards
   on Publish/Deploy/Smoke require. This job runs the **full** pipeline
   including a real Docker Hub push (build #3, from the earlier `file://` mount).
   See §8 and `docs/deployment-guide.md` §5.4.

`.jenkins-setup/` (setup secrets, raw logs) and `.venv/` are gitignored and are
never part of `checkout scm`, so no secret enters a build workspace.

> **Build-gate note (fixed before build #3).** The `Build image` stage originally
> used a declarative `changeset` guard. Because `cleanWs(deleteDirs:true)` wipes
> the workspace every build, the git plugin computed an **empty changelog** and
> `changeset` never matched — multibranch builds **#1 and #2 returned SUCCESS but
> skipped Build → Publish → Deploy → Smoke** ("Warning, empty changelog"). Fixed
> in commit `9b93e21` by deciding with `git diff --name-only HEAD~1 HEAD`
> instead (a fresh clone still has full history). Build #3 is the first run that
> executed every stage. Recorded as troubleshooting item **T14**.

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

## 5. Build #3 — authoritative SCM-driven end-to-end (multibranch, REAL push) ✅

The multibranch job `devops-case-study` discovered branch `main` at commit
**`9b93e21`** and ran the repository's real `Jenkinsfile` unchanged. **All eight
stages executed** (none skipped); the build finished **SUCCESS in ~118 s**
(`durMs=118203`), pushing to Docker Hub and deploying the pushed image to kind,
which pulled it back from the registry.

Checkout (`checkout scm` from `file:///repo-src`):
```
Obtained Jenkinsfile from 9b93e2104becbf1cb89950c8f4141b73c972a2e0
Checking out Revision 9b93e2104becbf1cb89950c8f4141b73c972a2e0 (main)
Building from commit 9b93e2104bec
```

Unit tests (ran in parallel with Build image):
```
+ python -m unittest discover -s app/tests -v
test_health (test_app.AppTests.test_health) ... ok
test_home (test_app.AppTests.test_home) ... ok
Ran 2 tests in 0.008s
```

Build image (BuildKit via buildx; Hub namespace masked as `****`):
```
+ docker build --pull --tag ****/devops-demo-web:9b93e2104bec --tag ****/devops-demo-web:latest \
    --label org.opencontainers.image.revision=9b93e2104bec... --label ...source=file:///repo-src .
#14 exporting manifest list sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150 done
built image id=sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150 size=186348946
```

**Publish image — REAL push to Docker Hub** (`dockerhub-creds`; user + token masked):
```
+ docker login --username **** --password-stdin
Login Succeeded
+ docker push ****/devops-demo-web:9b93e2104bec
The push refers to repository [docker.io/****/devops-demo-web]
...(12 layers)... Pushed
9b93e2104bec: digest: sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150 size: 856
+ docker push ****/devops-demo-web:latest
latest: digest: sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150 size: 856
```

**Deploy to Kubernetes** (`kubeconfig-dev`; kind internal API, agent → control-plane):
```
+ export KUBECONFIG=****
Kubernetes control plane is running at https://devops-demo-control-plane:6443
+ kubectl -n devops-demo set image deployment/demo-web demo-web=****/devops-demo-web:9b93e2104bec
deployment.apps/demo-web image updated
+ kubectl -n devops-demo rollout status deployment/demo-web --timeout=180s
deployment "demo-web" successfully rolled out
demo-web-6dcf87d5f8-c8vfn   1/1   Running   0   3s
demo-web-6dcf87d5f8-xwhc9   1/1   Running   0   12s
```

**Smoke test** (loopback `port-forward` only — no public port opened):
```
+ kubectl -n devops-demo port-forward --address 127.0.0.1 svc/demo-web 18082:80
--- /health ---
{"status":"ok"}
HTTP=200 time=0.002752s
--- / ---
{"message":"Hello from Kubernetes","service":"demo-web","version":"k8s"}
HTTP=200
smoke test ok
```

Result:
```
Build result: SUCCESS
Pipeline succeeded for ****/devops-demo-web:9b93e2104bec
Finished: SUCCESS
```

### 5.1 Registry round-trip proof (pushed digest == running-pod digest)

Verified independently on the kind node **after** the build. The pods run the
exact digest that was pushed, in `RepoDigest` (`docker.io/...@sha256:`) form —
which only appears for **registry-pulled** images. The tag `9b93e2104bec` was
built on the host daemon and was **never** `kind load`ed into the node, so a
successful rollout can only mean the node pulled it from Docker Hub:
```
$ kubectl -n devops-demo get deploy demo-web -o jsonpath='{..image}'
21520623/devops-demo-web:9b93e2104bec        (imagePullPolicy: IfNotPresent, readyReplicas 2/2)

$ kubectl -n devops-demo get pods -l app=demo-web -o jsonpath='{..imageID}'
docker.io/21520623/devops-demo-web@sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150
docker.io/21520623/devops-demo-web@sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150
```
Pushed digest `sha256:dc269a5a…6150` (console lines 441 & 541) **==** the
running pods' `imageID` digest ⇒ the full **build → push → pull → deploy →
smoke** loop is proven with real artifacts, not simulation.

## 6. Security notes observed in this run

- Credential values were masked in every `sh` invocation across all builds
  (`****/devops-demo-web:9b93e2104bec`, `docker login --username ****
  --password-stdin`, `export KUBECONFIG=****`). In build #3 the Docker Hub token
  was consumed only inside `withCredentials(...) { }` and piped via
  `--password-stdin` (never as a CLI argument), with `docker logout` on an EXIT
  trap. Jenkins also warned that `withEnv`/`echo` received a secret via Groovy
  interpolation — expected for the `environment { credentials(...) }` pattern and
  non-leaking (the value stays masked as `****`).
- The controller is loopback-only; the agent reaches it over the internal compose
  network; the smoke test used `kubectl port-forward --address 127.0.0.1`. No port
  was opened to the LAN/Internet at any point.
- The agent holds the host Docker socket (documented: any job here is effectively
  host-root). Only trusted pipelines run here.

## 7. Blockers RESOLVED (previously: full end-to-end push)

Both former blockers for an authoritative push run are now cleared:

1. **`dockerhub-creds`** — RESOLVED. The operator added a Docker Hub
   *Username with password* credential (user `21520623` + **access token**, never
   the account password) via the UI; its auto-generated UUID ID was normalized to
   `dockerhub-creds` (the ID the `Jenkinsfile` references). Build #3 used it:
   `docker login` → `Login Succeeded`, then a real push.
2. **Committed source** — RESOLVED, then **published**. Originally approved as
   *commit locally, no remote push* (`HEAD = 9b93e21`) and indexed from the
   read-only `file:///repo-src` mount. The tree is now **published to GitHub**
   (`main` = `703d0ed`, in sync with `origin/main`), and the multibranch source
   was migrated to GitHub HTTPS (see §8), so `checkout scm` clones from github.com.

Result: the authoritative `Jenkinsfile` ran Publish → Deploy → Smoke unchanged,
pushing `21520623/devops-demo-web:9b93e2104bec` + `:latest` and deploying the
pushed digest to kind (build #3, SUCCESS). **No remaining Phase 5 blockers.**

## 8. Migration to GitHub SCM (final audit, 2026-10-14)

Builds #1–#4 above ran from a local `file:///repo-src` bind-mount — the code was
on GitHub, but Jenkins was **not** building *from* GitHub, and there was **no
automatic trigger**. The final audit corrected this.

**Verified before the change (actual state):**
- Live job source: `jenkins.plugins.git.GitSCMSource`, remote `file:///repo-src`,
  credentialsId `none`, `BranchDiscoveryTrait`; **triggers: none**.
- Build #4 `remoteUrls: file:///repo-src`, `builtSHA1: eeb7f1d…`.
- GitHub `main` = `703d0ed…` (public repo; `git ls-remote https://…` OK from host,
  controller **and** agent — so an anonymous HTTPS clone needs no credential).
- SSH from this host is **not** authorized (`git@github.com: Permission denied
  (publickey)`); fetch/push over SSH unavailable. HTTPS is anonymous/read-only.

**Smallest safe change applied (reversible; prior `config.xml` backed up first):**
- Source → `https://github.com/DucBaoUIT/devops-engineer-case-study.git`
  (anonymous HTTPS, `credentialsId=null`), same `BranchDiscoveryTrait` +
  `scriptPath=Jenkinsfile`.
- Added `PeriodicFolderTrigger('5m')` — outbound-only re-index. **No webhook**:
  Jenkins is loopback-only behind NAT, and exposing :8080 is prohibited.
- Job description updated to match.

**Verification (build #5, real console excerpt):**
```
Cloning repository https://github.com/DucBaoUIT/devops-engineer-case-study.git
Checking out Revision 703d0ed5b14a8a384f3e888e74e46d2c35499d3f (main)
Obtained Jenkinsfile from 703d0ed5b14a8a384f3e888e74e46d2c35499d3f
Stage "Build image"          skipped due to when conditional
Stage "Publish image"        skipped due to when conditional
Stage "Deploy to Kubernetes" skipped due to when conditional
Stage "Smoke test"           skipped due to when conditional
Finished: SUCCESS
```
Live SCM audit after the build: `build #5 → remoteUrls:
https://github.com/DucBaoUIT/devops-engineer-case-study.git, builtSHA1:
703d0ed5b14a8a384f3e888e74e46d2c35499d3f`. Build #5 is **docs-only** vs its
parent (`eeb7f1d`), so the change-gate correctly skipped Build/Publish/Deploy/
Smoke — the live deployment stayed at `9b93e2104bec` (2/2), undisturbed.

**What is now true:** CI is genuinely GitHub-driven — a new commit to
`origin/main` is discovered within ~5 min and built from github.com. **Not yet
re-proven from GitHub:** a *build-relevant* change (one that re-runs
Build → Publish → Deploy) has not been pushed through the GitHub source, since
that would rebuild/re-push/re-deploy; the full push+deploy loop remains proven by
build #3 (§5). The gate is source-agnostic (`git diff HEAD~1 HEAD`), so a
build-relevant GitHub commit runs the full pipeline identically.
