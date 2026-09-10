#!/bin/bash
# Seção 20 — Camadas extras de segurança (para dados sigilosos)
#
# Empilha defesas ADICIONAIS sobre o hardening base (etapas 3, 4, 5, 12, 14):
# política de senha, bloqueio de core dumps, endurecimento extra do kernel,
# blacklist de módulos raros, AppArmor, auditoria de arquivos sensíveis e
# rotação agressiva do Fail2Ban. Os itens que podem causar lockout ou quebrar
# aplicações (2FA no SSH, userns-remap no Docker) são OPT-IN, com aviso.
#
# Defesa em profundidade: nenhuma camada isolada é suficiente; o valor está na
# soma. Idempotente — pode rodar de novo com segurança.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "20-hardening-extra"

title "20. Camadas extras de segurança (dados sigilosos)"

# ── 1. Política de senha forte (libpam-pwquality) ──────────────────────────
if [[ -f /etc/security/pwquality.conf ]] && grep -q "vps-setup" /etc/security/pwquality.conf; then
    already_done "Política de senha (pwquality)"
else
    info "Instalando e configurando política de senha forte..."
    DEBIAN_FRONTEND=noninteractive apt install -y libpam-pwquality >/dev/null 2>&1 || warn "Falha ao instalar libpam-pwquality."
    cat > /etc/security/pwquality.conf <<'EOF'
# vps-setup — política mínima de senha
minlen = 14
minclass = 3
maxrepeat = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
difok = 5
enforcing = 1
EOF
    log "Política de senha aplicada (mín. 14 caracteres, 3 classes)."
fi

# ── 2. Bloquear core dumps (evita vazar segredos da memória em disco) ──────
if [[ -f /etc/sysctl.d/99-coredump-hardening.conf ]]; then
    already_done "Core dumps desabilitados"
else
    info "Desabilitando core dumps..."
    echo "* hard core 0" > /etc/security/limits.d/99-coredump.conf
    cat > /etc/sysctl.d/99-coredump-hardening.conf <<'EOF'
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false
EOF
    log "Core dumps desabilitados."
fi

# ── 3. Endurecimento extra do kernel ───────────────────────────────────────
SYSCTL_EXTRA="/etc/sysctl.d/99-security-extra.conf"
if [[ -f "$SYSCTL_EXTRA" ]]; then
    already_done "Sysctl extra de segurança"
else
    info "Aplicando parâmetros extras do kernel..."
    cat > "$SYSCTL_EXTRA" <<'EOF'
# Oculta endereços de memória do kernel (dificulta exploits)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
# Restringe ptrace (impede um processo de ler a memória de outro)
kernel.yama.ptrace_scope = 1
# Impede symlinks/hardlinks maliciosos em diretórios world-writable
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
# Reduz superfície do BPF não privilegiado
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
# Loga pacotes com endereço de origem suspeito
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF
    sysctl --system >/dev/null 2>&1 || warn "sysctl --system retornou aviso (verifique manualmente)."
    log "Kernel endurecido."
fi

# ── 4. Blacklist de módulos e protocolos raros ─────────────────────────────
MODBLACK="/etc/modprobe.d/99-vps-blacklist.conf"
if [[ -f "$MODBLACK" ]]; then
    already_done "Blacklist de módulos"
else
    info "Bloqueando filesystems e protocolos de rede incomuns..."
    cat > "$MODBLACK" <<'EOF'
# Filesystems raramente usados — reduzem superfície de ataque
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install udf /bin/false
# Protocolos de rede raros
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF
    log "Blacklist de módulos criada."
fi

# ── 5. AppArmor (perfis de confinamento) ───────────────────────────────────
if systemctl is-active --quiet apparmor 2>/dev/null; then
    already_done "AppArmor ativo"
else
    info "Instalando e ativando o AppArmor..."
    DEBIAN_FRONTEND=noninteractive apt install -y apparmor apparmor-utils >/dev/null 2>&1 || warn "Falha ao instalar AppArmor."
    systemctl enable --now apparmor >/dev/null 2>&1 || warn "Não foi possível ativar o AppArmor."
    log "AppArmor ativado."
fi

# ── 6. Auditoria de arquivos sensíveis (auditd) ────────────────────────────
AUDIT_RULES="/etc/audit/rules.d/99-vps-hardening.rules"
if command -v auditctl &>/dev/null; then
    if [[ -f "$AUDIT_RULES" ]]; then
        already_done "Regras de auditoria"
    else
        info "Adicionando regras de auditoria para arquivos sensíveis..."
        cat > "$AUDIT_RULES" <<'EOF'
# Identidade e autenticação
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k privilege
-w /etc/sudoers.d/ -p wa -k privilege
# SSH e configuração de rede
-w /etc/ssh/sshd_config -p wa -k sshd
# Docker (quem mexe na infraestrutura de containers)
-w /usr/bin/docker -p x -k docker
-w /etc/docker/ -p wa -k docker
# Segredos da plataforma
-w /opt/platform/.env -p wa -k secrets
EOF
        augenrules --load >/dev/null 2>&1 || service auditd restart >/dev/null 2>&1 || warn "Recarregue o auditd manualmente."
        log "Regras de auditoria aplicadas."
    fi
