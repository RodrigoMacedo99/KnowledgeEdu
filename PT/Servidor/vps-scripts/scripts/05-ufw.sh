#!/bin/bash
# Seção 5 — Firewall com UFW

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "05-ufw"

title "5. Configuração do Firewall (UFW)"

prompt SSH_PORT "Porta SSH configurada" "2222"

info "Definindo política padrão: bloquear entradas, permitir saídas..."
ufw default deny incoming
ufw default allow outgoing

info "Liberando SSH na porta ${SSH_PORT}..."
ufw allow "${SSH_PORT}/tcp" comment 'SSH'

info "Liberando HTTP (80) e HTTPS (443)..."
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# ── PostgreSQL — apenas IP admin (opcional) ────────────────────────────────
echo
if confirm "Liberar porta PostgreSQL (5432) para um IP específico?"; then
    prompt ADMIN_IP "Seu IP público (deixe vazio para pular)"
    if [[ -n "${ADMIN_IP:-}" ]]; then
        ufw allow from "$ADMIN_IP" to any port 5432 proto tcp comment 'PostgreSQL admin'
        log "PostgreSQL liberado para $ADMIN_IP"
    fi
fi

# ── Ativar ─────────────────────────────────────────────────────────────────
echo
warn "O UFW será ativado agora. Certifique-se de que a porta SSH ${SSH_PORT} está correta."
if confirm "Ativar o firewall?"; then
    ufw --force enable
    log "UFW ativo."
else
    warn "UFW não ativado — execute manualmente: sudo ufw enable"
fi

info "Regras ativas:"
ufw status verbose

# ── Impedir que o Docker contorne o UFW ───────────────────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
if command -v docker &>/dev/null; then
    if [[ -f "$DAEMON_JSON" ]] && grep -q '"iptables": false' "$DAEMON_JSON"; then
        already_done "daemon.json (iptables: false)"
    else
        info "Configurando Docker para não contornar o UFW..."
        if [[ -f "$DAEMON_JSON" ]]; then
            cp "$DAEMON_JSON" "${DAEMON_JSON}.bak"
        fi
        cat > "$DAEMON_JSON" <<'EOF'
{
  "iptables": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
        systemctl restart docker
        log "Docker reconfigurado: iptables=false"
    fi
else
    info "Docker não instalado ainda — a configuração de iptables será feita na etapa 8."
fi

step_done "Firewall UFW"
