# Deployment Guide

This guide covers every environment the case study runs in. Every command
below has been executed on the target host at least once; the observed
result is referenced from `docs/evidence/`.

## 0. Prerequisites (already installed on the target VPS)

| Tool | Version verified | Install hint (Ubuntu 24.04) |
| --- | --- | --- |
| Docker Engine | 29.9.0 | `apt-get install docker.io` **or** the Docker Inc. repo |
| Docker Compose plugin | v2 (bundled with Docker 29) | ships with Docker |
| kind | 0.30.0 | `go install sigs.k8s.io/kind@v0.30.0` or a released binary |
| kubectl | v1.37.1 | `curl -LO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl` |
| python3 | 3.12.3 | preinstalled |
| python3-venv | preinstalled | `apt-get install python3-venv` if missing |
| git | 2.43.0 | preinstalled |
| curl | 8.5.0 | preinstalled |

Optional (only for the Jenkins stage):

| Tool | Reason |
| --- | --- |
| `jenkins/jenkins:lts-jdk17` container | Controller |
| A Linux agent with Docker socket access, `kubectl`, `python3-venv`, `git`, `curl` | Runs the `linux-docker-agent` label |

## 1. Local Python validation (no Docker)

```bash
cd ~/devops-case-study
python3 -m venv .venv
. .venv/bin/activate
pip install -r app/requirements-dev.txt
python -m unittest discover -s app/tests -v
```

**Expected:**
```
test_health (test_app.AppTests.test_health) ... ok
test_home  (test_app.AppTests.test_home)  ... ok
Ran 2 tests in 0.006s
OK
```

Verified result: `docs/evidence/phase4-kind-deploy.md` (bottom) and the
Phase-2 log in `docs/validation-report.md`.

## 2. Local Docker run (compose)

```bash
docker compose up --build -d app
curl -sS http://127.0.0.1:8081/health     # {"status":"ok"}
curl -sS http://127.0.0.1:8081/           # {"service":"demo-web", ...}
docker compose logs app --tail 30
docker compose down app                    # stop only the app service
```

Note: `docker-compose.yml` puts the `jenkins` service behind the
`jenkins` compose profile, so `docker compose up` will **not** start
Jenkins. That is deliberate — see §5.

## 3. Local Docker build with an immutable tag

```bash
GIT_SHA=$(git rev-parse --short=12 HEAD)
WORK_HASH=$( { git diff HEAD; git status --porcelain; } | sha256sum | cut -c1-8 )
TAG="${GIT_SHA}-w${WORK_HASH}"       # clean tree ⇒ -w<hash-of-empty>
docker build --pull -t "devops-demo-web:${TAG}" -t devops-demo-web:current .

# Verify graceful shutdown (tini is PID 1)
docker run -d --name smoke "devops-demo-web:${TAG}"
sleep 2
docker exec smoke readlink /proc/1/exe      # → /usr/bin/tini
time docker stop smoke                      # → ~0.2s, exit code 143
docker rm smoke
```

Verified: `docker stop` = 0.20 s / exit 143, versus 10.22 s / exit 137 on
the pre-tini image. Full numbers in `docs/pipeline-optimization.md`.

## 4. Kubernetes on kind (local lab)

### 4.1 Create the cluster (one-time)

```bash
cat > /tmp/kind-devops-demo.yaml <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: devops-demo
nodes:
  - role: control-plane
YAML

kind create cluster --name devops-demo --config /tmp/kind-devops-demo.yaml --wait 120s
kubectl cluster-info --context kind-devops-demo
kubectl get nodes
```

Observed on this VPS: cluster Ready after 18 s, total command 45.9 s
(image pull included).

### 4.2 Load the image into kind

`kind` runs Kubernetes inside a Docker container. That container has its
own image store — the host's Docker images are **not** visible to it until
you load them:

```bash
kind load docker-image "devops-demo-web:${TAG}" --name devops-demo
docker exec devops-demo-control-plane crictl images | grep devops-demo-web
```

