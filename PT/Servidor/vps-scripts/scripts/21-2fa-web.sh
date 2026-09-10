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

# ── 2. Instalar templates e renderizar o domínio ───────────────────────────
info "Instalando configuração do Authelia em ${AUTH_DIR}..."
mkdir -p "$AUTH_DIR"
sed -e "s|__DOMAIN__|${COOKIE_DOMAIN}|g" \
    -e "s|__AUTH_HOST__|${AUTH_HOST}|g" \
    "${TEMPLATES_DIR}/auth/configuration.yml" > "${AUTH_DIR}/configuration.yml"
cp "${TEMPLATES_DIR}/auth/compose.yml" "${AUTH_DIR}/compose.yml"

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

# ── 6. Resumo e como proteger um serviço ───────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Authelia no ar ══${RESET}"
echo -e "  Portal: ${CYAN}https://${AUTH_HOST}${RESET}   Usuário: ${CYAN}${ADMIN_USER}${RESET}"
echo
echo -e "${BOLD}Cadastrar o 2FA (primeiro acesso):${RESET}"
echo -e "  1. Aponte o DNS de ${AUTH_HOST} para o IP da VPS."
echo -e "  2. Acesse o portal, entre com usuário/senha e registre o app autenticador (TOTP)."
echo -e "     (O link de registro vai para ${CYAN}${AUTH_DIR}/notification.txt${RESET} — sem SMTP configurado.)"
echo
echo -e "${BOLD}Proteger um serviço com 2FA${RESET} — adicione ao router dele a label:"
echo -e "  ${CYAN}traefik.http.routers.<router>.middlewares=secure-chain@file,authelia@docker${RESET}"
echo -e "  Ex.: para o dashboard do Traefik e o Grafana, inclua ${CYAN}authelia@docker${RESET}"
echo -e "  na linha de middlewares do router e rode 'docker compose up -d' do stack."
echo
warn "Valide a config se algo não subir: docker compose -f ${AUTH_DIR}/compose.yml logs authelia"
warn "Ou: docker run --rm -v ${AUTH_DIR}:/config ${AUTHELIA_IMAGE} authelia validate-config --config /config/configuration.yml"

step_done "2FA web (Authelia, portal: ${AUTH_HOST})"
