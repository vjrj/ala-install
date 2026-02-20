pipeline {
  agent any

  tools {
    nodejs 'node-22'
  }

  options {
    disableConcurrentBuilds()
    timestamps()
    ansiColor('xterm')
  }

  parameters {
    booleanParam(
      name: 'FORCE_REDEPLOY',
      defaultValue: true,
      description: 'Run inventories + redeploy even if no changes are detected'
    )
    booleanParam(
      name: 'CLEAN_MACHINE',
      defaultValue: true,
      description: 'Wipe /data (except lost+found) and purge Docker before running'
    )
    booleanParam(
      name: 'ONLY_CLEAN',
      defaultValue: false,
      description: 'Only clean machines and stop'
    )
  }

  environment {
    TARGET_HOSTS = "gbif-es-docker-cluster-2023-1 gbif-es-docker-cluster-2023-2 gbif-es-docker-cluster-2023-3"

    BASE_DIR = "${env.HOME}/ala-install-docker-tests"
    ALA_DIR = "${env.HOME}/ala-install-docker-tests/ala-install"
    INVENTORY_DIR = "${env.HOME}/ala-install-docker-tests/lademo/lademo-inventories"
    INVENTORY_PARENT_DIR = "${env.HOME}/ala-install-docker-tests/lademo"
    GENERATOR_DIR = "${env.HOME}/ala-install-docker-tests/generator-living-atlas"

    BRANCH_ALA = "docker-compose-poc"
    BRANCH_GENERATOR = "master"

    ALA_GIT_URL = "https://github.com/vjrj/ala-install.git"
    GENERATOR_GIT_URL = "https://github.com/living-atlases/generator-living-atlas.git"
  }

  stages {

    stage('Clean machines (remote)') {
      when { expression { params.CLEAN_MACHINE || params.ONLY_CLEAN } }
      steps {
        script {
          if (!env.TARGET_HOSTS?.trim()) {
            error('TARGET_HOSTS is empty. Define it in the pipeline environment.')
          }

          def hosts = env.TARGET_HOSTS.trim().split(/\s+/)

          for (h in hosts) {
            sh("""
              set -eu
              set +e
              ssh-keygen -f "\$HOME/.ssh/known_hosts" -R "${h}" >/dev/null 2>&1
              ip=\$(ssh -G "${h}" | awk '/^hostname /{print \$2; exit}')
              if [ -n "\$ip" ]; then
                ssh-keygen -f "\$HOME/.ssh/known_hosts" -R "\$ip" >/dev/null 2>&1
                ssh-keyscan -H "\$ip" >> "\$HOME/.ssh/known_hosts" 2>/dev/null
              fi
              ssh-keyscan -H "${h}" >> "\$HOME/.ssh/known_hosts" 2>/dev/null
              set -e
            """.stripIndent())
          }

          def jobs = [:]
          for (h in hosts) {
            def targetHost = h
            jobs[targetHost] = {
              sh("""
                set -eu
                cat <<'EOF' | ssh ${targetHost} bash -s
                set -eu

                echo "==> Cleaning on \$(hostname)"

                if sudo -n true 2>/dev/null; then
                  if [ -d /data/docker-compose ] && command -v docker >/dev/null 2>&1; then
                    echo "==> Found /data/docker-compose, stopping services and removing volumes"
                    sudo find /data/docker-compose -maxdepth 2 -name "docker-compose.yml" -print -execdir docker compose down -v \\; || true
                  fi

                  if command -v systemctl >/dev/null 2>&1; then
                    echo "==> Stopping docker and containerd services"
                    sudo systemctl stop docker containerd 2>/dev/null || true
                  fi
                  
                  sudo pkill -9 -f unattended-upgrade || true
                  
                  if [ -d /data ]; then
                    echo "==> Content of /data before cleaning:"
                    sudo ls -la /data || true
                    echo "==> Cleaning files in /data (preserving lost+found and var-lib-containerd)"
                    sudo find /data -mindepth 1 -maxdepth 1 -not -name lost+found -not -name var-lib-containerd -print -exec rm -rf -- {} +
                    echo "==> Content of /data after cleaning:"
                    sudo ls -la /data || true
                  else
                    echo "==> Directory /data not found, skipping cleanup"
                  fi
                  
                  if command -v apt-get >/dev/null 2>&1; then
                    i=0
                    while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f unattended-upgrades >/dev/null 2>&1; do
                      i=\$((i+1))
                      if [ "\$i" -ge 60 ]; then
                        echo "ERROR: apt/dpkg busy for too long"
                        ps aux | egrep 'apt-get|apt |dpkg|unattended' || true
                        exit 1
                      fi
                      sleep 5
                    done

                    sudo dpkg --configure -a || true
                    sudo rm -f /var/cache/apt/pkgcache.bin* /var/cache/apt/srcpkgcache.bin* || true
                    sudo mkdir -p /var/cache/apt/archives/partial || true
                    sudo chmod 755 /var/cache/apt /var/cache/apt/archives /var/cache/apt/archives/partial || true

                    n=0
                    until sudo apt-get update -y; do
                      n=\$((n+1))
                      if [ "\$n" -ge 5 ]; then
                        echo "ERROR: apt-get update failed after retries"
                        exit 1
                      fi
                      sleep 5
                      sudo rm -f /var/cache/apt/pkgcache.bin* /var/cache/apt/srcpkgcache.bin* || true
                    done

                    sudo apt-get remove -y docker-ce docker-ce-cli docker.io containerd runc || true
                    sudo apt-get autoremove -y || true
                  fi

                  sudo rm -rf /etc/docker /etc/systemd/system/docker.service.d || true
                  sudo rm -f /var/run/docker.sock || true
                  sudo systemctl daemon-reload 2>/dev/null || true
                else
                  echo "WARNING: no passwordless sudo on \$(hostname)"
                fi
                EOF
              """.stripIndent())
            }
          }

          parallel jobs
        }
      }
    }

    stage('Prepare dirs') {
      when { expression { !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu
          mkdir -p "$BASE_DIR" "$ALA_DIR" "$GENERATOR_DIR" "$INVENTORY_DIR" "$INVENTORY_PARENT_DIR"
        '''
      }
    }

    stage('Update ala-install') {
      when { expression { !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu
          if [ ! -d "$ALA_DIR/.git" ]; then
            rm -rf "$ALA_DIR"
            git clone "$ALA_GIT_URL" "$ALA_DIR"
          fi

          cd "$ALA_DIR"
          git fetch --prune origin
          git checkout -B "$BRANCH_ALA" "origin/$BRANCH_ALA"
          git reset --hard "origin/$BRANCH_ALA"
          git clean -fdx
        '''
      }
    }

    stage('Update generator-living-atlas') {
      when { expression { !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu
          if [ ! -d "$GENERATOR_DIR/.git" ]; then
            rm -rf "$GENERATOR_DIR"
            git clone "$GENERATOR_GIT_URL" "$GENERATOR_DIR"
          fi

          cd "$GENERATOR_DIR"
          git fetch --prune origin
          git checkout -B "$BRANCH_GENERATOR" "origin/$BRANCH_GENERATOR"
          git reset --hard "origin/$BRANCH_GENERATOR"
          git clean -fdx
        '''
      }
    }

    stage('Decide redeploy') {
      when { expression { !params.ONLY_CLEAN } }
      steps {
        script {
          def isManual = currentBuild.rawBuild.getCause(hudson.model.Cause$UserIdCause) != null
          def isCron = currentBuild.rawBuild.getCause(hudson.triggers.TimerTrigger$TimerTriggerCause) != null

          if (params.FORCE_REDEPLOY) {
            env.DO_REDEPLOY = 'true'
            echo 'FORCE_REDEPLOY is true. Will regenerate inventories and redeploy.'
            return
          }

          if (isManual && !isCron) {
            env.DO_REDEPLOY = 'true'
            echo 'Manual run detected. Will regenerate inventories and redeploy.'
            return
          }

          def changed = sh(
            script: '''
              set -eu

              cd "$ALA_DIR"
              ALA_SHA="$(git rev-parse HEAD)"

              cd "$GENERATOR_DIR"
              GEN_SHA="$(git rev-parse HEAD)"

              ALA_FILE="$BASE_DIR/.last_sha_ala_install"
              GEN_FILE="$BASE_DIR/.last_sha_generator"

              ALA_OLD=""
              GEN_OLD=""

              if [ -f "$ALA_FILE" ]; then ALA_OLD="$(cat "$ALA_FILE")"; fi
              if [ -f "$GEN_FILE" ]; then GEN_OLD="$(cat "$GEN_FILE")"; fi

              if [ "$ALA_SHA" = "$ALA_OLD" ] && [ "$GEN_SHA" = "$GEN_OLD" ]; then
                echo "nochange"
              else
                echo "$ALA_SHA" > "$ALA_FILE"
                echo "$GEN_SHA" > "$GEN_FILE"
                echo "changed"
              fi
            ''',
            returnStdout: true
          ).trim()

          env.DO_REDEPLOY = (changed == 'changed') ? 'true' : 'false'

          if (env.DO_REDEPLOY != 'true') {
            echo 'No changes detected in ala-install or generator-living-atlas. Skipping inventories + redeploy.'
          } else {
            echo 'Changes detected. Will regenerate inventories and redeploy.'
          }
        }
      }
    }

    stage('Install generator deps (local checkout)') {
      when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu
          node -v

          NODE_HOME="$(cd "$(dirname "$(which node)")/.." && pwd)"
          NPM="node $NODE_HOME/lib/node_modules/npm/bin/npm-cli.js"
          $NPM -v

          cd "$GENERATOR_DIR"
          if [ -f package-lock.json ]; then
            $NPM ci
          else
            $NPM install
          fi

          $NPM install --no-audit --no-fund yeoman-generator

          test -d node_modules/yeoman-generator
          node -e "import('yeoman-generator').then(()=>console.log('yeoman-generator:ok')).catch(e=>{console.error(e); process.exit(1)})"
        '''
      }
    }

    stage('Install Yeoman + generator-living-atlas (npm)') {
      when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu

          NODE_HOME="$(cd "$(dirname "$(which node)")/.." && pwd)"
          NPM="node $NODE_HOME/lib/node_modules/npm/bin/npm-cli.js"

          cd "$INVENTORY_PARENT_DIR"
          if [ ! -f package.json ]; then
            $NPM init -y >/dev/null 2>&1
          fi

          rm -rf node_modules package-lock.json

          $NPM install --no-audit --no-fund yo yeoman-environment yeoman-generator generator-living-atlas@latest

          $NPM ls yo --depth=0
          $NPM ls generator-living-atlas --depth=0
          $NPM ls yeoman-generator --depth=0

          node -e "console.log('generator-living-atlas:', require('generator-living-atlas/package.json').version)"
          node -e "console.log('generator-living-atlas path:', require.resolve('generator-living-atlas/package.json'))"
        '''
      }
    }

    stage('Regenerate inventories with Yeoman (npm generator)') {
      when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu
          cd "$INVENTORY_PARENT_DIR"

          node -v

          node ./node_modules/yo/lib/cli.js --version
          node ./node_modules/yo/lib/cli.js living-atlas --replay-dont-ask --force
        '''
      }
    }

    stage('Redeploy') {
      when { expression { env.DO_REDEPLOY == 'true' && !params.ONLY_CLEAN } }
      steps {
        sh '''
          set -eu
          cd "$INVENTORY_DIR"

          export PATH="$BASE_DIR/.venv-ansible/bin:$PATH"
          export ANSIBLE_FORCE_COLOR=true
          export ANSIBLE_STDOUT_CALLBACK=yaml

          ansible-playbook --version
          ./ansiblew --alainstall=../../ala-install docker_compose -n
        '''
      }
    }

  }
}
