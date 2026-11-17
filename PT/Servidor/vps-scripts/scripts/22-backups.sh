#!/bin/bash
# Seção 22 — Backups automatizados e criptografados (CronJob no k3s)
#
# Todo dia, no horário escolhido, um CronJob no namespace 'operacao' faz dump
# lógico (pg_dump em texto) de cada banco Postgres dos namespaces de projeto e
# exporta suas configs e segredos. Tudo é cifrado com age usando SÓ a chave
# PÚBLICA (age1...), que é o único material que fica no cluster. A chave PRIVADA
# que restaura os backups fica com VOCÊ, fora do servidor — assim um vazamento
# do servidor não expõe os backups.
#
# Exige k3s (etapa 25). Os arquivos cifrados ficam no PVC 'backup-archives'.
# A chave privada NUNCA é gerada, exibida ou guardada por este script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"

require_root
init_log "22-backups"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
BACKUP_NAMESPACE="$PLATFORM_NAMESPACE"
CRON_MARKER="/opt/platform/backups/backup.sh"   # cron de host antigo (versões anteriores)

title "22. Backups automatizados e criptografados (CronJob)"

command -v k3s &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."

# ── 1. Destinatário age (somente chave pública) ────────────────────────────
echo
info "O backup é cifrado para uma CHAVE PÚBLICA age. Gere o par na SUA máquina:"
info "  age-keygen -o chave_privada.txt   (guarde o arquivo off-site; não o envie ao servidor)"
info "  A chave pública está na linha 'Public key:' e começa com age1."
prompt AGE_RECIPIENT "Chave pública age (age1...)" "$(get_config BACKUP_AGE_RECIPIENT)"
[[ "$AGE_RECIPIENT" =~ ^age1[0-9a-z]{58}$ ]] || die "Chave pública age inválida (esperado age1 + 58 caracteres)."
save_config BACKUP_AGE_RECIPIENT "$AGE_RECIPIENT"

# ── 2. Parâmetros ──────────────────────────────────────────────────────────
prompt RETENTION_DAYS "Reter backups por quantos dias (no PVC)" "14"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "Retenção inválida: use um número de dias."
prompt BACKUP_HOUR "Hora do backup diário (0-23)" "3"
[[ "$BACKUP_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || die "Hora inválida (0-23)."
BACKUP_SCHEDULE="0 ${BACKUP_HOUR} * * *"

# ── 3. Namespace, configuração e script no cluster ─────────────────────────
ensure_namespace "$BACKUP_NAMESPACE"

k3s kubectl create configmap backup-config -n "$BACKUP_NAMESPACE" \
    --from-literal=AGE_RECIPIENT="$AGE_RECIPIENT" \
    --from-literal=RETENTION_DAYS="$RETENTION_DAYS" \
    --from-literal=NAMESPACES="${PROJECT_NAMESPACES[*]}" \
    --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
k3s kubectl create configmap backup-script -n "$BACKUP_NAMESPACE" \
    --from-file=backup.sh="${TEMPLATES_DIR}/backups/backup.sh" \
    --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
log "Configuração e script do backup gravados no cluster."

# ServiceAccount, ClusterRole, PVC e CronJob (cronjob.yaml).
sed "s|__BACKUP_SCHEDULE__|${BACKUP_SCHEDULE}|" "${TEMPLATES_DIR}/backups/cronjob.yaml" \
    | k3s kubectl apply -f - >/dev/null
log "CronJob de backup agendado: ${BACKUP_SCHEDULE} (namespace ${BACKUP_NAMESPACE})."

# RoleBinding em cada namespace de projeto: o backup lê somente dentro dele.
for ns in "${PROJECT_NAMESPACES[@]}"; do
    ensure_namespace "$ns"
    k3s kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backup-dumper
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: backup-dumper
subjects:
  - kind: ServiceAccount
    name: backup-operator
    namespace: ${BACKUP_NAMESPACE}
EOF
done
log "Permissão de leitura do backup aplicada em ${#PROJECT_NAMESPACES[@]} namespace(s)."

# ── 4. Remove o cron de host de versões anteriores (substituído pelo CronJob) ─
# awk sai com 0 mesmo sem linhas — grep -v sairia 1 e abortaria sob pipefail.
if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    crontab -l 2>/dev/null | awk -v m="$CRON_MARKER" 'index($0, m) == 0' | crontab -
    warn "Cron de host antigo ($CRON_MARKER) removido — o backup agora é o CronJob."
fi

# ── 5. Teste imediato (opcional) ───────────────────────────────────────────
if confirm "Disparar um backup de teste agora?"; then
    TEST_JOB="backup-teste-$(date +%H%M%S)"
    if k3s kubectl create job -n "$BACKUP_NAMESPACE" --from=cronjob/backup "$TEST_JOB" >/dev/null; then
        log "Job de teste criado: ${TEST_JOB}"
        info "Acompanhe: sudo k3s kubectl logs -n ${BACKUP_NAMESPACE} job/${TEST_JOB}"
    else
        warn "Não consegui criar o job de teste — verifique com 'sudo k3s kubectl get cronjob -n ${BACKUP_NAMESPACE}'."
    fi
fi

echo
echo -e "${BOLD}${GREEN}══ Backups configurados (CronJob no k3s) ══${RESET}"
echo -e "  Cronjob: ${CYAN}backup${RESET} em ${CYAN}${BACKUP_NAMESPACE}${RESET} — ${CYAN}${BACKUP_SCHEDULE}${RESET}"
echo -e "  Arquivos: PVC ${CYAN}backup-archives${RESET} (retenção ${CYAN}${RETENTION_DAYS} dias${RESET})"
echo
echo -e "${BOLD}Restaurar (na sua máquina, com a chave privada):${RESET}"
echo -e "  ${CYAN}age -d -i chave_privada.txt backup_XXXX.tar.gz.age | tar xzf -${RESET}"
warn "Cópia off-site (rclone) NÃO está nesta versão: ainda não migrada para o CronJob."
warn "TESTE a restauração periodicamente — backup que nunca foi restaurado não é backup."

step_done "Backups criptografados (CronJob ${BACKUP_SCHEDULE}, retenção ${RETENTION_DAYS}d)"
