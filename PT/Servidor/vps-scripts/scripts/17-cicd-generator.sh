#!/bin/bash
# Seção 17 — Gerador de CI/CD (GitHub Actions) para qualquer projeto
#
# Gera, de forma interativa e genérica, um pipeline completo de CI/CD para um
# projeto criado pela etapa 15 (produção + staging, cada um com sua porta já
# alocada pelo registro central): lint + typecheck + testes + cobertura +
# security scan + build + deploy, seguindo os padrões de qualidade do
# repositório (agents/skills em .claude/).
#
# O script também prepara o lado do servidor: uma chave SSH restrita por
# ambiente (produção e staging nunca compartilham credencial) e o script de
# deploy de cada uma (rolling ou blue-green).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/ports.sh"

require_root
init_log "17-cicd-generator"

title "17. Gerador de CI/CD (GitHub Actions)"

# ── 1. Projeto ────────────────────────────────────────────────────────────
info "Projetos existentes em /opt/apps:"
ls -1 /opt/apps 2>/dev/null | grep -v '^\.' | sed 's/^/    - /' || true
echo

prompt PROJECT_NAME "Nome do projeto (deve existir em /opt/apps, criado na etapa 15)" ""

SERVICE_USER="$PROJECT_NAME"
PROJECT_DIR="/opt/apps/${PROJECT_NAME}"
[[ -d "$PROJECT_DIR" ]] || die "Projeto '${PROJECT_NAME}' não encontrado em ${PROJECT_DIR}. Execute a etapa 15 primeiro."

# ── 2. Metadados do projeto (domínios, portas, ambientes) ────────────────
METADATA_FILE="${PROJECT_DIR}/.project.env"
if [[ -f "$METADATA_FILE" ]]; then
    info "Lendo metadados salvos pela etapa 15 (${METADATA_FILE})..."
    source "$METADATA_FILE"
else
    warn "Projeto sem metadados (${METADATA_FILE} não existe — foi criado antes desta versão da etapa 15)."
    warn "Vou reconstruir os metadados agora e salvá-los para as próximas execuções."
    prompt PROD_DOMAIN "Domínio de produção" ""
    MAIN_BRANCH="main"
    PROD_PORT=$(allocate_port "$PROJECT_NAME" "production" 3000)
    info "Porta de produção registrada: ${PROD_PORT}"

    STAGING_ENABLED="n"
    [[ -d "${PROJECT_DIR}/staging" ]] && STAGING_ENABLED="y"
    STAGING_DOMAIN="" STAGING_PORT="" STAGING_BRANCH="develop"
    if [[ "$STAGING_ENABLED" == "y" ]]; then
        prompt STAGING_DOMAIN "Domínio de staging" "staging.${PROD_DOMAIN}"
        prompt STAGING_BRANCH "Branch que o staging acompanha" "develop"
        STAGING_PORT=$(allocate_port "$PROJECT_NAME" "staging" 4000)
        info "Porta de staging registrada: ${STAGING_PORT}"
    fi

    cat > "$METADATA_FILE" <<EOF
PROD_DOMAIN=${PROD_DOMAIN}
PROD_PORT=${PROD_PORT}
MAIN_BRANCH=${MAIN_BRANCH}
STAGING_ENABLED=${STAGING_ENABLED}
STAGING_DOMAIN=${STAGING_DOMAIN}
STAGING_PORT=${STAGING_PORT}
STAGING_BRANCH=${STAGING_BRANCH}
EOF
    chown "${SERVICE_USER}:webapps" "$METADATA_FILE"
    chmod 640 "$METADATA_FILE"
fi

APP_DIR_PRODUCTION="${PROJECT_DIR}/production/app"
APP_DIR_STAGING="${PROJECT_DIR}/staging/app"

[[ -d "$APP_DIR_PRODUCTION" ]] || warn "Repositório de produção não encontrado em ${APP_DIR_PRODUCTION} — copie o workflow manualmente depois."
if [[ "$STAGING_ENABLED" == "y" && ! -d "$APP_DIR_STAGING" ]]; then
    warn "Staging está marcado como habilitado, mas ${APP_DIR_STAGING} não existe."