Observed: `kind load` = 2.10 s for a 45 MB compressed image.

### 4.3 Deploy

```bash
IMAGE="devops-demo-web:${TAG}" scripts/deploy.sh
```

The script:
1. Renders `k8s/overlays/kind` with `kubectl kustomize --load-restrictor LoadRestrictionsNone`
   (the flag is required because the overlay references files two levels up).
2. `kubectl apply -f -` the rendered bundle (namespace + deployment + service).
3. `kubectl set image` when `IMAGE` is provided.
4. `kubectl rollout status --timeout=180s`.

Observed: 2/2 pods Ready, 0 restarts, image `devops-demo-web:cc5480ddbf9e-w53253e69`.

### 4.4 Smoke test (loopback only)

```bash
kubectl -n devops-demo port-forward --address 127.0.0.1 svc/demo-web 8082:80 &
PF=$!
sleep 2
curl -sS -w "\nHTTP=%{http_code} time=%{time_total}s\n" http://127.0.0.1:8082/health
curl -sS http://127.0.0.1:8082/
kill $PF
```

**Do not** replace `--address 127.0.0.1` with `0.0.0.0` — that would
publish the service on every interface without going through a firewall
review.

### 4.5 Rollback

```bash
scripts/rollback.sh                       # undo to previous revision
REVISION=3 scripts/rollback.sh            # pin to revision 3
DRY_RUN=1 scripts/rollback.sh             # preview only
```

Verified in `docs/evidence/phase7-rollback-drill.md`: after a deliberate
`kubectl set image ... :does-not-exist`, the new ReplicaSet stayed in
`ImagePullBackOff` while the old ReplicaSet kept serving traffic
(`maxUnavailable=0`). `scripts/rollback.sh` restored the working image and
the rollout converged in <5 s.

### 4.6 Tear down (only when you mean it)

```bash
kubectl delete -k k8s/overlays/kind --load-restrictor LoadRestrictionsNone
kind delete cluster --name devops-demo
```

`kind delete cluster` destroys the cluster container and everything in it.
Nothing else on the host is touched.

## 5. Jenkins CI/CD (deployed — loopback only)

**Status on this VPS:** Jenkins **is running** — controller `2.541.3`
(`jenkins/jenkins:lts-jdk17`) bound to `127.0.0.1:8080` / `127.0.0.1:50000`
only, with a dedicated inbound agent `linux-docker-agent` (online, 2
executors) and a **green** CI verification build (`devops-demo-web` #2,
SUCCESS, 16.09 s). Full evidence: `docs/evidence/phase5-jenkins-ci.md`.

One acceptance item remains **BLOCKED**: **A19** (push to Docker Hub) needs
the `dockerhub-creds` access-token credential, which the operator must add
via the UI (an assistant cannot receive secrets). See §5.4.

The `jenkins` and `jenkins-agent` services are behind the `jenkins` compose
profile, so a plain `docker compose up` does **not** start them.

### 5.1 What was provisioned (all verified by command)

| Component | State | Verified by |
| --- | --- | --- |
| Controller | Up, loopback-only, HTTP 200, wizard complete | `curl 127.0.0.1:8080/login` → 200 |
| Plugins | 71 installed & active (incl. `git`, `workflow-aggregator`, `credentials-binding`, `junit`, `timestamper`, `ws-cleanup`) | Groovy plugin enumeration |
| Agent node `linux-docker-agent` | Online, 2 executors, labels `linux-docker-agent docker kind`, `JNLP4-connect` | `03-node-status.groovy` |
| Agent toolchain | docker 27.5.1 (+ host daemon 29.9.0), **buildx v0.38.0**, kubectl v1.34.0, kind v0.30.0, python 3.13.5, git 2.47.3 | `docker exec … version` |
| Agent → kind API | Reachable & authenticated over the `kind` network | in-build `kubectl cluster-info` |
| Credential `dockerhub-username` | Secret text = namespace `21520623` | Groovy credential listing |
| Credential `kubeconfig-dev` | Secret file = kind **internal** kubeconfig (5640 B) | used in build #2 |
| Credential `dockerhub-creds` | **ABSENT — BLOCKED** (operator adds token via UI) | Groovy `present: false` |
| Job `devops-demo-web` | Pipeline, build #2 SUCCESS | REST `lastBuild/api/json` |

