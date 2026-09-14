#!/bin/bash
# Seção 26 — Observabilidade no k3s (paridade com o modelo Docker)
#
# Instala, via Helm, o kube-prometheus-stack (Prometheus + Grafana + Alertmanager
# + node-exporter + kube-state-metrics) e, opcionalmente, Loki + Alloy para os
# logs de todos os pods. Grafana é exposto por Ingress com HTTPS (cert-manager).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "26-k3s-observability"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="observability"

title "26. Observabilidade no k3s"

command -v k3s  &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."
command -v helm &>/dev/null || die "Helm não instalado — rode a etapa 25 primeiro."
k3s kubectl get clusterissuer letsencrypt &>/dev/null || warn "ClusterIssuer 'letsencrypt' ausente — o HTTPS do Grafana só sai com o cert-manager (etapa 25)."

# ── 1. Dados ───────────────────────────────────────────────────────────────
prompt GRAFANA_HOST "Domínio do Grafana (ex: grafana.seudominio.com)" ""
GRAFANA_PASS="$(openssl rand -base64 24)"

echo
echo -e "  ${YELLOW}1${RESET}) Webhook genérico (Slack/Discord/Teams/Google Chat)"
echo -e "  ${YELLOW}2${RESET}) Telegram (bot + chat)"
echo -e "  ${YELLOW}3${RESET}) Pular por agora"
prompt ALERT_CHOICE "Destino dos alertas" "3"

ALERT_WEBHOOK="" TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""
case "$ALERT_CHOICE" in
    1)
        prompt ALERT_WEBHOOK "URL do webhook" "$(get_config ALERT_WEBHOOK_URL)"
        save_config ALERT_WEBHOOK_URL "$ALERT_WEBHOOK"
        ;;
    2)
        info "Crie um bot em https://t.me/BotFather (comando /newbot) e copie o token."
        prompt_secret TELEGRAM_BOT_TOKEN "Token do bot do Telegram"
        info "Chat ID: mande uma mensagem ao bot e acesse https://api.telegram.org/bot<TOKEN>/getUpdates"
        info "(ou fale com @userinfobot no Telegram para pegar o seu chat_id pessoal)."
        prompt TELEGRAM_CHAT_ID "Chat ID do Telegram (número — negativo se for grupo)" "$(get_config TELEGRAM_CHAT_ID)"
        save_config TELEGRAM_CHAT_ID "$TELEGRAM_CHAT_ID"
        ;;
    *) info "Alertas sem destino por enquanto." ;;
esac

# ── 2. Repositórios Helm ───────────────────────────────────────────────────
info "Adicionando repositórios Helm..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

# ── 3. Values (renderiza o domínio; anexa o webhook se houver) ─────────────
VALUES="$(mktemp)"
sed "s|__GRAFANA_HOST__|${GRAFANA_HOST}|g" "${TEMPLATES_DIR}/k3s/values/monitoring.yaml" > "$VALUES"
if [[ -n "$ALERT_WEBHOOK" || ( -n "$TELEGRAM_CHAT_ID" && -n "$TELEGRAM_BOT_TOKEN" ) ]]; then
    {
        cat <<EOF

alertmanager:
  config:
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
          - url: '${ALERT_WEBHOOK}'
            send_resolved: true
EOF
        else
            cat <<EOF
        telegram_configs:
          - bot_token: '${TELEGRAM_BOT_TOKEN}'
            chat_id: ${TELEGRAM_CHAT_ID}
            api_url: 'https://api.telegram.org'
            parse_mode: 'HTML'
            send_resolved: true
EOF
        fi
    } >> "$VALUES"
fi

# ── 4. kube-prometheus-stack ───────────────────────────────────────────────
info "Instalando o kube-prometheus-stack (pode demorar no primeiro pull)..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n "$NS" --create-namespace \
    -f "$VALUES" \
    --set grafana.adminPassword="${GRAFANA_PASS}" \
    --wait --timeout 10m \
    || warn "Instalação retornou aviso — verifique com 'helm -n ${NS} status monitoring'."
rm -f "$VALUES"

# ── 5. Logs (opcional): Loki + Alloy ───────────────────────────────────────
echo
if confirm "Instalar Loki + Alloy para agregação de logs dos pods?"; then
    info "Instalando o Loki (SingleBinary)..."
    helm upgrade --install loki grafana/loki -n "$NS" -f "${TEMPLATES_DIR}/k3s/values/loki.yaml" \
        --wait --timeout 10m || warn "Loki retornou aviso — confira a versão do chart e os values."
    info "Instalando o Alloy (coletor de logs)..."
    helm upgrade --install alloy grafana/alloy -n "$NS" -f "${TEMPLATES_DIR}/k3s/values/alloy.yaml" \
        --wait --timeout 5m || warn "Alloy retornou aviso — confira RBAC/valores do chart."
fi

# ── 6. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Observabilidade no k3s ══${RESET}"
echo -e "  Grafana:  ${CYAN}https://${GRAFANA_HOST}${RESET}"
echo -e "  Usuário:  ${CYAN}admin${RESET}   Senha: ${CYAN}${GRAFANA_PASS}${RESET}  (guarde-a)"
echo -e "  Estado:   ${CYAN}sudo k3s kubectl get pods -n ${NS}${RESET}"
echo
warn "Aponte o DNS de ${GRAFANA_HOST} para o IP da VPS para o cert-manager emitir o HTTPS."
warn "Se o Grafana ainda pedir 2FA, proteja o Ingress com o Authelia (etapa 27)."

step_done "Observabilidade no k3s (Grafana: ${GRAFANA_HOST})"