fi

info "Ambientes deste projeto:"
echo -e "  Produção: ${CYAN}https://${PROD_DOMAIN}${RESET} — porta ${CYAN}${PROD_PORT}${RESET} — branch ${CYAN}${MAIN_BRANCH}${RESET}"
if [[ "$STAGING_ENABLED" == "y" ]]; then
    echo -e "  Staging:  ${CYAN}https://${STAGING_DOMAIN}${RESET} — porta ${CYAN}${STAGING_PORT}${RESET} — branch ${CYAN}${STAGING_BRANCH}${RESET}"
else
    echo -e "  Staging:  ${YELLOW}não habilitado para este projeto${RESET}"
fi

# ── 3. Stack do projeto ───────────────────────────────────────────────────
echo
echo -e "  ${BOLD}Qual a stack do projeto?${RESET}"
echo -e "    ${YELLOW}1${RESET}) Node.js / TypeScript"
echo -e "    ${YELLOW}2${RESET}) Python"
echo -e "    ${YELLOW}3${RESET}) Go"
echo -e "    ${YELLOW}4${RESET}) Docker genérico (sem linguagem específica — apenas build/scan/deploy)"
echo
prompt STACK_CHOICE "Escolha" "1"

case "$STACK_CHOICE" in
    1) STACK="node" ;;
    2) STACK="python" ;;
    3) STACK="go" ;;
    4) STACK="docker" ;;
    *) die "Opção inválida: $STACK_CHOICE" ;;
esac

COVERAGE_THRESHOLD=80
LINT_CMD="" TYPECHECK_CMD="" TEST_CMD="" AUDIT_CMD="" RUNTIME_VERSION="" DOCKERFILE_PATH="Dockerfile"

case "$STACK" in
    node)
        info "Recomendado: npm ci (builds reproduzíveis), ESLint + TypeScript strict, Jest/Vitest com --coverage, npm audit --audit-level=high."
        prompt RUNTIME_VERSION  "Versão do Node.js"                 "22"
        prompt LINT_CMD         "Comando de lint"                   "npm run lint"
        prompt TYPECHECK_CMD    "Comando de typecheck"               "npm run typecheck"
        prompt TEST_CMD         "Comando de testes (com cobertura)"  "npm test -- --coverage"
        prompt AUDIT_CMD        "Comando de audit de dependências"   "npm audit --audit-level=high"
        prompt COVERAGE_THRESHOLD "Cobertura mínima exigida (%)"     "80"
        ;;
    python)
        info "Recomendado: ruff (lint), mypy (typecheck), pytest --cov, pip-audit."
        prompt RUNTIME_VERSION  "Versão do Python"                  "3.12"
        prompt LINT_CMD         "Comando de lint"                   "ruff check ."
        prompt TYPECHECK_CMD    "Comando de typecheck"               "mypy ."
        prompt TEST_CMD         "Comando de testes (com cobertura)"  "pytest --cov --cov-report=xml --cov-report=term"
        prompt AUDIT_CMD        "Comando de audit de dependências"   "pip-audit"
        prompt COVERAGE_THRESHOLD "Cobertura mínima exigida (%)"     "80"
        ;;
    go)
        info "Recomendado: golangci-lint, go vet, go test com -race e -coverprofile, govulncheck."
        prompt RUNTIME_VERSION  "Versão do Go"                      "1.22"
        prompt LINT_CMD         "Comando de lint"                   "golangci-lint run"
        prompt TYPECHECK_CMD    "Comando de vet"                    "go vet ./..."
        prompt TEST_CMD         "Comando de testes (com cobertura)"  "go test -race -coverprofile=coverage.out ./..."
        prompt AUDIT_CMD        "Comando de audit de vulnerabilidades" "govulncheck ./..."
        prompt COVERAGE_THRESHOLD "Cobertura mínima exigida (%)"     "80"
        ;;
    docker)
        warn "Stack genérica: sem etapa de lint/test automática — adicione a sua antes do build."
        warn "Recomendado: mesmo sem linguagem definida, mantenha um job de testes antes do deploy (CLAUDE.md exige happy path + erro cobertos)."
        prompt DOCKERFILE_PATH "Caminho do Dockerfile" "Dockerfile"
        ;;