else
    warn "auditd não instalado — rode a etapa 1 (pacotes essenciais) primeiro."
fi

# ── 7. Fail2Ban — jail 'recidive' (bane reincidentes por muito mais tempo) ─
JAIL_RECIDIVE="/etc/fail2ban/jail.d/recidive.conf"
if command -v fail2ban-client &>/dev/null; then
    if [[ -f "$JAIL_RECIDIVE" ]]; then
        already_done "Fail2Ban recidive"
    else
        info "Configurando jail 'recidive' do Fail2Ban..."
        cat > "$JAIL_RECIDIVE" <<'EOF'
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 5
EOF
        systemctl restart fail2ban >/dev/null 2>&1 || warn "Reinicie o Fail2Ban manualmente."
        log "Jail recidive ativa (reincidentes banidos por 1 semana)."
    fi
else
    warn "Fail2Ban não instalado — rode a etapa 4 primeiro."
fi

# ── 8. [OPT-IN] 2FA (TOTP) no SSH ──────────────────────────────────────────
echo
warn "2FA no SSH adiciona um segundo fator (app autenticador) além da chave."
warn "RISCO: se mal configurado, pode causar LOCKOUT. Mantenha uma sessão SSH aberta ao ativar."
if confirm "Instalar o suporte a 2FA (TOTP) no SSH agora?"; then
    DEBIAN_FRONTEND=noninteractive apt install -y libpam-google-authenticator >/dev/null 2>&1 \
        && log "libpam-google-authenticator instalado." \
        || warn "Falha na instalação."
    echo
    info "Para ATIVAR o 2FA (faça com uma sessão aberta como salvaguarda):"
    echo -e "  1. Como o usuário SSH, rode: ${CYAN}google-authenticator${RESET} (escaneie o QR no app)."
    echo -e "  2. Em ${CYAN}/etc/pam.d/sshd${RESET}, adicione: ${CYAN}auth required pam_google_authenticator.so${RESET}"
    echo -e "  3. Em ${CYAN}/etc/ssh/sshd_config${RESET}: ${CYAN}KbdInteractiveAuthentication yes${RESET} e"
    echo -e "     ${CYAN}AuthenticationMethods publickey,keyboard-interactive${RESET}"
    echo -e "  4. ${CYAN}sudo sshd -t && sudo systemctl restart ssh${RESET} (teste num NOVO terminal)."
else
    info "2FA no SSH pulado."
fi

# ── 9. [OPT-IN] userns-remap no Docker ─────────────────────────────────────
echo
warn "userns-remap mapeia o root do container para um usuário sem privilégio no host"
warn "(mitiga fugas de container), mas pode quebrar bind mounts e volumes existentes."
if confirm "Ativar userns-remap no Docker? (recomendado só em setup novo)"; then
    DAEMON_JSON="/etc/docker/daemon.json"
    if grep -q '"userns-remap"' "$DAEMON_JSON" 2>/dev/null; then
        already_done "userns-remap"
    else
        cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)" 2>/dev/null || true
        # Insere a chave userns-remap preservando o resto (requer jq).
        if command -v jq &>/dev/null; then
            tmp=$(mktemp)
            jq '. + {"userns-remap":"default"}' "$DAEMON_JSON" > "$tmp" && mv "$tmp" "$DAEMON_JSON"
            systemctl restart docker && log "userns-remap ativado (mapeamento 'default')."
            warn "Suba os stacks novamente (etapas 9 e 19) — os volumes podem precisar de reajuste de permissão."
        else
            warn "jq não instalado — edite ${DAEMON_JSON} manualmente e adicione: \"userns-remap\": \"default\""
        fi
    fi
else
    info "userns-remap pulado."
fi

# ── 10. Guia de camadas que exigem ação sua (fora do escopo automatizável) ─
echo
echo -e "${BOLD}Camadas adicionais recomendadas para dados sigilosos:${RESET}"
echo -e "  • ${BOLD}Criptografia em repouso:${RESET} use um provedor com disco criptografado (LUKS)."
echo -e "    Full-disk encryption é definido na PROVISÃO da VPS, não pós-instalação."
echo -e "  • ${BOLD}Segredos versionados:${RESET} criptografe .env com SOPS + age antes de commitar."
echo -e "  • ${BOLD}Backups criptografados:${RESET} passe os dumps por 'gpg --encrypt' e guarde off-site."
echo -e "  • ${BOLD}Banco:${RESET} exija TLS e senha scram-sha-256; nunca exponha a porta (só túnel SSH)."
echo -e "  • ${BOLD}WAF/IPS:${RESET} considere CrowdSec com bouncer no Traefik para bloqueio colaborativo."
echo -e "  Detalhes em ${CYAN}PT/Servidor/SEGURANCA.md${RESET} e ${CYAN}PT/Cyberseguranca/CYBERSEGURANCA.md${RESET}."

step_done "Camadas extras de segurança"
