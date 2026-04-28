#!/bin/bash
# Seção 7 — Estrutura de pastas e permissões

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "07-folder-structure"

title "7. Estrutura de pastas e permissões"

PROJECT_NAME="sql-challenge"
SERVICE_USER="sqlchallenge"
PROJECT_DIR="/opt/apps/${PROJECT_NAME}"

# ── Criar pasta do projeto ─────────────────────────────────────────────────
if [[ -d "$PROJECT_DIR" ]]; then
    already_done "Pasta $PROJECT_DIR"
else
    info "Criando $PROJECT_DIR..."
    mkdir -p "$PROJECT_DIR"
fi

info "Aplicando dono e permissões em $PROJECT_DIR..."
chown "${SERVICE_USER}:webapps" "$PROJECT_DIR"
chmod 750 "$PROJECT_DIR"

# ── Clonar repositório (opcional) ─────────────────────────────────────────
if [[ ! -d "$PROJECT_DIR/backend" ]]; then
    echo
    if confirm "Clonar repositório do SQL Challenge agora?"; then
        prompt REPO_URL "URL do repositório git"
        info "Clonando como $SERVICE_USER..."
        sudo -u "$SERVICE_USER" git clone "$REPO_URL" "$PROJECT_DIR/backend"
        chown -R "${SERVICE_USER}:webapps" "$PROJECT_DIR/backend"
        chmod 750 "$PROJECT_DIR/backend"
    else
        warn "Clone pulado — faça manualmente:"
        warn "  sudo -u ${SERVICE_USER} git clone URL ${PROJECT_DIR}/backend"
    fi
fi

# ── Criar .env ────────────────────────────────────────────────────────────
ENV_FILE="$PROJECT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    already_done ".env em $PROJECT_DIR"
else
    info "Criando .env vazio em $PROJECT_DIR..."
    touch "$ENV_FILE"
    chown "${SERVICE_USER}:webapps" "$ENV_FILE"
    chmod 640 "$ENV_FILE"

    warn "Edite o arquivo de variáveis: sudo nano ${ENV_FILE}"

    # Link simbólico dentro do projeto
    BACKEND_ENV="$PROJECT_DIR/backend/.env"
    if [[ -d "$PROJECT_DIR/backend" && ! -L "$BACKEND_ENV" ]]; then
        ln -s "$ENV_FILE" "$BACKEND_ENV"
        log "Link simbólico criado: $BACKEND_ENV → $ENV_FILE"
    fi
fi

info "Permissões em /opt/apps:"
ls -la /opt/apps/

step_done "Estrutura de pastas ($PROJECT_DIR)"
