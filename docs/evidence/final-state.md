# Final state snapshot
Timestamp: 2026-10-13T21:19:56Z — regenerated **after** the authoritative
Jenkins multibranch build **#3** pushed `21520623/devops-demo-web:9b93e2104bec`
to Docker Hub and deployed it to kind.

> Every value below is real command output captured at the timestamp above. No
> secrets are included (the Docker Hub namespace and image digest are public
> registry metadata). Cross-reference: `docs/evidence/phase5-jenkins-ci.md` §5.

## Host
Linux ubuntu 6.8.0-79-generic #79-Ubuntu SMP PREEMPT_DYNAMIC Tue Aug 12 14:42:46 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux

## kind clusters
devops-demo

## kubectl config current-context
kind-devops-demo

## Nodes
NAME                        STATUS   ROLES           AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION     CONTAINER-RUNTIME
devops-demo-control-plane   Ready    control-plane   123m   v1.34.0   172.19.0.2    <none>        Debian GNU/Linux 12 (bookworm)   6.8.0-79-generic   containerd://2.1.3

## Namespace devops-demo — all resources
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE                        NOMINATED NODE   READINESS GATES
pod/demo-web-6dcf87d5f8-c8vfn   1/1     Running   0          12m   10.244.0.13   devops-demo-control-plane   <none>           <none>
pod/demo-web-6dcf87d5f8-xwhc9   1/1     Running   0          12m   10.244.0.12   devops-demo-control-plane   <none>           <none>

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE    SELECTOR
service/demo-web   ClusterIP   10.96.165.119   <none>        80/TCP    122m   app=demo-web

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE    CONTAINERS   IMAGES                                  SELECTOR
deployment.apps/demo-web   2/2     2            2           122m   demo-web     21520623/devops-demo-web:9b93e2104bec   app=demo-web

NAME                                  DESIRED   CURRENT   READY   AGE    CONTAINERS   IMAGES                                   SELECTOR
replicaset.apps/demo-web-574fc97cc9   0         0         0       122m   demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=574fc97cc9
replicaset.apps/demo-web-5bf94898b8   0         0         0       119m   demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=5bf94898b8
replicaset.apps/demo-web-5df6475d74   0         0         0       121m   demo-web     devops-demo-web:does-not-exist           app=demo-web,pod-template-hash=5df6475d74
replicaset.apps/demo-web-6cb55b7f6    0         0         0       113m   demo-web     devops-demo-web:cc5480ddbf9e-w53253e69   app=demo-web,pod-template-hash=6cb55b7f6
replicaset.apps/demo-web-6dcf87d5f8   2         2         2       12m    demo-web     21520623/devops-demo-web:9b93e2104bec    app=demo-web,pod-template-hash=6dcf87d5f8

The `0/0/0` ReplicaSets are the Phase-7 rollback and bad-image drills
(`does-not-exist`, `...w4e1fd322`), retained by rollout history. The active
ReplicaSet `demo-web-6dcf87d5f8` (2/2) runs the CI-pushed Hub image.

## Deployment image + pull policy + resources
image: 21520623/devops-demo-web:9b93e2104bec      (pushed by Jenkins build #3)
imagePullPolicy: IfNotPresent
requests: {"cpu":"100m","memory":"64Mi"}
limits:   {"cpu":"500m","memory":"256Mi"}

## Registry round-trip (running pods carry the pushed digest)
demo-web-6dcf87d5f8-c8vfn -> docker.io/21520623/devops-demo-web@sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150
demo-web-6dcf87d5f8-xwhc9 -> docker.io/21520623/devops-demo-web@sha256:dc269a5a81963340bc9e1701db5c27e6f16dc7f74c30d11f979f204a2ba76150

The `@sha256:` RepoDigest form only appears for **registry-pulled** images; the
tag was never `kind load`ed. This digest equals the one pushed in build #3
(`docs/evidence/phase5-jenkins-ci.md` §5.1) ⇒ build → push → pull → deploy proven.

## Endpoints
NAME       ENDPOINTS                           AGE
demo-web   10.244.0.12:8080,10.244.0.13:8080   122m

## Docker images (devops-demo-web)
REPOSITORY                  TAG                      IMAGE ID       SIZE   NOTE
21520623/devops-demo-web    9b93e2104bec             dc269a5a8196   186MB  pushed to Docker Hub (build #3)
21520623/devops-demo-web    latest                   dc269a5a8196   186MB  pushed to Docker Hub (build #3)
21520623/devops-demo-web    ci-2                     a55ba3da6fbd   186MB  earlier CI-harness build #2
devops-demo-web             cc5480ddbf9e-w53253e69   a14b555418d2   186MB  Phase-4 kind-loaded
devops-demo-web             current                  a14b555418d2   186MB
devops-demo-web             cc5480ddbf9e-w4e1fd322   71d9d3c72606   186MB
devops-demo-web             phase3                   71d9d3c72606   186MB
devops-demo-web             cc5480ddbf9e             b609eacbfb91   185MB
devops-demo-web             local                    b609eacbfb91   185MB

## Docker compose app
NAMES                     IMAGE          STATUS                 PORTS
devops-case-study-app-1   208bc553c2b3   Up 3 hours (healthy)   0.0.0.0:8081->8080/tcp, [::]:8081->8080/tcp

## Unit tests (host, repo `.venv`)
test_health (test_app.AppTests.test_health) ... ok
test_home (test_app.AppTests.test_home) ... ok

----------------------------------------------------------------------
Ran 2 tests in 0.006s

OK

## Live smoke test (host -> kind svc/demo-web over loopback port-forward)
--- /health ---
{"status":"ok"}
HTTP=200 time=0.002713s
--- / ---
{"message":"Hello from Kubernetes","service":"demo-web","version":"k8s"}
HTTP=200

## Jenkins (loopback only — 127.0.0.1:8080 / 127.0.0.1:50000)
controller: jenkins/jenkins:lts-jdk17, version 2.541.3, HTTP 200, wizard complete
agent:      linux-docker-agent — online, 2 executors (docker+buildx, kubectl, kind, python3-venv, git)
jobs:       devops-case-study (Multibranch, file:///repo-src) — main build #3 SUCCESS end-to-end
            devops-demo-web  (read-only CI harness) — build #2 SUCCESS
creds:      dockerhub-username, kubeconfig-dev, dockerhub-creds — all present (values masked)

## Git status
## main...origin/main [ahead 3]     (3 local commits, NOT pushed — per operator approval)
9b93e21 Jenkins: make Build-image gate robust to cleanWs (git-diff instead of changeset)
3a3c472 Jenkins: enable SCM-driven run (multibranch file://) + fix first-build changeset skip
edb4f14 Complete DevOps case study: kind deploy, hardened image, Jenkins CI/CD, docs+evidence
HEAD=9b93e2104becbf1cb89950c8f4141b73c972a2e0

Working tree at capture: the Phase-5 documentation reconciliation (this
snapshot + `validation-report.md`, `evidence/phase5-jenkins-ci.md`,
`troubleshooting.md`, `README.md`, `deployment-guide.md`,
`environment-audit.md`, `pipeline-optimization.md`) recording build #3 as the
authoritative run; committed as a docs-only commit on top of `9b93e21`.
