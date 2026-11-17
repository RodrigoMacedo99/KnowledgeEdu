#!/bin/bash
# Seção 19 — Stack de observabilidade (métricas, logs e dashboards)
#
# Sobe Prometheus + Grafana + Loki + Alloy + cAdvisor + node-exporter + Alertmanager
# em /opt/platform/observability. Só o Grafana é acessível de fora (via Traefik,
# com login). O resto vive apenas na rede interna 'observability'.
#
# Segredos de alerta (token do Telegram, URL do webhook) NÃO vão para o YAML:
# ficam em arquivos próprios, legíveis só pelo UID do Alertmanager (65534), e o
# YAML referencia o caminho (bot_token_file / url_file). Nada disso é impresso.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "19-observability"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
PLATFORM_DIR="/opt/platform"
OBS_DIR="${PLATFORM_DIR}/observability"
PLATFORM_ENV="${PLATFORM_DIR}/.env"
SECRETS_DIR="${OBS_DIR}/secrets"
ALERTMANAGER_UID=65534   # usuário 'nobody', que a imagem prom/alertmanager usa
ALERTMANAGER_YML="${OBS_DIR}/alertmanager/alertmanager.yml"
SECRET_IN_CONTAINER="/etc/alertmanager/secrets"

title "19. Observabilidade (Prometheus, Grafana, Loki, Alloy)"

[[ -d "$OBS_DIR" ]] || die "Pasta ${OBS_DIR} não existe — rode a etapa 7 primeiro."
docker network inspect observability &>/dev/null || die "Rede 'observability' não existe — rode a etapa 8 primeiro."
docker network inspect edge &>/dev/null || die "Rede 'edge' não existe — rode as etapas 8 e 9 primeiro."

# write_secret_file <arquivo> <valor> — grava sem eco, 400, dono do UID do Alertmanager.
write_secret_file() {
    local file="$1" value="$2"
    (umask 077; printf '%s' "$value" > "$file")
    chown "${ALERTMANAGER_UID}:${ALERTMANAGER_UID}" "$file"
    chmod 400 "$file"
}

# ── 1. Dados de configuração ───────────────────────────────────────────────
prompt GRAFANA_HOST "Domínio do Grafana (ex: grafana.seudominio.com)" ""

echo
info "Alertas: o Prometheus já vem com regras de SLO; escolha para onde notificar."
echo -e "  ${YELLOW}1${RESET}) Webhook genérico (Slack/Discord/Teams/Google Chat)"
echo -e "  ${YELLOW}2${RESET}) Telegram (bot + chat)"
echo -e "  ${YELLOW}3${RESET}) Pular por agora (configura depois em alertmanager.yml)"
prompt ALERT_CHOICE "Escolha" "3"

ALERT_WEBHOOK="" TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""
case "$ALERT_CHOICE" in
    1)
        prompt_secret ALERT_WEBHOOK "URL do webhook (não será exibida)"
        ;;
    2)
        info "Crie um bot em https://t.me/BotFather (comando /newbot) e copie o token."
        prompt_secret TELEGRAM_BOT_TOKEN "Token do bot do Telegram (não será exibido)"
        info "Chat ID: mande uma mensagem ao bot e acesse"
        info "  https://api.telegram.org/bot<TOKEN>/getUpdates"
        info "(ou fale com @userinfobot no Telegram para pegar o seu chat_id pessoal)."
        prompt TELEGRAM_CHAT_ID "Chat ID do Telegram (número — negativo se for grupo)" "$(get_config TELEGRAM_CHAT_ID)"
        save_config TELEGRAM_CHAT_ID "$TELEGRAM_CHAT_ID"
        ;;
    *) info "Alertas sem destino por enquanto." ;;
esac

# ── 2. Copiar os templates (preservando configs já editadas) ───────────────
info "Instalando configuração da observabilidade em ${OBS_DIR}..."
cp -rn "${TEMPLATES_DIR}/observability/." "${OBS_DIR}/"
# Vazio por padrão (login normal do Grafana); a etapa 21 preenche com o SSO.
touch "${OBS_DIR}/grafana.env"

