// Jenkins Declarative Pipeline for the DevOps case study.
// Tests and image build run in parallel. Publish and deploy only run on main
// after a successful build.
// Image tags use the Git commit SHA for traceability; latest is for convenience.
// Secrets are managed through Jenkins Credentials:
//   - dockerhub-creds: Docker Hub username and access token
//   - kubeconfig-dev: kubeconfig for the devops-demo namespace
//
// Required tools on linux-docker-agent:
// git, Python 3.12, Docker CLI, kubectl, kind and curl.
// Use a dedicated agent instead of the built-in node.

pipeline {
  agent { label 'linux-docker-agent' }

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 25, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
    skipDefaultCheckout(false)
  }

  environment {
    // Docker Hub namespace. Read from a Jenkins text credential
    DOCKERHUB_USERNAME = credentials('dockerhub-username')
    IMAGE_NAME         = "${DOCKERHUB_USERNAME}/devops-demo-web"
    IMAGE_TAG          = "${env.GIT_COMMIT ? env.GIT_COMMIT.take(12) : env.BUILD_NUMBER}"
    IMAGE_REF          = "${IMAGE_NAME}:${IMAGE_TAG}"
    IMAGE_LATEST       = "${IMAGE_NAME}:latest"
    K8S_NAMESPACE      = 'devops-demo'
    K8S_DEPLOYMENT     = 'demo-web'
    K8S_OVERLAY        = 'k8s/overlays/kind'   // switch to a prod overlay when available
    // Caches live on the agent's persistent volume root (/home/jenkins/agent is a
    // named Docker volume), OUTSIDE $WORKSPACE. post { cleanWs(deleteDirs:true) }
    // only wipes the per-build workspace subdir, so keeping the caches one level
    // up lets them survive across builds. Previously PIP_CACHE_DIR was
    // ${WORKSPACE}/.pip-cache, which cleanWs deleted every run, so each build
    // re-created the venv AND re-downloaded all wheels from PyPI (~70-80 s).
    PIP_CACHE_DIR      = '/home/jenkins/agent/.cache/pip'
    BUILDKIT_CACHE_DIR = '/home/jenkins/agent/.cache/buildkit'
    DOCKER_BUILDKIT    = '1'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA_SHORT = sh(returnStdout: true, script: 'git rev-parse --short=12 HEAD').trim()
          echo "Building from commit ${env.GIT_SHA_SHORT}"
        }
      }
    }

    stage('Validate repo') {
      steps {
        sh '''
          set -eu
          echo "--- required files ---"
          for f in Dockerfile .dockerignore app/app.py app/requirements.txt app/tests/test_app.py k8s/deployment.yaml k8s/service.yaml k8s/namespace.yaml; do
            test -f "$f" || { echo "MISSING: $f" >&2; exit 1; }
            echo "ok: $f"
          done
          echo "--- no accidental secrets committed ---"
          if git ls-files | grep -Ei '(^|/)(id_rsa|id_ed25519|.*\\.pem|.*\\.key|kubeconfig|credentials.*|secrets/.*)$'; then
            echo "Refusing to build: secret-like file is tracked." >&2
            exit 1
          fi
          echo "--- dockerfile sanity ---"
          grep -q "^USER " Dockerfile || { echo "Dockerfile has no USER directive" >&2; exit 1; }
          echo "validation ok"
        '''
      }
    }

    // Tests and image build are independent → run in parallel.
    stage('Test & Build') {
      parallel {
        stage('Unit tests') {
          steps {
            sh '''
              set -eu
              python3 -m venv .venv
              . .venv/bin/activate
              pip install --cache-dir "$PIP_CACHE_DIR" --upgrade pip wheel >/dev/null
              pip install --cache-dir "$PIP_CACHE_DIR" -r app/requirements-dev.txt
              python -m unittest discover -s app/tests -v
            '''
          }
          post {
            always {
              junit allowEmptyResults: true, testResults: 'app/tests/**/*.xml'
            }
          }
        }

        stage('Build image') {
          // Skip the build when only documentation/slides changed.
          when {
            expression {
              def out = sh(returnStdout: true,
                script: 'git diff --name-only HEAD~1 HEAD 2>/dev/null || echo __BUILD__').trim()
              if (!out || out.contains('__BUILD__')) { return true }
              return out.split('\n').any { p ->
                p == 'Dockerfile' || p == '.dockerignore' || p == 'Jenkinsfile' ||
                p.startsWith('app/') || p.startsWith('k8s/') || p.startsWith('scripts/')
              }
            }
          }
          steps {
            sh '''
              set -eu
              mkdir -p "$BUILDKIT_CACHE_DIR"
              docker build \
                --pull \
                --tag "$IMAGE_REF" \
                --tag "$IMAGE_LATEST" \
                --label "org.opencontainers.image.revision=$GIT_COMMIT" \
                --label "org.opencontainers.image.source=$GIT_URL" \
                --label "org.opencontainers.image.created=$(date -u +%FT%TZ)" \
                .
              docker image inspect "$IMAGE_REF" --format 'built image id={{.Id}} size={{.Size}}'
            '''
            script { env.IMAGE_BUILT = 'true' }
          }
        }
      }
    }

    stage('Publish image') {
      when {
        allOf {
          branch 'main'
          expression { return env.IMAGE_BUILT == 'true' }
        }
      }
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'dockerhub-creds',
          usernameVariable: 'DH_USER',
          passwordVariable: 'DH_TOKEN'
        )]) {
          sh '''
            set -eu
            echo "$DH_TOKEN" | docker login --username "$DH_USER" --password-stdin
            trap 'docker logout >/dev/null 2>&1 || true' EXIT
            docker push "$IMAGE_REF"
            docker push "$IMAGE_LATEST"
            # Record the digest for downstream traceability.
            docker image inspect "$IMAGE_REF" --format '{{index .RepoDigests 0}}' > .image-digest || true
          '''
        }
        archiveArtifacts artifacts: '.image-digest', allowEmptyArchive: true, fingerprint: true
      }
    }

    stage('Deploy to Kubernetes') {
      when {
        allOf {
          branch 'main'
          expression { return env.IMAGE_BUILT == 'true' }
        }
      }
      steps {
        withCredentials([file(credentialsId: 'kubeconfig-dev', variable: 'KCFG')]) {
          sh '''
            set -eu
            export KUBECONFIG="$KCFG"
            kubectl cluster-info | head -1
            kubectl apply -f k8s/namespace.yaml

            # Prefer the kustomize overlay when present (adds startupProbe and
            # pins imagePullPolicy for the target environment). Fall back to
            # the flat manifests otherwise.
            if [ -d "$K8S_OVERLAY" ]; then
              kubectl kustomize "$K8S_OVERLAY" --load-restrictor LoadRestrictionsNone \
                | kubectl apply -f -
            else
              kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
            fi

            kubectl -n "$K8S_NAMESPACE" set image "deployment/$K8S_DEPLOYMENT" \
              "demo-web=$IMAGE_REF" --record=false

            kubectl -n "$K8S_NAMESPACE" rollout status "deployment/$K8S_DEPLOYMENT" --timeout=180s
            kubectl -n "$K8S_NAMESPACE" get pods -l app="$K8S_DEPLOYMENT" -o wide
          '''
        }
      }
    }

    stage('Smoke test') {
      when {
        allOf {
          branch 'main'
          expression { return env.IMAGE_BUILT == 'true' }
        }
      }
      steps {
        withCredentials([file(credentialsId: 'kubeconfig-dev', variable: 'KCFG')]) {
          sh '''
            set -eu
            export KUBECONFIG="$KCFG"
            LOCAL_PORT=18082
            kubectl -n "$K8S_NAMESPACE" port-forward --address 127.0.0.1 \
              "svc/$K8S_DEPLOYMENT" "${LOCAL_PORT}:80" >/tmp/pf.log 2>&1 &
            PF_PID=$!
            trap 'kill $PF_PID 2>/dev/null || true' EXIT
            # wait for port-forward to be ready
            for i in $(seq 1 20); do
              if curl -sf "http://127.0.0.1:${LOCAL_PORT}/health" >/dev/null 2>&1; then break; fi
              sleep 1
            done
            echo "--- /health ---"
            curl -sfS -w "\\nHTTP=%{http_code} time=%{time_total}s\\n" "http://127.0.0.1:${LOCAL_PORT}/health"
            echo "--- / ---"
            curl -sfS -w "\\nHTTP=%{http_code}\\n" "http://127.0.0.1:${LOCAL_PORT}/"
            echo "smoke test ok"
          '''
        }
      }
    }
  }

  post {
    always {
      echo "Build result: ${currentBuild.currentResult}"
      sh 'docker image ls --format "{{.Repository}}:{{.Tag}} {{.Size}}" | head -20 || true'
    }
    success {
      echo "Pipeline succeeded for ${env.IMAGE_REF}"
    }
    // Slack alerts - default channel `#pipeline-status`
    failure {
      echo """
Pipeline failed. To roll back the deployment manually:
  export KUBECONFIG=<kubeconfig>
  kubectl -n ${env.K8S_NAMESPACE} rollout undo deployment/${env.K8S_DEPLOYMENT}
  kubectl -n ${env.K8S_NAMESPACE} rollout status deployment/${env.K8S_DEPLOYMENT}
Or use scripts/rollback.sh from the repository root.
"""
      script {
        try {
          slackSend(
            color: 'danger',
            message: ":x: *BUILD FAILED* — ${env.JOB_NAME} #${env.BUILD_NUMBER} " +
                     "(<${env.BUILD_URL}|open build>)\n" +
                     ">Branch: `${env.BRANCH_NAME ?: 'unknown'}`  ·  Commit: `${env.GIT_SHA_SHORT ?: env.GIT_COMMIT ?: 'n/a'}`\n" +
                     ">Result: *${currentBuild.currentResult}* after ${currentBuild.durationString?.replace(' and counting', '') ?: 'n/a'}\n" +
                     ">:arrows_counterclockwise: If the deploy stage ran, roll back with `scripts/rollback.sh` " +
                     "(or `kubectl -n ${env.K8S_NAMESPACE} rollout undo deployment/${env.K8S_DEPLOYMENT}`)."
          )
        } catch (ignored) {
          echo "Slack failure alert could not be sent (non-fatal): ${ignored}"
        }
      }
    }
    unstable {
      script {
        try {
          slackSend(
            color: 'warning',
            message: ":warning: *BUILD UNSTABLE* — ${env.JOB_NAME} #${env.BUILD_NUMBER} " +
                     "(<${env.BUILD_URL}|open build>) — tests failed but the pipeline completed."
          )
        } catch (ignored) {
          echo "Slack unstable alert could not be sent (non-fatal): ${ignored}"
        }
      }
    }
    fixed {
      script {
        try {
          slackSend(
            color: 'good',
            message: ":white_check_mark: *BUILD FIXED* — ${env.JOB_NAME} #${env.BUILD_NUMBER} " +
                     "(<${env.BUILD_URL}|open build>) is green again."
          )
        } catch (ignored) {
          echo "Slack fixed alert could not be sent (non-fatal): ${ignored}"
        }
      }
    }
    cleanup {
      cleanWs(deleteDirs: true, notFailBuild: true, cleanupMatrixParent: false)
    }
  }
}