esac

# ── 4. Banco de dados nos testes ──────────────────────────────────────────
USE_DB="n"
DB_TYPE="postgres" DB_IMAGE="postgres:16" DB_PORT="5432"
DB_SERVICE_YAML=""
if [[ "$STACK" != "docker" ]] && confirm "Os testes precisam de banco de dados (integração)?"; then
    USE_DB="y"
    echo -e "    ${YELLOW}1${RESET}) PostgreSQL   ${YELLOW}2${RESET}) MySQL   ${YELLOW}3${RESET}) MongoDB"
    prompt DB_CHOICE "Escolha" "1"
    case "$DB_CHOICE" in
        1) DB_TYPE="postgres" DB_IMAGE="postgres:16" DB_PORT="5432" ;;
        2) DB_TYPE="mysql"    DB_IMAGE="mysql:8"      DB_PORT="3306" ;;
        3) DB_TYPE="mongo"    DB_IMAGE="mongo:7"       DB_PORT="27017" ;;
        *) die "Opção inválida: $DB_CHOICE" ;;
    esac
    info "Recomendado: testes de integração contra banco real via container de serviço (nunca mock), com health check antes dos testes começarem."

    case "$DB_TYPE" in
        postgres)
            DB_SERVICE_YAML="    services:
      db:
        image: ${DB_IMAGE}
        env:
          POSTGRES_DB: test
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
        ports: [\"${DB_PORT}:${DB_PORT}\"]
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5"
            ;;
        mysql)
            DB_SERVICE_YAML="    services:
      db:
        image: ${DB_IMAGE}
        env:
          MYSQL_ROOT_PASSWORD: test
          MYSQL_DATABASE: test
        ports: [\"${DB_PORT}:${DB_PORT}\"]
        options: >-
          --health-cmd \"mysqladmin ping -proot\"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5"
            ;;
        mongo)
            DB_SERVICE_YAML="    services:
      db:
        image: ${DB_IMAGE}
        ports: [\"${DB_PORT}:${DB_PORT}\"]
        options: >-
          --health-cmd \"mongosh --eval 'db.runCommand({ping:1})'\"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5"
            ;;
    esac
fi

# ── 5. Estratégia de deploy (produção) ────────────────────────────────────
echo
echo -e "  ${BOLD}Estratégia de deploy em produção:${RESET}"
echo -e "    ${YELLOW}1${RESET}) Rolling  — git pull + docker compose up --build -d, com health check e rollback automático (recomendado para VPS única)"
echo -e "    ${YELLOW}2${RESET}) Blue-Green — dois containers em portas distintas, troca do upstream do Nginx sem downtime (mais complexo, exige mais RAM/CPU)"
echo
warn "Canary verdadeiro exige balanceador de carga externo (ALB, Cloudflare, k8s) — não é viável em uma única VPS."
warn "Se precisar de rollout gradual, prefira feature flags na aplicação em vez de canary de infraestrutura."
warn "O ambiente de staging sempre usa rolling — não vale a complexidade do blue-green em um ambiente de teste."
prompt DEPLOY_CHOICE "Escolha" "1"

case "$DEPLOY_CHOICE" in
    1) DEPLOY_STRATEGY="rolling" ;;
    2) DEPLOY_STRATEGY="bluegreen" ;;
    *) die "Opção inválida: $DEPLOY_CHOICE" ;;
esac

REQUIRE_APPROVAL="y"
info "Recomendado (CLAUDE.md): deploy para produção requer aprovação manual via GitHub Environment."
confirm "Exigir aprovação manual antes do deploy em produção?" || REQUIRE_APPROVAL="n"

