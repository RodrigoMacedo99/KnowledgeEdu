#!/bin/bash
# Seção 1 — Acesso inicial e atualização do sistema

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_ubuntu
init_log "01-update"

title "1. Atualização do sistema e pacotes essenciais"

info "Atualizando lista de pacotes..."
apt update -qq

info "Aplicando upgrades disponíveis..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq

info "Instalando pacotes essenciais..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    curl git ufw nano htop \
    fail2ban unattended-upgrades \
    apt-listchanges logwatch auditd

step_done "Atualização do sistema"
