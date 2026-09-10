#!/bin/bash
# Seção 7 — Estrutura de pastas e permissões (genérica)
#
# A VPS hospeda MÚLTIPLOS serviços. Esta etapa não conhece nenhum projeto
# específico: ela só prepara a árvore base que todo o resto usa —
#   /opt/platform  → infraestrutura compartilhada (Traefik + observabilidade)
#   /opt/apps      → um subdiretório por serviço (criado depois pela etapa 15)
# Projetos concretos entram pela etapa 15; aqui é só o alicerce.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "07-folder-structure"

title "7. Estrutura de pastas e permissões"

APPS_DIR="/opt/apps"
PLATFORM_DIR="/opt/platform"

# ── Grupo compartilhado das aplicações ─────────────────────────────────────
if getent group webapps &>/dev/null; then
    already_done "Grupo webapps"
else
    info "Criando grupo webapps..."
    groupadd webapps
fi

# ── /opt/apps — raiz de todos os serviços ──────────────────────────────────
if [[ -d "$APPS_DIR" ]]; then
    already_done "Pasta $APPS_DIR"
else
    info "Criando $APPS_DIR..."
    mkdir -p "$APPS_DIR"
fi
# root é dono, webapps pode entrar/ler. Cada projeto (etapa 15) recebe seu
# próprio dono e permissões isoladas dentro daqui.
chown root:webapps "$APPS_DIR"
chmod 750 "$APPS_DIR"

# ── /opt/platform — infra compartilhada (Traefik, observabilidade) ─────────
# Se o grupo docker existir (caminho Docker), ele é o grupo dono para o
# 'docker compose --env-file' ler o .env; no caminho k3s (sem Docker), root:root.
PLATFORM_GROUP="root"
getent group docker &>/dev/null && PLATFORM_GROUP="docker"

if [[ -d "$PLATFORM_DIR" ]]; then
    already_done "Pasta $PLATFORM_DIR"
else
    info "Criando $PLATFORM_DIR (edge/ e observability/)..."
    mkdir -p "$PLATFORM_DIR/edge" "$PLATFORM_DIR/observability"
fi
chown -R "root:${PLATFORM_GROUP}" "$PLATFORM_DIR"
chmod 750 "$PLATFORM_DIR"

# ── .env da plataforma (segredos de Traefik/Grafana) ───────────────────────
PLATFORM_ENV="${PLATFORM_DIR}/.env"
if [[ -f "$PLATFORM_ENV" ]]; then
    already_done ".env da plataforma"
else
    info "Criando ${PLATFORM_ENV} (preenchido pelas etapas 9 e 19)..."
    touch "$PLATFORM_ENV"
    chown "root:${PLATFORM_GROUP}" "$PLATFORM_ENV"
    # 640: só root escreve; o grupo lê (docker compose --env-file, quando houver).
    chmod 640 "$PLATFORM_ENV"
fi

echo
info "Estrutura criada:"
echo -e "  ${CYAN}${PLATFORM_DIR}${RESET}  → infra compartilhada (etapas 9 e 19)"
echo -e "  ${CYAN}${APPS_DIR}${RESET}      → serviços (etapa 15)"
echo
ls -la /opt/ | grep -E 'apps|platform' || true

step_done "Estrutura de pastas (/opt/apps, /opt/platform)"