prompt COMPOSE_FILE      "Nome do arquivo docker-compose (usado nos dois ambientes)" "docker-compose.yml"
prompt HEALTHCHECK_PATH  "Rota de health check da API (usada nos dois ambientes)" "/health"

GREEN_PORT=""
if [[ "$DEPLOY_STRATEGY" == "bluegreen" ]]; then
    GREEN_PORT=$(allocate_port "$PROJECT_NAME" "production-green" $((PROD_PORT + 1)))
    info "Porta do segundo ambiente (green) de produção: ${GREEN_PORT}."
fi

# ── 6. Conexão com a VPS (para os jobs de deploy) ─────────────────────────
prompt VPS_USER "Usuário SSH usado no deploy (deve estar nos grupos webapps e docker)" "admin"
prompt VPS_HOST "IP ou domínio da VPS" ""
prompt VPS_PORT "Porta SSH da VPS" "22"

id "$VPS_USER" &>/dev/null || die "Usuário '${VPS_USER}' não existe nesta VPS."

# ── 7. Permissão de grupo para deploy sem shell do usuário de serviço ─────
# O usuário de serviço do projeto é --no-create-home / nologin (etapa 15), então
# o GitHub Actions não pode logar como ele. O deploy usa o admin, que já está
# no grupo 'webapps' (etapa 6) — aqui garantimos que esse grupo tenha permissão
# de escrita, e o setgid faz os arquivos atualizados pelo deploy permanecerem
# no grupo webapps (senão o git pull do admin criaria arquivos com grupo errado).
if find "$PROJECT_DIR" -maxdepth 0 -perm -2000 | grep -q .; then
    already_done "setgid + escrita de grupo em ${PROJECT_DIR}"
else
    info "Ajustando permissões de ${PROJECT_DIR} para permitir deploy via grupo webapps..."
    chmod -R g+w "$PROJECT_DIR"
    find "$PROJECT_DIR" -type d -exec chmod g+s {} \;
    log "Grupo webapps agora tem escrita, com setgid nos diretórios."
fi

# ── 8. Chave SSH restrita por ambiente ────────────────────────────────────
# Produção e staging usam chaves diferentes: cada uma só executa o deploy.sh
# do seu próprio ambiente (restrição "command=" em authorized_keys), então um
# vazamento da chave de staging nunca alcança produção.
setup_deploy_key() {
    local env_name="$1" deploy_script="$2"
    local key_path="/home/${VPS_USER}/.ssh/deploy_${PROJECT_NAME}_${env_name}"

    # As mensagens abaixo vão para stderr (>&2) de propósito: o chamador captura
    # o stdout desta função via $(...) para obter só o caminho da chave — se as
    # mensagens fossem para stdout, iriam misturadas dentro dessa variável.
    if [[ -f "${key_path}.pub" ]]; then
        already_done "Chave de deploy (${env_name}) ${key_path}" >&2
    else
        info "Gerando par de chaves ed25519 para o GitHub Actions (${env_name})..." >&2
        install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "/home/${VPS_USER}/.ssh"
        sudo -u "$VPS_USER" ssh-keygen -t ed25519 -C "github-actions-${PROJECT_NAME}-${env_name}" -f "$key_path" -N ""
    fi

    local auth_keys="/home/${VPS_USER}/.ssh/authorized_keys"
    local key_line="command=\"${deploy_script}\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,no-pty $(cat "${key_path}.pub")"

    touch "$auth_keys"
    if grep -qF "${deploy_script}" "$auth_keys" 2>/dev/null; then
        already_done "Entrada em authorized_keys para ${deploy_script}" >&2
    else
        info "Restringindo a chave de deploy (${env_name}) a executar apenas ${deploy_script}..." >&2
        echo "$key_line" >> "$auth_keys"
        chown "${VPS_USER}:${VPS_USER}" "$auth_keys"
        chmod 600 "$auth_keys"
        log "Chave restrita (${env_name}) adicionada — não pode abrir shell, portas ou X11." >&2
    fi

    echo "$key_path"
}

