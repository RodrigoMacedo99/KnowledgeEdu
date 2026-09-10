#!/bin/bash
# Backup criptografado da VPS — gerado pela etapa 22.
# Faz dump lógico dos bancos, empacota configs/segredos, criptografa com age
# (só a chave PRIVADA, guardada por você off-site, consegue restaurar) e aplica
# retenção. Off-site opcional via rclone.
set -euo pipefail

CONF="/opt/platform/backups/backup.env"
# shellcheck disable=SC1090
source "$CONF"

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="/opt/platform/backups/archives"
WORK="$(mktemp -d)"
mkdir -p "$OUT_DIR"
trap 'rm -rf "$WORK"' EXIT

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"; }

# ── 1. Dump lógico dos bancos Postgres em execução ─────────────────────────
docker ps --format '{{.Names}} {{.Image}}' | grep -iE 'postgres' | while read -r name _; do
    user="$(docker exec "$name" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
    db="$(docker exec "$name" printenv POSTGRES_DB 2>/dev/null || true)"
    [[ -z "$db" ]] && continue
    if docker exec "$name" pg_dump -U "$user" "$db" > "$WORK/db_${name}.sql" 2>/dev/null; then
        log "dump ok: $name ($db)"
    else
        log "AVISO: falha no dump de $name"
    fi
done

# ── 2. Configs e segredos (compose, .env, configs da plataforma) ───────────
tar czf "$WORK/config.tar.gz" \
    /opt/platform/.env \
    /opt/platform/*/compose.yml \
    /opt/platform/*/*.yml \
    /opt/platform/*/*.alloy \
    /opt/apps/*/.project.env \
    /opt/apps/*/*/compose.override.yml \
    /opt/apps/*/*/.env 2>/dev/null || true

# ── 3. Empacota tudo e criptografa (stream, sem intermediário em claro) ────
tar czf - -C "$WORK" . | age -r "$AGE_RECIPIENT" -o "$OUT_DIR/backup_${STAMP}.tar.gz.age"
log "criado: $OUT_DIR/backup_${STAMP}.tar.gz.age"

# ── 4. Retenção local ──────────────────────────────────────────────────────
find "$OUT_DIR" -name '*.age' -mtime "+${RETENTION_DAYS}" -delete

# ── 5. Cópia off-site opcional (rclone) ────────────────────────────────────
if [[ -n "${RCLONE_REMOTE:-}" ]] && command -v rclone >/dev/null; then
    rclone copy "$OUT_DIR/backup_${STAMP}.tar.gz.age" "$RCLONE_REMOTE" && log "enviado off-site: $RCLONE_REMOTE"
fi

log "backup concluído."
