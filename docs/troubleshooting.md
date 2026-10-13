# Troubleshooting

Real issues encountered while bringing this case study up on the target VPS,
in the order they were hit. Each entry lists the symptom, the diagnostic
command(s), the root cause, and the fix that was actually applied.

---

## T1. `docker stop` takes 10 seconds and returns exit code 137

**Symptom.** The Flask container ignores SIGTERM. `docker stop` waits the
full grace period, then SIGKILLs the process. `docker inspect` shows
`ExitCode=137`.

**Diagnosis.**
```bash
docker run -d --name diag devops-demo-web:local
docker exec diag sh -c 'readlink /proc/1/exe; tr "\0" " " < /proc/1/cmdline; echo'
time docker stop diag
docker inspect diag --format '{{.State.ExitCode}}'
```

**Root cause.** Python is PID 1 inside the container. Python's default
SIGTERM behaviour is to terminate immediately **without cleanup**, and
Werkzeug's dev server does not install a SIGTERM handler. Combined with the
kernel's special rules for PID 1 (only signals with installed handlers are
delivered), the SIGTERM from Docker is effectively dropped. Docker then
SIGKILLs after `--stop-timeout`.

**Fix applied.** Install `tini` in the image and set it as `ENTRYPOINT`.
tini becomes PID 1, forwards SIGTERM to `python app.py`, and reaps zombies.
```dockerfile
RUN apt-get install -y --no-install-recommends tini=0.19.*
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python","app.py"]
```

**Result.** `docker stop` = 0.20 s, exit code 143 (SIGTERM). Verified side
by side against the pre-tini image in `docs/pipeline-optimization.md`.

---

## T2. `kubectl apply -k k8s/overlays/kind` fails with "security; file … is not in or below …"

**Symptom.**
```
error: accumulating resources: accumulation err='accumulating resources from
'../../namespace.yaml': security; file '/root/devops-case-study/k8s/namespace.yaml'
is not in or below '/root/devops-case-study/k8s/overlays/kind''
```

**Root cause.** Kustomize's default load restrictor forbids a kustomization
from referencing files outside its own directory tree. This is a
deliberate safety default (a malicious kustomization cannot read arbitrary
host paths).

**Fix applied.** Pass `--load-restrictor LoadRestrictionsNone` when
rendering. `kubectl apply -k` does **not** accept that flag, so the render
and apply steps are split:
```bash
kubectl kustomize k8s/overlays/kind --load-restrictor LoadRestrictionsNone \
  | kubectl apply -f -
```
`scripts/deploy.sh` does this for you.

**Alternative considered and rejected.** Moving the base manifests into
`k8s/base/`. That would satisfy the default restrictor but rewrites the
repository layout the user already has. Deferred until there is a real
reason (a second overlay).

---

## T3. `kubectl port-forward svc/demo-web 127.0.0.1:8082:80` → "Service 'demo-web' does not have a named port '127.0.0.1'"

**Symptom.** The command looks right but kubectl parses `127.0.0.1:8082`
as `<pod-name>:<port>` instead of `<address>:<port>`.

**Root cause.** `kubectl port-forward` does not accept an address as part
of the port argument. The address must be passed via `--address`.

**Fix.**
```bash
kubectl -n devops-demo port-forward --address 127.0.0.1 svc/demo-web 8082:80
```
All examples in this repo use that form. The bad form is kept here as a
search anchor for anyone hitting the same error.

---

## T4. New pod stuck in `ErrImagePull` / `ImagePullBackOff` after `kubectl set image`

**Symptom.**
```
demo-web-5df6475d74-dkd5c   0/1   ImagePullBackOff   0   19s
```
Events:
```
Warning  Failed  ...  Failed to pull image "devops-demo-web:does-not-exist":
  pull access denied, repository does not exist or may require authorization:
  server message: insufficient_scope: authorization failed
```

**Root cause (three common variants).**
1. Tag genuinely does not exist (typo, deleted tag).
2. Image is local-only and was never loaded into kind nor pushed to a registry.
3. Private repository, missing `imagePullSecrets`.

**Diagnosis.**
```bash
kubectl -n devops-demo describe pod <pod>       # read the Events section
docker exec devops-demo-control-plane crictl images | grep <name>
```

**Fix (variant 2 — the one hit here).** Load the image into kind:
```bash
kind load docker-image devops-demo-web:<tag> --name devops-demo
```
And make sure the overlay sets `imagePullPolicy: IfNotPresent` so kubelet
uses the local image instead of trying to pull it.

**Recovery.** The old ReplicaSet keeps serving because
`maxUnavailable: 0`. Run:
```bash
scripts/rollback.sh
```
Verified: rollback converged in <5 s, `/health` returned 200 immediately
after (`docs/evidence/phase7-rollback-drill.md`).

---