### 5.2 How it was brought up (repeatable)

All steps ran on the host; the idempotent Groovy/REST helpers live in the
gitignored `.jenkins-setup/` (never committed — they reference bootstrap
secrets by file, and no secret is printed).

```bash
# 1. Build the agent image (Docker CLI + buildx + kubectl + kind + venv + git)
docker compose build jenkins-agent

# 2. Start the controller (loopback only) and wait for it to be ready
docker compose --profile jenkins up -d jenkins
docker compose logs -f jenkins        # "Jenkins is fully up and running"

# 3. Complete the wizard headlessly + install plugins, then restart so the
#    ref/plugins → live copy happens (jenkins-plugin-cli). See .jenkins-setup/.

# 4. Create the inbound agent node; the JNLP secret is written to a
#    controller file and copied to .jenkins-setup/agent-secret (chmod 600,
#    gitignored, never printed).
bash .jenkins-setup/run-groovy.sh .jenkins-setup/02-node.groovy

# 5. Start the agent, feeding it the secret via env (not the compose file)
JENKINS_AGENT_SECRET="$(cat .jenkins-setup/agent-secret)" \
  docker compose --profile jenkins up -d jenkins-agent
bash .jenkins-setup/run-groovy.sh .jenkins-setup/03-node-status.groovy   # isOnline=true

# 6. Create credentials (dockerhub-username, kubeconfig-dev). The plaintext
#    kubeconfig is deleted by the script right after it is stored.
bash .jenkins-setup/run-groovy.sh .jenkins-setup/04-credentials.groovy

# 7. Create the pipeline job from its config.xml
curl -sS -u "$ADMIN_USER:$ADMIN_PW" -H "Jenkins-Crumb: $CRUMB" \
  -X POST "http://127.0.0.1:8080/createItem?name=devops-demo-web" \
  -H 'Content-Type: application/xml' --data-binary @.jenkins-setup/job-devops-demo-web.xml
```

To reach the UI, open an SSH tunnel (do **not** widen the bind):
```
ssh -L 8080:127.0.0.1:8080 user@vps   # then http://127.0.0.1:8080
```

### 5.3 The pipeline job today (CI verification harness)

The repository working tree is **uncommitted** (`HEAD = cc5480d`), whose
committed `Jenkinsfile` is an older draft. Committing to your repo was not
done unilaterally. So the `devops-demo-web` job proves the pipeline against
the **current** tree without committing: the agent bind-mounts the working
tree read-only at `/repo-src`, copies it into the workspace (excluding
`.venv/` and `.jenkins-setup/` so no secret enters the build), and runs the
real **Validate → Unit tests → Build image** stages plus a **read-only**
`kubeconfig-dev` cluster check. `Publish → Deploy → Smoke` are intentionally
**SKIPPED**. Build #2 result (verified):

```
Validate repo        ok (required files present, no secret-like file tracked, Dockerfile has USER)
Unit tests           Ran 2 tests … OK  (test_health, test_home)
Build image          BuildKit build, image sha256:a55ba3da6fbd… size=186398778
Verify cluster       deploy demo-web 2/2, image devops-demo-web:cc5480ddbf9e-w53253e69
Publish/Deploy/Smoke SKIPPED (policy)
Finished: SUCCESS    (16.09 s)
```

The **authoritative** pipeline is the repository `Jenkinsfile` (6 stages,
SHA-based immutable tags, `when { changeset }` gating, `branch 'main'`
publish gate, port-forward smoke test). §5.4 explains how to switch the job
onto it.

