#!/bin/bash
# Seção 22 — Backups criptografados dos bancos (CronJob em cada namespace)
#
# O backup roda como CronJob DENTRO do namespace de cada banco, definido em
# base/<sistema>/backup.yaml e base/sdi/backup.yaml (repositório infra). Cada job:
#   - faz pg_dump do próprio banco e valida com pg_restore --list;
#   - cifra com age usando SÓ a chave PÚBLICA (Secret 'backup-age');
#   - guarda no PVC do próprio namespace, com retenção de 7 dias.
# Não há permissão cruzada entre namespaces e nenhum job lê Secrets alheios.
#
# Este script faz 3 coisas:
#   1. grava a chave PÚBLICA age em um Secret 'backup-age' em cada namespace;
#   2. remove o desenho antigo (ServiceAccount, ClusterRole e RoleBinding de leitura
#      de Secrets, job central em 'operacao' e cron de host);
#   3. confere que os CronJobs existem.
# A chave PRIVADA nunca é gerada, exibida ou guardada aqui.
# O PVC 'backup-archives' (arquivos cifrados do desenho antigo) NÃO é apagado: apagar
# o volume apaga os dados. Quem decide sobre ele é você.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"

require_root
init_log "22-backups"

OLD_CRON_MARKER="/opt/platform/backups/backup.sh"
BACKUP_NAMESPACES=(sdi sga siepe sigma sgoa sca)

title "22. Backups criptografados dos bancos (CronJob)"

command -v k3s &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."

# ── 1. Chave pública age ───────────────────────────────────────────────────
info "O backup é cifrado para uma CHAVE PÚBLICA age. Gere o par na SUA máquina:"
info "  age-keygen -o chave_privada.txt   (guarde off-site; não envie ao servidor)"
info "  A chave pública está na linha 'Public key:' e começa com age1."
prompt AGE_RECIPIENT "Chave pública age (age1...)" "$(get_config BACKUP_AGE_RECIPIENT)"
[[ "$AGE_RECIPIENT" =~ ^age1[0-9a-z]{58}$ ]] || die "Chave pública age inválida (esperado age1 + 58 caracteres)."
save_config BACKUP_AGE_RECIPIENT "$AGE_RECIPIENT"

# ── 2. Secret com a chave pública em cada namespace de banco ───────────────
for ns in "${BACKUP_NAMESPACES[@]}"; do
    ensure_namespace "$ns"
    k3s kubectl create secret generic backup-age -n "$ns" \
        --from-literal=recipient="$AGE_RECIPIENT" \
        --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
done
log "Secret backup-age gravado em: ${BACKUP_NAMESPACES[*]}."

# ── 3. Remove o desenho antigo (sem apagar dados) ──────────────────────────
# Job central, permissões de leitura de Secrets e configs antigas. Não há dados aqui.
k3s kubectl delete cronjob backup -n operacao --ignore-not-found >/dev/null
k3s kubectl delete serviceaccount backup-operator -n operacao --ignore-not-found >/dev/null
k3s kubectl delete clusterrole backup-dumper --ignore-not-found >/dev/null
k3s kubectl delete configmap backup-config backup-script -n operacao --ignore-not-found >/dev/null
for ns in "${BACKUP_NAMESPACES[@]}"; do
    k3s kubectl delete rolebinding backup-dumper -n "$ns" --ignore-not-found >/dev/null
done

if k3s kubectl get pvc backup-archives -n operacao &>/dev/null; then
    warn "O volume 'backup-archives' (operacao) ainda existe, com arquivos cifrados do desenho antigo."
    warn "Não foi apagado. Confira o que tem e decida: sudo k3s kubectl -n operacao get pvc backup-archives"
fi

# Cron de host do desenho antigo (/opt/platform/backups/backup.sh).
if crontab -l 2>/dev/null | grep -qF "$OLD_CRON_MARKER"; then
    crontab -l 2>/dev/null | awk -v m="$OLD_CRON_MARKER" 'index($0, m) == 0' | crontab -
    log "Cron de host do backup antigo removido."
fi

# ── 4. Confere os CronJobs ─────────────────────────────────────────────────
for ns in "${BACKUP_NAMESPACES[@]}"; do
    job="backup-db"
    [[ "$ns" == "sdi" ]] && job="sdi-backup"
    if k3s kubectl get cronjob "$job" -n "$ns" &>/dev/null; then
        log "CronJob ${job} presente em ${ns}."
    else
        warn "CronJob ${job} ainda não existe em ${ns}. Aplique o overlay do infra (kubectl apply -k overlays/prod)."
    fi
done

warn "Cópia off-site (rclone) ainda NÃO existe. Depende das credenciais do storage (T-29)."
warn "Restauração: ainda não testada com este desenho (T-43)."

step_done "Backups criptografados dos bancos (CronJob em ${#BACKUP_NAMESPACES[@]} namespaces)"
