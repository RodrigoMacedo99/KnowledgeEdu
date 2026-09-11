#!/bin/bash
# Seção 2 — Criar usuário administrador e desabilitar root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "02-admin-user"

title "2. Criação do usuário administrador"

prompt ADMIN_USER "Nome do usuário admin" "admin"

# ── Criar usuário ──────────────────────────────────────────────────────────
if id "$ADMIN_USER" &>/dev/null; then
    already_done "Usuário '$ADMIN_USER'"
else
    info "Criando usuário '$ADMIN_USER'..."
    adduser --gecos "" "$ADMIN_USER"
fi

# ── Permissão sudo ─────────────────────────────────────────────────────────
if groups "$ADMIN_USER" | grep -qw sudo; then
    already_done "Grupo sudo para '$ADMIN_USER'"
else
    info "Adicionando '$ADMIN_USER' ao grupo sudo..."
    usermod -aG sudo "$ADMIN_USER"
fi

# ── Chave SSH do admin ──────────────────────────────────────────────────────
# Copiamos SOMENTE o authorized_keys do root (não as chaves privadas dele) e,
# como o acesso root pode ser por console/senha (sem chave no root), permitimos
# COLAR a chave pública do admin — senão ele nasceria sem acesso por SSH.
ADMIN_SSH="/home/${ADMIN_USER}/.ssh"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_SSH"
touch "${ADMIN_SSH}/authorized_keys"

if [[ -f /root/.ssh/authorized_keys ]]; then
    info "Copiando authorized_keys do root para '$ADMIN_USER'..."
    cat /root/.ssh/authorized_keys >> "${ADMIN_SSH}/authorized_keys"
fi

prompt_optional ADMIN_KEY "Cole a chave pública SSH do admin (ssh-ed25519 AAAA... / ssh-rsa ...) — vazio se já copiada do root" ""
if [[ -n "$ADMIN_KEY" ]]; then
    grep -qF "$ADMIN_KEY" "${ADMIN_SSH}/authorized_keys" || echo "$ADMIN_KEY" >> "${ADMIN_SSH}/authorized_keys"
fi

# Remove linhas em branco/duplicadas e ajusta dono e permissões.
sed -i '/^[[:space:]]*$/d' "${ADMIN_SSH}/authorized_keys"
sort -u "${ADMIN_SSH}/authorized_keys" -o "${ADMIN_SSH}/authorized_keys"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "$ADMIN_SSH"
chmod 700 "$ADMIN_SSH"
chmod 600 "${ADMIN_SSH}/authorized_keys"

if [[ -s "${ADMIN_SSH}/authorized_keys" ]]; then
    log "authorized_keys do '$ADMIN_USER' configurado ($(wc -l < "${ADMIN_SSH}/authorized_keys") chave(s))."
else
    warn "O '$ADMIN_USER' está SEM nenhuma chave autorizada."
fi

# ── Bloquear senha do root (com salvaguarda contra lockout) ────────────────
echo
if [[ ! -s "${ADMIN_SSH}/authorized_keys" ]]; then
    warn "NÃO vou oferecer o bloqueio do root: o '$ADMIN_USER' não tem chave SSH e"
    warn "isso causaria LOCKOUT. Adicione a chave pública do admin e rode a etapa 2 de novo."
else
    warn "ATENÇÃO: antes de bloquear o root, confirme em OUTRO terminal que consegue:"
    warn "  ssh ${ADMIN_USER}@IP_DA_VPS -p <porta_ssh>  e depois  sudo whoami"
    echo
    if confirm "Você JÁ confirmou o acesso do '$ADMIN_USER' e quer bloquear o root agora?"; then
        passwd -l root
        log "Login do root bloqueado."
    else
        warn "Root não bloqueado — faça 'sudo passwd -l root' após confirmar o acesso do ${ADMIN_USER}."
    fi
fi

step_done "Usuário administrador '$ADMIN_USER'"
