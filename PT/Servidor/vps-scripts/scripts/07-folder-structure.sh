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

# ── Clonar repositórios ────────────────────────────────────────────────────
declare -A REPOS=(
    ["backend"]="https://github.com/sql-challenge/sql-challenge-backend.git"
    ["frontend"]="https://github.com/sql-challenge/sql-challenge-frontend.git"
    ["modelagem"]="https://github.com/sql-challenge/sql-challenge-modelagem_de_dados.git"
)

echo
for DEST in "${!REPOS[@]}"; do
    REPO_URL="${REPOS[$DEST]}"
    TARGET_DIR="$PROJECT_DIR/$DEST"

    if [[ -d "$TARGET_DIR" ]]; then
        already_done "Repositório $DEST ($TARGET_DIR)"
        continue
    fi

    if confirm "Clonar $DEST? ($REPO_URL)"; then
        info "Clonando $DEST como $SERVICE_USER..."
        if sudo -u "$SERVICE_USER" git clone "$REPO_URL" "$TARGET_DIR"; then
            chown -R "${SERVICE_USER}:webapps" "$TARGET_DIR"
            find "$TARGET_DIR" -type d -exec chmod 750 {} \;
            find "$TARGET_DIR" -type f -exec chmod 640 {} \;
            log "$DEST clonado em $TARGET_DIR"
        else
            warn "Falha ao clonar $DEST — faça manualmente:"
            warn "  sudo -u ${SERVICE_USER} git clone ${REPO_URL} ${TARGET_DIR}"
        fi
    else
        warn "Clone de $DEST pulado — faça manualmente:"
        warn "  sudo -u ${SERVICE_USER} git clone ${REPO_URL} ${TARGET_DIR}"
    fi
done

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

    # Link simbólico para o backend
    BACKEND_ENV="$PROJECT_DIR/backend/.env"
    if [[ -d "$PROJECT_DIR/backend" && ! -L "$BACKEND_ENV" ]]; then
        ln -s "$ENV_FILE" "$BACKEND_ENV"
        log "Link simbólico criado: $BACKEND_ENV → $ENV_FILE"
    fi
fi

info "Permissões em /opt/apps:"
ls -la /opt/apps/
ls -la "$PROJECT_DIR/"

step_done "Estrutura de pastas ($PROJECT_DIR)"