## T5. Pod `Running` but `Ready 0/1` after patching `readinessProbe.httpGet.path`

**Symptom.** During a deliberate drill, patching the readiness path to
`/does-not-exist` leaves the pod Running with `READY 0/1`. Endpoints move
the pod IP into `notReadyAddresses`.

**Root cause.** Readiness failing does **not** restart the container — it
only removes the pod from the Service endpoints. That is by design.
Liveness failing would restart it; startup failing would eventually
restart it too.

**Fix / restore.**
```bash
kubectl -n devops-demo patch deployment demo-web --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health"}]'
kubectl -n devops-demo rollout status deployment/demo-web --timeout=60s
kubectl -n devops-demo get endpoints demo-web
```

**Interview note.** This is the difference between the three probes:
- `startupProbe` — "has the app finished booting?" gates the other two.
- `readinessProbe` — "can this pod serve traffic right now?" toggles
  endpoint membership. Failure does **not** kill the pod.
- `livenessProbe` — "is this pod deadlocked?" failure **restarts** the
  container.

---

## T6. `docker build` succeeds but the tag does not appear in `docker images`

**Symptom.** During one measurement run, `docker build -q -t <tag> . >/dev/null`
returned exit 0 but the tag was not in `docker images`, and running the tag
produced "pull access denied … repository does not exist".

**Root cause.** The Dockerfile at that moment referenced an external base
image (`krallin/tini:0.19.0-static`) that did not exist. BuildKit printed
the error on stderr, but stderr was swallowed by the surrounding pipeline
(`{ time -p …; } 2>&1 | awk '/^real/{…}'`). The measured "time" was the
time to fail, not to succeed.

**Lesson.** Never pipe `docker build` output through an aggressive filter
in a benchmark script. Either capture full logs to a file and grep the
last line, or check the exit code separately:
```bash
if ! docker build -t "$TAG" . > /tmp/build.log 2>&1; then
  tail -30 /tmp/build.log; exit 1
fi
```

**Fix applied.** Reverted to `apt-get install tini=0.19.*` from the Debian
repository (which is guaranteed to exist for `python:3.12-slim`), and re-ran
the measurements with full stderr visible.

---

## T7. `docker manifest inspect <image>` returns "authentication required"

**Symptom.** Trying to enumerate valid tags for `krallin/tini`:
```
denied: requested access to the resource is denied
unauthorized: authentication required
```

**Root cause.** Docker Hub requires authentication for the manifest
endpoint on this host (or the tag genuinely does not exist).

**Workaround.** Just try to `docker pull <image>:<tag>` and read the error.
Or query the public tag list at `https://hub.docker.com/v2/repositories/<ns>/<repo>/tags/`.

**Impact on this project.** None — we removed the external tini image
dependency (see T6).

---

## T8. `pip3` binary missing on Ubuntu 24.04

**Symptom.** `pip3 --version` → command not found.

**Root cause.** Ubuntu 24.04 splits pip into `python3-pip` and enforces
PEP 668 (externally-managed-environment). The system-wide `pip3` binary
may not be present.

**Fix.** Always create a venv:
```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r app/requirements-dev.txt
```
All commands in this repo use `.venv/bin/python -m pip` or the activated
venv. No system-wide pip installs are performed.

---

## T9. `kubectl top pods` → "Metrics API not available"

**Symptom.**
```
error: Metrics API not available
```

**Root cause.** kind does not ship metrics-server. That is fine for the
case study — we are not measuring resource usage, only enforcing
requests/limits.

**Fix (optional, if you want live usage numbers).**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# kind uses self-signed certs on the kubelet, so metrics-server needs:
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```
Not applied here; noted so the reader is not surprised.

---

## T10. `/tmp` not writable in some sandboxed shells

**Symptom.** During one drill, a script that redirected to `/tmp/pf.log`
failed with `Read-only file system` inside a bwrap-wrapped subshell, even
though `/tmp` was writable in the parent shell.

**Root cause.** The agent harness sometimes wraps commands in a bubblewrap
sandbox that mounts `/` read-only and only exposes the workspace directory
as writable. `/tmp` is inside `/`, so it becomes read-only in that
context.

**Fix.** Use `docs/evidence/tmp/` (inside the workspace) for scratch files
when running under the harness. For normal interactive use, `/tmp` is
fine.

---

## T11. Rollback warns about last-applied-configuration drift

**Symptom.** After `kubectl rollout undo`:
```
Warning: resource deployments/demo-web was previously managed with 'kubectl apply'.
Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration
annotation, which may cause unexpected behavior on future 'kubectl apply' operations.
```

**Root cause.** `kubectl set image` and `kubectl rollout undo` mutate the
live object without updating the last-applied annotation, so the next
`kubectl apply -f` may see a diff that no longer matches reality.

**Fix.** After a rollback, re-apply the desired state:
```bash
scripts/rollback.sh
IMAGE=devops-demo-web:<good-tag> scripts/deploy.sh
```
The deploy script always renders the overlay and applies it, which
restores the annotation.

---

## T12. Jenkins agent missing Docker socket access

**Status: RESOLVED — option 1 was applied.** Jenkins now runs on this host
(loopback-only) with a dedicated inbound agent that has the socket mounted.

**Symptom.** A pipeline `sh` step fails with `Cannot connect to the Docker
daemon at unix:///var/run/docker.sock`.