DEPLOY_SCRIPT_PRODUCTION="${PROJECT_DIR}/deploy-production.sh"
DEPLOY_KEY_PRODUCTION=$(setup_deploy_key "production" "$DEPLOY_SCRIPT_PRODUCTION")

DEPLOY_SCRIPT_STAGING="${PROJECT_DIR}/deploy-staging.sh"
DEPLOY_KEY_STAGING=""
if [[ "$STAGING_ENABLED" == "y" ]]; then
    DEPLOY_KEY_STAGING=$(setup_deploy_key "staging" "$DEPLOY_SCRIPT_STAGING")
fi

# ── 9. Scripts de deploy no servidor ──────────────────────────────────────
if [[ "$DEPLOY_STRATEGY" == "rolling" ]]; then
    cat > "$DEPLOY_SCRIPT_PRODUCTION" <<EOF
#!/bin/bash
# Deploy rolling (produção) — gerado por 17-cicd-generator.sh. Chamado apenas
# pela chave SSH restrita do GitHub Actions (ver authorized_keys de ${VPS_USER}).
set -euo pipefail

APP_DIR="${APP_DIR_PRODUCTION}"
LOG_FILE="${PROJECT_DIR}/deploy-production.log"
COMPOSE_FILE="${COMPOSE_FILE}"
HEALTH_URL="http://localhost:${PROD_PORT}${HEALTHCHECK_PATH}"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$*" | tee -a "\$LOG_FILE"; }

cd "\$APP_DIR"
PREV_COMMIT="\$(git rev-parse HEAD)"

log "Deploy (produção) iniciado — atualizando ${MAIN_BRANCH}..."
git fetch --quiet origin "${MAIN_BRANCH}"
git checkout --quiet "${MAIN_BRANCH}"
git reset --hard --quiet "origin/${MAIN_BRANCH}"

docker compose -f "\$COMPOSE_FILE" up --build -d

log "Aguardando health check em \$HEALTH_URL..."
for _ in \$(seq 1 10); do
    if curl -fsS "\$HEALTH_URL" >/dev/null 2>&1; then
        log "Deploy concluído — commit \$(git rev-parse --short HEAD)."
        docker image prune -f >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 3
done

log "Health check falhou — revertendo para \$PREV_COMMIT."
git reset --hard --quiet "\$PREV_COMMIT"
docker compose -f "\$COMPOSE_FILE" up --build -d
log "Rollback concluído."
exit 1
EOF
else
    NGINX_SITE="/etc/nginx/sites-available/${PROJECT_NAME}-production"
    UPSTREAM_FILE="/etc/nginx/conf.d/upstream-${PROJECT_NAME}-production.conf"
    STATE_FILE="${PROJECT_DIR}/.active_color"

    [[ -f "$STATE_FILE" ]] || echo "blue" > "$STATE_FILE"

    if [[ -f "$UPSTREAM_FILE" ]]; then
        already_done "Upstream Nginx para blue-green (${UPSTREAM_FILE})"
    else
        info "Convertendo o site de produção do Nginx para usar upstream comutável (blue-green)..."
        cat > "$UPSTREAM_FILE" <<EOF
upstream ${PROJECT_NAME}_production_backend {
    server 127.0.0.1:${PROD_PORT};
}
EOF
        if [[ -f "$NGINX_SITE" ]]; then
            sed -i "s#proxy_pass\s*http://localhost:[0-9]*;#proxy_pass http://${PROJECT_NAME}_production_backend;#" "$NGINX_SITE"
            nginx -t && systemctl reload nginx
        else
            warn "Site do Nginx (${NGINX_SITE}) não encontrado — execute a etapa 15 e rode este script de novo."
        fi
    fi

    cat > "$DEPLOY_SCRIPT_PRODUCTION" <<EOF
#!/bin/bash
# Deploy blue-green (produção) — gerado por 17-cicd-generator.sh. Chamado
# apenas pela chave SSH restrita do GitHub Actions (ver authorized_keys de ${VPS_USER}).
set -euo pipefail

