#!/bin/bash
# Seção 15 — Adicionar um novo projeto (produção + staging)
#
# Cada projeto ganha dois ambientes isolados (produção e, opcionalmente,
# staging): clone próprio, .env próprio, site próprio no Nginx e porta
# própria. A porta de cada ambiente é alocada automaticamente pelo registro
# central (lib/ports.sh) — a VPS hospeda vários projetos, então a porta nunca
# pode ser escolhida à mão sem risco de colidir com outro projeto já criado.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/ports.sh"

require_root
init_log "15-new-project"

title "15. Adicionar novo projeto"

prompt PROJECT_NAME "Nome do projeto (sem espaços, minúsculas)" ""
prompt PROD_DOMAIN  "Domínio de produção (ex: api.meudominio.com)" ""
prompt_optional REPO_URL  "URL do repositório git (deixe vazio para pular)" ""
prompt_optional EMAIL_SSL "E-mail para o certificado SSL (deixe vazio para pular SSL)" ""

echo
info "Recomendado: mantenha um ambiente de staging isolado para validar antes de promover para produção."
CREATE_STAGING="n"
confirm "Criar também um ambiente de staging para este projeto?" && CREATE_STAGING="y"

STAGING_DOMAIN=""
STAGING_BRANCH="develop"
if [[ "$CREATE_STAGING" == "y" ]]; then
    prompt STAGING_DOMAIN "Domínio de staging" "staging.${PROD_DOMAIN}"
    prompt STAGING_BRANCH "Branch que o staging deve acompanhar" "develop"
fi

PROJECT_DIR="/opt/apps/${PROJECT_NAME}"

# ── Portas alocadas automaticamente (nunca colidem entre projetos) ────────
PROD_PORT=$(allocate_port "$PROJECT_NAME" "production" 3000)
info "Porta alocada para produção: ${PROD_PORT}"

STAGING_PORT=""
if [[ "$CREATE_STAGING" == "y" ]]; then
    STAGING_PORT=$(allocate_port "$PROJECT_NAME" "staging" 4000)
    info "Porta alocada para staging: ${STAGING_PORT}"
fi

echo
info "Criando projeto '${PROJECT_NAME}'..."
echo -e "  Pasta:     ${CYAN}${PROJECT_DIR}${RESET}"
echo -e "  Produção:  ${CYAN}https://${PROD_DOMAIN}${RESET} (porta ${PROD_PORT}, branch main)"
[[ "$CREATE_STAGING" == "y" ]] && echo -e "  Staging:   ${CYAN}https://${STAGING_DOMAIN}${RESET} (porta ${STAGING_PORT}, branch ${STAGING_BRANCH})"
echo

confirm "Confirmar e prosseguir?" || die "Operação cancelada."

# ── 1. Usuário de serviço (compartilhado pelos dois ambientes) ───────────
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

mkdir -p "$PROJECT_DIR"
chown "${PROJECT_NAME}:webapps" "$PROJECT_DIR"
chmod 750 "$PROJECT_DIR"

