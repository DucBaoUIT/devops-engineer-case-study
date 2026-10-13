# Final state snapshot
Timestamp: 2026-10-13T19:32:19Z

## Host
Linux ubuntu 6.8.0-79-generic #79-Ubuntu SMP PREEMPT_DYNAMIC Tue Aug 12 14:42:46 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux

## kind clusters
devops-demo

## kubectl config current-context
kind-devops-demo

## Nodes
NAME                        STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION     CONTAINER-RUNTIME
devops-demo-control-plane   Ready    control-plane   16m   v1.34.0   172.19.0.2    <none>        Debian GNU/Linux 12 (bookworm)   6.8.0-79-generic   containerd://2.1.3

## Namespace devops-demo — all resources
NAME                           READY   STATUS    RESTARTS   AGE     IP            NODE                        NOMINATED NODE   READINESS GATES
pod/demo-web-6cb55b7f6-7z9ph   1/1     Running   0          6m10s   10.244.0.10   devops-demo-control-plane   <none>           <none>
pod/demo-web-6cb55b7f6-dcjjx   1/1     Running   0          6m7s    10.244.0.11   devops-demo-control-plane   <none>           <none>

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
service/demo-web   ClusterIP   10.96.165.119   <none>        80/TCP    14m   app=demo-web

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                                   SELECTOR
deployment.apps/demo-web   2/2     2            2           14m   demo-web     devops-demo-web:cc5480ddbf9e-w53253e69   app=demo-web

NAME                                  DESIRED   CURRENT   READY   AGE     CONTAINERS   IMAGES                                   SELECTOR
replicaset.apps/demo-web-574fc97cc9   0         0         0       14m     demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=574fc97cc9
replicaset.apps/demo-web-5bf94898b8   0         0         0       12m     demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=5bf94898b8
replicaset.apps/demo-web-5df6475d74   0         0         0       14m     demo-web     devops-demo-web:does-not-exist           app=demo-web,pod-template-hash=5df6475d74
replicaset.apps/demo-web-6cb55b7f6    2         2         2       6m10s   demo-web     devops-demo-web:cc5480ddbf9e-w53253e69   app=demo-web,pod-template-hash=6cb55b7f6

## Deployment image + probes + resources
image: devops-demo-web:cc5480ddbf9e-w53253e69
imagePullPolicy: IfNotPresent
requests: {"cpu":"100m","memory":"64Mi"}
limits: {"cpu":"500m","memory":"256Mi"}

## Endpoints
NAME             ADDRESSTYPE   PORTS   ENDPOINTS                 AGE
demo-web-qhjml   IPv4          8080    10.244.0.10,10.244.0.11   14m

## Docker images (devops-demo-web)
REPOSITORY        TAG                      IMAGE ID       SIZE
devops-demo-web   cc5480ddbf9e-w53253e69   a14b555418d2   186MB
devops-demo-web   current                  a14b555418d2   186MB
devops-demo-web   cc5480ddbf9e-w4e1fd322   71d9d3c72606   186MB
devops-demo-web   phase3                   71d9d3c72606   186MB
devops-demo-web   cc5480ddbf9e             b609eacbfb91   185MB
devops-demo-web   local                    b609eacbfb91   185MB

## Docker compose app
NAMES                     IMAGE          STATUS                    PORTS
devops-case-study-app-1   208bc553c2b3   Up 54 minutes (healthy)   0.0.0.0:8081->8080/tcp, [::]:8081->8080/tcp

## Unit tests
test_health (test_app.AppTests.test_health) ... ok
test_home (test_app.AppTests.test_home) ... ok

----------------------------------------------------------------------
Ran 2 tests in 0.006s

OK

## Git status
## main...origin/main
 M .dockerignore
 M Dockerfile
 M Jenkinsfile
 M docker-compose.yml
 M scripts/deploy.sh
 M scripts/rollback.sh
?? docs/architecture.md
?? docs/deployment-guide.md
?? docs/environment-audit.md
?? docs/evidence/
?? docs/pipeline-optimization.md
?? docs/troubleshooting.md
?? k8s/overlays/