APP_DIR="${APP_DIR_PRODUCTION}"
LOG_FILE="${PROJECT_DIR}/deploy-production.log"
COMPOSE_FILE="${COMPOSE_FILE}"
STATE_FILE="${STATE_FILE}"
UPSTREAM_FILE="${UPSTREAM_FILE}"
BLUE_PORT="${PROD_PORT}"
GREEN_PORT="${GREEN_PORT}"
HEALTH_PATH="${HEALTHCHECK_PATH}"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$*" | tee -a "\$LOG_FILE"; }

CURRENT="\$(cat "\$STATE_FILE")"
if [[ "\$CURRENT" == "blue" ]]; then
    NEXT="green"; NEXT_PORT="\$GREEN_PORT"; CURRENT_PORT="\$BLUE_PORT"
else
    NEXT="blue"; NEXT_PORT="\$BLUE_PORT"; CURRENT_PORT="\$GREEN_PORT"
fi

cd "\$APP_DIR"
log "Deploy blue-green iniciado — atualizando ${MAIN_BRANCH}, subindo ambiente '\$NEXT' na porta \$NEXT_PORT..."
git fetch --quiet origin "${MAIN_BRANCH}"
git checkout --quiet "${MAIN_BRANCH}"
git reset --hard --quiet "origin/${MAIN_BRANCH}"

APP_PORT="\$NEXT_PORT" COMPOSE_PROJECT_NAME="${PROJECT_NAME}-\$NEXT" \\
    docker compose -f "\$COMPOSE_FILE" -p "${PROJECT_NAME}-\$NEXT" up --build -d

log "Aguardando health check do ambiente '\$NEXT' em http://localhost:\$NEXT_PORT\$HEALTH_PATH..."
for _ in \$(seq 1 10); do
    if curl -fsS "http://localhost:\$NEXT_PORT\$HEALTH_PATH" >/dev/null 2>&1; then
        log "Ambiente '\$NEXT' saudável — trocando o upstream do Nginx."
        cat > "\$UPSTREAM_FILE" <<NGINXEOF
upstream ${PROJECT_NAME}_production_backend {
    server 127.0.0.1:\$NEXT_PORT;
}
NGINXEOF
        nginx -t && systemctl reload nginx
        echo "\$NEXT" > "\$STATE_FILE"
        log "Tráfego migrado para '\$NEXT'. Ambiente '\$CURRENT' mantido no ar para rollback rápido."
        docker image prune -f >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 3
done

log "Health check do ambiente '\$NEXT' falhou — derrubando e mantendo '\$CURRENT' em produção."
docker compose -f "\$COMPOSE_FILE" -p "${PROJECT_NAME}-\$NEXT" down
exit 1
EOF
fi

chown "${SERVICE_USER}:webapps" "$DEPLOY_SCRIPT_PRODUCTION"
chmod 750 "$DEPLOY_SCRIPT_PRODUCTION"
log "Script de deploy de produção (${DEPLOY_STRATEGY}) criado em ${DEPLOY_SCRIPT_PRODUCTION}."

if [[ "$STAGING_ENABLED" == "y" ]]; then
    cat > "$DEPLOY_SCRIPT_STAGING" <<EOF
#!/bin/bash
# Deploy rolling (staging) — gerado por 17-cicd-generator.sh. Chamado apenas
# pela chave SSH restrita do GitHub Actions (ver authorized_keys de ${VPS_USER}).
# Staging sempre usa rolling — não vale a complexidade do blue-green num
# ambiente que existe justamente para quebrar antes de virar produção.
set -euo pipefail

APP_DIR="${APP_DIR_STAGING}"
LOG_FILE="${PROJECT_DIR}/deploy-staging.log"
COMPOSE_FILE="${COMPOSE_FILE}"
HEALTH_URL="http://localhost:${STAGING_PORT}${HEALTHCHECK_PATH}"

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$*" | tee -a "\$LOG_FILE"; }

cd "\$APP_DIR"
PREV_COMMIT="\$(git rev-parse HEAD)"

