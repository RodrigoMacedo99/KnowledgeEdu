#!/bin/bash
# Seção 4 — Proteção contra força bruta com Fail2Ban

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "04-fail2ban"

title "4. Configuração do Fail2Ban"

prompt SSH_PORT  "Porta SSH configurada" "2222"
prompt ADMIN_IP  "Seu IP público (será ignorado pelo Fail2Ban — rode 'curl ifconfig.me' no seu PC)" ""

JAIL_LOCAL="/etc/fail2ban/jail.local"

if [[ -f "$JAIL_LOCAL" ]]; then
    already_done "jail.local"
else
    info "Criando $JAIL_LOCAL..."

    IGNOREIP="127.0.0.1/8 ::1"
    [[ -n "${ADMIN_IP:-}" ]] && IGNOREIP="${IGNOREIP} ${ADMIN_IP}"

    cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd
# IPs nunca banidos — inclui o IP do administrador
ignoreip = ${IGNOREIP}

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
maxretry = 5
bantime  = 86400
EOF
fi

info "Habilitando e reiniciando Fail2Ban..."
systemctl enable fail2ban
systemctl restart fail2ban

info "Status atual:"
fail2ban-client status 2>/dev/null || warn "Fail2Ban ainda inicializando — aguarde alguns segundos."

step_done "Fail2Ban (porta SSH: ${SSH_PORT})"