**Root cause.** The `jenkins/jenkins:lts-jdk17` image does not include a
Docker CLI, and even if you install one, the container has no access to
the host's Docker socket by default.

**Fix applied (option 1).** A dedicated `jenkins-agent` container built
from `jenkins-agent.Dockerfile` (`jenkins/inbound-agent:latest-jdk17` base)
mounts `/var/run/docker.sock`, installs the Docker CLI + buildx + `kubectl`
+ `kind` + `python3-venv` + `git`, and is labelled `linux-docker-agent`.
The `jenkins` and `jenkins-agent` services sit behind the `jenkins` compose
profile so a plain `docker compose up` does **not** start them. The
controller binds `127.0.0.1:8080` / `127.0.0.1:50000` only — no public
exposure. Verified in `docs/evidence/phase5-jenkins-ci.md` §1 (agent
toolchain) and §4 (in-build `docker build` succeeded on the agent).

**Options considered (decreasing order of preference).**
1. Dedicated **agent** container with the Docker CLI installed and
   `/var/run/docker.sock` mounted, labelled `linux-docker-agent`. Never
   mount the socket into the controller. ← **chosen**.
2. **Kaniko** or **Buildah** for socket-less builds inside the pipeline.
   Slower but no host Docker exposure.
3. A **Kubernetes pod template agent** with a `docker:dind` sidecar. Only
   if you have a real Kubernetes cluster to run agents on.

**Security caveat (still true).** Any job on `linux-docker-agent` is
effectively host-root because of the socket mount. Only trusted pipelines
run here. See `docs/deployment-guide.md` §5.

---

## T13. `ERROR: BuildKit is enabled but the buildx component is missing or broken`

**Symptom.** Jenkins build #1 on the agent failed at the *Build image*
stage (all prior stages green), 15 s, `result: FAILURE`:
```
+ docker build --tag ****/devops-demo-web:ci-1 --label ... .
ERROR: BuildKit is enabled but the buildx component is missing or broken.
       Install the buildx component to build images with BuildKit
```

**Diagnosis.** On the agent container:
```bash
docker exec devops-case-study-jenkins-agent-1 docker version      # client present
docker exec devops-case-study-jenkins-agent-1 docker buildx version
# → "docker: 'buildx' is not a docker command"
docker exec devops-case-study-jenkins-agent-1 \
  ls /usr/local/libexec/docker/cli-plugins/                        # empty
```

**Root cause.** The agent image installed Docker from the **static CLI
tarball**, which ships only the `docker` binary — not the `buildx` CLI
plugin. The app `Dockerfile` requires BuildKit (`# syntax=docker/dockerfile:1.7`
and `RUN --mount=type=cache,...`), and with `DOCKER_BUILDKIT=1` the `docker`
client delegates to `docker-buildx`, which was absent.

**Fix applied.** Install buildx into the agent image at the CLI-plugin path,
pinning the version to match the host (`docker buildx version` → v0.38.0):
```dockerfile
ARG BUILDX_VERSION=v0.38.0
RUN mkdir -p /usr/local/libexec/docker/cli-plugins \
 && curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
      -o /usr/local/libexec/docker/cli-plugins/docker-buildx \
 && chmod 0755 /usr/local/libexec/docker/cli-plugins/docker-buildx
```
Then rebuild the agent image and recreate the container:
```bash
docker compose build jenkins-agent
JENKINS_AGENT_SECRET="$(cat .jenkins-setup/agent-secret)" \
  docker compose --profile jenkins up -d jenkins-agent
docker exec devops-case-study-jenkins-agent-1 docker buildx version   # v0.38.0
```

**Result.** Build #2 SUCCEEDED in 16.09 s; the *Build image* stage ran a
BuildKit build with the `--mount=type=cache` layers hitting cache
(`docs/evidence/phase5-jenkins-ci.md` §4). Sanity line in
`jenkins-agent.Dockerfile` now also runs `docker buildx version` at image
build time so a missing plugin fails the image build, not the pipeline.

**Lesson.** A "docker" install is not one thing. The static CLI tarball,
the `docker.io` apt package, and the Docker Inc. repo bundle different sets
of CLI plugins. When a build needs BuildKit features, verify `docker buildx
version` explicitly — do not assume it ships with the `docker` binary.
