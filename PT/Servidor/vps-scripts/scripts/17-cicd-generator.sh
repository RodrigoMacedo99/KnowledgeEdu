#!/bin/bash
# Seção 17 — Gerador de CI/CD (GitHub Actions) para um serviço
#
# Gera um pipeline completo (lint + typecheck + testes + cobertura + security
# scan + build + deploy) para um serviço criado pela etapa 15, e prepara o lado
# do servidor: chave SSH restrita por ambiente e o script de deploy de cada um.
#
# Deploy é ROLLING (git pull + docker compose up --build, com health check e
# rollback). Numa VPS única é a estratégia recomendada; para rollout gradual sem
# downtime, use serviços ponderados (weighted) do Traefik ou feature flags na
# aplicação (ver VPS_SETUP.md / OBSERVABILIDADE.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "17-cicd-generator"

title "17. Gerador de CI/CD (GitHub Actions)"

# ── 1. Serviço ─────────────────────────────────────────────────────────────
info "Serviços existentes em /opt/apps:"
ls -1 /opt/apps 2>/dev/null | grep -v '^\.' | sed 's/^/    - /' || true
echo

prompt PROJECT_NAME "Nome do serviço (deve existir em /opt/apps, criado na etapa 15)" ""

SERVICE_USER="$PROJECT_NAME"
PROJECT_DIR="/opt/apps/${PROJECT_NAME}"
[[ -d "$PROJECT_DIR" ]] || die "Serviço '${PROJECT_NAME}' não encontrado em ${PROJECT_DIR}. Rode a etapa 15 primeiro."

# ── 2. Metadados (gravados pela etapa 15) ──────────────────────────────────
METADATA_FILE="${PROJECT_DIR}/.project.env"
if [[ -f "$METADATA_FILE" ]]; then
    info "Lendo metadados (${METADATA_FILE})..."
    # shellcheck disable=SC1090
    source "$METADATA_FILE"
else
    warn "Sem metadados — reconstruindo o essencial."
    MAIN_BRANCH="main"
    STAGING_ENABLED="n"; STAGING_BRANCH="develop"
    [[ -d "${PROJECT_DIR}/staging" ]] && STAGING_ENABLED="y"
    prompt PRIMARY_DOMAIN "Domínio principal de produção" ""
    STAGING_PRIMARY_DOMAIN=""
fi

APP_DIR_PRODUCTION="${PROJECT_DIR}/production/app"
APP_DIR_STAGING="${PROJECT_DIR}/staging/app"
OVERRIDE_PRODUCTION="${PROJECT_DIR}/production/compose.override.yml"
OVERRIDE_STAGING="${PROJECT_DIR}/staging/compose.override.yml"

[[ -d "$APP_DIR_PRODUCTION" ]] || warn "Repositório de produção não encontrado em ${APP_DIR_PRODUCTION}."

info "Ambientes deste serviço:"
echo -e "  Produção: ${CYAN}https://${PRIMARY_DOMAIN:-?}${RESET} — branch ${CYAN}${MAIN_BRANCH}${RESET}"
if [[ "$STAGING_ENABLED" == "y" ]]; then
    echo -e "  Staging:  ${CYAN}https://${STAGING_PRIMARY_DOMAIN:-?}${RESET} — branch ${CYAN}${STAGING_BRANCH}${RESET}"
else
    echo -e "  Staging:  ${YELLOW}não habilitado${RESET}"
fi

# ── 3. Stack ───────────────────────────────────────────────────────────────
echo
echo -e "  ${BOLD}Qual a stack do serviço?${RESET}"
echo -e "    ${YELLOW}1${RESET}) Node.js/TypeScript  ${YELLOW}2${RESET}) Python  ${YELLOW}3${RESET}) Go  ${YELLOW}4${RESET}) Docker genérico"
prompt STACK_CHOICE "Escolha" "1"
case "$STACK_CHOICE" in
    1) STACK="node" ;; 2) STACK="python" ;; 3) STACK="go" ;; 4) STACK="docker" ;;
    *) die "Opção inválida: $STACK_CHOICE" ;;
