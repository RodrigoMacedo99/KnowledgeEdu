#!/bin/bash
# Seção 14 — Hardening contínuo do servidor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "14-hardening"

title "14. Hardening contínuo do servidor"

# ── 14.1 Parâmetros de rede do kernel ─────────────────────────────────────
SYSCTL_CONF="/etc/sysctl.d/99-security-hardening.conf"
if [[ -f "$SYSCTL_CONF" ]]; then
    already_done "sysctl hardening"
else
    info "Aplicando hardening de parâmetros de rede do kernel..."
    cat > "$SYSCTL_CONF" <<'EOF'
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
EOF
    sysctl --system -q
    log "Parâmetros de kernel aplicados."
fi

# ── 14.2 Auditoria sudo ───────────────────────────────────────────────────
SUDOERS_DROP="/etc/sudoers.d/security-audit"
if [[ -f "$SUDOERS_DROP" ]]; then
    already_done "Auditoria sudo"
else
    info "Configurando auditoria e timeout do sudo..."
    cat > "$SUDOERS_DROP" <<'EOF'
Defaults timestamp_timeout=5
Defaults logfile="/var/log/sudo.log"
EOF
    chmod 440 "$SUDOERS_DROP"
    touch /var/log/sudo.log
    chmod 600 /var/log/sudo.log
    log "Auditoria sudo ativa — log em /var/log/sudo.log"
fi

# ── 14.3 AIDE — integridade de arquivos ──────────────────────────────────
if command -v aide &>/dev/null; then
    already_done "AIDE instalado"
else
    if confirm "Instalar AIDE (controle de integridade de arquivos)?"; then
        info "Instalando AIDE..."
        DEBIAN_FRONTEND=noninteractive apt install -y aide
        info "Gerando baseline do AIDE (pode demorar alguns minutos)..."
        aideinit
        cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
        log "Baseline AIDE gerado. Rode 'aide --check' periodicamente."
    fi
fi

# ── 14.4 Rotina de segurança semanal ─────────────────────────────────────
echo
title "Rotina de segurança semanal"

info "Usuários com shell ativo:"
getent passwd | grep -E '/bin/bash|/bin/sh' | awk -F: '{print $1, $7}'

echo
info "Portas expostas:"
ss -tulpen

echo
info "Status do Fail2Ban:"
fail2ban-client status sshd 2>/dev/null

echo
info "Imagens Docker em uso:"
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}" 2>/dev/null || warn "Docker não acessível."

step_done "Hardening contínuo"
