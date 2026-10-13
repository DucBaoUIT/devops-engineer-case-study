# Environment Audit — Phase 1 Discovery

Date (UTC): 2026-10-14
Auditor: Senior DevOps Engineer (autonomous agent)
Scope: single-host audit of the machine hosting `~/devops-case-study`.

> Secret policy: no credential material, tokens, private keys or `~/.docker/config.json`
> contents are reproduced in this document. Only *presence/absence* is recorded.

## 1. Host & kernel

| Item | Value |
| --- | --- |
| Hostname | `ubuntu` |
| User | `root` (uid 0) — full sudo |
| OS | Ubuntu 24.04.3 LTS (Noble) |
| Kernel | `6.8.0-79-generic` x86_64 |
| Uptime | ~44 min at audit time |
| Load avg (1/5/15) | 0.06 / 0.09 / 0.04 (idle) |

## 2. Compute & storage

| Item | Value | Comment |
| --- | --- | --- |
| vCPU | 8 | Plenty for a single-node kind cluster + Jenkins container |
| RAM | 11 GiB total, 8.7 GiB free, 2.2 GiB buff/cache | Comfortable |
| Swap | 0 B | None configured — kubelet eviction relies on memory limits |
| Disk `/` | 67 GB total, 3.2 GB used, 64 GB avail (5%) | Ample for images and kind node |

## 3. Network & exposure

| Interface | Address | Note |
| --- | --- | --- |
| `eth0` | 192.168.1.251/24 | **Private LAN — VPS is behind NAT**, not directly Internet-routed |
| `docker0` | 172.17.0.1/16 | Default Docker bridge |
| `br-02d968526c1d` | 172.18.0.1/16 | Compose network `devops-case-study_default` |

Listening sockets (subset):

| Local | Process | Risk |
| --- | --- | --- |
| `0.0.0.0:22` | sshd | Existing SSH — must not be altered |
| `0.0.0.0:8081` | docker-proxy → `devops-case-study-app-1` | Compose demo app, on LAN |
| `127.0.0.1:43827`, `127.0.0.1:56510` | node, Qoder IDE | Loopback only |
| `127.0.0.53:53` | systemd-resolved | Loopback only |

Firewall:

- `ufw` binary **not installed**.
- No `nftables`/`iptables` custom rules inspected (host is behind NAT — inbound
  from Internet requires provider-level port forwarding).
- **Rule applied:** no changes made to SSH, network, or firewall configuration.

## 4. Tooling matrix

| Tool | Status | Version |
| --- | --- | --- |
| `git` | ✅ installed | 2.43.0 |
| `python3` | ✅ installed | 3.12.3 |
| `pip3` (system binary) | ❌ missing | Use `python3 -m pip` instead |
| Python venv (`.venv/`) | ✅ present | pip 24.0, Flask 3.1.0 installed |
| `docker` CLI + daemon | ✅ running | 29.9.0 (server), systemd cgroup driver, overlayfs |
| `docker-compose` v1 binary | ❌ missing | Use `docker compose` (plugin) — verified available |
| `kind` | ✅ installed | 0.30.0 |
| `kubectl` | ✅ installed | v1.37.1 (client) |
| `helm` | ❌ not installed | Not required for this case study |
| `java` | ❌ not installed | Jenkins will run inside a container |
| `curl` | ✅ installed | 8.5.0 |
| `jq` | ❌ not installed | Use `python3 -c "import json…"` fallback |

## 5. Docker runtime state

- Socket: `/var/run/docker.sock`, owner `root:docker`, mode `0660`. Not exposed on TCP.
- Running containers: 1 — `devops-case-study-app-1` (healthy, uptime 31 min).
- Images: 1 — `devops-demo-web:local` (185 MB).
- Networks: default + `devops-case-study_default` (compose).
- Docker Hub auth: `~/.docker/config.json` **absent** → not logged in.

## 6. Kubernetes state

