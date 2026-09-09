#!/bin/bash
# Seção 9 — Edge proxy (Traefik v3) como porta de entrada de todos os serviços
#
# O Traefik recebe todo o tráfego em 80/443 e roteia para o container certo com
# base no domínio — descobrindo as rotas pelas LABELS de cada container (nada de
# editar arquivo por projeto). Ele também emite/renova o HTTPS (Let's Encrypt)
# automaticamente. Não fala direto com o socket do Docker: usa o
# docker-socket-proxy em modo leitura.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "09-edge-proxy"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
EDGE_DIR="/opt/platform/edge"
PLATFORM_ENV="/opt/platform/.env"

title "9. Edge proxy (Traefik v3)"

[[ -d "$EDGE_DIR" ]] || die "Pasta ${EDGE_DIR} não existe — rode a etapa 7 primeiro."
docker network inspect edge &>/dev/null || die "Rede 'edge' não existe — rode a etapa 8 primeiro."

# ── 1. Dados de configuração ───────────────────────────────────────────────
prompt ACME_EMAIL         "E-mail para o Let's Encrypt (avisos de expiração)" ""
prompt TRAEFIK_DASHBOARD_HOST "Domínio do dashboard do Traefik (ex: traefik.seudominio.com)" ""
prompt DASH_USER          "Usuário do dashboard"                        "admin"
prompt_secret DASH_PASS   "Senha do dashboard"

# ── 2. Copiar/renderizar os templates ──────────────────────────────────────
info "Instalando configuração do Traefik em ${EDGE_DIR}..."
mkdir -p "${EDGE_DIR}/dynamic"

# traefik.yml precisa do e-mail embutido: o Traefik NÃO expande ${VAR} dentro do
# arquivo estático, então substituímos aqui na cópia.
sed "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
    "${TEMPLATES_DIR}/edge/traefik.yml" > "${EDGE_DIR}/traefik.yml"

cp "${TEMPLATES_DIR}/edge/dynamic/security.yml" "${EDGE_DIR}/dynamic/security.yml"
cp "${TEMPLATES_DIR}/edge/compose.yml"          "${EDGE_DIR}/compose.yml"

# ── 3. acme.json (armazém dos certificados) ────────────────────────────────
if [[ ! -f "${EDGE_DIR}/acme.json" ]]; then
    info "Criando acme.json (chmod 600 — exigido pelo Traefik)..."
    touch "${EDGE_DIR}/acme.json"
fi
chmod 600 "${EDGE_DIR}/acme.json"

# ── 4. Basic-auth do dashboard (arquivo dinâmico, fora do compose) ─────────
# Geramos o hash com openssl (apr1) e o gravamos num arquivo do file provider.
# Assim o hash (cheio de '$') nunca passa pela interpolação do docker compose.
info "Gerando credencial do dashboard..."
DASH_HASH="$(openssl passwd -apr1 "$DASH_PASS")"
cat > "${EDGE_DIR}/dynamic/dashboard-auth.yml" <<EOF
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "${DASH_USER}:${DASH_HASH}"
EOF
chmod 640 "${EDGE_DIR}/dynamic/dashboard-auth.yml"

# ── 5. Registrar o domínio do dashboard no .env da plataforma ──────────────
touch "$PLATFORM_ENV"
if grep -q '^TRAEFIK_DASHBOARD_HOST=' "$PLATFORM_ENV"; then
    sed -i "s|^TRAEFIK_DASHBOARD_HOST=.*|TRAEFIK_DASHBOARD_HOST=${TRAEFIK_DASHBOARD_HOST}|" "$PLATFORM_ENV"
else
    echo "TRAEFIK_DASHBOARD_HOST=${TRAEFIK_DASHBOARD_HOST}" >> "$PLATFORM_ENV"
fi
chmod 640 "$PLATFORM_ENV"

# ── 6. Subir o Traefik ─────────────────────────────────────────────────────
info "Subindo o Traefik..."
docker compose --env-file "$PLATFORM_ENV" -f "${EDGE_DIR}/compose.yml" up -d

echo
echo -e "${BOLD}${GREEN}══ Traefik no ar ══${RESET}"
echo -e "  Dashboard: ${CYAN}https://${TRAEFIK_DASHBOARD_HOST}${RESET} (basic-auth + allowlist de IP)"
echo -e "  HTTPS automático via Let's Encrypt para todo serviço com labels do Traefik."
warn "Ajuste a allowlist do dashboard em ${EDGE_DIR}/dynamic/security.yml (middleware admin-allowlist)."
warn "Aponte o DNS de ${TRAEFIK_DASHBOARD_HOST} para o IP da VPS antes de acessar (o cert só é emitido com o DNS resolvendo)."

step_done "Edge proxy Traefik (dashboard: ${TRAEFIK_DASHBOARD_HOST})"
