#!/bin/bash
# Seção 30 — Gestão de usuários da VPS
#
# Ponto único para administrar quem tem acesso ao servidor: usuários HUMANOS
# (admin, operadores — etapa 28) e usuários de SERVIÇO (um por projeto, criados
# sozinhos pela etapa 15/29). Cobre o que fica faltando depois que a conta já
# existe: listar, gerenciar chaves SSH, bloquear/desbloquear, alternar sudo e
# remover com segurança (limpando cron e o AllowUsers do sshd_config).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "30-user-manager"

SSHD_CONFIG="/etc/ssh/sshd_config"

# ── Remove um nome da linha AllowUsers, preservando os demais ──────────────
remove_from_allowusers() {
    local target="$1"
    local line rest
    line="$(grep -E "^AllowUsers " "$SSHD_CONFIG" 2>/dev/null | head -1)"
    [[ -z "$line" ]] && return 0
    rest="${line#AllowUsers}"
    local -a names kept
    read -ra names <<< "$rest"
    local n
    for n in "${names[@]}"; do
        [[ "$n" != "$target" ]] && kept+=("$n")
    done
    sed -i "s/^AllowUsers .*/AllowUsers ${kept[*]}/" "$SSHD_CONFIG"
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
        warn "sshd -t falhou após editar AllowUsers — revise ${SSHD_CONFIG} manualmente."
    fi
}

# ── 1. Listar usuários humanos (admin/operadores) ──────────────────────────
list_human_users() {
    echo
    echo -e "${BOLD}Usuários humanos (UID 1000-65533 — admin/operadores):${RESET}"
    printf "  %-15s %-6s %-6s %-10s %s\n" "USUÁRIO" "UID" "SUDO" "STATUS" "GRUPOS"
    local found=0
    while IFS=: read -r name _ uid _ _ _ _; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        found=1
        local sudo_flag="não"
        groups "$name" 2>/dev/null | grep -qw sudo && sudo_flag="sim"
        local grp
        grp="$(id -nG "$name" 2>/dev/null | tr ' ' ',')"
        local status="ativo"
        passwd -S "$name" 2>/dev/null | awk '{print $2}' | grep -q '^L' && status="BLOQUEADO"
        local expiry
        expiry="$(chage -l "$name" 2>/dev/null | awk -F': ' '/Account expires/ {print $2}')"
        [[ -n "$expiry" && "$expiry" != "never" ]] && status="EXPIRADO"
        printf "  %-15s %-6s %-6s %-10s %s\n" "$name" "$uid" "$sudo_flag" "$status" "$grp"
    done < /etc/passwd
    [[ "$found" -eq 0 ]] && echo "  (nenhum usuário humano além do root encontrado)"
}