log "Deploy (staging) iniciado — atualizando ${STAGING_BRANCH}..."
git fetch --quiet origin "${STAGING_BRANCH}"
git checkout --quiet "${STAGING_BRANCH}"
git reset --hard --quiet "origin/${STAGING_BRANCH}"

docker compose -f "\$COMPOSE_FILE" up --build -d

log "Aguardando health check em \$HEALTH_URL..."
for _ in \$(seq 1 10); do
    if curl -fsS "\$HEALTH_URL" >/dev/null 2>&1; then
        log "Deploy concluído — commit \$(git rev-parse --short HEAD)."
        docker image prune -f >/dev/null 2>&1 || true
        exit 0
    fi
    sleep 3
done

log "Health check falhou — revertendo para \$PREV_COMMIT."
git reset --hard --quiet "\$PREV_COMMIT"
docker compose -f "\$COMPOSE_FILE" up --build -d
log "Rollback concluído."
exit 1
EOF
    chown "${SERVICE_USER}:webapps" "$DEPLOY_SCRIPT_STAGING"
    chmod 750 "$DEPLOY_SCRIPT_STAGING"
    log "Script de deploy de staging (rolling) criado em ${DEPLOY_SCRIPT_STAGING}."
fi

# ── 10. Workflow do GitHub Actions ────────────────────────────────────────
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

case "$STACK" in
    node)
        cat <<EOF
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "${RUNTIME_VERSION}"
          cache: npm
      - run: npm ci
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
      - uses: actions/setup-node@v4
        with:
          node-version: "${RUNTIME_VERSION}"
          cache: npm
      - run: npm ci
      - run: ${TEST_CMD}
      - name: Verificar cobertura mínima (${COVERAGE_THRESHOLD}%)
        run: npx nyc check-coverage --lines ${COVERAGE_THRESHOLD} --branches ${COVERAGE_THRESHOLD} || echo "::warning::ajuste este passo ao seu test runner (jest/vitest coverageThreshold)"

  security:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2
      - run: npm ci
      - run: ${AUDIT_CMD}
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          severity: CRITICAL,HIGH
          exit-code: "1"
EOF
        ;;
    python)
        cat <<EOF
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "${RUNTIME_VERSION}"
          cache: pip
      - run: pip install -r requirements.txt
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
      - uses: actions/setup-python@v5
        with:
          python-version: "${RUNTIME_VERSION}"
          cache: pip
      - run: pip install -r requirements.txt
      - run: ${TEST_CMD}
      - name: Verificar cobertura mínima (${COVERAGE_THRESHOLD}%)
        run: |
          coverage report --fail-under=${COVERAGE_THRESHOLD} || (echo "::error::cobertura abaixo de ${COVERAGE_THRESHOLD}%" && exit 1)

  security:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2
      - run: pip install -r requirements.txt
      - run: ${AUDIT_CMD}
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          severity: CRITICAL,HIGH
          exit-code: "1"
EOF
        ;;
    go)
        cat <<EOF
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "${RUNTIME_VERSION}"
          cache: true
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
      - uses: actions/setup-go@v5
        with:
          go-version: "${RUNTIME_VERSION}"
          cache: true
      - run: ${TEST_CMD}
      - name: Verificar cobertura mínima (${COVERAGE_THRESHOLD}%)
        run: |
          go tool cover -func=coverage.out | tail -1 | awk '{print substr(\$3, 1, length(\$3)-1)}' | \\
          awk -v min=${COVERAGE_THRESHOLD} '{ if (\$1 < min) { print "cobertura " \$1 "% abaixo de " min "%"; exit 1 } }'

  security:
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2
      - run: go install golang.org/x/vuln/cmd/govulncheck@latest
      - run: ${AUDIT_CMD}
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          severity: CRITICAL,HIGH
          exit-code: "1"
EOF
        ;;
    docker)
        cat <<EOF
  # Stack genérica — adicione aqui o job de testes da sua aplicação
  # antes do build (CLAUDE.md exige happy path + 1 caminho de erro cobertos).

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: gitleaks/gitleaks-action@v2
EOF
        ;;
esac

