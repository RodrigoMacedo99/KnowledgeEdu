#!/bin/bash
# Seção 12 — Atualizações automáticas de segurança

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "12-auto-updates"

title "12. Atualizações automáticas de segurança"

# ── unattended-upgrades ────────────────────────────────────────────────────
UPGRADES_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
BACKUP="${UPGRADES_CONF}.bak.$(date +%Y%m%d%H%M%S)"

info "Configurando unattended-upgrades..."
cp "$UPGRADES_CONF" "$BACKUP" 2>/dev/null || true

cat > "$UPGRADES_CONF" <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF

# ── Periodicidade ─────────────────────────────────────────────────────────
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

info "Verificando serviço..."
systemctl is-enabled unattended-upgrades &>/dev/null && log "unattended-upgrades ativo." || \
    systemctl enable --now unattended-upgrades

step_done "Atualizações automáticas de segurança"
