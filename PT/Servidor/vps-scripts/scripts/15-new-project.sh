#!/bin/bash
# Seção 15 — Adicionar um novo projeto

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "15-new-project"

title "15. Adicionar novo projeto"

prompt PROJECT_NAME "Nome do projeto (sem espaços, minúsculas)" ""
prompt DOMAIN       "Domínio do projeto (ex: api.meudominio.com)" ""
prompt BACKEND_PORT "Porta interna do backend"                    "3001"
prompt REPO_URL     "URL do repositório git (deixe vazio para pular)" ""
prompt EMAIL_SSL    "E-mail para o certificado SSL"               ""

PROJECT_DIR="/opt/apps/${PROJECT_NAME}"

echo
info "Criando projeto '${PROJECT_NAME}'..."
echo -e "  Pasta:   ${CYAN}${PROJECT_DIR}${RESET}"
echo -e "  Domínio: ${CYAN}${DOMAIN}${RESET}"
echo -e "  Porta:   ${CYAN}${BACKEND_PORT}${RESET}"
echo

confirm "Confirmar e prosseguir?" || die "Operação cancelada."

# ── 1. Usuário de serviço ─────────────────────────────────────────────────
if id "$PROJECT_NAME" &>/dev/null; then
    already_done "Usuário $PROJECT_NAME"
else
    info "Criando usuário de serviço $PROJECT_NAME..."
    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --gid webapps \
        --comment "${PROJECT_NAME} service user" \
        "$PROJECT_NAME"
fi

# ── 2. Pasta e permissões ─────────────────────────────────────────────────
info "Criando estrutura de pastas..."
mkdir -p "$PROJECT_DIR"
chown "${PROJECT_NAME}:webapps" "$PROJECT_DIR"
chmod 750 "$PROJECT_DIR"

# ── 3. Repositório ────────────────────────────────────────────────────────
if [[ -n "$REPO_URL" && ! -d "$PROJECT_DIR/app" ]]; then
    info "Clonando repositório..."
    sudo -u "$PROJECT_NAME" git clone "$REPO_URL" "$PROJECT_DIR/app"
    chown -R "${PROJECT_NAME}:webapps" "$PROJECT_DIR/app"
    chmod 750 "$PROJECT_DIR/app"
fi

# ── 4. Arquivo .env ───────────────────────────────────────────────────────
ENV_FILE="${PROJECT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    info "Criando arquivo .env..."
    touch "$ENV_FILE"
    chown "${PROJECT_NAME}:webapps" "$ENV_FILE"
    chmod 640 "$ENV_FILE"

    if [[ -d "${PROJECT_DIR}/app" && ! -L "${PROJECT_DIR}/app/.env" ]]; then
        ln -s "$ENV_FILE" "${PROJECT_DIR}/app/.env"
        log "Link simbólico .env criado."
    fi
    warn "Edite as variáveis: sudo nano ${ENV_FILE}"
fi

# ── 5. Nginx ──────────────────────────────────────────────────────────────
NGINX_SITE="/etc/nginx/sites-available/${PROJECT_NAME}"
if [[ -f "$NGINX_SITE" ]]; then
    already_done "Nginx site ${PROJECT_NAME}"
else
    info "Criando configuração do Nginx..."
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 10M;
    server_tokens        off;
    proxy_read_timeout   60s;
    proxy_connect_timeout 10s;

    location / {
        proxy_pass             http://localhost:${BACKEND_PORT};
        proxy_http_version     1.1;
        proxy_set_header Upgrade            \$http_upgrade;
        proxy_set_header Connection         'upgrade';
        proxy_set_header Host               \$host;
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  \$scheme;
        proxy_cache_bypass                  \$http_upgrade;
    }
}
EOF
    ln -sf "$NGINX_SITE" "/etc/nginx/sites-enabled/${PROJECT_NAME}"
    nginx -t && systemctl reload nginx
fi

# ── 6. SSL ────────────────────────────────────────────────────────────────
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
if [[ -d "$CERT_PATH" ]]; then
    already_done "Certificado SSL para $DOMAIN"
elif [[ -n "$EMAIL_SSL" ]]; then
    info "Emitindo certificado SSL para ${DOMAIN}..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL_SSL" --redirect
else
    warn "E-mail para SSL não informado — execute manualmente:"
    warn "  sudo certbot --nginx -d ${DOMAIN}"
fi

# ── 7. Script de backup ───────────────────────────────────────────────────
BACKUP_SCRIPT="${PROJECT_DIR}/backup.sh"
if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    if confirm "Criar script de backup automático do banco de dados?"; then
        prompt CONTAINER_NAME "Nome do container do banco"  "${PROJECT_NAME}-db"
        prompt DB_USER        "Usuário do PostgreSQL"       "app_user"
        prompt DB_NAME        "Nome do banco de dados"      "app_db"

        cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
BACKUP_DIR="${PROJECT_DIR}/backups"
DATE=\$(date +%Y%m%d_%H%M%S)
mkdir -p "\$BACKUP_DIR"
docker exec ${CONTAINER_NAME} pg_dump -U ${DB_USER} -d ${DB_NAME} \\
    | gzip > "\$BACKUP_DIR/${DB_NAME}_\$DATE.sql.gz"
find "\$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
echo "Backup: ${DB_NAME}_\$DATE.sql.gz"
EOF
        chown "${PROJECT_NAME}:webapps" "$BACKUP_SCRIPT"
        chmod +x "$BACKUP_SCRIPT"

        CRON_LINE="0 3 * * * ${BACKUP_SCRIPT} >> ${PROJECT_DIR}/backup.log 2>&1"
        (crontab -u "$PROJECT_NAME" -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT") || \
            (crontab -u "$PROJECT_NAME" -l 2>/dev/null; echo "$CRON_LINE") | crontab -u "$PROJECT_NAME" -
        log "Cron de backup configurado para $PROJECT_NAME."
    fi
fi

# ── Resumo ────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Projeto '${PROJECT_NAME}' criado ══${RESET}"
echo -e "  Usuário:  ${CYAN}${PROJECT_NAME}${RESET}"
echo -e "  Pasta:    ${CYAN}${PROJECT_DIR}${RESET}"
echo -e "  Domínio:  ${CYAN}https://${DOMAIN}${RESET}"
echo -e "  Porta:    ${CYAN}${BACKEND_PORT}${RESET} (interna, via Nginx)"
echo -e "  .env:     ${CYAN}${ENV_FILE}${RESET}"
echo
warn "Próximos passos: edite o .env e suba os containers com 'docker compose up --build -d'."

step_done "Projeto ${PROJECT_NAME}"