- `kubectl config get-contexts` returns empty — no kubeconfig.
- `kind get clusters` returns "No kind clusters found".
- No system-level kubelet/containerd-for-k8s (only Docker's own containerd).

## 7. Jenkins state

- No `jenkins` systemd service, no `jenkins` container running.
- `docker-compose.yml` **declares** a `jenkins/jenkins:lts-jdk17` service with
  port bindings `8080:8080` and `50000:50000` on `0.0.0.0`.
  This service is *not started*.
- **Risk if started as-is:** binds to all interfaces. Host has no firewall, but
  the primary NIC is on RFC1918 space behind NAT, so exposure is LAN-only
  unless the provider forwards 8080. Still, the safer default is
  `127.0.0.1:8080:8080` + SSH tunnel for admin access.
- **Action taken (Phase 1):** Jenkins NOT started during discovery.
  Awaiting approval (see §10 Blockers).
- **Update (Phase 5):** approved and deployed **loopback-only**. The compose
  bindings were changed from `0.0.0.0` to `127.0.0.1:8080` / `127.0.0.1:50000`
  (the safer default recommended above), a dedicated `linux-docker-agent`
  was provisioned with the Docker socket, and the `devops-demo-web` job ran
  green (build #2, SUCCESS). The `0.0.0.0` binding and "not started" state
  described above were the pre-Phase-5 snapshot and are no longer in effect.
  See `docs/deployment-guide.md` §5 and `docs/evidence/phase5-jenkins-ci.md`.

## 8. Repository state

```
Branch: main  → origin/main (up-to-date, no uncommitted changes)
Remote: git@github.com:DucBaoUIT/devops-engineer-case-study.git
Log:
  cc5480d  Initial DevOps case study
```

Files inspected before any edit:

- `README.md`, `Dockerfile`, `.dockerignore`, `docker-compose.yml`, `Jenkinsfile`
- `app/app.py`, `app/requirements.txt`, `app/requirements-dev.txt`, `app/tests/test_app.py`
- `k8s/namespace.yaml`, `k8s/deployment.yaml`, `k8s/service.yaml`
- `scripts/deploy.sh`, `scripts/rollback.sh`
- `docs/SLIDE_NOTES.md`, `.gitignore`
- Existing artefacts kept intact: `docs/DevOps_CaseStudy_Report.pdf`,
  `slides/DevOps_CaseStudy_Presentation.pptx`

Placeholders found (not yet substituted):

| File | Placeholder | Needs |
| --- | --- | --- |
| `Jenkinsfile` | `IMAGE_NAME = 'DOCKERHUB_USERNAME/devops-demo-web'` | Real Docker Hub namespace |
| `k8s/deployment.yaml` | `image: DOCKERHUB_USERNAME/devops-demo-web:latest` | Real image ref + immutable tag |
| `README.md` | `DOCKERHUB_USERNAME` mention | Same |

## 9. Application smoke check (existing container)

```
GET http://127.0.0.1:8081/health  → HTTP 200  {"status":"ok"}   (1.6 ms)
GET http://127.0.0.1:8081/        → {"message":"Hello from Docker Compose","service":"demo-web","version":"local"}
Container user: 10001 (non-root)   Health: healthy
```

## 10. Risks & prerequisites still missing

| # | Item | Severity | Mitigation |
| --- | --- | --- | --- |
| R1 | Docker Hub credentials not configured (`~/.docker/config.json` absent) | High for Phase 5 push | **RESOLVED (Phase 5):** operator added Jenkins credential `dockerhub-creds` (user `21520623` + access token) via the UI; build #3 `docker login` → push succeeded. No token committed, no host `docker login`. |
| R2 | Docker Hub **username/namespace** unknown — placeholder `DOCKERHUB_USERNAME` in `Jenkinsfile` and `k8s/deployment.yaml` | High | **RESOLVED (Phase 5):** namespace = `21520623`; replaced the placeholder in the manifests, overlay, README and Jenkinsfile, and stored as the `dockerhub-username` credential. |
| R3 | Jenkins service in `docker-compose.yml` binds `0.0.0.0:8080` and `0.0.0.0:50000` with no host firewall | Medium (LAN-only in practice) | Change to `127.0.0.1:8080:8080` / `127.0.0.1:50000:50000` and access via SSH tunnel; get approval before starting. |
| R4 | No Jenkins agent image with Docker CLI + kubectl + Python; controller image alone cannot run pipeline `sh` steps that need Docker socket | Medium | Two safe options: (a) mount `/var/run/docker.sock` into an *agent* container (never the controller running untrusted jobs); (b) use Kaniko/Buildah for socket-less builds. Ask user preference. |
| R5 | `pip3` and `jq` not installed on host | Low | Use `python3 -m pip` and `python3 -c "import json…"`; install only if required. |
| R6 | Kind cluster image loading — no public registry pull yet | Low | Use `kind load docker-image` for local images; switch to registry pull once R1/R2 are resolved. |
| R7 | `imagePullPolicy: Always` in `k8s/deployment.yaml` combined with `kind load` will fail unless image actually exists in a reachable registry | Medium | For kind lab, set `IfNotPresent` when using loaded images; keep `Always` only when the image is on Docker Hub. |
| R8 | `requirements-dev.txt` duplicates `requirements.txt` (no lint/test deps) | Low | Acceptable for the case study; note in optimization phase. |
| R9 | No swap; memory pressure would OOM-kill pods | Low | Requests/limits already set in deployment. |
| R10 | Existing published artefacts (`docs/DevOps_CaseStudy_Report.pdf`, `slides/*.pptx`) must not be overwritten | Info | Only add new docs under `docs/`; update slide notes if actually re-presenting. |

## 11. Blockers requiring user decision (single ask)

To be raised once, at the end of the independent phases:

1. **Docker Hub namespace/username** (needed to remove the `DOCKERHUB_USERNAME`
   placeholder in `Jenkinsfile` + `k8s/deployment.yaml` and to push images).
2. **Docker Hub authentication method**: (a) `docker login` on host now, or
   (b) only as a Jenkins credential later, or (c) skip push and run kind-only.
3. **Jenkins on this VPS**: approve starting `jenkins/jenkins:lts-jdk17` from
   `docker-compose.yml` with ports rebound to `127.0.0.1` (SSH tunnel access),
   or defer Jenkins entirely and finish the rest with kind only.
4. **Jenkins build agent strategy**: mount Docker socket into a dedicated
   `jenkins-agent` container (with the security caveat), or use Kaniko
   (socket-less) — required before the pipeline can actually build images.

Everything else in Phases 2, 3, 4, 6, 7, 8, 9 proceeds without waiting.

## 12. What was **not** changed in Phase 1

- No package installs (`apt`, `pip` outside venv).
- No systemd unit touched.
- No firewall/SSH/network change.
- No Docker container, image, volume or network removed.
- No Kubernetes cluster created or deleted.
- No file inside the repository modified.
- No secret read, printed, or written to disk.

**Phase 1 status: PASS.**