esac

COVERAGE_THRESHOLD=80
LINT_CMD="" TYPECHECK_CMD="" TEST_CMD="" AUDIT_CMD="" RUNTIME_VERSION="" DOCKERFILE_PATH="Dockerfile"

case "$STACK" in
    node)
        prompt RUNTIME_VERSION  "Versão do Node.js"                  "22"
        prompt LINT_CMD         "Comando de lint"                    "npm run lint"
        prompt TYPECHECK_CMD    "Comando de typecheck"               "npm run typecheck"
        prompt TEST_CMD         "Comando de testes (com cobertura)"  "npm test -- --coverage"
        prompt AUDIT_CMD        "Comando de audit"                   "npm audit --audit-level=high"
        prompt COVERAGE_THRESHOLD "Cobertura mínima (%)"             "80"
        ;;
    python)
        prompt RUNTIME_VERSION  "Versão do Python"                   "3.12"
        prompt LINT_CMD         "Comando de lint"                    "ruff check ."
        prompt TYPECHECK_CMD    "Comando de typecheck"               "mypy ."
        prompt TEST_CMD         "Comando de testes (com cobertura)"  "pytest --cov --cov-report=xml --cov-report=term"
        prompt AUDIT_CMD        "Comando de audit"                   "pip-audit"
        prompt COVERAGE_THRESHOLD "Cobertura mínima (%)"             "80"
        ;;
    go)
        prompt RUNTIME_VERSION  "Versão do Go"                       "1.22"
        prompt LINT_CMD         "Comando de lint"                    "golangci-lint run"
        prompt TYPECHECK_CMD    "Comando de vet"                     "go vet ./..."
        prompt TEST_CMD         "Comando de testes (com cobertura)"  "go test -race -coverprofile=coverage.out ./..."
        prompt AUDIT_CMD        "Comando de audit"                   "govulncheck ./..."
        prompt COVERAGE_THRESHOLD "Cobertura mínima (%)"             "80"
        ;;
    docker)
        warn "Stack genérica: adicione seu job de testes antes do build (CLAUDE.md exige testes)."
        prompt DOCKERFILE_PATH "Caminho do Dockerfile" "Dockerfile"
        ;;
esac

# ── 4. Banco de dados nos testes ───────────────────────────────────────────
USE_DB="n"; DB_SERVICE_YAML=""
if [[ "$STACK" != "docker" ]] && confirm "Os testes precisam de banco de dados (integração)?"; then
    USE_DB="y"
    echo -e "    ${YELLOW}1${RESET}) PostgreSQL  ${YELLOW}2${RESET}) MySQL  ${YELLOW}3${RESET}) MongoDB"
    prompt DB_CHOICE "Escolha" "1"
    case "$DB_CHOICE" in
        1) DB_SERVICE_YAML="    services:
      db:
        image: postgres:17
        env:
          POSTGRES_DB: test
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        ports: [\"5432:5432\"]
        options: >-
          --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5" ;;
        2) DB_SERVICE_YAML="    services:
      db:
        image: mysql:8
        env:
          MYSQL_ROOT_PASSWORD: test
          MYSQL_DATABASE: test
        ports: [\"3306:3306\"]
        options: >-
          --health-cmd \"mysqladmin ping -proot\" --health-interval 10s --health-timeout 5s --health-retries 5" ;;
        3) DB_SERVICE_YAML="    services:
      db:
        image: mongo:7
        ports: [\"27017:27017\"]
        options: >-
          --health-cmd \"mongosh --eval 'db.runCommand({ping:1})'\" --health-interval 10s --health-timeout 5s --health-retries 5" ;;
        *) die "Opção inválida: $DB_CHOICE" ;;
    esac
fi

# ── 5. Deploy ──────────────────────────────────────────────────────────────
REQUIRE_APPROVAL="y"
info "Recomendado (CLAUDE.md): deploy de produção requer aprovação manual (GitHub Environment)."
confirm "Exigir aprovação manual antes do deploy em produção?" || REQUIRE_APPROVAL="n"