cat <<EOF

  build:
    runs-on: ubuntu-latest
    needs: ${BUILD_NEEDS}
    if: github.event_name == 'pull_request' || github.ref == 'refs/heads/${MAIN_BRANCH}'$([[ "$STAGING_ENABLED" == "y" ]] && echo " || github.ref == 'refs/heads/${STAGING_BRANCH}'")
    steps:
      - uses: actions/checkout@v4
      - name: Build da imagem Docker (valida o build antes do deploy)
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
      # A chave em VPS_SSH_KEY (secret do Environment "staging") só executa
      # ${DEPLOY_SCRIPT_STAGING} no servidor (restrição "command=" em
      # authorized_keys) — nunca alcança o deploy de produção.
      - name: Deploy no ambiente de staging
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
      # A chave em VPS_SSH_KEY (secret do Environment "production") só
      # executa ${DEPLOY_SCRIPT_PRODUCTION} no servidor — texto de "script"
      # abaixo é ignorado pelo servidor, mas é exigido pela action.
      - name: Deploy no ambiente de produção
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
    log "Cópia também colocada em ${APP_DIR_PRODUCTION}/.github/workflows/ci-cd.yml"
fi

# ── 11. Resumo e próximos passos ──────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ CI/CD gerado para '${PROJECT_NAME}' ══${RESET}"
echo -e "  Stack:            ${CYAN}${STACK}${RESET}"
echo -e "  Estratégia (prod):${CYAN}${DEPLOY_STRATEGY}${RESET}"
echo -e "  Cobertura mínima: ${CYAN}${COVERAGE_THRESHOLD}%${RESET}"
echo -e "  Workflow:         ${CYAN}${WORKFLOW_FILE}${RESET}"
echo
echo -e "${BOLD}Faça o commit do workflow:${RESET}"
echo -e "  1. Copie ${CYAN}${WORKFLOW_FILE}${RESET} para ${CYAN}.github/workflows/ci-cd.yml${RESET} no seu repositório local (ou use a cópia já feita em ${APP_DIR_PRODUCTION}, se existir)."
echo -e "  2. Faça commit e push."
echo
echo -e "${BOLD}Crie os dois GitHub Environments${RESET} (Settings → Environments) com o MESMO nome de secret em cada um — o workflow escolhe os valores certos pelo job que está rodando:"
echo
echo -e "  ${YELLOW}Environment \"production\"${RESET} (ative 'Required reviewers' se quiser aprovação manual):"
echo -e "    VPS_HOST    = ${VPS_HOST}"
echo -e "    VPS_USER    = ${VPS_USER}"
echo -e "    VPS_PORT    = ${VPS_PORT}"
echo -e "    VPS_SSH_KEY = (chave privada de produção, abaixo)"
echo
cat "$DEPLOY_KEY_PRODUCTION"
echo

if [[ "$STAGING_ENABLED" == "y" ]]; then
    echo -e "  ${YELLOW}Environment \"staging\"${RESET} (normalmente sem revisores — deploy automático ao empurrar em ${STAGING_BRANCH}):"
    echo -e "    VPS_HOST    = ${VPS_HOST}"
    echo -e "    VPS_USER    = ${VPS_USER}"
    echo -e "    VPS_PORT    = ${VPS_PORT}"
    echo -e "    VPS_SSH_KEY = (chave privada de staging, abaixo)"
    echo
    cat "$DEPLOY_KEY_STAGING"
    echo
fi

if [[ "$REQUIRE_APPROVAL" == "y" ]]; then
    warn "No Environment 'production', ative 'Required reviewers' — o job deploy-production vai pausar até aprovação manual."
fi
warn "Ative branch protection na branch '${MAIN_BRANCH}': exigir que o CI passe e proibir push direto/force-push."
warn "Guarde as chaves privadas acima com segurança — cada uma só executa o deploy.sh do seu próprio ambiente, nada mais."

step_done "CI/CD (${PROJECT_NAME}, stack ${STACK}, deploy produção ${DEPLOY_STRATEGY}, staging ${STAGING_ENABLED})"
