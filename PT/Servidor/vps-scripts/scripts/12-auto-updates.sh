#!/bin/bash
# Seção 12 — Atualizações automáticas de segurança
#
# Atualizações de segurança são aplicadas sozinhas. Quando uma atualização exige
# reinício, ele acontece SOMENTE no horário fixo de Automatic-Reboot-Time (03:30):
# o unattended-upgrades agenda o reinício para essa hora e não reinicia em outro
# momento. Por isso a configuração efetiva é conferida ao final.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "12-auto-updates"

title "12. Atualizações automáticas de segurança"

REBOOT_TIME="03:30"

# ── unattended-upgrades ────────────────────────────────────────────────────
UPGRADES_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"
PERIODIC_CONF="/etc/apt/apt.conf.d/20auto-upgrades"
# Backups ficam FORA de apt.conf.d: o apt lê todo arquivo ali e ignora, com aviso,
# os que não terminam em .conf ('Ignoring file ... invalid filename extension').
BACKUP_DIR="/var/backups/vps-setup"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
BACKUP="${BACKUP_DIR}/50unattended-upgrades.bak.$(date +%Y%m%d%H%M%S)"

# Migra backups deixados em apt.conf.d por execuções anteriores (mesmo conteúdo, fora do apt).
shopt -s nullglob
for stray in /etc/apt/apt.conf.d/*.bak.*; do
    mv "$stray" "${BACKUP_DIR}/"
    warn "Backup antigo fora de apt.conf.d movido para ${BACKUP_DIR}."
done
shopt -u nullglob

info "Configurando unattended-upgrades (reinício automático só às ${REBOOT_TIME})..."
if [[ -f "$UPGRADES_CONF" ]]; then
    cp "$UPGRADES_CONF" "$BACKUP"
fi

cat > "$UPGRADES_CONF" <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
EOF

# ── Periodicidade ─────────────────────────────────────────────────────────
cat > "$PERIODIC_CONF" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ── Confere a configuração EFETIVA (a que o apt usa, depois de todos os arquivos) ─
# Um arquivo de outra origem sobrescrevendo o horário faria o reinício cair em
# outro momento; por isso o valor efetivo é verificado, não só o que escrevemos.
effective_reboot_time="$(apt-config dump 2>/dev/null \
    | sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\(.*\)";/\1/p' | tail -n1)"
effective_reboot="$(apt-config dump 2>/dev/null \
    | sed -n 's/^Unattended-Upgrade::Automatic-Reboot "\(.*\)";/\1/p' | tail -n1)"
[[ "$effective_reboot_time" == "$REBOOT_TIME" ]] \
    || die "Horário de reinício efetivo é '${effective_reboot_time:-vazio}', esperado ${REBOOT_TIME}."
[[ "$effective_reboot" == "true" ]] \
    || die "Automatic-Reboot efetivo é '${effective_reboot:-vazio}', esperado true."
log "Reinício automático efetivo: somente às ${REBOOT_TIME}."

# Validação de execução sem aplicar nada: --dry-run não instala pacotes nem reinicia.
# Um aviso de arquivo ignorado pelo apt também reprova a etapa.
command -v unattended-upgrade &>/dev/null || die "unattended-upgrade não instalado (apt install unattended-upgrades)."
DRY_LOG="$(mktemp)"
if ! unattended-upgrade --dry-run --debug >/dev/null 2>"$DRY_LOG"; then
    rm -f "$DRY_LOG"
    die "unattended-upgrade --dry-run falhou — configuração não validada."
fi
if grep -q "Ignoring file" "$DRY_LOG"; then
    grep "Ignoring file" "$DRY_LOG" | head -3
    rm -f "$DRY_LOG"
    die "O apt está ignorando arquivos de configuração (veja acima)."
fi
rm -f "$DRY_LOG"
log "unattended-upgrade --dry-run: configuração válida, sem arquivos ignorados."

info "Verificando serviço..."
systemctl is-enabled unattended-upgrades &>/dev/null && log "unattended-upgrades ativo." || \
    systemctl enable --now unattended-upgrades

step_done "Atualizações automáticas de segurança (reinício às ${REBOOT_TIME})"