prompt COMPOSE_FILE     "Nome do compose no repositório" "compose.yml"
prompt HEALTHCHECK_PATH "Rota de health check (via domínio público)" "/health"

# ── 6. Conexão com a VPS ───────────────────────────────────────────────────
prompt VPS_USER "Usuário SSH usado no deploy (grupos webapps e docker)" "admin"
prompt VPS_HOST "IP ou domínio da VPS" ""
prompt VPS_PORT "Porta SSH da VPS" "2222"
id "$VPS_USER" &>/dev/null || die "Usuário '${VPS_USER}' não existe nesta VPS."

# ── 7. Permissões de grupo para o deploy ───────────────────────────────────
if find "$PROJECT_DIR" -maxdepth 0 -perm -2000 | grep -q .; then
    already_done "setgid + escrita de grupo em ${PROJECT_DIR}"
else
    info "Ajustando permissões de ${PROJECT_DIR} para deploy via grupo webapps..."
    chmod -R g+w "$PROJECT_DIR"
    find "$PROJECT_DIR" -type d -exec chmod g+s {} \;
fi

# ── 8. Chave SSH restrita por ambiente ─────────────────────────────────────
setup_deploy_key() {
    local env_name="$1" deploy_script="$2"
    local key_path="/home/${VPS_USER}/.ssh/deploy_${PROJECT_NAME}_${env_name}"

    if [[ -f "${key_path}.pub" ]]; then
        already_done "Chave de deploy (${env_name})" >&2
    else
        info "Gerando chave ed25519 para o GitHub Actions (${env_name})..." >&2
        install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "/home/${VPS_USER}/.ssh"
        sudo -u "$VPS_USER" ssh-keygen -t ed25519 -C "github-actions-${PROJECT_NAME}-${env_name}" -f "$key_path" -N ""
    fi

    local auth_keys="/home/${VPS_USER}/.ssh/authorized_keys"
    local key_line="command=\"${deploy_script}\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,no-pty $(cat "${key_path}.pub")"
    touch "$auth_keys"
    if grep -qF "${deploy_script}" "$auth_keys" 2>/dev/null; then
        already_done "authorized_keys para ${deploy_script}" >&2
    else
        echo "$key_line" >> "$auth_keys"
        chown "${VPS_USER}:${VPS_USER}" "$auth_keys"
        chmod 600 "$auth_keys"
        log "Chave restrita (${env_name}) adicionada." >&2
    fi
    echo "$key_path"
}

DEPLOY_SCRIPT_PRODUCTION="${PROJECT_DIR}/deploy-production.sh"
DEPLOY_KEY_PRODUCTION=$(setup_deploy_key "production" "$DEPLOY_SCRIPT_PRODUCTION")
DEPLOY_SCRIPT_STAGING="${PROJECT_DIR}/deploy-staging.sh"
DEPLOY_KEY_STAGING=""
[[ "$STAGING_ENABLED" == "y" ]] && DEPLOY_KEY_STAGING=$(setup_deploy_key "staging" "$DEPLOY_SCRIPT_STAGING")

# ── 9. Scripts de deploy (rolling, com override do Traefik) ────────────────
write_deploy_script() {
    local env_name="$1" branch="$2" app_dir="$3" override="$4" domain="$5" script_path="$6"
    cat > "$script_path" <<EOF
#!/bin/bash
# Deploy rolling (${env_name}) — gerado por 17-cicd-generator.sh. Chamado apenas
# pela chave SSH restrita do GitHub Actions.
set -euo pipefail

APP_DIR="${app_dir}"
OVERRIDE="${override}"
COMPOSE_FILE="${COMPOSE_FILE}"
BRANCH="${branch}"
HEALTH_URL="https://${domain}${HEALTHCHECK_PATH}"
LOG_FILE="${PROJECT_DIR}/deploy-${env_name}.log"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$*" | tee -a "\$LOG_FILE"; }
compose() { docker compose -f "\$COMPOSE_FILE" -f "\$OVERRIDE" "\$@"; }

cd "\$APP_DIR"
PREV_COMMIT="\$(git rev-parse HEAD)"

log "Deploy (${env_name}) — atualizando \$BRANCH..."
git fetch --quiet origin "\$BRANCH"
git checkout --quiet "\$BRANCH"
git reset --hard --quiet "origin/\$BRANCH"

compose up --build -d

log "Aguardando health check em \$HEALTH_URL..."
for _ in \$(seq 1 10); do
    if curl -fsS "\$HEALTH_URL" >/dev/null 2>&1; then
        log "Deploy concluído — commit \$(git rev-parse --short HEAD)."
        docker image prune -f >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 5
done

log "Health check falhou — revertendo para \$PREV_COMMIT."
git reset --hard --quiet "\$PREV_COMMIT"
compose up --build -d
log "Rollback concluído."
exit 1
EOF
    chown "${SERVICE_USER}:webapps" "$script_path"
    chmod 750 "$script_path"
    log "Script de deploy (${env_name}) criado em ${script_path}."
}

