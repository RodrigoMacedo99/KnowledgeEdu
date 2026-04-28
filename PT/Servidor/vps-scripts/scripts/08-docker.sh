#!/bin/bash
# Seção 8 — Instalar e configurar o Docker com segurança

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "08-docker"

title "8. Instalação e configuração do Docker"

prompt ADMIN_USER "Nome do usuário admin" "admin"

# ── Instalar Docker ────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    already_done "Docker $(docker --version)"
else
    info "Baixando e instalando Docker via script oficial..."
    curl -fsSL https://get.docker.com | sh
fi

# ── Grupo docker para o admin ──────────────────────────────────────────────
if groups "$ADMIN_USER" | grep -qw docker; then
    already_done "Usuário '$ADMIN_USER' no grupo docker"
else
    info "Adicionando '$ADMIN_USER' ao grupo docker..."
    usermod -aG docker "$ADMIN_USER"
    warn "Faça logout/login para usar docker sem sudo."
fi

# ── daemon.json — bloquear iptables ───────────────────────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
if [[ -f "$DAEMON_JSON" ]] && grep -q '"iptables": false' "$DAEMON_JSON"; then
    already_done "daemon.json (iptables: false)"
else
    info "Configurando /etc/docker/daemon.json..."
    [[ -f "$DAEMON_JSON" ]] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak"
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
    log "Docker reiniciado com iptables=false"
fi

info "Docker version: $(docker --version)"
info "Docker Compose version: $(docker compose version)"

step_done "Docker"
