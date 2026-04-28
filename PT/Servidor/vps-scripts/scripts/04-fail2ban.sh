#!/bin/bash
# Seção 4 — Proteção contra força bruta com Fail2Ban

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "04-fail2ban"

title "4. Configuração do Fail2Ban"

prompt SSH_PORT "Porta SSH configurada" "2222"

JAIL_LOCAL="/etc/fail2ban/jail.local"

if [[ -f "$JAIL_LOCAL" ]]; then
    already_done "jail.local"
else
    info "Criando $JAIL_LOCAL..."
    cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 86400
EOF
fi

info "Habilitando e reiniciando Fail2Ban..."
systemctl enable fail2ban
systemctl restart fail2ban

info "Status atual:"
fail2ban-client status 2>/dev/null || warn "Fail2Ban ainda inicializando — aguarde alguns segundos."

step_done "Fail2Ban (porta SSH: ${SSH_PORT})"