write_deploy_script "production" "$MAIN_BRANCH" "$APP_DIR_PRODUCTION" "$OVERRIDE_PRODUCTION" "$PRIMARY_DOMAIN" "$DEPLOY_SCRIPT_PRODUCTION"
[[ "$STAGING_ENABLED" == "y" ]] && \
    write_deploy_script "staging" "$STAGING_BRANCH" "$APP_DIR_STAGING" "$OVERRIDE_STAGING" "$STAGING_PRIMARY_DOMAIN" "$DEPLOY_SCRIPT_STAGING"

# ── 10. Workflow do GitHub Actions ─────────────────────────────────────────
WORKFLOW_DIR="${PROJECT_DIR}/cicd"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_FILE="${WORKFLOW_DIR}/ci-cd.yml"

BUILD_NEEDS="[test, security]"
[[ "$STACK" == "docker" ]] && BUILD_NEEDS="[security]"
TRIGGER_BRANCHES="${MAIN_BRANCH}"
[[ "$STAGING_ENABLED" == "y" ]] && TRIGGER_BRANCHES="${MAIN_BRANCH}, ${STAGING_BRANCH}"

{
cat <<EOF
name: CI/CD — ${PROJECT_NAME}

on:
  push:
    branches: [${TRIGGER_BRANCHES}]
  pull_request:
    branches: [${MAIN_BRANCH}]

concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

jobs:
EOF

if [[ "$STACK" != "docker" ]]; then
    SETUP_STEP="" INSTALL_STEP=""
    case "$STACK" in
        node)   SETUP_STEP="      - uses: actions/setup-node@v4
        with:
          node-version: \"${RUNTIME_VERSION}\"
          cache: npm"; INSTALL_STEP="      - run: npm ci" ;;
        python) SETUP_STEP="      - uses: actions/setup-python@v5
        with:
          python-version: \"${RUNTIME_VERSION}\"
          cache: pip"; INSTALL_STEP="      - run: pip install -r requirements.txt" ;;
        go)     SETUP_STEP="      - uses: actions/setup-go@v5
        with:
          go-version: \"${RUNTIME_VERSION}\"
          cache: true"; INSTALL_STEP="" ;;
    esac

    cat <<EOF
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
${SETUP_STEP}
${INSTALL_STEP}
      - run: ${LINT_CMD}
      - run: ${TYPECHECK_CMD}

  test:
    runs-on: ubuntu-latest
    needs: lint
EOF
    [[ "$USE_DB" == "y" ]] && printf '%s\n' "$DB_SERVICE_YAML"
    cat <<EOF
    steps:
      - uses: actions/checkout@v4
${SETUP_STEP}
${INSTALL_STEP}
      - run: ${TEST_CMD}
      - name: Cobertura mínima (${COVERAGE_THRESHOLD}%)
        run: echo "::notice::garanta ${COVERAGE_THRESHOLD}% no seu test runner (coverageThreshold / --fail-under / go cover)"

  security:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2
${INSTALL_STEP}
      - run: ${AUDIT_CMD}
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          severity: CRITICAL,HIGH
          exit-code: "1"
