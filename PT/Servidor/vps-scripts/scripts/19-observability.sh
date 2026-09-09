#!/bin/bash
# Seção 19 — Stack de observabilidade (métricas, logs e dashboards)
#
# Sobe Prometheus + Grafana + Loki + Alloy + cAdvisor + node-exporter em
# /opt/platform/observability. Só o Grafana é acessível de fora (via Traefik,
# com login). O resto vive apenas na rede interna 'observability'.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "19-observability"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
OBS_DIR="/opt/platform/observability"
PLATFORM_ENV="/opt/platform/.env"

title "19. Observabilidade (Prometheus, Grafana, Loki, Alloy)"

[[ -d "$OBS_DIR" ]] || die "Pasta ${OBS_DIR} não existe — rode a etapa 7 primeiro."
docker network inspect observability &>/dev/null || die "Rede 'observability' não existe — rode a etapa 8 primeiro."
docker network inspect edge &>/dev/null || die "Rede 'edge' não existe — rode as etapas 8 e 9 primeiro."

# ── 1. Dados de configuração ───────────────────────────────────────────────
prompt GRAFANA_HOST "Domínio do Grafana (ex: grafana.seudominio.com)" ""

# ── 2. Copiar os templates (preservando configs já editadas) ───────────────
info "Instalando configuração da observabilidade em ${OBS_DIR}..."
cp -rn "${TEMPLATES_DIR}/observability/." "${OBS_DIR}/"

# ── 3. Segredos no .env da plataforma ──────────────────────────────────────
touch "$PLATFORM_ENV"

if grep -q '^GRAFANA_HOST=' "$PLATFORM_ENV"; then
    sed -i "s|^GRAFANA_HOST=.*|GRAFANA_HOST=${GRAFANA_HOST}|" "$PLATFORM_ENV"
else
    echo "GRAFANA_HOST=${GRAFANA_HOST}" >> "$PLATFORM_ENV"
fi

if grep -q '^GF_SECURITY_ADMIN_PASSWORD=' "$PLATFORM_ENV"; then
    GRAFANA_PASS="$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$PLATFORM_ENV" | cut -d= -f2-)"
    already_done "Senha do Grafana (mantida a existente)"
else
    GRAFANA_PASS="$(openssl rand -base64 24)"
    echo "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}" >> "$PLATFORM_ENV"
    log "Senha admin do Grafana gerada."
fi
chmod 640 "$PLATFORM_ENV"

# ── 4. Subir a stack ───────────────────────────────────────────────────────
info "Subindo a stack de observabilidade (pode demorar no primeiro pull)..."
docker compose --env-file "$PLATFORM_ENV" -f "${OBS_DIR}/compose.yml" up -d

# ── 5. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Observabilidade no ar ══${RESET}"
echo -e "  Grafana:  ${CYAN}https://${GRAFANA_HOST}${RESET}"
echo -e "  Usuário:  ${CYAN}admin${RESET}"
echo -e "  Senha:    ${CYAN}${GRAFANA_PASS}${RESET}  (também em ${PLATFORM_ENV})"
echo
echo -e "  Datasources Prometheus e Loki já provisionados."
echo -e "  Importe dashboards prontos em Grafana → Dashboards → Import (por ID):"
echo -e "    • ${YELLOW}1860${RESET}  — Node Exporter Full (host)"
echo -e "    • ${YELLOW}19792${RESET} — cAdvisor (containers)"
echo -e "    • ${YELLOW}17346${RESET} — Traefik v3"
echo
warn "Aponte o DNS de ${GRAFANA_HOST} para o IP da VPS para o Traefik emitir o certificado."
warn "Guarde a senha do Grafana com segurança."

step_done "Observabilidade (Grafana: ${GRAFANA_HOST})"
