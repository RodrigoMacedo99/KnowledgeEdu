#!/bin/bash
# Seção 28 — Criar um usuário operador (além do admin)
#
# Cria uma conta humana adicional que pode RODAR ESTE SCRIPT (via sudo) para
# configurar novos serviços, ver logs, etc. Ele entra nos grupos certos (sudo,
# webapps e docker/k3s conforme existam), recebe a chave SSH e é liberado no SSH
# (AllowUsers) — sem isso o hardening da etapa 3 o bloquearia.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "28-operator-user"

title "28. Usuário operador (além do admin)"

prompt OP_USER "Nome do novo usuário (sem espaços, minúsculas)" ""
[[ "$OP_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nome inválido: use minúsculas, dígitos, '-' ou '_'."

# ── 1. Criar o usuário (com home e shell, é uma conta humana) ──────────────
if id "$OP_USER" &>/dev/null; then
    already_done "Usuário $OP_USER"
else
    info "Criando usuário $OP_USER..."
    useradd -m -s /bin/bash "$OP_USER"
fi

# ── 2. Senha (necessária para o sudo, já que o login é por chave) ──────────
info "Defina a senha do $OP_USER (usada só para confirmar comandos sudo)."
prompt_secret OP_PASS "Senha para $OP_USER"
echo "${OP_USER}:${OP_PASS}" | chpasswd
log "Senha definida."

# ── 3. Grupos ──────────────────────────────────────────────────────────────
usermod -aG sudo "$OP_USER"
info "Adicionado ao grupo sudo."
if getent group webapps &>/dev/null; then usermod -aG webapps "$OP_USER"; info "Adicionado ao grupo webapps."; fi
if getent group docker  &>/dev/null; then usermod -aG docker  "$OP_USER"; info "Adicionado ao grupo docker."; fi

# ── 4. Chave SSH ───────────────────────────────────────────────────────────
prompt_optional OP_KEY "Chave pública SSH do operador (ssh-ed25519 AAAA... / ssh-rsa ...) — vazio p/ adicionar depois" ""
if [[ -n "$OP_KEY" ]]; then
    install -d -m 700 -o "$OP_USER" -g "$OP_USER" "/home/${OP_USER}/.ssh"
    touch "/home/${OP_USER}/.ssh/authorized_keys"
    grep -qF "$OP_KEY" "/home/${OP_USER}/.ssh/authorized_keys" || echo "$OP_KEY" >> "/home/${OP_USER}/.ssh/authorized_keys"
    chown "${OP_USER}:${OP_USER}" "/home/${OP_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${OP_USER}/.ssh/authorized_keys"
    log "Chave SSH autorizada para $OP_USER."
else
    warn "Sem chave agora — o $OP_USER NÃO conseguirá logar por SSH até você adicionar a chave em /home/${OP_USER}/.ssh/authorized_keys."
fi

# ── 5. Liberar no SSH (AllowUsers) — senão o hardening bloqueia ────────────
SSHD="/etc/ssh/sshd_config"
if grep -qE "^AllowUsers " "$SSHD" 2>/dev/null; then
    if grep -qE "^AllowUsers .*(^| )${OP_USER}( |\$)" "$SSHD"; then
        already_done "AllowUsers já inclui $OP_USER"
    else
        sed -i "s/^AllowUsers .*/& ${OP_USER}/" "$SSHD"
        log "$OP_USER adicionado ao AllowUsers do SSH."
    fi
else
    warn "Diretiva AllowUsers não encontrada no sshd_config — verifique a etapa 3."
fi

if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    log "SSH recarregado."
else
    error "sshd -t falhou — NÃO recarreguei o SSH. Revise ${SSHD}."
fi

# ── 6. Acesso ao k3s (se instalado) — kubectl sem sudo ─────────────────────
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    install -d -m 700 -o "$OP_USER" -g "$OP_USER" "/home/${OP_USER}/.kube"
    cp /etc/rancher/k3s/k3s.yaml "/home/${OP_USER}/.kube/config"
    chown "${OP_USER}:${OP_USER}" "/home/${OP_USER}/.kube/config"
    chmod 600 "/home/${OP_USER}/.kube/config"
    log "kubeconfig do k3s copiado para o $OP_USER (kubectl sem sudo)."
fi

echo
echo -e "${BOLD}${GREEN}══ Operador '${OP_USER}' criado ══${RESET}"
echo -e "  Ele roda este script com: ${CYAN}sudo bash setup.sh${RESET}"
echo -e "  Login: ${CYAN}ssh ${OP_USER}@<IP> -p <porta_ssh>${RESET}"
warn "TESTE o login do ${OP_USER} num NOVO terminal antes de fechar esta sessão."

step_done "Usuário operador ${OP_USER}"
