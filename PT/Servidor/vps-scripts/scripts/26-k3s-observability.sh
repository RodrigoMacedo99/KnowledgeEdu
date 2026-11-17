#!/bin/bash
# Seção 26 — Observabilidade no k3s (paridade com o modelo Docker)
#
# Instala, via Helm, o kube-prometheus-stack (Prometheus + Grafana + Alertmanager
# + node-exporter + kube-state-metrics) e, opcionalmente, Loki + Alloy para os
# logs de todos os pods. Tudo no namespace 'operacao'. O Grafana é exposto por
# IngressRoute do Traefik, com HTTPS via Let's Encrypt (etapa 25).
#
# Segredos: senha do Grafana e token/URL de alerta vão para Secrets do k3s, nunca
# para a linha de comando, para o values, nem para a tela.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"

require_root
init_log "26-k3s-observability"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS="$PLATFORM_NAMESPACE"
GRAFANA_SECRET="grafana-admin"
ALERT_SECRET="alertmanager-secrets"
ALERT_SECRET_DIR="/etc/alertmanager/secrets/${ALERT_SECRET}"

# Versões dos charts fixadas: atualizar deliberadamente, testando o render.
KPS_CHART_VERSION="93.4.0"
LOKI_CHART_VERSION="7.6.0"
ALLOY_CHART_VERSION="1.16.0"

title "26. Observabilidade no k3s"

command -v k3s  &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."
command -v helm &>/dev/null || die "Helm não instalado — rode a etapa 25 primeiro."
k3s kubectl -n kube-system get helmchartconfig traefik &>/dev/null \
    || warn "Traefik do k3s sem configuração ACME — o HTTPS do Grafana não será emitido (rode a etapa 25)."

# ── 1. Dados ───────────────────────────────────────────────────────────────
prompt GRAFANA_HOST "Domínio do Grafana (ex: grafana.seudominio.com)" ""

echo
echo -e "  ${YELLOW}1${RESET}) Webhook genérico (Slack/Discord/Teams/Google Chat)"
echo -e "  ${YELLOW}2${RESET}) Telegram (bot + chat)"
echo -e "  ${YELLOW}3${RESET}) Pular por agora"
prompt ALERT_CHOICE "Destino dos alertas" "3"

ALERT_WEBHOOK="" TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""
case "$ALERT_CHOICE" in
    1)
        prompt_secret ALERT_WEBHOOK "URL do webhook (não será exibida)"
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

# ── 2. Namespace e Secrets ─────────────────────────────────────────────────
ensure_namespace "$NS"

# A senha de administrador é gerada uma única vez: trocá-la depois exigiria mexer
# no banco do Grafana, e reexecutar a etapa não pode perder o acesso.
if k3s kubectl get secret "$GRAFANA_SECRET" -n "$NS" &>/dev/null; then
    already_done "Senha do Grafana (Secret ${GRAFANA_SECRET} mantido)"
else
    # shellcheck disable=SC2034  # lidas por k8s_secret_from_vars (indireção ${!var})
    GF_ADMIN_USER="admin"
    # shellcheck disable=SC2034  # idem
    GF_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    k8s_secret_from_vars "$GRAFANA_SECRET" "$NS" "admin-user=GF_ADMIN_USER" "admin-password=GF_ADMIN_PASSWORD"
    log "Senha de administrador do Grafana gravada no Secret ${GRAFANA_SECRET}."
fi

ALERT_KEY_SPEC=""
if [[ -n "$ALERT_WEBHOOK" ]]; then
    k8s_secret_from_vars "$ALERT_SECRET" "$NS" "webhook_url=ALERT_WEBHOOK"
    ALERT_KEY_SPEC="webhook"
