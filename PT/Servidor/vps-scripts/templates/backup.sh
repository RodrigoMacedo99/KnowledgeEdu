#!/bin/bash
# Template de backup automático do banco de dados.
# Substitua: PROJECT_DIR, CONTAINER_NAME, DB_USER, DB_NAME
# Copie para: /opt/apps/NOME_PROJETO/backup.sh

BACKUP_DIR="PROJECT_DIR/backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

docker exec CONTAINER_NAME pg_dump -U DB_USER -d DB_NAME \
    | gzip > "$BACKUP_DIR/DB_NAME_$DATE.sql.gz"

find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete

echo "Backup concluído: DB_NAME_$DATE.sql.gz"
