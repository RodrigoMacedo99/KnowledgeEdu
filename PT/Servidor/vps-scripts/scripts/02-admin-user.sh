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

# ── Copiar chaves SSH do root ──────────────────────────────────────────────
if [[ -d /root/.ssh ]]; then
    info "Copiando chaves SSH do root para '$ADMIN_USER'..."
    rsync --archive --chown="${ADMIN_USER}:${ADMIN_USER}" /root/.ssh "/home/${ADMIN_USER}"
    log "Chaves SSH copiadas."
else
    warn "Pasta /root/.ssh não encontrada — copie manualmente sua chave pública depois."
fi

# ── Bloquear senha do root ─────────────────────────────────────────────────
echo
warn "ATENÇÃO: antes de bloquear o root, confirme que consegue logar com '$ADMIN_USER'."
warn "Abra outro terminal e execute: ssh ${ADMIN_USER}@IP_DA_VPS && sudo whoami"
echo

if confirm "Bloquear login do root agora?"; then
    passwd -l root
    log "Login do root bloqueado."
else
    warn "Root não bloqueado — faça isso manualmente após confirmar o acesso admin."
fi

step_done "Usuário administrador '$ADMIN_USER'"
