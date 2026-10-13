# Phase 4 evidence — kind cluster + deployment + smoke test
Timestamp: 2026-10-13T19:18:38Z

## kubectl get all -n devops-demo -o wide
NAME                            READY   STATUS    RESTARTS   AGE   IP           NODE                        NOMINATED NODE   READINESS GATES
pod/demo-web-574fc97cc9-j26mw   1/1     Running   0          65s   10.244.0.5   devops-demo-control-plane   <none>           <none>
pod/demo-web-574fc97cc9-jt4rv   1/1     Running   0          65s   10.244.0.6   devops-demo-control-plane   <none>           <none>

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
service/demo-web   ClusterIP   10.96.165.119   <none>        80/TCP    65s   app=demo-web

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                                   SELECTOR
deployment.apps/demo-web   2/2     2            2           65s   demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web

NAME                                  DESIRED   CURRENT   READY   AGE   CONTAINERS   IMAGES                                   SELECTOR
replicaset.apps/demo-web-574fc97cc9   2         2         2       65s   demo-web     devops-demo-web:cc5480ddbf9e-w4e1fd322   app=demo-web,pod-template-hash=574fc97cc9
replicaset.apps/demo-web-5df6475d74   0         0         0       39s   demo-web     devops-demo-web:does-not-exist           app=demo-web,pod-template-hash=5df6475d74

## kubectl describe deployment/demo-web -n devops-demo
Name:                   demo-web
Namespace:              devops-demo
CreationTimestamp:      Wed, 14 Oct 2026 02:17:33 +0700
Labels:                 <none>
Annotations:            deployment.kubernetes.io/revision: 3
Selector:               app=demo-web
Replicas:               2 desired | 2 updated | 2 total | 2 available | 0 unavailable
StrategyType:           RollingUpdate
MinReadySeconds:        0
RollingUpdateStrategy:  0 max unavailable, 1 max surge
Pod Template:
  Labels:  app=demo-web
  Containers:
   demo-web:
    Image:      devops-demo-web:cc5480ddbf9e-w4e1fd322
    Port:       8080/TCP (http)
    Host Port:  0/TCP (http)
    Limits:
      cpu:     500m
      memory:  256Mi
    Requests:
      cpu:      100m
      memory:   64Mi
    Liveness:   http-get http://:http/health delay=10s timeout=1s period=10s successThreshold=1 failureThreshold=3
    Readiness:  http-get http://:http/health delay=3s timeout=1s period=5s successThreshold=1 failureThreshold=3
    Startup:    http-get http://:http/health delay=0s timeout=1s period=2s successThreshold=1 failureThreshold=30
    Environment:
      APP_VERSION:  k8s
      APP_MESSAGE:  Hello from Kubernetes
    Mounts:         <none>
  Volumes:          <none>
  Node-Selectors:   <none>
  Tolerations:      <none>
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    True    NewReplicaSetAvailable
OldReplicaSets:  demo-web-5df6475d74 (0/0 replicas created)
NewReplicaSet:   demo-web-574fc97cc9 (2/2 replicas created)
Events:
  Type    Reason             Age   From                   Message
  ----    ------             ----  ----                   -------
  Normal  ScalingReplicaSet  65s   deployment-controller  Scaled up replica set demo-web-574fc97cc9 from 0 to 2
  Normal  ScalingReplicaSet  39s   deployment-controller  Scaled up replica set demo-web-5df6475d74 from 0 to 1
  Normal  ScalingReplicaSet  20s   deployment-controller  Scaled down replica set demo-web-5df6475d74 from 1 to 0

## kubectl rollout history
deployment.apps/demo-web 
REVISION  CHANGE-CAUSE
2         <none>
3         <none>


## Smoke tests via 'kubectl port-forward svc/demo-web 8082:80 --address 127.0.0.1'

```
{"status":"ok"}

HTTP=200 time=0.003630s
{"status":"ok"}

HTTP=200 time=0.002836s
{"status":"ok"}

HTTP=200 time=0.002485s
{"message":"Hello from Kubernetes","service":"demo-web","version":"k8s"}

HTTP=200
```
