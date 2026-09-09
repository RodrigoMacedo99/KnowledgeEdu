#!/bin/bash
# Seção 8 — Instalar e configurar o Docker com segurança
#
# Além de instalar o Docker, esta etapa prepara o modelo multi-serviço:
#   • daemon.json com log rotativo e live-restore (containers sobrevivem a um
#     restart do daemon);
#   • as redes EXTERNAS compartilhadas 'edge' e 'observability', usadas pelo
#     Traefik (etapa 9) e pela observabilidade (etapa 19) e por cada serviço
#     (etapa 15).

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

# ── daemon.json ────────────────────────────────────────────────────────────
# Importante: neste modelo o Docker PRECISA gerenciar o iptables (padrão), pois
# o Traefik publica 80/443. O antigo 'iptables: false' impediria isso. A defesa
# contra exposição indevida vem de outra regra: as aplicações NÃO publicam
# portas no host (o Traefik as alcança pela rede 'edge'); o único serviço que
# publica em 0.0.0.0 é o Traefik (80/443, que é o que queremos público). O que
# precisar de porta de host (ex.: túnel de banco) publica só em 127.0.0.1.
DAEMON_JSON="/etc/docker/daemon.json"
if [[ -f "$DAEMON_JSON" ]] && grep -q '"live-restore": true' "$DAEMON_JSON"; then
    already_done "daemon.json"
else
    info "Configurando /etc/docker/daemon.json..."
    [[ -f "$DAEMON_JSON" ]] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak"
    cat > "$DAEMON_JSON" <<'EOF'
{
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker
    log "Docker reiniciado com daemon.json atualizado."
fi

# ── ufw-docker (defesa em profundidade) ────────────────────────────────────
# Faz as regras do UFW valerem também para portas publicadas por containers,
# fechando a brecha clássica "Docker ignora o UFW".
UFW_DOCKER="/usr/local/bin/ufw-docker"
if command -v ufw &>/dev/null && [[ ! -f "$UFW_DOCKER" ]]; then
    if confirm "Instalar ufw-docker para o UFW controlar também as portas do Docker?"; then
        info "Instalando ufw-docker..."
        curl -fsSL https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker \
            -o "$UFW_DOCKER" && chmod +x "$UFW_DOCKER"
        "$UFW_DOCKER" install && systemctl restart ufw
        log "ufw-docker instalado."
    fi
else
    [[ -f "$UFW_DOCKER" ]] && already_done "ufw-docker"
fi

# ── Redes externas compartilhadas ──────────────────────────────────────────
for net in edge observability; do
    if docker network inspect "$net" &>/dev/null; then
        already_done "Rede docker '$net'"
    else
        info "Criando rede externa '$net'..."
        docker network create "$net"
    fi
done

info "Docker version: $(docker --version)"
info "Docker Compose version: $(docker compose version)"

step_done "Docker (redes: edge, observability)"
