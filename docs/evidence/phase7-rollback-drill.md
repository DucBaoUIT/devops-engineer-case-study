# Phase 7 evidence — Rollback and troubleshooting drill

Timestamp: 2026-10-13T19:19:57Z
Cluster: kind/devops-demo  Namespace: devops-demo  Deployment: demo-web

Objective: prove that a bad rollout does **not** take the service down
(maxUnavailable=0), and that `kubectl rollout undo` restores service
within seconds. Also verify probe behaviour when the readiness endpoint
starts failing.
NAME                        READY   STATUS         RESTARTS   AGE     IP           NODE                        NOMINATED NODE   READINESS GATES
demo-web-574fc97cc9-j26mw   1/1     Running        0          2m30s   10.244.0.5   devops-demo-control-plane   <none>           <none>
demo-web-574fc97cc9-jt4rv   1/1     Running        0          2m30s   10.244.0.6   devops-demo-control-plane   <none>           <none>
demo-web-5df6475d74-pwlwn   0/1     ErrImagePull   0          6s      10.244.0.8   devops-demo-control-plane   <none>           <none>

## Drill 1: bad image tag

```
before: devops-demo-web:cc5480ddbf9e-w4e1fd322
NAME                        READY   STATUS         RESTARTS   AGE     IP           NODE                        NOMINATED NODE   READINESS GATES
demo-web-574fc97cc9-j26mw   1/1     Running        0          2m30s   10.244.0.5   devops-demo-control-plane   <none>           <none>
demo-web-574fc97cc9-jt4rv   1/1     Running        0          2m30s   10.244.0.6   devops-demo-control-plane   <none>           <none>
demo-web-5df6475d74-pwlwn   0/1     ErrImagePull   0          6s      10.244.0.8   devops-demo-control-plane   <none>           <none>
---
```

Old pod kept serving (maxUnavailable=0 protects availability):
```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE     CONTAINERS   IMAGES                           SELECTOR
demo-web   2/2     1            2           2m30s   demo-web     devops-demo-web:does-not-exist   app=demo-web
```
>>> Rollout history before rollback:
deployment.apps/demo-web 
REVISION  CHANGE-CAUSE
3         <none>
4         <none>

>>> Executing: kubectl rollout undo --namespace devops-demo deployment/demo-web
Warning: resource deployments/demo-web was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations. Consider using 'kubectl apply' with your previous configuration file instead.
deployment.apps/demo-web rolled back
>>> Waiting for rollout to stabilise (timeout=120s)
deployment "demo-web" successfully rolled out

>>> Rollout history after rollback:
deployment.apps/demo-web 
REVISION  CHANGE-CAUSE
4         <none>
5         <none>


>>> Current image and pods:
image=devops-demo-web:cc5480ddbf9e-w4e1fd322
NAME                        READY   STATUS        RESTARTS   AGE     IP           NODE                        NOMINATED NODE   READINESS GATES
demo-web-574fc97cc9-j26mw   1/1     Running       0          2m46s   10.244.0.5   devops-demo-control-plane   <none>           <none>
demo-web-574fc97cc9-jt4rv   1/1     Running       0          2m46s   10.244.0.6   devops-demo-control-plane   <none>           <none>
demo-web-5df6475d74-pwlwn   0/1     Terminating   0          22s     10.244.0.8   devops-demo-control-plane   <none>           <none>

## Drill 2: failed readiness probe

Patched readinessProbe path from /health to /does-not-exist.
Expected: pods stay Running (liveness still passes), but Ready=0/1,
and Service endpoints are drained. Then restored.

```
NAME                        READY   STATUS    RESTARTS   AGE     IP           NODE                        NOMINATED NODE   READINESS GATES
demo-web-574fc97cc9-j26mw   1/1     Running   0          2m54s   10.244.0.5   devops-demo-control-plane   <none>           <none>
demo-web-574fc97cc9-jt4rv   1/1     Running   0          2m54s   10.244.0.6   devops-demo-control-plane   <none>           <none>
demo-web-5bf94898b8-5lml7   0/1     Running   0          8s      10.244.0.9   devops-demo-control-plane   <none>           <none>
-- endpoints (should be empty) --
- addresses:
  - ip: 10.244.0.5
  - ip: 10.244.0.6
  notReadyAddresses:
  - ip: 10.244.0.9
NAME                        READY   STATUS        RESTARTS   AGE     IP           NODE                        NOMINATED NODE   READINESS GATES
demo-web-574fc97cc9-j26mw   1/1     Running       0          2m54s   10.244.0.5   devops-demo-control-plane   <none>           <none>
demo-web-574fc97cc9-jt4rv   1/1     Running       0          2m54s   10.244.0.6   devops-demo-control-plane   <none>           <none>
demo-web-5bf94898b8-5lml7   0/1     Terminating   0          8s      10.244.0.9   devops-demo-control-plane   <none>           <none>
NAME       ENDPOINTS                         AGE
demo-web   10.244.0.5:8080,10.244.0.6:8080   2m54s
```

## Drill 3: unit test failure

The pipeline runs unit tests before build. Simulating a failure locally:
```
test_will_fail (__main__.FakeFailure.test_will_fail) ... FAIL

======================================================================
FAIL: test_will_fail (__main__.FakeFailure.test_will_fail)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "<stdin>", line 4, in test_will_fail
AssertionError: 1 != 2 : simulated test failure — pipeline must not build/push/deploy

----------------------------------------------------------------------
Ran 1 test in 0.000s

FAILED (failures=1)
```
NAME                            READY   STATUS    RESTARTS   AGE     IP           NODE                        NOMINATED NODE   READINESS GATES
pod/demo-web-574fc97cc9-j26mw   1/1     Running   0          2m54s   10.244.0.5   devops-demo-control-plane   <none>           <none>
pod/demo-web-574fc97cc9-jt4rv   1/1     Running   0          2m54s   10.244.0.6   devops-demo-control-plane   <none>           <none>
pod/demo-web-5bf94898b8-5lml7   0/1     Error     0          8s      10.244.0.9   devops-demo-control-plane   <none>           <none>

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE     SELECTOR
service/demo-web   ClusterIP   10.96.165.119   <none>        80/TCP    2m54s   app=demo-web

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE     CONTAINERS   IMAGES                                   SELECTOR
deployment.apps/demo-web   2/2     2            2           2m54s   demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web

NAME                                  DESIRED   CURRENT   READY   AGE     CONTAINERS   IMAGES                                   SELECTOR
replicaset.apps/demo-web-574fc97cc9   2         2         2       2m54s   demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=574fc97cc9
replicaset.apps/demo-web-5bf94898b8   0         0         0       8s      demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=5bf94898b8
replicaset.apps/demo-web-5df6475d74   0         0         0       2m28s   demo-web     devops-demo-web:does-not-exist           app=demo-web,pod-template-hash=5df6475d74
