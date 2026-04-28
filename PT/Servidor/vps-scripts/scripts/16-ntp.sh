#!/bin/bash
# Seção 16 — NTP: Sincronização de tempo com Chrony
#
# Servidores precisam de relógio preciso para:
#   - Validade de certificados SSL (Let's Encrypt rejeita desvios > 5 min)
#   - Timestamps corretos em logs e auditorias
#   - Execução correta de tarefas cron
#
# Fonte complementar: Redes II — SENAI CIMATEC (NTP porta 123/UDP)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "16-ntp"

title "16. Sincronização de tempo (NTP / Chrony)"

# ── Timezone ───────────────────────────────────────────────────────────────
CURRENT_TZ=$(cat /etc/timezone 2>/dev/null || echo "não definido")
info "Timezone atual: ${CURRENT_TZ}"

echo
if confirm "Reconfigurar timezone?"; then
    dpkg-reconfigure tzdata
fi

# ── Instalar Chrony ────────────────────────────────────────────────────────
if command -v chronyd &>/dev/null; then
    already_done "Chrony $(chronyd --version 2>&1 | head -1)"
else
    info "Instalando chrony (substituto moderno do ntpd)..."
    DEBIAN_FRONTEND=noninteractive apt install -y chrony
fi

# ── Configurar servidores NTP ─────────────────────────────────────────────
CHRONY_CONF="/etc/chrony/chrony.conf"

if grep -q "pool.ntp.br" "$CHRONY_CONF" 2>/dev/null; then
    already_done "Servidores NTP brasileiros já configurados"
else
    info "Adicionando servidores NTP brasileiros ao chrony.conf..."
    # Insere servidores brasileiros antes do pool padrão Ubuntu
    sed -i '1s/^/# Servidores NTP brasileiros (pool.ntp.br)\npool pool.ntp.br iburst maxsources 4\n\n/' "$CHRONY_CONF"
fi

# ── Ativar e verificar ────────────────────────────────────────────────────
info "Habilitando e reiniciando chrony..."
systemctl enable chrony
systemctl restart chrony

info "Aguardando sincronização inicial (10s)..."
sleep 10

info "Status da sincronização:"
chronyc tracking 2>/dev/null || warn "Chrony ainda sincronizando — aguarde alguns minutos."

echo
info "Servidores NTP em uso:"
chronyc sources -v 2>/dev/null || true

echo
info "Data e hora atual do servidor:"
date

# ── Liberar porta NTP no UFW (opcional — só se esta VPS for servidor NTP) ─
echo
warn "Por padrão a porta NTP (123/UDP) fica FECHADA — correto para cliente NTP."
warn "Só libere se esta VPS for distribuir hora para outros servidores na rede."
if confirm "Liberar porta 123/UDP no UFW (modo servidor NTP)?"; then
    ufw allow 123/udp comment 'NTP server'
    log "Porta 123/UDP liberada no UFW."
fi

step_done "NTP / Chrony (timezone: $(cat /etc/timezone))"
