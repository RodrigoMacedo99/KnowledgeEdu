#!/bin/bash
# Seção 21 — 2FA/SSO nos serviços web (Authelia + Traefik forward-auth)
#
# Sobe o Authelia em /opt/platform/auth. Ele vira um portal de login único: ao
# adicionar o middleware 'authelia@docker' a qualquer serviço, o Traefik primeiro
# manda o visitante autenticar (senha + 2FA) antes de deixar passar.
#
# Notificador (cadastro/reset do 2FA): SMTP ou arquivo. Com SMTP, as credenciais
# são TESTADAS antes de qualquer configuração ser gravada — credencial recusada
# faria o Authelia reiniciar em loop. O modo escolhido fica registrado.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "21-2fa-web"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
AUTH_DIR="/opt/platform/auth"
PLATFORM_ENV="/opt/platform/.env"
AUTHELIA_IMAGE="authelia/authelia:4.38.19"
SMTP_MAX_ATTEMPTS=3

title "21. 2FA/SSO nos serviços web (Authelia)"

docker network inspect edge &>/dev/null || die "Rede 'edge' não existe — rode as etapas 8 e 9 primeiro."
require_command docker

# smtp_auth_check <host> <porta> <usuário> <senha>
# Testa AUTH LOGIN de verdade. A senha vai ao openssl por stdin (printf é builtin
# e o base64 recebe por pipe): nunca aparece em linha de comando nem na tela.
# 465 = TLS implícito; demais portas = STARTTLS. Retorna 0 só com 235.
smtp_auth_check() {
    local host="$1" port="$2" user="$3" pass="$4" user_b64 pass_b64 transcript
    local tls_args=(-starttls smtp)
    [[ "$port" == "465" ]] && tls_args=()
    user_b64="$(printf '%s' "$user" | base64 -w0)"
    pass_b64="$(printf '%s' "$pass" | base64 -w0)"
    transcript="$(
        { printf 'EHLO authelia-check\r\nAUTH LOGIN\r\n%s\r\n%s\r\nQUIT\r\n' "$user_b64" "$pass_b64"; } \
            | timeout 40 openssl s_client -quiet -crlf "${tls_args[@]}" -connect "${host}:${port}" 2>/dev/null
    )" || transcript=""
    if grep -q '^235 ' <<< "$transcript"; then
        return 0
    fi
    if grep -q '^535 ' <<< "$transcript"; then
        SMTP_CHECK_REASON="credenciais recusadas pelo servidor (535)"
    else
        SMTP_CHECK_REASON="sem resposta de autenticação (verifique host, porta e TLS)"
    fi
    return 1
}

# ── 1. Dados (lembra o que já foi digitado antes, exceto segredos) ─────────
prompt AUTH_HOST     "Domínio do portal de login (ex: auth.seudominio.com)" "$(get_config AUTHELIA_AUTH_HOST)"
prompt COOKIE_DOMAIN "Domínio base compartilhado pelos serviços (ex: seudominio.com)" "$(get_config AUTHELIA_COOKIE_DOMAIN)"
prompt ADMIN_USER    "Usuário administrador do portal" "$(get_config AUTHELIA_ADMIN_USER admin)"
prompt ADMIN_EMAIL   "E-mail do administrador" "$(get_config AUTHELIA_ADMIN_EMAIL)"
prompt_secret ADMIN_PASS "Senha do administrador do portal (não será exibida)"
save_config AUTHELIA_AUTH_HOST "$AUTH_HOST"
save_config AUTHELIA_COOKIE_DOMAIN "$COOKIE_DOMAIN"
save_config AUTHELIA_ADMIN_USER "$ADMIN_USER"
save_config AUTHELIA_ADMIN_EMAIL "$ADMIN_EMAIL"

# ── 2. Notificador: SMTP validado ou arquivo ───────────────────────────────
echo
info "Sem SMTP, o link de cadastro do 2FA e de reset cai em /config/notification.txt no servidor."
NOTIFIER_MODE="file"
if confirm "Configurar envio por e-mail (SMTP) para cadastro/reset do 2FA?"; then
    prompt SMTP_HOST   "Servidor SMTP (ex: smtp.sendpulse.com)"    "$(get_config AUTHELIA_SMTP_HOST)"
    prompt SMTP_PORT   "Porta SMTP (587 = STARTTLS, 465 = TLS)"     "$(get_config AUTHELIA_SMTP_PORT 587)"
    prompt SMTP_USER   "Usuário/login SMTP"                         "$(get_config AUTHELIA_SMTP_USER "$ADMIN_EMAIL")"
    prompt SMTP_SENDER "Remetente (From)"                           "$(get_config AUTHELIA_SMTP_SENDER "Authelia <no-reply@${COOKIE_DOMAIN}>")"
    SMTP_OK="n"
    for attempt in $(seq 1 "$SMTP_MAX_ATTEMPTS"); do
        prompt_secret SMTP_PASS "Senha (ou app-password) do SMTP (tentativa ${attempt}/${SMTP_MAX_ATTEMPTS})"
        info "Testando a autenticação em ${SMTP_HOST}:${SMTP_PORT}..."
        if smtp_auth_check "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" "$SMTP_PASS"; then
            SMTP_OK="y"
            break
        fi
        warn "Autenticação SMTP falhou: ${SMTP_CHECK_REASON}."
    done
    if [[ "$SMTP_OK" == "y" ]]; then
        NOTIFIER_MODE="smtp"
        log "SMTP autenticado com sucesso."
        save_config AUTHELIA_SMTP_HOST "$SMTP_HOST"
        save_config AUTHELIA_SMTP_PORT "$SMTP_PORT"
        save_config AUTHELIA_SMTP_USER "$SMTP_USER"
        save_config AUTHELIA_SMTP_SENDER "$SMTP_SENDER"
    else
        confirm "Continuar SEM SMTP (cadastro do 2FA via arquivo)? Não: aborta sem gravar nada." \
            || die "SMTP não validado — nada foi gravado. Corrija as credenciais e rode de novo."
        warn "Seguindo em modo arquivo (notification.txt)."
    fi
