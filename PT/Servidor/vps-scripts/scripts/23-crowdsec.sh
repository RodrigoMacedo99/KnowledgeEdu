#!/bin/bash
# Seção 23 — CrowdSec (IPS colaborativo)
#
# CrowdSec lê os logs do SSH (journald) e do Traefik (arquivo de access log, gravado
# pelo HelmChartConfig base/edge/traefik-config.yaml do repositório infra). Detecta
# comportamentos maliciosos e um "bouncer" bane os IPs no firewall. Diferente do
# Fail2Ban, ele também consome uma blocklist COLABORATIVA da comunidade.
#
# Instalação host-level (apt). O projeto não usa Docker.
#
# Os IPs da equipe ficam numa allowlist, para que a equipe nunca seja banida por
# erro de senha ou de chave.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "23-crowdsec"

title "23. CrowdSec (IPS colaborativo)"

TRAEFIK_LOG_DIR="/var/log/traefik"
TRAEFIK_LOG="${TRAEFIK_LOG_DIR}/access.log"
BOUNCER_CONF="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"

# ── 1. Instalar CrowdSec ───────────────────────────────────────────────────
if command -v cscli &>/dev/null; then
    already_done "CrowdSec $(cscli version 2>/dev/null | head -1)"
else
    info "Adicionando o repositório do CrowdSec..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash \
        || die "Falha ao configurar o repositório do CrowdSec."
    info "Instalando o CrowdSec..."
    DEBIAN_FRONTEND=noninteractive apt install -y crowdsec || die "Falha ao instalar o CrowdSec."
fi

# ── 2. Bouncer de firewall (aplica os banimentos no iptables) ──────────────
if dpkg -l 2>/dev/null | grep -q crowdsec-firewall-bouncer; then
    already_done "Firewall bouncer"
else
    info "Instalando o firewall bouncer..."
    DEBIAN_FRONTEND=noninteractive apt install -y crowdsec-firewall-bouncer-iptables \
        || die "Falha ao instalar o bouncer: apt install crowdsec-firewall-bouncer-iptables"
fi

# O tráfego HTTP/HTTPS chega ao Traefik do k3s por encaminhamento (cadeia FORWARD),
# não pela INPUT. Um IP banido só deixa de entrar se o bouncer atuar nas duas cadeias.
[[ -f "$BOUNCER_CONF" ]] || die "Arquivo do bouncer não encontrado: ${BOUNCER_CONF}. Confira a instalação do bouncer."
if grep -qE '^iptables_chains:' "$BOUNCER_CONF"; then
    # Reescreve só o bloco iptables_chains: remove os itens antigos e põe INPUT e FORWARD.
    tmp_conf="$(mktemp)"
    awk '
        /^iptables_chains:/ { print; print "  - INPUT"; print "  - FORWARD"; skip = 1; next }
        skip && /^[[:space:]]*-[[:space:]]/ { next }
        { skip = 0; print }
    ' "$BOUNCER_CONF" > "$tmp_conf"
    cat "$tmp_conf" > "$BOUNCER_CONF"
    rm -f "$tmp_conf"
else
    printf '\niptables_chains:\n  - INPUT\n  - FORWARD\n' >> "$BOUNCER_CONF"
fi
# Confere a configuração gravada: as duas cadeias precisam estar lá.
awk '/^iptables_chains:/{f=1; next} f && /^[[:space:]]*-[[:space:]]/{print; next} {f=0}' "$BOUNCER_CONF" \
    | grep -qx "  - FORWARD" && grep -q "  - INPUT" "$BOUNCER_CONF" \
    || die "Não consegui gravar INPUT e FORWARD em ${BOUNCER_CONF}."
log "Bouncer configurado para INPUT e FORWARD."

# ── 3. Coleções (regras de detecção) ───────────────────────────────────────
info "Instalando as coleções (sshd, linux, traefik)..."
cscli collections install crowdsecurity/sshd    >/dev/null 2>&1 || warn "Não instalei a coleção sshd."
cscli collections install crowdsecurity/linux   >/dev/null 2>&1 || warn "Não instalei a coleção linux."
cscli collections install crowdsecurity/traefik >/dev/null 2>&1 || warn "Não instalei a coleção traefik."

# ── 4. Aquisição: SSH (journald) e Traefik (arquivo) ───────────────────────
mkdir -p /etc/crowdsec/acquis.d
cat > /etc/crowdsec/acquis.d/sshd.yaml <<'EOF'
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"
labels:
  type: syslog
EOF