# ── 3. Segredos de alerta em arquivos (fora do YAML) ───────────────────────
mkdir -p "$SECRETS_DIR"
chmod 750 "$SECRETS_DIR"
[[ -n "$ALERT_WEBHOOK" ]] && write_secret_file "${SECRETS_DIR}/webhook_url" "$ALERT_WEBHOOK"
[[ -n "$TELEGRAM_BOT_TOKEN" ]] && write_secret_file "${SECRETS_DIR}/telegram_bot_token" "$TELEGRAM_BOT_TOKEN"

{
    cat <<EOF
route:
  receiver: 'default'
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: 'default'
EOF
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        cat <<EOF
    webhook_configs:
      - url_file: '${SECRET_IN_CONTAINER}/webhook_url'
        send_resolved: true
EOF
    elif [[ -n "$TELEGRAM_CHAT_ID" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
        cat <<EOF
    telegram_configs:
      - bot_token_file: '${SECRET_IN_CONTAINER}/telegram_bot_token'
        chat_id: ${TELEGRAM_CHAT_ID}
        api_url: 'https://api.telegram.org'
        parse_mode: 'HTML'
        send_resolved: true
EOF
    fi
} > "$ALERTMANAGER_YML"
chmod 640 "$ALERTMANAGER_YML"
# O Alertmanager (UID 65534) precisa LER o YAML; ACL mínima, sem abrir a árvore.
grant_container_read "$ALERTMANAGER_UID" "$ALERTMANAGER_YML" "$PLATFORM_DIR"

if [[ -n "$ALERT_WEBHOOK" ]]; then
    log "Alertmanager configurado para enviar ao webhook (URL em arquivo de 400)."
elif [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    log "Alertmanager configurado para enviar ao Telegram (token em arquivo de 400)."
else
    info "Alertas ativos, mas sem destino — defina depois em ${ALERTMANAGER_YML}."
fi

# ── 4. Variáveis da plataforma (.env: 600, só root) ─────────────────────────
[[ -f "$PLATFORM_ENV" ]] || install -m 600 /dev/null "$PLATFORM_ENV"

if grep -q '^GRAFANA_HOST=' "$PLATFORM_ENV"; then
    sed -i "s|^GRAFANA_HOST=.*|GRAFANA_HOST=${GRAFANA_HOST}|" "$PLATFORM_ENV"
else
    echo "GRAFANA_HOST=${GRAFANA_HOST}" >> "$PLATFORM_ENV"
fi

if grep -q '^GF_SECURITY_ADMIN_PASSWORD=' "$PLATFORM_ENV"; then
    already_done "Senha do Grafana (mantida a existente)"
else
    echo "GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 24)" >> "$PLATFORM_ENV"
    log "Senha admin do Grafana gerada e gravada em ${PLATFORM_ENV}."
fi
chmod 600 "$PLATFORM_ENV"

# ── 5. Subir a stack ───────────────────────────────────────────────────────
info "Subindo a stack de observabilidade (pode demorar no primeiro pull)..."
docker compose --env-file "$PLATFORM_ENV" -f "${OBS_DIR}/compose.yml" up -d

# ── 6. Resumo (nenhuma senha impressa) ─────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Observabilidade no ar ══${RESET}"
echo -e "  Grafana:  ${CYAN}https://${GRAFANA_HOST}${RESET}"
echo -e "  Usuário:  ${CYAN}admin${RESET}"
echo -e "  Senha:    em ${CYAN}${PLATFORM_ENV}${RESET} (GF_SECURITY_ADMIN_PASSWORD). Para ler:"
echo -e "            ${CYAN}sudo grep '^GF_SECURITY_ADMIN_PASSWORD=' ${PLATFORM_ENV}${RESET}"
echo
echo -e "  Datasources Prometheus e Loki já provisionados."
echo -e "  Importe dashboards prontos em Grafana → Dashboards → Import (por ID):"
echo -e "    • ${YELLOW}1860${RESET}  — Node Exporter Full (host)"
echo -e "    • ${YELLOW}19792${RESET} — cAdvisor (containers)"
echo -e "    • ${YELLOW}17346${RESET} — Traefik v3"
echo
warn "Aponte o DNS de ${GRAFANA_HOST} para o IP da VPS para o Traefik emitir o certificado."

step_done "Observabilidade (Grafana: ${GRAFANA_HOST})"
