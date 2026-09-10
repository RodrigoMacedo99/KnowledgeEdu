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
# Funciona para qualquer runtime: containers Docker e/ou pods do k3s.
if command -v docker &>/dev/null; then
    docker ps --format '{{.Names}} {{.Image}}' | grep -iE 'postgres' | while read -r name _; do
        user="$(docker exec "$name" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
        db="$(docker exec "$name" printenv POSTGRES_DB 2>/dev/null || true)"
        [[ -z "$db" ]] && continue
        if docker exec "$name" pg_dump -U "$user" "$db" > "$WORK/db_${name}.sql" 2>/dev/null; then
            log "dump ok (docker): $name ($db)"
        else
            log "AVISO: falha no dump docker de $name"
        fi
    done
fi

if command -v k3s &>/dev/null; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    k3s kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
        | grep -i postgres | while read -r ns pod _; do
        user="$(k3s kubectl exec -n "$ns" "$pod" -- printenv POSTGRES_USER 2>/dev/null || echo postgres)"
        db="$(k3s kubectl exec -n "$ns" "$pod" -- printenv POSTGRES_DB 2>/dev/null || true)"
        [[ -z "$db" ]] && continue
        if k3s kubectl exec -n "$ns" "$pod" -- pg_dump -U "$user" "$db" > "$WORK/db_k3s_${ns}_${pod}.sql" 2>/dev/null; then
            log "dump ok (k3s): $ns/$pod ($db)"
        else
            log "AVISO: falha no dump k3s de $ns/$pod"
        fi
    done
fi

# ── 2. Configs e segredos (compose, .env, configs da plataforma) ───────────
tar czf "$WORK/config.tar.gz" \
    /opt/platform/.env \
    /opt/platform/*/compose.yml \
    /opt/platform/*/*.yml \
    /opt/platform/*/*.alloy \
    /opt/platform/k3s/*.yaml \
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