# ── Provisiona um ambiente (produção ou staging) ──────────────────────────
provision_environment() {
    local env_name="$1" domain="$2" port="$3"
    local env_dir="${PROJECT_DIR}/${env_name}"

    info "Provisionando ambiente '${env_name}'..."
    mkdir -p "$env_dir"
    chown "${PROJECT_NAME}:webapps" "$env_dir"
    chmod 750 "$env_dir"

    if [[ -n "$REPO_URL" && ! -d "${env_dir}/app" ]]; then
        info "Clonando repositório em ${env_name}..."
        sudo -u "$PROJECT_NAME" git clone "$REPO_URL" "${env_dir}/app"
        chown -R "${PROJECT_NAME}:webapps" "${env_dir}/app"
        chmod 750 "${env_dir}/app"
    fi

    local env_file="${env_dir}/.env"
    if [[ -f "$env_file" ]]; then
        already_done ".env de ${env_name}"
    else
        info "Criando .env vazio para ${env_name}..."
        touch "$env_file"
        chown "${PROJECT_NAME}:webapps" "$env_file"
        chmod 640 "$env_file"

        if [[ -d "${env_dir}/app" && ! -L "${env_dir}/app/.env" ]]; then
            ln -s "$env_file" "${env_dir}/app/.env"
            log "Link simbólico .env criado para ${env_name}."
        fi
        warn "Edite as variáveis: sudo nano ${env_file}"
    fi

    local nginx_site="/etc/nginx/sites-available/${PROJECT_NAME}-${env_name}"
    if [[ -f "$nginx_site" ]]; then
        already_done "Nginx site ${PROJECT_NAME}-${env_name}"
    else
        info "Criando configuração do Nginx para ${env_name}..."
        cat > "$nginx_site" <<EOF
server {
    listen 80;
    server_name ${domain};

    client_max_body_size 10M;
    server_tokens        off;
    proxy_read_timeout   60s;
    proxy_connect_timeout 10s;

    location / {
        proxy_pass             http://localhost:${port};
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
        ln -sf "$nginx_site" "/etc/nginx/sites-enabled/${PROJECT_NAME}-${env_name}"
        nginx -t && systemctl reload nginx
    fi

    local cert_path="/etc/letsencrypt/live/${domain}"
    if [[ -d "$cert_path" ]]; then
        already_done "Certificado SSL para ${domain}"
    elif [[ -n "$EMAIL_SSL" ]]; then
        info "Emitindo certificado SSL para ${domain}..."
        certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$EMAIL_SSL" --redirect
    else
        warn "E-mail para SSL não informado — execute manualmente:"
        warn "  sudo certbot --nginx -d ${domain}"
    fi
}

# ── 2. Produção ───────────────────────────────────────────────────────────
provision_environment "production" "$PROD_DOMAIN" "$PROD_PORT"

# ── 3. Staging (opcional) ─────────────────────────────────────────────────
if [[ "$CREATE_STAGING" == "y" ]]; then
    provision_environment "staging" "$STAGING_DOMAIN" "$STAGING_PORT"
fi

# ── 4. Metadados do projeto (lidos depois pela etapa 17) ─────────────────
cat > "${PROJECT_DIR}/.project.env" <<EOF
PROD_DOMAIN=${PROD_DOMAIN}
PROD_PORT=${PROD_PORT}
MAIN_BRANCH=main
STAGING_ENABLED=${CREATE_STAGING}
STAGING_DOMAIN=${STAGING_DOMAIN}
STAGING_PORT=${STAGING_PORT}
STAGING_BRANCH=${STAGING_BRANCH}
EOF
chown "${PROJECT_NAME}:webapps" "${PROJECT_DIR}/.project.env"
chmod 640 "${PROJECT_DIR}/.project.env"

# ── 5. Script de backup do banco (produção) ───────────────────────────────
BACKUP_SCRIPT="${PROJECT_DIR}/backup.sh"
if [[ -f "$BACKUP_SCRIPT" ]]; then
    already_done "Script de backup"
elif confirm "Criar script de backup automático do banco de dados de produção?"; then
    prompt CONTAINER_NAME "Nome do container do banco (produção)" "${PROJECT_NAME}-db"
    prompt DB_USER        "Usuário do PostgreSQL"                  "app_user"
    prompt DB_NAME        "Nome do banco de dados"                 "app_db"

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

# ── Resumo ────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Projeto '${PROJECT_NAME}' criado ══${RESET}"
echo -e "  Usuário:   ${CYAN}${PROJECT_NAME}${RESET}"
echo -e "  Pasta:     ${CYAN}${PROJECT_DIR}${RESET}"
echo -e "  Produção:  ${CYAN}https://${PROD_DOMAIN}${RESET} (porta ${PROD_PORT}) — ${PROJECT_DIR}/production/"
if [[ "$CREATE_STAGING" == "y" ]]; then
    echo -e "  Staging:   ${CYAN}https://${STAGING_DOMAIN}${RESET} (porta ${STAGING_PORT}) — ${PROJECT_DIR}/staging/"
else
    echo -e "  Staging:   ${YELLOW}não criado${RESET}"
fi
echo
warn "Próximos passos: edite os arquivos .env de cada ambiente e suba os containers com 'docker compose up --build -d'."
warn "Use a etapa 17 para gerar o CI/CD (GitHub Actions) deste projeto — ela já lê as portas e domínios acima."
warn "Veja todas as portas reservadas na VPS a qualquer momento com a etapa 18."

step_done "Projeto ${PROJECT_NAME}"