# O log do Traefik é gravado pelo Traefik do k3s (HelmChartConfig do infra) em
# /var/log/traefik/access.log. A pasta é criada aqui para o caso de o Traefik ainda
# não ter subido.
mkdir -p "$TRAEFIK_LOG_DIR"
cat > /etc/crowdsec/acquis.d/traefik.yaml <<EOF
source: file
filenames:
  - ${TRAEFIK_LOG}
labels:
  type: traefik
EOF
log "Aquisição configurada: SSH (journald) e Traefik (${TRAEFIK_LOG})."

# Rotação do log do Traefik: sem isso o arquivo cresce sem limite.
# copytruncate, porque o Traefik não reabre o arquivo sozinho após a rotação.
cat > /etc/logrotate.d/traefik-access <<EOF
${TRAEFIK_LOG} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
log "Rotação do log do Traefik configurada (diária, 7 arquivos)."

# ── 5. Allowlist da equipe ─────────────────────────────────────────────────
# Usa a mesma lista de IPs da etapa 5 (UFW). Sem ela, a equipe pode se banir.
TEAM_IPS="$(get_config TEAM_IPS)"
if [[ -z "$TEAM_IPS" ]]; then
    warn "TEAM_IPS não definido. Rode a etapa 5 antes, senão a equipe pode ser banida."
else
    mkdir -p /etc/crowdsec/parsers/s02-enrich
    {
        echo "name: cimatec/equipe-allowlist"
        echo "description: IPs da equipe, nunca banidos pelo CrowdSec"
        echo "whitelist:"
        echo "  reason: \"equipe\""
        echo "  ip:"
        for ip in $TEAM_IPS; do
            # Só IP único. CIDR não entra nesta lista.
            [[ "$ip" == */* ]] && continue
            echo "    - \"${ip}\""
        done
    } > /etc/crowdsec/parsers/s02-enrich/equipe-allowlist.yaml
    log "Allowlist da equipe gravada (IPs únicos de TEAM_IPS)."
    if [[ "$TEAM_IPS" == *"/"* ]]; then
        warn "Há CIDR em TEAM_IPS: a allowlist aceita só IPs únicos. Ajuste se precisar."
    fi
fi

# ── 6. Reiniciar e habilitar ───────────────────────────────────────────────
systemctl enable crowdsec >/dev/null 2>&1 || true
systemctl restart crowdsec || die "Falha ao reiniciar o crowdsec. Veja 'journalctl -u crowdsec' e 'sudo crowdsec -t'."
systemctl enable crowdsec-firewall-bouncer >/dev/null 2>&1 || true
systemctl restart crowdsec-firewall-bouncer || warn "Falha ao reiniciar o bouncer. Veja 'journalctl -u crowdsec-firewall-bouncer'."

# ── 7. Conferências ────────────────────────────────────────────────────────
systemctl is-active --quiet crowdsec || die "crowdsec não está ativo após o restart."
systemctl is-active --quiet crowdsec-firewall-bouncer || warn "crowdsec-firewall-bouncer não está ativo."
if cscli metrics show acquisition 2>/dev/null | grep -q "ssh"; then
    log "CrowdSec está lendo o SSH."
else
    warn "Ainda não vejo o SSH nas métricas. Confira: sudo cscli metrics show acquisition"
fi
if [[ -s "$TRAEFIK_LOG" ]]; then
    log "Log do Traefik presente. CrowdSec deve ler o tráfego HTTP."
else
    warn "Ainda sem ${TRAEFIK_LOG}. Ele aparece depois que o HelmChartConfig do Traefik for aplicado e houver tráfego."
fi
if iptables -S 2>/dev/null | grep -q "CROWDSEC"; then
    log "Cadeia do CrowdSec presente no iptables."
else
    warn "Não vejo a cadeia do CrowdSec no iptables. Confira: sudo iptables -S | grep -i crowdsec"
fi

# ── 8. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ CrowdSec ativo ══${RESET}"
echo -e "  Ver decisões (bans):   ${CYAN}sudo cscli decisions list${RESET}"
echo -e "  Ver alertas:           ${CYAN}sudo cscli alerts list${RESET}"
echo -e "  Ver métricas:          ${CYAN}sudo cscli metrics${RESET}"
echo -e "  Coleções instaladas:   ${CYAN}sudo cscli collections list${RESET}"
echo
info "Opcional: registre-se no console (cscli console enroll) para a blocklist colaborativa completa."

step_done "CrowdSec (SSH e Traefik; bouncer em INPUT e FORWARD; allowlist da equipe)"