EOF
else
    cat <<EOF
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2
EOF
fi

cat <<EOF

  build:
    runs-on: ubuntu-latest
    needs: ${BUILD_NEEDS}
    if: github.event_name == 'pull_request' || github.ref == 'refs/heads/${MAIN_BRANCH}'$([[ "$STAGING_ENABLED" == "y" ]] && echo " || github.ref == 'refs/heads/${STAGING_BRANCH}'")
    steps:
      - uses: actions/checkout@v4
      - name: Build da imagem Docker
        run: docker build -t ${PROJECT_NAME}:ci -f ${DOCKERFILE_PATH:-Dockerfile} .
      - uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${PROJECT_NAME}:ci
          severity: CRITICAL,HIGH
          exit-code: "1"
EOF

if [[ "$STAGING_ENABLED" == "y" ]]; then
cat <<EOF

  deploy-staging:
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/${STAGING_BRANCH}'
    environment: staging
    steps:
      - name: Deploy (staging)
        uses: appleboy/ssh-action@v1
        with:
          host: \${{ secrets.VPS_HOST }}
          username: \${{ secrets.VPS_USER }}
          key: \${{ secrets.VPS_SSH_KEY }}
          port: \${{ secrets.VPS_PORT }}
          script: exit
EOF
fi

cat <<EOF

  deploy-production:
    runs-on: ubuntu-latest
    needs: build
    if: github.ref == 'refs/heads/${MAIN_BRANCH}'
    environment: production
    steps:
      - name: Deploy (produção)
        uses: appleboy/ssh-action@v1
        with:
          host: \${{ secrets.VPS_HOST }}
          username: \${{ secrets.VPS_USER }}
          key: \${{ secrets.VPS_SSH_KEY }}
          port: \${{ secrets.VPS_PORT }}
          script: exit
EOF
} > "$WORKFLOW_FILE"

chown "${SERVICE_USER}:webapps" "$WORKFLOW_FILE"
chmod 640 "$WORKFLOW_FILE"
log "Workflow gerado em ${WORKFLOW_FILE}."

if [[ -d "${APP_DIR_PRODUCTION}/.git" ]]; then
    mkdir -p "${APP_DIR_PRODUCTION}/.github/workflows"
    cp "$WORKFLOW_FILE" "${APP_DIR_PRODUCTION}/.github/workflows/ci-cd.yml"
    chown -R "${SERVICE_USER}:webapps" "${APP_DIR_PRODUCTION}/.github"
fi

# ── 11. Resumo ─────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ CI/CD gerado para '${PROJECT_NAME}' ══${RESET}"
echo -e "  Stack:    ${CYAN}${STACK}${RESET}   Deploy: ${CYAN}rolling${RESET}   Workflow: ${CYAN}${WORKFLOW_FILE}${RESET}"
echo
echo -e "${BOLD}Crie os GitHub Environments${RESET} (Settings → Environments) com os secrets:"
echo -e "  ${YELLOW}production${RESET} (ative 'Required reviewers' se quiser aprovação):"
echo -e "    VPS_HOST=${VPS_HOST}  VPS_USER=${VPS_USER}  VPS_PORT=${VPS_PORT}  VPS_SSH_KEY=(chave privada abaixo)"
echo
cat "$DEPLOY_KEY_PRODUCTION"
echo
if [[ "$STAGING_ENABLED" == "y" ]]; then
    echo -e "  ${YELLOW}staging${RESET}:"
    echo -e "    VPS_HOST=${VPS_HOST}  VPS_USER=${VPS_USER}  VPS_PORT=${VPS_PORT}  VPS_SSH_KEY=(chave privada abaixo)"
    echo
    cat "$DEPLOY_KEY_STAGING"
    echo
fi
[[ "$REQUIRE_APPROVAL" == "y" ]] && warn "Ative 'Required reviewers' no Environment 'production'."
warn "Ative branch protection em '${MAIN_BRANCH}' (CI obrigatório, sem push direto)."

step_done "CI/CD (${PROJECT_NAME}, stack ${STACK}, deploy rolling)"
