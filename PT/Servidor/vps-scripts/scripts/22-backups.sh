#!/bin/bash
# Seção 22 — Backups automatizados e criptografados
#
# Backup lógico dos bancos + configs/segredos, criptografado com age. O servidor
# guarda apenas a chave PÚBLICA (para cifrar); a chave PRIVADA (para restaurar)
# fica com VOCÊ, off-site — assim um vazamento do servidor não expõe os backups.
# Roda por cron diariamente. Cópia off-site opcional via rclone.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "22-backups"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
BK_DIR="/opt/platform/backups"

title "22. Backups automatizados e criptografados"

# ── 1. Ferramenta de criptografia (age) ────────────────────────────────────
if command -v age &>/dev/null; then
    already_done "age instalado"
else
    info "Instalando o age..."
    DEBIAN_FRONTEND=noninteractive apt install -y age >/dev/null 2>&1 || die "Falha ao instalar o age."
fi

mkdir -p "$BK_DIR/archives"

# ── 2. Destinatário age (chave pública) ────────────────────────────────────
echo
info "O backup é cifrado para uma CHAVE PÚBLICA age; só a privada restaura."
echo -e "  ${YELLOW}1${RESET}) Já tenho uma chave pública age (age1...)"
echo -e "  ${YELLOW}2${RESET}) Gerar um par agora (mostro a privada UMA vez — guarde off-site)"
prompt AGE_CHOICE "Escolha" "2"

AGE_RECIPIENT=""
if [[ "$AGE_CHOICE" == "1" ]]; then
    prompt AGE_RECIPIENT "Chave pública age (age1...)" ""
else
    # age-keygen SE RECUSA a sobrescrever um arquivo existente — então geramos
    # num diretório temporário e num caminho que ainda não existe (não usar
    # 'mktemp' de arquivo, que cria o arquivo vazio e faria o age-keygen falhar).
    TMPKEY_DIR="$(mktemp -d)"
    TMPKEY="${TMPKEY_DIR}/age.key"
    if ! age-keygen -o "$TMPKEY"; then
        rm -rf "$TMPKEY_DIR"
        die "Falha ao gerar o par de chaves age."
    fi
    AGE_RECIPIENT="$(grep -m1 -oE 'age1[0-9a-z]+' "$TMPKEY" || true)"
    echo
    echo -e "${BOLD}${RED}══ GUARDE ESTA CHAVE PRIVADA OFF-SITE (some da tela depois) ══${RESET}"
    cat "$TMPKEY"
    echo -e "${BOLD}${RED}════════════════════════════════════════════════════════════${RESET}"
    echo
    warn "Sem esta chave privada, NÃO há como restaurar os backups."
    read -rp "$(echo -e "${YELLOW}Copiei a chave privada para um local seguro. Enter para apagá-la do servidor...${RESET} ")" _
    shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"
    rmdir "$TMPKEY_DIR" 2>/dev/null || true
fi
[[ -z "$AGE_RECIPIENT" ]] && die "Chave pública age não definida."

# ── 3. Parâmetros ──────────────────────────────────────────────────────────
prompt RETENTION_DAYS "Reter backups por quantos dias (local)" "14"
prompt_optional RCLONE_REMOTE "Destino off-site rclone (ex: r2:bucket/vps) — vazio p/ pular" ""
prompt BACKUP_HOUR "Hora do backup diário (0-23)" "3"

# ── 4. Config e script ─────────────────────────────────────────────────────
cat > "${BK_DIR}/backup.env" <<EOF
AGE_RECIPIENT="${AGE_RECIPIENT}"
RETENTION_DAYS="${RETENTION_DAYS}"
RCLONE_REMOTE="${RCLONE_REMOTE}"
EOF
chmod 600 "${BK_DIR}/backup.env"

cp "${TEMPLATES_DIR}/backups/backup.sh" "${BK_DIR}/backup.sh"
chmod 700 "${BK_DIR}/backup.sh"

# ── 5. Cron diário ─────────────────────────────────────────────────────────
CRON_LINE="0 ${BACKUP_HOUR} * * * ${BK_DIR}/backup.sh >> ${BK_DIR}/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -vF "${BK_DIR}/backup.sh"; echo "$CRON_LINE" ) | crontab -
log "Cron de backup diário às ${BACKUP_HOUR}h configurado."

# ── 6. Teste imediato ──────────────────────────────────────────────────────
if confirm "Rodar um backup de teste agora?"; then
    "${BK_DIR}/backup.sh" && log "Backup de teste concluído." || warn "Backup de teste falhou — veja ${BK_DIR}/backup.log"
fi

echo
echo -e "${BOLD}${GREEN}══ Backups configurados ══${RESET}"
echo -e "  Arquivos: ${CYAN}${BK_DIR}/archives/*.age${RESET}   Retenção: ${CYAN}${RETENTION_DAYS} dias${RESET}"
echo
echo -e "${BOLD}Restaurar (na sua máquina, com a chave privada):${RESET}"
echo -e "  ${CYAN}age -d -i chave_privada.txt backup_XXXX.tar.gz.age | tar xzf -${RESET}"
warn "TESTE a restauração periodicamente — backup que nunca foi restaurado não é backup."
[[ -n "$RCLONE_REMOTE" ]] && ! command -v rclone &>/dev/null && \
    warn "rclone não está instalado — instale e configure o remote '${RCLONE_REMOTE}' para o off-site funcionar."

step_done "Backups criptografados (retenção ${RETENTION_DAYS}d)"
