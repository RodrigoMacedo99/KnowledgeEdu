#!/bin/bash
# Seção 21 — 2FA/SSO nos serviços web (Authelia + Traefik forward-auth)
#
# Sobe o Authelia em /opt/platform/auth. Ele vira um portal de login único: ao
# adicionar o middleware 'authelia@docker' a qualquer serviço, o Traefik primeiro
# manda o visitante autenticar (senha + 2FA) antes de deixar passar. Um único
# lugar para proteger dashboard do Traefik, Grafana, staging e painéis internos.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "21-2fa-web"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
AUTH_DIR="/opt/platform/auth"
PLATFORM_ENV="/opt/platform/.env"
AUTHELIA_IMAGE="authelia/authelia:4.38"

title "21. 2FA/SSO nos serviços web (Authelia)"

docker network inspect edge &>/dev/null || die "Rede 'edge' não existe — rode as etapas 8 e 9 primeiro."
require_command docker

# ── 1. Dados ───────────────────────────────────────────────────────────────
prompt AUTH_HOST     "Domínio do portal de login (ex: auth.seudominio.com)" ""
prompt COOKIE_DOMAIN "Domínio base compartilhado pelos serviços (ex: seudominio.com)" ""
prompt ADMIN_USER    "Usuário administrador do portal" "admin"
prompt ADMIN_EMAIL   "E-mail do administrador" ""
prompt_secret ADMIN_PASS "Senha do administrador do portal"

echo
info "Sem SMTP, o link de cadastro do 2FA e resets caem em notification.txt no servidor."
USE_SMTP="n"
if confirm "Configurar envio por e-mail (SMTP) para cadastro/reset do 2FA?"; then
    USE_SMTP="y"
    prompt SMTP_HOST   "Servidor SMTP (ex: smtp.gmail.com)"        ""
    prompt SMTP_PORT   "Porta SMTP (587 = STARTTLS, 465 = TLS)"    "587"
    prompt SMTP_USER   "Usuário/login SMTP"                        "$ADMIN_EMAIL"
    prompt SMTP_SENDER "Remetente (From)"                          "Authelia <no-reply@${COOKIE_DOMAIN}>"
    prompt_secret SMTP_PASS "Senha (ou app-password) do SMTP"
fi

# ── 2. Instalar templates e renderizar o domínio ───────────────────────────
info "Instalando configuração do Authelia em ${AUTH_DIR}..."
mkdir -p "$AUTH_DIR"
sed -e "s|__DOMAIN__|${COOKIE_DOMAIN}|g" \
    -e "s|__AUTH_HOST__|${AUTH_HOST}|g" \
    "${TEMPLATES_DIR}/auth/configuration.yml" > "${AUTH_DIR}/configuration.yml"
cp "${TEMPLATES_DIR}/auth/compose.yml" "${AUTH_DIR}/compose.yml"

# Notifier: SMTP (se informado) ou arquivo. Anexado ao fim da config.
if [[ "$USE_SMTP" == "y" ]]; then
    # 465 = TLS implícito (submissions://); demais portas = STARTTLS (smtp://).
    if [[ "$SMTP_PORT" == "465" ]]; then SMTP_SCHEME="submissions"; else SMTP_SCHEME="smtp"; fi
    cat >> "${AUTH_DIR}/configuration.yml" <<EOF

notifier:
  smtp:
    address: '${SMTP_SCHEME}://${SMTP_HOST}:${SMTP_PORT}'
    username: '${SMTP_USER}'
    sender: '${SMTP_SENDER}'
    subject: '[Authelia] {title}'
EOF
    # Senha do SMTP como segredo no .env (recriada sem sed p/ aceitar qualquer caractere).
    sed -i '/^AUTHELIA_NOTIFIER_SMTP_PASSWORD=/d' "$PLATFORM_ENV" 2>/dev/null || true
    echo "AUTHELIA_NOTIFIER_SMTP_PASSWORD=${SMTP_PASS}" >> "$PLATFORM_ENV"
    log "Notifier SMTP configurado (${SMTP_HOST}:${SMTP_PORT})."
else
    cat >> "${AUTH_DIR}/configuration.yml" <<'EOF'

notifier:
  filesystem:
    filename: '/config/notification.txt'
EOF
    info "Notifier em arquivo (/config/notification.txt)."
fi

# ── 3. Hash argon2 da senha do admin (gerado pelo próprio Authelia) ────────
info "Gerando hash argon2 da senha (via imagem do Authelia)..."
HASH="$(docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$ADMIN_PASS" 2>/dev/null | awk '/Digest:/ {print $2}')"
[[ -z "$HASH" ]] && die "Falha ao gerar o hash da senha."

cat > "${AUTH_DIR}/users_database.yml" <<EOF
users:
  ${ADMIN_USER}:
    disabled: false
    displayname: 'Administrador'
    password: '${HASH}'
    email: '${ADMIN_EMAIL}'
    groups:
      - 'admins'
EOF
chmod 640 "${AUTH_DIR}/users_database.yml"

# ── 4. Segredos no .env da plataforma (idempotente) ────────────────────────
touch "$PLATFORM_ENV"
add_secret() {
    local key="$1"
    grep -q "^${key}=" "$PLATFORM_ENV" && return 0
    echo "${key}=$(openssl rand -hex 64)" >> "$PLATFORM_ENV"
    log "Segredo ${key} gerado."
}
add_secret AUTHELIA_SESSION_SECRET
add_secret AUTHELIA_STORAGE_ENCRYPTION_KEY
add_secret AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET

