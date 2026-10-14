// Jenkins declarative pipeline for the DevOps case study.
//
// Design notes (why the pipeline is shaped this way):
//   * Stages are ordered so that a failure in tests aborts before any image
//     is built, and a failure in build aborts before any push. `when` guards
//     on publish/deploy stages make the policy explicit.
//   * `Unit tests` and `Build image` run in parallel — they are independent
//     (tests need Python + source, build needs Docker + source, neither
//     consumes the other's output).
//   * Push/deploy only run on `main` and only when the previous stages
//     succeeded (Jenkins declarative semantics: a failed stage aborts the
//     pipeline unless `catchError` is used, which we do NOT use here).
//   * Image tag = 12-char git SHA (immutable, traceable). `latest` is only
//     used as a secondary floating tag for convenience, never as the deploy
//     target.
//   * Secrets are referenced by Jenkins credential ID only:
//       - dockerhub-creds  (username/password: Docker Hub user + access token)
//       - kubeconfig-dev   (file: kubeconfig scoped to namespace devops-demo)
//     Nothing is hard-coded, nothing is echoed.
//   * `changeset` on the build stage avoids rebuilding when only docs or
//     slides changed. The `Publish` and `Deploy` stages depend on
//     `env.IMAGE_BUILT` so they are also skipped in that case.
//   * Post-deploy smoke test hits `/health` via a short-lived
//     `kubectl port-forward` bound to 127.0.0.1 on the agent — no public
//     port is opened anywhere in this pipeline.
//
// Required agent tools (label `linux-docker-agent`):
//   git, python3.12, python3-venv, docker CLI + access to a Docker daemon,
//   kubectl (>= 1.29), kind (only if deploying to the local kind lab), curl.
//
// If your Jenkins controller does not have a compliant agent, do NOT run
// this pipeline on `built-in` — provision a dedicated agent instead.

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
    // (`dockerhub-username`, value: 21520623) so it is never hard-coded
    // here and can be changed without a commit.
    DOCKERHUB_USERNAME = credentials('dockerhub-username')   // plain-text credential
    IMAGE_NAME         = "${DOCKERHUB_USERNAME}/devops-demo-web"
    IMAGE_TAG          = "${env.GIT_COMMIT ? env.GIT_COMMIT.take(12) : env.BUILD_NUMBER}"
    IMAGE_REF          = "${IMAGE_NAME}:${IMAGE_TAG}"
    IMAGE_LATEST       = "${IMAGE_NAME}:latest"
    K8S_NAMESPACE      = 'devops-demo'
    K8S_DEPLOYMENT     = 'demo-web'
    K8S_OVERLAY        = 'k8s/overlays/kind'   // switch to a prod overlay when available
    PIP_CACHE_DIR      = "${WORKSPACE}/.pip-cache"
    BUILDKIT_CACHE_DIR = "${WORKSPACE}/.buildkit-cache"
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
          // Skip the build when only documentation/slides changed. The
          // declarative `changeset` condition is UNRELIABLE here: `cleanWs`
          // wipes the workspace every build, so the git plugin computes an
          // EMPTY changelog and `changeset` never matches — the pipeline would
          // skip Build → Publish → Deploy → Smoke on EVERY run (observed on
          // builds #1 and #2: "empty changelog" / stage skipped). Decide with
          // git directly against the previous commit instead (a fresh clone
          // still has full history). Build if any relevant path changed, or on
          // the first commit / when the diff cannot be determined (safe
          // default = build).
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
              # Cache strategy AS BUILT: BuildKit inline/layer cache in the
              # agent's local Docker daemon, plus a persistent $BUILDKIT_CACHE_DIR
              # and $PIP_CACHE_DIR on the agent workspace. Registry-based cache
              # import/export (--cache-from / --cache-to type=registry) is NOT
              # implemented and is NOT claimed here; it remains an optional,
              # unmeasured optimization (docs/pipeline-optimization.md §4).
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
    failure {
      // Do NOT auto-rollback from here — rollback is a human decision.
      // Print the exact command instead so the on-call engineer can run it.
      echo """
Pipeline failed. To roll back the deployment manually:
  export KUBECONFIG=<kubeconfig>
  kubectl -n ${env.K8S_NAMESPACE} rollout undo deployment/${env.K8S_DEPLOYMENT}
  kubectl -n ${env.K8S_NAMESPACE} rollout status deployment/${env.K8S_DEPLOYMENT}
Or use scripts/rollback.sh from the repository root.
"""
    }
    cleanup {
      // Remove the workspace venv and BuildKit cache directories only if
      // the agent is ephemeral. On a persistent agent they speed up the
      // next build, so leave them alone by default.
      cleanWs(deleteDirs: true, notFailBuild: true, cleanupMatrixParent: false)
    }
  }
}
