#!/bin/bash
# Seção 11 — Segurança do banco de dados PostgreSQL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "11-postgres"

title "11. Segurança do PostgreSQL"

# ── Verificar docker-compose.yml ──────────────────────────────────────────
COMPOSE_FILE="/opt/apps/sql-challenge/backend/docker-compose.yml"

if [[ -f "$COMPOSE_FILE" ]]; then
    info "Verificando binding de porta no docker-compose.yml..."
    if grep -qE '"5432:5432"' "$COMPOSE_FILE" && ! grep -qE '"127\.0\.0\.1:5432:5432"' "$COMPOSE_FILE"; then
        warn "PROBLEMA DETECTADO: porta 5432 exposta sem binding ao localhost!"
        warn "  Altere em $COMPOSE_FILE:"
        warn "  DE:  - \"5432:5432\""
        warn "  PARA: - \"127.0.0.1:5432:5432\""
    else
        log "Binding de porta OK (127.0.0.1:5432:5432)."
    fi
else
    warn "docker-compose.yml não encontrado em $COMPOSE_FILE"
    info "Lembre-se: use sempre  127.0.0.1:5432:5432  e nunca  5432:5432  no ports."
fi

# ── Gerar senha forte ──────────────────────────────────────────────────────
echo
info "Gerando senha segura para o banco de dados:"
DB_PASSWORD=$(openssl rand -base64 32)
echo -e "${GREEN}Senha gerada:${RESET} ${BOLD}${DB_PASSWORD}${RESET}"
echo
warn "Copie esta senha para o .env do projeto (variável POSTGRES_PASSWORD ou similar)."
warn "Ela não será salva em nenhum arquivo por segurança."

# ── Criar script de backup ────────────────────────────────────────────────
PROJECT_DIR="/opt/apps/sql-challenge"
BACKUP_SCRIPT="$PROJECT_DIR/backup.sh"

if [[ -f "$BACKUP_SCRIPT" ]]; then
    already_done "Script de backup"
else
    prompt CONTAINER_NAME "Nome do container do banco de dados" "sql-challenge-db"
    prompt DB_USER        "Usuário do PostgreSQL"               "challenge_user"
    prompt DB_NAME        "Nome do banco de dados"              "db_gestao"

    info "Criando script de backup em $BACKUP_SCRIPT..."
    cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
BACKUP_DIR="${PROJECT_DIR}/backups"
DATE=\$(date +%Y%m%d_%H%M%S)
mkdir -p "\$BACKUP_DIR"

docker exec ${CONTAINER_NAME} pg_dump -U ${DB_USER} -d ${DB_NAME} \\
    | gzip > "\$BACKUP_DIR/db_${DB_NAME}_\$DATE.sql.gz"

find "\$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete

echo "Backup concluído: db_${DB_NAME}_\$DATE.sql.gz"
EOF

    chown sqlchallenge:webapps "$BACKUP_SCRIPT" 2>/dev/null || true
    chmod +x "$BACKUP_SCRIPT"

    info "Adicionando cron de backup diário às 3h..."
    CRON_LINE="0 3 * * * ${BACKUP_SCRIPT} >> ${PROJECT_DIR}/backup.log 2>&1"
    (crontab -u sqlchallenge -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT") || \
        (crontab -u sqlchallenge -l 2>/dev/null; echo "$CRON_LINE") | crontab -u sqlchallenge -
    log "Cron de backup configurado."
fi

echo
info "Para acessar o banco remotamente via túnel SSH (sem abrir portas):"
echo -e "  ${CYAN}ssh -L 5432:localhost:5432 vps${RESET}"

step_done "Segurança do PostgreSQL"
