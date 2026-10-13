pipeline {
  agent { label 'linux-docker-agent' }
  options { timestamps(); disableConcurrentBuilds(); timeout(time: 25, unit: 'MINUTES'); buildDiscarder(logRotator(numToKeepStr: '20')) }
  environment {
    IMAGE_NAME = 'DOCKERHUB_USERNAME/devops-demo-web'
    IMAGE_TAG = "${env.GIT_COMMIT ? env.GIT_COMMIT.take(12) : env.BUILD_NUMBER}"
    K8S_NAMESPACE = 'devops-demo'
  }
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Unit tests') {
      steps { sh 'python3 -m venv .venv && . .venv/bin/activate && pip install --cache-dir .pip-cache -r app/requirements-dev.txt && python -m unittest discover -s app/tests -v' }
    }
    stage('Build image') { steps { sh 'docker build --pull -t "$IMAGE_NAME:$IMAGE_TAG" .' } }
    stage('Push image') {
      when { branch 'main' }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DH_USER', passwordVariable: 'DH_TOKEN')]) {
          sh 'echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin && docker push "$IMAGE_NAME:$IMAGE_TAG" && docker logout'
        }
      }
    }
    stage('Deploy Kubernetes') {
      when { branch 'main' }
      steps {
        withCredentials([file(credentialsId: 'kubeconfig-dev', variable: 'KCFG')]) {
          sh 'export KUBECONFIG="$KCFG"; kubectl apply -f k8s/namespace.yaml; kubectl apply -f k8s/deployment.yaml; kubectl apply -f k8s/service.yaml; kubectl set image deployment/demo-web demo-web="$IMAGE_NAME:$IMAGE_TAG" -n "$K8S_NAMESPACE"; kubectl rollout status deployment/demo-web -n "$K8S_NAMESPACE" --timeout=120s'
        }
      }
    }
  }
  post { always { echo "Build result: ${currentBuild.currentResult}" }; failure { echo 'Inspect failed stage logs and Kubernetes events before rollback.' } }
}