### 5.4 Switch to the authoritative SCM-driven `Jenkinsfile` (+ unblock push)

Two things are required; both need operator action:

1. **Add the `dockerhub-creds` credential** (unblocks Publish → Deploy →
   Smoke, acceptance item **A19**). In the UI: *Manage Jenkins → Credentials
   → System → Global → Add Credentials*:
   - Kind: **Username with password**
   - ID: `dockerhub-creds`
   - Username: `21520623`
   - Password: a Docker Hub **access token** (never the account password)

   The `Jenkinsfile` consumes it via
   `withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', …)])`.
   `dockerhub-username` (namespace) and `kubeconfig-dev` already exist.

2. **Point the job at SCM** so `checkout scm` builds the current pipeline.
   The working tree must be committed (and pushed if the SCM is remote).
   Then either:
   - Edit `devops-demo-web` → *Pipeline → Definition: Pipeline script from
     SCM* → Git, your repo URL + a read-only SCM credential, Script Path
     `Jenkinsfile`; **or**
   - Create a **Multibranch Pipeline** (`devops-case-study`) with
     *Build Configuration → by Jenkinsfile*. Branch indexing discovers
     `main`.

   The pipeline still requires the `linux-docker-agent` label (already
   online). On `main`, with `dockerhub-creds` present, it pushes
   `21520623/devops-demo-web:<git-sha>` and `:latest`, deploys via the
   `kubeconfig-dev` overlay, and smoke-tests over a loopback port-forward.

> **Why not done automatically:** committing to your repo and supplying a
> registry token both require explicit approval / a secret I must not
> handle. Everything credential-independent in Phase 5 is complete and
> verified.

### 5.5 Generate a namespace-scoped kubeconfig for Jenkins

The deployed `kubeconfig-dev` credential holds the **kind internal**
kubeconfig, which is fine for this single-tenant lab cluster. For a shared
or real cluster, do **not** hand Jenkins an admin kubeconfig — create a
service account limited to `devops-demo`:

```bash
kubectl -n devops-demo create serviceaccount jenkins-deployer
kubectl -n devops-demo create role jenkins-deployer \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=deployments,replicasets,pods,services,endpoints,events
kubectl -n devops-demo create rolebinding jenkins-deployer \
  --role=jenkins-deployer --serviceaccount=devops-demo:jenkins-deployer

# Long-lived token (Kubernetes 1.24+)
kubectl -n devops-demo create token jenkins-deployer --duration=8760h > /tmp/jenkins.token

# Assemble a kubeconfig (do not print the token to logs)
kubectl config view --raw --minify --flatten > /tmp/kubeconfig-dev
# ...then edit /tmp/kubeconfig-dev to use the token from /tmp/jenkins.token
# and delete /tmp/jenkins.token immediately after uploading to Jenkins.
```

Upload the resulting file to Jenkins as `kubeconfig-dev` (Secret file).

### 5.6 Trigger a build and read the result

```bash
# In the Jenkins UI: devops-case-study → main → Build Now
# Or via CLI once the crumb is fetched:
curl -sS -X POST "http://127.0.0.1:8080/job/devops-case-study/job/main/build" \
     --user "<you>:<api-token>"
```

Watch the console output. On success you should see every stage green and:

```
Smoke test ok
Build result: SUCCESS
```

## 6. Docker Hub publish

Once `dockerhub-creds` exists, the Publish stage runs `docker push
"$IMAGE_REF"` and `docker push "$IMAGE_LATEST"` automatically on `main`.
To push manually for the first time (e.g. to seed the repository):

```bash
docker login                              # prompts, no shell history
docker tag devops-demo-web:${TAG} <hub-user>/devops-demo-web:${TAG}
docker push <hub-user>/devops-demo-web:${TAG}
docker logout
```

Do not commit `~/.docker/config.json`.
