#!/bin/bash
# Seção 28 — Criar um usuário operador (além do admin)
#
# Cria um usuário adicional que pode RODAR ESTE SCRIPT (via sudo) para
# configurar novos serviços, ver logs, etc. Ele entra nos grupos certos (sudo,
# webapps e docker/k3s conforme existam), recebe a chave SSH e é liberado no SSH
# (AllowUsers) — sem isso o hardening da etapa 3 o bloquearia.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

require_root
init_log "28-operator-user"

title "28. Usuário operador (além do admin)"

prompt OP_USER "Nome do novo usuário (sem espaços, minúsculas)" ""
[[ "$OP_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nome inválido: use minúsculas, dígitos, '-' ou '_'."

# ── 1. Criar o usuário (com home e shell — diferente da conta de um serviço) ─
if id "$OP_USER" &>/dev/null; then
    already_done "Usuário $OP_USER"
else
    info "Criando usuário $OP_USER..."
    useradd -m -s /bin/bash "$OP_USER"
fi

# ── 2. Senha (necessária para o sudo, já que o login é por chave) ──────────
info "Defina a senha do $OP_USER (usada só para confirmar comandos sudo)."
prompt_secret OP_PASS "Senha para $OP_USER"
printf '%s:%s\n' "$OP_USER" "$OP_PASS" | chpasswd
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

# ── 6. Acesso ao k3s — kubeconfig de LEITURA (nunca o admin do cluster) ─────
# O k3s.yaml é a credencial de administrador do cluster: copiá-lo daria acesso
# total ao operador. Aqui ele recebe um ServiceAccount só com leitura (ver
# templates/k3s/operador-rbac.yaml): sem Secrets, sem exec, sem escrita.
ADMIN_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
OP_KUBE_DIR="/home/${OP_USER}/.kube"
OP_KUBECONFIG="${OP_KUBE_DIR}/config"

# Remove a cópia do admin deixada por versões anteriores deste script.
if [[ -f "$OP_KUBECONFIG" ]] && grep -q 'client-certificate-data' "$OP_KUBECONFIG"; then
    shred -u "$OP_KUBECONFIG" 2>/dev/null || rm -f "$OP_KUBECONFIG"
    warn "kubeconfig com credencial de administrador (versão antiga) removido."
fi

# wait_for_token <secret> — o k3s preenche o token do Secret de forma assíncrona.
# Guarda o resultado em TOKEN_B64 (sem subshell, para o die do chamador funcionar).
wait_for_token() {
    local secret="$1" _
    TOKEN_B64=""
    for _ in $(seq 1 30); do
        TOKEN_B64="$(k3s kubectl get secret "$secret" -n "$PLATFORM_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null)" || TOKEN_B64=""
        [[ -n "$TOKEN_B64" ]] && return 0
        sleep 1
    done
    return 1
}

# write_operator_kubeconfig <serviço> <servidor> <CA> <token> — o token vai direto
# para o arquivo (umask 077), nunca para a tela nem para a linha de comando.
write_operator_kubeconfig() {
    local sa="$1" server="$2" ca="$3" token="$4"
    install -d -m 700 -o "$OP_USER" -g "$OP_USER" "$OP_KUBE_DIR"
    (
        umask 077
        cat > "$OP_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: ${sa}
    user:
      token: ${token}
contexts:
  - name: ${sa}@k3s
    context:
      cluster: k3s
      user: ${sa}
      namespace: ${PLATFORM_NAMESPACE}
current-context: ${sa}@k3s
EOF
    )
    chown "${OP_USER}:${OP_USER}" "$OP_KUBECONFIG"
    chmod 600 "$OP_KUBECONFIG"
}

OP_SA="operador-${OP_USER//_/-}"
if [[ -f "$ADMIN_KUBECONFIG" ]]; then
    ensure_namespace "$PLATFORM_NAMESPACE"
    sed -e "s|__SA__|${OP_SA}|g" -e "s|__NS__|${PLATFORM_NAMESPACE}|g" \
        "${TEMPLATES_DIR}/k3s/operador-rbac.yaml" | k3s kubectl apply -f - >/dev/null
    wait_for_token "${OP_SA}-token" || die "O k3s não preencheu o token de '${OP_SA}' a tempo."
    OP_TOKEN="$(printf '%s' "$TOKEN_B64" | base64 -d)"
    OP_SERVER="$(k3s kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
    OP_CA="$(k3s kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    write_operator_kubeconfig "$OP_SA" "$OP_SERVER" "$OP_CA" "$OP_TOKEN"
    log "kubeconfig de LEITURA para $OP_USER criado (ServiceAccount ${OP_SA})."
else
    warn "k3s não instalado — kubeconfig do operador não criado (rode a etapa 25 e depois esta etapa de novo)."
fi

echo
echo -e "${BOLD}${GREEN}══ Operador '${OP_USER}' criado ══${RESET}"
echo -e "  Ele roda este script com: ${CYAN}sudo bash setup.sh${RESET}"
echo -e "  Login: ${CYAN}ssh ${OP_USER}@<IP> -p <porta_ssh>${RESET}"
warn "TESTE o login do ${OP_USER} num NOVO terminal antes de fechar esta sessão."

step_done "Usuário operador ${OP_USER}"