# ── 2. Listar usuários de serviço (um por projeto) ─────────────────────────
list_service_users() {
    echo
    echo -e "${BOLD}Usuários de serviço (um por projeto — etapa 15/29):${RESET}"
    printf "  %-20s %-15s %s\n" "PROJETO" "USUÁRIO" "PASTA"
    local found=0
    for dir in /opt/apps/*/; do
        [[ -d "$dir" ]] || continue
        found=1
        local project owner
        project="$(basename "$dir")"
        owner="$(stat -c '%U' "$dir" 2>/dev/null)"
        printf "  %-20s %-15s %s\n" "$project" "$owner" "$dir"
    done
    [[ "$found" -eq 0 ]] && echo "  (nenhum serviço criado ainda — use a etapa 15 ou 29)"
}

# ── 3. Chaves SSH de um usuário ─────────────────────────────────────────────
manage_ssh_keys() {
    echo
    prompt SSH_USER "Nome do usuário" ""
    id "$SSH_USER" &>/dev/null || { warn "Usuário '${SSH_USER}' não existe."; return; }
    local home
    home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
    if [[ -z "$home" || "$home" == "/" ]]; then
        warn "'${SSH_USER}' não tem pasta home (parece ser usuário de serviço, sem login) — não gerencio chaves aqui."
        return
    fi
    local akfile="${home}/.ssh/authorized_keys"

    echo
    echo -e "${BOLD}Chaves autorizadas de ${SSH_USER}:${RESET}"
    if [[ -s "$akfile" ]]; then
        nl -ba "$akfile" | sed 's/^/  /'
    else
        echo "  (nenhuma chave cadastrada)"
    fi
    echo
    echo -e "  ${YELLOW}1${RESET}) Adicionar uma chave"
    echo -e "  ${YELLOW}2${RESET}) Remover uma chave (pelo número da lista acima)"
    echo -e "  ${YELLOW}0${RESET}) Voltar"
    read -rp "$(echo -e "${YELLOW}Escolha:${RESET} ")" sk
    case "$sk" in
        1)
            prompt NEW_KEY "Cole a chave pública (ssh-ed25519 AAAA... / ssh-rsa ...)" ""
            install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "${home}/.ssh"
            touch "$akfile"
            grep -qF "$NEW_KEY" "$akfile" || echo "$NEW_KEY" >> "$akfile"
            chown "${SSH_USER}:${SSH_USER}" "$akfile"
            chmod 600 "$akfile"
            log "Chave adicionada para ${SSH_USER}."
            ;;
        2)
            prompt LINE_NUM "Número da chave a remover" ""
            if [[ -s "$akfile" ]] && sed -n "${LINE_NUM}p" "$akfile" | grep -q .; then
                confirm "Remover a chave da linha ${LINE_NUM}?" && sed -i "${LINE_NUM}d" "$akfile" && log "Chave removida."
            else
                warn "Linha inválida ou arquivo vazio."
            fi
            ;;
        0) return ;;
        *) warn "Opção inválida." ;;
    esac
}

# ── 4. Bloquear / desbloquear acesso ────────────────────────────────────────
lock_user() {
    echo
    prompt LOCK_USER "Nome do usuário a bloquear" ""
    id "$LOCK_USER" &>/dev/null || { warn "Usuário '${LOCK_USER}' não existe."; return; }
    [[ "$LOCK_USER" == "root" ]] && { warn "Root já é bloqueado pela etapa 2 — use-a para isso."; return; }
    confirm "Bloquear TODO acesso (senha + SSH) de '${LOCK_USER}'? A conta e os arquivos não são apagados." || return
    usermod -L "$LOCK_USER"
    usermod --expiredate 1 "$LOCK_USER"
    log "'${LOCK_USER}' bloqueado (senha travada + conta expirada). Chaves SSH continuam salvas, só não autenticam mais."
}

unlock_user() {
    echo
    prompt UNLOCK_USER "Nome do usuário a desbloquear" ""
    id "$UNLOCK_USER" &>/dev/null || { warn "Usuário '${UNLOCK_USER}' não existe."; return; }
    usermod -U "$UNLOCK_USER"
    usermod --expiredate '' "$UNLOCK_USER"
    log "'${UNLOCK_USER}' desbloqueado."
}

# ── 5. Alternar acesso sudo ──────────────────────────────────────────────────
toggle_sudo() {
    echo
    prompt SUDO_USER "Nome do usuário" ""
    id "$SUDO_USER" &>/dev/null || { warn "Usuário '${SUDO_USER}' não existe."; return; }
    if groups "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
        confirm "Remover '${SUDO_USER}' do grupo sudo?" && deluser "$SUDO_USER" sudo && log "'${SUDO_USER}' removido do sudo."
    else
        confirm "Adicionar '${SUDO_USER}' ao grupo sudo?" && usermod -aG sudo "$SUDO_USER" && log "'${SUDO_USER}' adicionado ao sudo."
    fi
}

# ── 6. Remover um usuário operador (destrutivo) ─────────────────────────────
remove_operator() {
    echo
    prompt DEL_USER "Nome do usuário a remover" ""
    id "$DEL_USER" &>/dev/null || { warn "Usuário '${DEL_USER}' não existe."; return; }
    if [[ "$DEL_USER" == "root" || "$DEL_USER" == "admin" ]]; then
        warn "Não removo 'root' nem 'admin' por aqui — isso poderia te trancar fora do servidor."
        return
    fi
    local uid
    uid="$(id -u "$DEL_USER")"
    if [[ "$uid" -lt 1000 ]]; then
        warn "'${DEL_USER}' parece ser um usuário de SERVIÇO (uid ${uid}), dono de arquivos em /opt/apps."
        warn "Removê-lo NÃO apaga o projeto — só o dono dos arquivos passa a ser um UID órfão."
        confirm "Ainda assim remover '${DEL_USER}'?" || return
    fi

    echo
    warn "Isso remove PERMANENTEMENTE:"
    warn "  • a conta '${DEL_USER}' e sua pasta home"
    warn "  • o crontab de '${DEL_USER}' (se houver)"
    warn "  • a entrada dele no AllowUsers do sshd_config"
    confirm "Confirma a remoção de '${DEL_USER}'?" || return

    crontab -u "$DEL_USER" -r 2>/dev/null || true
    userdel -r "$DEL_USER" 2>/dev/null || userdel "$DEL_USER" 2>/dev/null || warn "userdel retornou aviso — verifique manualmente."
    remove_from_allowusers "$DEL_USER"
    log "'${DEL_USER}' removido."
}

# ── Menu ─────────────────────────────────────────────────────────────────────
title "30. Gestão de usuários"

show_user_menu() {
    echo
    echo -e "  ${YELLOW}1${RESET}) Listar usuários humanos (admin/operadores)"
    echo -e "  ${YELLOW}2${RESET}) Listar usuários de serviço (por projeto)"
    echo -e "  ${YELLOW}3${RESET}) Adicionar um novo operador (etapa 28)"
    echo -e "  ${YELLOW}4${RESET}) Gerenciar chaves SSH de um usuário"
    echo -e "  ${YELLOW}5${RESET}) Bloquear acesso de um usuário"
    echo -e "  ${YELLOW}6${RESET}) Desbloquear acesso de um usuário"
    echo -e "  ${YELLOW}7${RESET}) Alternar acesso sudo de um usuário"
    echo -e "  ${YELLOW}8${RESET}) Remover um usuário (destrutivo)"
    echo -e "  ${YELLOW}0${RESET}) Voltar"
    echo
}

while true; do
    show_user_menu
    read -rp "$(echo -e "${YELLOW}Escolha uma opção:${RESET} ")" choice
    case "$choice" in
        1) list_human_users ;;
        2) list_service_users ;;
        3) bash "${SCRIPT_DIR}/28-operator-user.sh" ;;
        4) manage_ssh_keys ;;
        5) lock_user ;;
        6) unlock_user ;;
        7) toggle_sudo ;;
        8) remove_operator ;;
        0) break ;;
        *) warn "Opção inválida." ;;
    esac
done

step_done "Gestão de usuários"
