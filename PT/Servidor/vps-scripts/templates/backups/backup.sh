#!/usr/bin/env bash
# Backup criptografado do k3s — executado pelo CronJob 'backup' (namespace operacao),
# gerado pela etapa 22. Roda DENTRO do pod, não no host.
#
# Para cada namespace de projeto: dump lógico (pg_dump em texto) dos bancos Postgres
# e export das configs/segredos. Tudo é cifrado com age usando SÓ a chave PÚBLICA
# (ConfigMap backup-config). Quem lê o cluster não abre os arquivos: a chave privada
# que restaura fica off-site, com o operador.
set -euo pipefail

: "${AGE_RECIPIENT:?AGE_RECIPIENT ausente (ConfigMap backup-config)}"
: "${RETENTION_DAYS:?RETENTION_DAYS ausente}"
: "${NAMESPACES:?NAMESPACES ausente}"

ARCHIVE_DIR="${ARCHIVE_DIR:-/backups}"
WORK_DIR="${WORK_DIR:-/work}"   # emptyDir em memória: o conteúdo em claro nunca toca o disco
STAMP="$(date +%Y%m%d_%H%M%S)"
WORK="$(mktemp -d "${WORK_DIR}/run.XXXXXX")"
FAILED=0
trap 'rm -rf "$WORK"' EXIT

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"; }
fail() { log "ERRO: $*"; FAILED=$((FAILED + 1)); }

# dump_postgres <namespace> <pod>
dump_postgres() {
    local ns="$1" pod="$2" user db out
    # Variáveis ausentes são normais (usa padrões); a falha do próprio dump não é mascarada.
    user="$(kubectl exec -n "$ns" "$pod" -- printenv POSTGRES_USER 2>/dev/null || echo postgres)"
    db="$(kubectl exec -n "$ns" "$pod" -- printenv POSTGRES_DB 2>/dev/null || true)"
    if [[ -z "$db" ]]; then
        log "AVISO: $ns/$pod sem POSTGRES_DB — pulado"
        return 0
    fi
    out="${WORK}/db_${ns}_${pod}.sql"
    if kubectl exec -n "$ns" "$pod" -- pg_dump --format=plain -U "$user" "$db" > "$out"; then
        log "dump ok: $ns/$pod ($db)"
    else
        fail "pg_dump falhou em $ns/$pod"
    fi
}

# dump_namespace <namespace> — procura pods cuja imagem contém 'postgres'.
# awk devolve 0 mesmo sem linhas (grep sairia 1 e abortaria sob pipefail).
dump_namespace() {
    local ns="$1" pods pod
    if ! pods="$(kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].image}{"\n"}{end}')"; then
        fail "não consegui listar pods de $ns"
        return 0
    fi
    for pod in $(printf '%s\n' "$pods" | awk 'tolower($2) ~ /postgres/ {print $1}'); do
        dump_postgres "$ns" "$pod"
    done
}

# export_configs <namespace> — manifests (inclui Secrets, necessários para restaurar).
export_configs() {
    local ns="$1"
    if kubectl get all,configmap,secret,ingressroute,middleware,cronjob -n "$ns" -o yaml > "${WORK}/k8s_${ns}.yaml"; then
        log "configs exportadas: $ns"
    else
        fail "export de configs falhou em $ns"
    fi
}

for ns in $NAMESPACES; do
    dump_namespace "$ns"
    export_configs "$ns"
done

# Empacota e cifra em um único stream: sem arquivo intermediário em claro.
ARCHIVE="${ARCHIVE_DIR}/backup_${STAMP}.tar.gz.age"
tar -czf - -C "$WORK" . | age -r "$AGE_RECIPIENT" -o "$ARCHIVE"
log "criado: $(basename "$ARCHIVE")"

find "$ARCHIVE_DIR" -name '*.age' -mtime "+${RETENTION_DAYS}" -delete

if (( FAILED > 0 )); then
    log "backup concluído COM ${FAILED} erro(s) — o job falha para aparecer no monitoramento"
    exit 1
fi
log "backup concluído sem erros."
