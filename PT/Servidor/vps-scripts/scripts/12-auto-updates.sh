#!/bin/bash
# Seção 12 — Atualizações automáticas de segurança
#
# Atualizações de segurança são instaladas todo dia, sozinhas. O REINÍCIO não é
# feito pelo unattended-upgrades: o Automatic-Reboot-Time dele só aceita horário
# diário, e o projeto decidiu reiniciar aos DOMINGOS às 03:00 (horário de Brasília).
# Por isso:
#   - unattended-upgrades instala as atualizações e NÃO reinicia;
#   - um timer do systemd roda todo domingo às 03:00 e reinicia SOMENTE se o
#     sistema marcar que precisa (/var/run/reboot-required).
# Tudo é conferido ao final: horário do sistema, configuração efetiva e timer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "12-auto-updates"

title "12. Atualizações automáticas de segurança"

TZ_EXPECTED="America/Sao_Paulo"
REBOOT_DAY="Sun"
REBOOT_TIME="03:00"
REBOOT_UNIT="reinicio-semanal"

# O timer usa o fuso do sistema. Sem o fuso certo, "03:00" cairia em outro horário.
current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[[ "$current_tz" == "$TZ_EXPECTED" ]] \
    || die "Fuso do sistema é '${current_tz:-desconhecido}', esperado ${TZ_EXPECTED}. Rode: sudo timedatectl set-timezone ${TZ_EXPECTED}"

# ── unattended-upgrades: instala, não reinicia ─────────────────────────────
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

info "Configurando unattended-upgrades (atualiza todo dia, sem reinício automático)..."
if [[ -f "$UPGRADES_CONF" ]]; then
    cp "$UPGRADES_CONF" "$BACKUP"
fi

cat > "$UPGRADES_CONF" <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Reinício NÃO é feito aqui: ver o timer reinicio-semanal (domingo 03:00).
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > "$PERIODIC_CONF" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ── Aviso de reinício necessário (fonte do /var/run/reboot-required) ──────
if ! dpkg -s update-notifier-common &>/dev/null; then
    info "Instalando update-notifier-common (gera o aviso de reinício necessário)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y update-notifier-common >/dev/null \
        || die "Falha ao instalar update-notifier-common."
fi

# ── Timer semanal: domingo 03:00, reinicia só se precisar ─────────────────
info "Criando o timer de reinício (${REBOOT_DAY} ${REBOOT_TIME}, só se necessário)..."
cat > "/etc/systemd/system/${REBOOT_UNIT}.service" <<'EOF'
[Unit]
Description=Reinício semanal, somente se o sistema pedir

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -f /var/run/reboot-required ]; then logger -t reinicio-semanal "reinício agendado: atualizações pendentes"; /bin/systemctl reboot; else logger -t reinicio-semanal "sem reinício necessário"; fi'
EOF

cat > "/etc/systemd/system/${REBOOT_UNIT}.timer" <<EOF
[Unit]
Description=Reinício semanal aos domingos às ${REBOOT_TIME}

[Timer]
OnCalendar=${REBOOT_DAY} *-*-* ${REBOOT_TIME}:00
# Sem recuperação: se o servidor estava desligado no horário, não reinicia depois.
Persistent=false
Unit=${REBOOT_UNIT}.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${REBOOT_UNIT}.timer" >/dev/null

# ── Confere a configuração EFETIVA (a que o apt usa, depois de todos os arquivos) ─
# Um arquivo de outra origem reativando o reinício faria o servidor reiniciar em
# outro momento; por isso o valor efetivo é verificado, não só o que escrevemos.
effective_reboot="$(apt-config dump 2>/dev/null \
    | sed -n 's/^Unattended-Upgrade::Automatic-Reboot "\(.*\)";/\1/p' | tail -n1)"
[[ "$effective_reboot" == "false" ]] \
    || die "Automatic-Reboot efetivo é '${effective_reboot:-vazio}', esperado false (o reinício é só no timer)."

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

# Timer ativo e com o próximo disparo no domingo às 03:00.
systemctl is-active --quiet "${REBOOT_UNIT}.timer" || die "Timer ${REBOOT_UNIT}.timer não está ativo."
next_run="$(systemctl show "${REBOOT_UNIT}.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
log "Próximo reinício agendado: ${next_run:-desconhecido} (esperado: domingo 03:00)."

info "Verificando serviço..."
systemctl is-enabled unattended-upgrades &>/dev/null && log "unattended-upgrades ativo." || \
    systemctl enable --now unattended-upgrades

step_done "Atualizações automáticas (instalação diária; reinício domingos às ${REBOOT_TIME})"