elif [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    k8s_secret_from_vars "$ALERT_SECRET" "$NS" "telegram_bot_token=TELEGRAM_BOT_TOKEN"
    ALERT_KEY_SPEC="telegram"
fi

# ── 3. Repositórios Helm ───────────────────────────────────────────────────
info "Atualizando repositórios Helm (versões fixadas abaixo)..."
helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add --force-update grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

# ── 4. Values: template + destinos de alerta (só referências a arquivos de Secret) ─
# Escreve a seção 'alertmanager' com caminhos de arquivo, nunca com o valor do segredo.
write_alertmanager_values() {
    [[ -n "$ALERT_KEY_SPEC" ]] || return 0
    cat <<EOF

alertmanager:
  alertmanagerSpec:
    secrets:
      - ${ALERT_SECRET}
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
    if [[ "$ALERT_KEY_SPEC" == "webhook" ]]; then
        cat <<EOF
        webhook_configs:
          - url_file: '${ALERT_SECRET_DIR}/webhook_url'
            send_resolved: true
EOF
    else
        cat <<EOF
        telegram_configs:
          - bot_token_file: '${ALERT_SECRET_DIR}/telegram_bot_token'
            chat_id: ${TELEGRAM_CHAT_ID}
            api_url: 'https://api.telegram.org'
            parse_mode: 'HTML'
            send_resolved: true
EOF
    fi
}

VALUES="$(mktemp)"
sed "s|__GRAFANA_HOST__|${GRAFANA_HOST}|g" "${TEMPLATES_DIR}/k3s/values/monitoring.yaml" > "$VALUES"
write_alertmanager_values >> "$VALUES"

# ── 5. kube-prometheus-stack ───────────────────────────────────────────────
info "Instalando o kube-prometheus-stack ${KPS_CHART_VERSION} (pode demorar no primeiro pull)..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "$KPS_CHART_VERSION" -n "$NS" \
    -f "$VALUES" --wait --timeout 10m
rm -f "$VALUES"

# ── 6. Grafana exposto por IngressRoute (não por Ingress) ──────────────────
sed "s|__GRAFANA_HOST__|${GRAFANA_HOST}|g" "${TEMPLATES_DIR}/k3s/grafana-ingressroute.yaml" \
    | k3s kubectl apply -f - >/dev/null
log "Grafana publicado em https://${GRAFANA_HOST} (IngressRoute, HTTPS automático)."

# ── 7. Logs (opcional): Loki + Alloy ───────────────────────────────────────
echo
if confirm "Instalar Loki + Alloy para agregação de logs dos pods?"; then
    info "Instalando o Loki ${LOKI_CHART_VERSION} (SingleBinary)..."
    helm upgrade --install loki grafana/loki --version "$LOKI_CHART_VERSION" -n "$NS" \
        -f "${TEMPLATES_DIR}/k3s/values/loki.yaml" --wait --timeout 10m
    info "Instalando o Alloy ${ALLOY_CHART_VERSION} (coletor de logs)..."
    helm upgrade --install alloy grafana/alloy --version "$ALLOY_CHART_VERSION" -n "$NS" \
        -f "${TEMPLATES_DIR}/k3s/values/alloy.yaml" --wait --timeout 5m
fi

# ── 8. Resumo (a senha NÃO é exibida) ──────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Observabilidade no k3s ══${RESET}"
echo -e "  Grafana:  ${CYAN}https://${GRAFANA_HOST}${RESET}   Usuário: ${CYAN}admin${RESET}"
echo -e "  Senha:    no Secret ${CYAN}${GRAFANA_SECRET}${RESET} (namespace ${NS}). Para ler:"
echo -e "            ${CYAN}sudo k3s kubectl -n ${NS} get secret ${GRAFANA_SECRET} -o jsonpath='{.data.admin-password}' | base64 -d${RESET}"
echo -e "  Estado:   ${CYAN}sudo k3s kubectl get pods -n ${NS}${RESET}"
echo
warn "Aponte o DNS de ${GRAFANA_HOST} para o IP da VPS para o HTTPS sair no primeiro acesso."
warn "Para exigir 2FA no Grafana, rode a etapa 27 (Authelia)."

step_done "Observabilidade no k3s (Grafana: ${GRAFANA_HOST})"