fi
save_config AUTHELIA_NOTIFIER_MODE "$NOTIFIER_MODE"
log "Modo do notificador: ${NOTIFIER_MODE}."

# ── 3. Hash argon2 (senha por stdin, nunca por argv) ───────────────────────
info "Gerando hash argon2 da senha (via imagem do Authelia)..."
HASH_OUTPUT="$(printf '%s\n' "$ADMIN_PASS" \
    | docker run --rm -i --entrypoint sh "$AUTHELIA_IMAGE" \
        -c 'read -r pw && authelia crypto hash generate argon2 --password "$pw"' 2>/dev/null)" || HASH_OUTPUT=""
HASH="$(awk '/Digest:/ {print $2}' <<< "$HASH_OUTPUT")"
[[ -n "$HASH" ]] || die "Falha ao gerar o hash da senha."

# ── 4. Instalar templates e renderizar ─────────────────────────────────────
info "Instalando configuração do Authelia em ${AUTH_DIR}..."
mkdir -p "$AUTH_DIR"
sed -e "s|__DOMAIN__|${COOKIE_DOMAIN}|g" \
    -e "s|__AUTH_HOST__|${AUTH_HOST}|g" \
    "${TEMPLATES_DIR}/auth/configuration.yml" > "${AUTH_DIR}/configuration.yml"
cp "${TEMPLATES_DIR}/auth/compose.yml" "${AUTH_DIR}/compose.yml"

if [[ "$NOTIFIER_MODE" == "smtp" ]]; then
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
else
    cat >> "${AUTH_DIR}/configuration.yml" <<'EOF'

notifier:
  filesystem:
    filename: '/config/notification.txt'
EOF
fi

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

# ── 5. Segredos no .env da plataforma (600, só root) ───────────────────────
[[ -f "$PLATFORM_ENV" ]] || install -m 600 /dev/null "$PLATFORM_ENV"
if [[ "$NOTIFIER_MODE" == "smtp" ]]; then
    sed -i '/^AUTHELIA_NOTIFIER_SMTP_PASSWORD=/d' "$PLATFORM_ENV"
    printf 'AUTHELIA_NOTIFIER_SMTP_PASSWORD=%s\n' "$SMTP_PASS" >> "$PLATFORM_ENV"
fi
add_secret() {
    local key="$1"
    grep -q "^${key}=" "$PLATFORM_ENV" && return 0
    printf '%s=%s\n' "$key" "$(openssl rand -hex 64)" >> "$PLATFORM_ENV"
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
chmod 600 "$PLATFORM_ENV"

# ── 6. Subir ───────────────────────────────────────────────────────────────
info "Subindo o Authelia..."
docker compose --env-file "$PLATFORM_ENV" -f "${AUTH_DIR}/compose.yml" up -d

# ── 7. Proteger dashboard do Traefik e Grafana com o Authelia ──────────────
# Feito só AGORA (não nos templates) porque o middleware 'authelia@docker' só
# existe depois que o Authelia sobe. Idempotente.
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
protect_with_authelia "/opt/platform/edge/compose.yml" "dashboard" \
    "admin-allowlist@file,authelia@docker" "Edge/Traefik"
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
protect_with_authelia "/opt/platform/observability/compose.yml" "grafana" \
    "secure-chain@file,authelia@docker" "Observabilidade"

# ── 8. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Authelia no ar ══${RESET}"
echo -e "  Portal: ${CYAN}https://${AUTH_HOST}${RESET}   Usuário: ${CYAN}${ADMIN_USER}${RESET}"
echo -e "  Notificador: ${CYAN}${NOTIFIER_MODE}${RESET}"
echo
echo -e "${BOLD}Cadastrar o 2FA (primeiro acesso):${RESET}"
echo -e "  1. Aponte o DNS de ${AUTH_HOST} para o IP da VPS."
echo -e "  2. Acesse o portal, entre com usuário/senha e registre o app autenticador (TOTP)."
if [[ "$NOTIFIER_MODE" == "smtp" ]]; then
    echo -e "     (O link de registro chega no e-mail via SMTP configurado.)"
else
    echo -e "     (Sem SMTP: o link cai em ${CYAN}/config/notification.txt${RESET} dentro do contêiner.)"
    echo -e "     Leia com: ${CYAN}docker exec authelia cat /config/notification.txt${RESET}"
fi
echo
echo -e "${BOLD}Proteger OUTRO serviço com 2FA${RESET} — adicione ao router dele a label:"
echo -e "  ${CYAN}traefik.http.routers.<router>.middlewares=secure-chain@file,authelia@docker${RESET}"
echo -e "  e rode 'docker compose up -d' do stack correspondente."
echo
warn "Se algo não subir: docker compose -f ${AUTH_DIR}/compose.yml logs authelia"

step_done "2FA web (Authelia, portal: ${AUTH_HOST}, notificador: ${NOTIFIER_MODE})"
