#!/bin/bash
# Seção 23 — CrowdSec (IPS colaborativo)
#
# CrowdSec lê os logs (SSH e, opcionalmente, Traefik), detecta comportamentos
# maliciosos e um "bouncer" bane os IPs no firewall. Diferente do Fail2Ban, ele
# também consome uma blocklist COLABORATIVA da comunidade — IPs já conhecidos por
# atacar outros servidores são bloqueados preventivamente.
#
# Instalação host-level (apt), que é a forma mais estável. Roda como root, então
# lê o socket do Docker diretamente para a aquisição do Traefik (opcional).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "23-crowdsec"

title "23. CrowdSec (IPS colaborativo)"

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
        || warn "Falha ao instalar o bouncer — instale manualmente: apt install crowdsec-firewall-bouncer-iptables"
fi

# ── 3. Coleções (regras de detecção) ───────────────────────────────────────
info "Garantindo as coleções base (sshd, linux)..."
cscli collections install crowdsecurity/sshd  >/dev/null 2>&1 || true
cscli collections install crowdsecurity/linux >/dev/null 2>&1 || true

# ── 4. Aquisição do Traefik (opcional) ─────────────────────────────────────
echo
if confirm "Também monitorar os logs do Traefik (detecta ataques HTTP)?"; then
    prompt TRAEFIK_CONTAINER "Padrão do nome do container do Traefik (regex)" "traefik"
    mkdir -p /etc/crowdsec/acquis.d
    cat > /etc/crowdsec/acquis.d/traefik.yaml <<EOF
source: docker
container_name_regexp:
  - "${TRAEFIK_CONTAINER}"
labels:
  type: traefik
EOF
    cscli collections install crowdsecurity/traefik >/dev/null 2>&1 || warn "Não instalei a coleção traefik — verifique com 'cscli collections list'."
    log "Aquisição do Traefik configurada."
    warn "Se o restart do crowdsec falhar logo abaixo, confira o arquivo gerado:"
    warn "  sudo crowdsec -t   # valida a configuração sem reiniciar o serviço"
fi

# ── 5. Reiniciar e habilitar ───────────────────────────────────────────────
systemctl enable crowdsec >/dev/null 2>&1 || true
systemctl restart crowdsec || warn "Falha ao reiniciar o crowdsec — veja 'journalctl -u crowdsec'."
systemctl restart crowdsec-firewall-bouncer >/dev/null 2>&1 || true

# ── 6. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ CrowdSec ativo ══${RESET}"
echo -e "  Ver decisões (bans):   ${CYAN}sudo cscli decisions list${RESET}"
echo -e "  Ver alertas:           ${CYAN}sudo cscli alerts list${RESET}"
echo -e "  Ver métricas:          ${CYAN}sudo cscli metrics${RESET}"
echo -e "  Coleções instaladas:   ${CYAN}sudo cscli collections list${RESET}"
echo
info "Opcional: registre-se no console (cscli console enroll) para a blocklist colaborativa completa."
warn "O bouncer usa iptables — convive com o UFW/ufw-docker, mas confira 'cscli decisions list' após uns minutos."

step_done "CrowdSec (IPS colaborativo)"