if grep -q '^AUTH_HOST=' "$PLATFORM_ENV"; then
    sed -i "s|^AUTH_HOST=.*|AUTH_HOST=${AUTH_HOST}|" "$PLATFORM_ENV"
else
    echo "AUTH_HOST=${AUTH_HOST}" >> "$PLATFORM_ENV"
fi
chmod 640 "$PLATFORM_ENV"

# ── 5. Subir ───────────────────────────────────────────────────────────────
info "Subindo o Authelia..."
docker compose --env-file "$PLATFORM_ENV" -f "${AUTH_DIR}/compose.yml" up -d

# ── 5b. Proteger dashboard do Traefik e Grafana com o Authelia ─────────────
# Feito só AGORA (não nos templates) porque o middleware 'authelia@docker' só
# existe depois que o Authelia sobe — se estivesse fixo no edge, o router
# quebraria antes da etapa 21. Idempotente.
protect_with_authelia() {
    local compose_file="$1" router="$2" new_mw="$3" stack="$4"
    if [[ ! -f "$compose_file" ]]; then
        warn "${stack} não instalado — pulei a proteção de '${router}'."
        return
    fi
    if grep -q "routers.${router}.middlewares=.*authelia@docker" "$compose_file"; then
        already_done "'${router}' já protegido pelo Authelia"
        return
    fi
    if ! grep -q "traefik.http.routers.${router}.middlewares=" "$compose_file"; then
        warn "Router '${router}' não encontrado em ${compose_file} — proteja manualmente."
        return
    fi
    cp "$compose_file" "${compose_file}.bak.$(date +%s)"
    sed -i "s|\(traefik.http.routers.${router}.middlewares=\).*|\1${new_mw}|" "$compose_file"
    docker compose --env-file "$PLATFORM_ENV" -f "$compose_file" up -d >/dev/null 2>&1 \
        && log "'${router}' agora exige login no Authelia." \
        || warn "Reaplique manualmente: docker compose -f ${compose_file} up -d"
}

echo
info "Protegendo o dashboard do Traefik e o Grafana com o Authelia (padrão)..."
# Dashboard: troca o basic-auth pelo Authelia, mantendo a allowlist de IP.
protect_with_authelia "/opt/platform/edge/compose.yml" "dashboard" \
    "admin-allowlist@file,authelia@docker" "Edge/Traefik"
# Grafana: login único (SSO) de verdade — confia no cabeçalho Remote-User que o
# Authelia injeta, evitando um segundo login. Só é seguro porque o Grafana só é
# alcançável via Traefik+Authelia; a whitelist restringe a confiança à rede edge.
GRAFANA_ENV="/opt/platform/observability/grafana.env"
if [[ -f "/opt/platform/observability/compose.yml" ]]; then
    EDGE_SUBNET="$(docker network inspect edge -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
    cat > "$GRAFANA_ENV" <<EOF
# SSO via Authelia (auth proxy) — gerado pela etapa 21.
GF_AUTH_PROXY_ENABLED=true
GF_AUTH_PROXY_HEADER_NAME=Remote-User
GF_AUTH_PROXY_HEADER_PROPERTY=username
GF_AUTH_PROXY_AUTO_SIGN_UP=true
GF_AUTH_PROXY_HEADERS=Email:Remote-Email Name:Remote-Name Groups:Remote-Groups
GF_AUTH_PROXY_ENABLE_LOGIN_TOKEN=true
GF_AUTH_PROXY_SYNC_TTL=60
GF_AUTH_PROXY_WHITELIST=${EDGE_SUBNET}
EOF
    log "Grafana com login único via Authelia (auth proxy, whitelist ${EDGE_SUBNET:-edge})."
fi
# Adiciona o Authelia à frente do Grafana e reaplica (pega o grafana.env acima).
protect_with_authelia "/opt/platform/observability/compose.yml" "grafana" \
    "secure-chain@file,authelia@docker" "Observabilidade"

# ── 6. Resumo e como proteger um serviço ───────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Authelia no ar ══${RESET}"
echo -e "  Portal: ${CYAN}https://${AUTH_HOST}${RESET}   Usuário: ${CYAN}${ADMIN_USER}${RESET}"
echo
echo -e "${BOLD}Cadastrar o 2FA (primeiro acesso):${RESET}"
echo -e "  1. Aponte o DNS de ${AUTH_HOST} para o IP da VPS."
echo -e "  2. Acesse o portal, entre com usuário/senha e registre o app autenticador (TOTP)."
if [[ "$USE_SMTP" == "y" ]]; then
    echo -e "     (O link de registro chega no e-mail via SMTP configurado.)"
else
    echo -e "     (Sem SMTP: o link de registro cai em ${CYAN}${AUTH_DIR}/notification.txt${RESET} — leia-o lá.)"
fi
echo
echo -e "${BOLD}Já protegidos por padrão:${RESET} dashboard do Traefik e Grafana."
echo
echo -e "${BOLD}Proteger OUTRO serviço com 2FA${RESET} — adicione ao router dele a label:"
echo -e "  ${CYAN}traefik.http.routers.<router>.middlewares=secure-chain@file,authelia@docker${RESET}"
echo -e "  e rode 'docker compose up -d' do stack correspondente."
echo
warn "Valide a config se algo não subir: docker compose -f ${AUTH_DIR}/compose.yml logs authelia"
warn "Ou: docker run --rm -v ${AUTH_DIR}:/config ${AUTHELIA_IMAGE} authelia validate-config --config /config/configuration.yml"

step_done "2FA web (Authelia, portal: ${AUTH_HOST})"
