# DevOps Engineer Case Study

Covers mandatory Task 0 (Kubernetes), plus Task 1 (Jenkins CI/CD) and Task 4 (Pipeline Optimization).

## Prerequisites
Linux, Docker Engine + Compose plugin, Git, Python 3.12, kubectl, kind or Minikube, and Docker Hub account/access token.

## Local app and tests
```bash
docker compose up --build -d app
curl http://localhost:8081/health
docker compose down
python3 -m venv .venv
. .venv/bin/activate
pip install -r app/requirements-dev.txt
python -m unittest discover -s app/tests -v
```

## Jenkins
```bash
docker compose up -d jenkins
docker exec $(docker compose ps -q jenkins) cat /var/jenkins_home/secrets/initialAdminPassword
```
Open http://localhost:8080. Configure a Linux agent labelled `linux-docker-agent` with Docker CLI/daemon, Python, kubectl and Git. This starter Compose file runs the controller and demo app; a build-capable agent should be a dedicated Linux VM or a reviewed custom agent image. Avoid mounting Docker socket into untrusted jobs.

Add Jenkins credentials:
- `dockerhub-creds`: username + Docker Hub access token.
- `kubeconfig-dev`: kubeconfig restricted to namespace `devops-demo`.
Change `IMAGE_NAME` in Jenkinsfile and replace `DOCKERHUB_USERNAME` in Kubernetes manifest. Configure a multibranch pipeline; publishing/deploying stages run on `main`.

## Kubernetes local demo (kind)
```bash
kind create cluster --name devops-demo
sed -i 's|DOCKERHUB_USERNAME|YOUR_DOCKERHUB_USERNAME|g' k8s/deployment.yaml
kubectl apply -f k8s/
kubectl rollout status deployment/demo-web -n devops-demo
kubectl port-forward -n devops-demo svc/demo-web 8082:80
curl http://localhost:8082/health
```
Ensure the image exists in Docker Hub and is public, or configure an imagePullSecret for a private repository.

## Rollback and scaling
```bash
kubectl rollout history deployment/demo-web -n devops-demo
kubectl rollout undo deployment/demo-web -n devops-demo
kubectl scale deployment/demo-web --replicas=3 -n devops-demo
```
Database migrations and external side effects need separate backward-compatible rollback planning.

## Task 4: optimize pipeline
1. Cache dependencies and invalidate cache when requirements change.
2. Order Dockerfile layers to preserve dependency cache.
3. Parallelize independent test/lint/security stages if agents have capacity.
4. Build once and promote the same immutable image digest across environments.
5. Scale/right-size agents using queue and stage-duration measurements.

## Troubleshooting
- ImagePullBackOff: verify tag, repository visibility and imagePullSecret.
- CrashLoopBackOff: inspect `kubectl logs` and `kubectl describe pod`; verify port, env and probes.
- Rollout timeout: inspect events, readiness and resource constraints.
- Push denied: check Docker Hub token scope and Jenkins credential ID.
- Agent offline: check URL, network, node name, secret and label.

## Limitations
This is a starter scaffold, not proof of a successful live deployment. Run it in your own environment, capture actual test/rollout evidence, and replace placeholders. For production add scanning/signing, approvals, monitoring, RBAC and secret management.
# devops-engineer-case-study
