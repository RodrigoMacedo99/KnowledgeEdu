#!/bin/bash
# Seção 3 — Hardening do SSH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "03-ssh-hardening"

title "3. Hardening do SSH"

prompt SSH_PORT    "Porta SSH (recomendado: fora do padrão 22)" "2222"
prompt ALLOW_USER  "Usuário permitido via SSH" "admin"

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

info "Fazendo backup: $BACKUP"
cp "$SSHD_CONFIG" "$BACKUP"

# ── Aplicar configurações ──────────────────────────────────────────────────
apply_setting() {
    local key="$1" value="$2"
    if grep -qE "^#?${key}\s" "$SSHD_CONFIG"; then
        sed -i "s|^#\?${key}\s.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

info "Aplicando configurações de segurança no sshd_config..."

# Se a etapa 20 já ligou o 2FA no SSH antes, o sshd_config tem
# 'AuthenticationMethods ...,keyboard-interactive' — forçar
# KbdInteractiveAuthentication de volta para "no" (nosso padrão de base)
# deixaria essa diretiva exigindo um método que acabamos de desligar, e o
# 'sshd -t' recusa a configuração inteira. Preserva o 2FA já configurado.
KBD_INTERACTIVE_DEFAULT="no"
if grep -qE "^AuthenticationMethods .*keyboard-interactive" "$SSHD_CONFIG" 2>/dev/null; then
    KBD_INTERACTIVE_DEFAULT="yes"
    info "2FA no SSH (etapa 20) já estava ativo — mantendo KbdInteractiveAuthentication yes."
fi

apply_setting "Port"                          "$SSH_PORT"
apply_setting "PermitRootLogin"               "no"
apply_setting "PasswordAuthentication"        "no"
apply_setting "PermitEmptyPasswords"          "no"
apply_setting "KbdInteractiveAuthentication"  "$KBD_INTERACTIVE_DEFAULT"
apply_setting "UsePAM"                        "yes"
apply_setting "PubkeyAuthentication"          "yes"
apply_setting "AuthorizedKeysFile"            ".ssh/authorized_keys"
apply_setting "LoginGraceTime"                "30"
apply_setting "MaxAuthTries"                  "3"
apply_setting "MaxSessions"                   "5"
apply_setting "MaxStartups"                   "3:50:10"
apply_setting "AllowUsers"                    "$ALLOW_USER"
apply_setting "X11Forwarding"                 "no"
apply_setting "AllowTcpForwarding"            "no"
apply_setting "AllowAgentForwarding"          "no"
apply_setting "PermitTunnel"                  "no"
apply_setting "PrintLastLog"                  "yes"
apply_setting "ClientAliveInterval"           "300"
apply_setting "ClientAliveCountMax"           "2"
apply_setting "Banner"                        "/etc/issue.net"

# ── Banner de aviso legal — exibido ANTES do login ────────────────────────
# Recomendado pelo caderno Redes II (SENAI CIMATEC) — tem valor legal
BANNER_FILE="/etc/issue.net"
if [[ -s "$BANNER_FILE" ]] && grep -q "autorizado" "$BANNER_FILE"; then
    already_done "Banner de aviso legal (issue.net)"
else
    info "Criando banner de aviso legal em $BANNER_FILE..."
    cat > "$BANNER_FILE" <<'EOF'
╔══════════════════════════════════════════════════════════════════════════╗
║                    ⚠  ACESSO RESTRITO — SISTEMA PRIVADO  ⚠              ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║  Este sistema é de uso exclusivo de usuários AUTORIZADOS.                ║
║  Todo acesso, comando e transferência de dados é MONITORADO              ║
║  e REGISTRADO em conformidade com a legislação vigente.                  ║
║                                                                          ║
║  Acessos não autorizados configuram crime de invasão de dispositivo       ║
║  informático (Art. 154-A do Código Penal Brasileiro — Lei 12.737/2012).  ║
║                                                                          ║
║  Se você não é um usuário autorizado, DESCONECTE IMEDIATAMENTE.          ║
║                                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
EOF
    log "Banner de aviso criado em $BANNER_FILE"
fi

# ── Identidade do servidor (exibida no MOTD) — genérica e configurável ─────
# Nada aqui é fixo: os dados são perguntados e salvos num arquivo que o MOTD lê
# em tempo de execução. Deixe qualquer campo em branco para omiti-lo. Para mudar
# depois, basta editar /etc/vps-setup/server-info (sem reexecutar este script).
SERVER_INFO="/etc/vps-setup/server-info"
mkdir -p /etc/vps-setup
# Reaproveita valores já salvos como default (idempotente em reexecuções).
# shellcheck disable=SC1090
[[ -f "$SERVER_INFO" ]] && source "$SERVER_INFO"

prompt          SERVER_NAME   "Identificação do servidor (título do MOTD)"            "${SERVER_NAME:-$(hostname)}"
prompt_optional ADMIN_NAME    "Administrado por (nome/organização) — vazio p/ omitir" "${ADMIN_NAME:-}"
prompt_optional ADMIN_CONTACT "Contato/URL (ex: github.com/voce) — vazio p/ omitir"  "${ADMIN_CONTACT:-}"
prompt_optional SERVER_DESC   "Descrição curta do servidor — vazio p/ texto genérico" "${SERVER_DESC:-}"

cat > "$SERVER_INFO" <<EOF
# Identidade exibida no MOTD (etapa 3). Edite à vontade — o MOTD lê em tempo real.
SERVER_NAME="${SERVER_NAME}"
ADMIN_NAME="${ADMIN_NAME}"
ADMIN_CONTACT="${ADMIN_CONTACT}"
SERVER_DESC="${SERVER_DESC}"
EOF
chmod 644 "$SERVER_INFO"
log "Identidade do servidor salva em $SERVER_INFO."

# ── MOTD — exibido APÓS o login bem-sucedido ──────────────────────────────
# ASCII art genérico ("SERVER") + identidade lida de $SERVER_INFO em runtime.
MOTD_CUSTOM="/etc/update-motd.d/00-server-banner"
if [[ -f "$MOTD_CUSTOM" ]]; then
    already_done "MOTD customizado"
else
    info "Criando MOTD com banner do servidor..."

    # Desabilita MOTDs padrão do Ubuntu (notícias, publicidade)
    chmod -x /etc/update-motd.d/10-help-text    2>/dev/null || true
    chmod -x /etc/update-motd.d/50-motd-news    2>/dev/null || true
    chmod -x /etc/update-motd.d/80-esm-announce 2>/dev/null || true
    chmod -x /etc/update-motd.d/91-contract-ua-esm-status 2>/dev/null || true

    cat > "$MOTD_CUSTOM" <<'MOTD'
#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'

echo -e "${CYAN}${BOLD}"
cat <<'ASCII'

 ██████╗ ██████╗ ██████╗ ██╗   ██╗███████╗██████╗
██╔════╝██╔════╝ ██╔══██╗██║   ██║██╔════╝██╔══██╗
╚█████╗ █████╗   ██████╔╝╚██╗ ██╔╝█████╗  ██████╔╝
 ╚═══██╗██╔══╝   ██╔══██╗ ╚████╔╝ ██╔══╝  ██╔══██╗
██████╔╝███████╗ ██║  ██║  ╚██╔╝  ███████╗██║  ██║
╚═════╝ ╚══════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝

              INFRAESTRUTURA  ·  SEGURA  ·  ISOLADA

ASCII
echo -e "${RESET}"

# Identidade configurável — definida em /etc/vps-setup/server-info (etapa 3).
[ -f /etc/vps-setup/server-info ] && . /etc/vps-setup/server-info

[ -n "${SERVER_NAME:-}" ]    && echo -e "  ${BOLD}Servidor:${RESET}         ${CYAN}${SERVER_NAME}${RESET}"
[ -n "${ADMIN_NAME:-}" ]     && echo -e "  ${BOLD}Administrado por:${RESET} ${CYAN}${ADMIN_NAME}${RESET}"
[ -n "${ADMIN_CONTACT:-}" ]  && echo -e "  ${BOLD}Contato:${RESET}          ${CYAN}${ADMIN_CONTACT}${RESET}"
echo
if [ -n "${SERVER_DESC:-}" ]; then
    echo -e "  ${SERVER_DESC}"
else
    echo -e "  Servidor de aplicações em containers Docker, isolado por serviço,"
    echo -e "  protegido por firewall, proxy reverso com HTTPS e monitoramento ativo."
fi
echo -e "  ${BOLD}${CYAN}────────────────────────────────────────────────────${RESET}"
echo

# ── Info do sistema ──────────────────────────────────────────────────────
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
UPTIME=$(uptime -p 2>/dev/null || uptime)
LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
MEM_USED=$(free -h | awk '/^Mem/ {print $3}')
MEM_TOTAL=$(free -h | awk '/^Mem/ {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}')
IP_PUB=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/A")
TIME_NOW=$(date '+%d/%m/%Y %H:%M:%S %Z')

echo -e "  ${BOLD}Host:${RESET}     ${GREEN}${HOSTNAME}${RESET}"
echo -e "  ${BOLD}Sistema:${RESET}  ${OS}"
echo -e "  ${BOLD}Kernel:${RESET}   ${KERNEL}"
echo -e "  ${BOLD}IP Público:${RESET} ${CYAN}${IP_PUB}${RESET}"
echo -e "  ${BOLD}Data/Hora:${RESET} ${TIME_NOW}"
echo
echo -e "  ${BOLD}Uptime:${RESET}   ${UPTIME}"
echo -e "  ${BOLD}Load:${RESET}     ${LOAD}"
echo -e "  ${BOLD}Memória:${RESET}  ${MEM_USED} / ${MEM_TOTAL}"
echo -e "  ${BOLD}Disco /:${RESET}  ${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"
echo

# ── Containers Docker ativos ─────────────────────────────────────────────
if command -v docker &>/dev/null; then
    CONTAINERS=$(docker ps --format "{{.Names}} [{{.Status}}]" 2>/dev/null)
    if [[ -n "$CONTAINERS" ]]; then
        echo -e "  ${BOLD}Containers ativos:${RESET}"
        while IFS= read -r line; do
            echo -e "    ${GREEN}▸${RESET} $line"
        done <<< "$CONTAINERS"
        echo
    fi
fi

# ── Alertas de segurança ─────────────────────────────────────────────────
BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
[[ -n "$BANNED" && "$BANNED" != "0" ]] && \
    echo -e "  ${RED}${BOLD}[!] Fail2Ban: ${BANNED} IP(s) banidos atualmente${RESET}"

UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable 2>/dev/null || echo 0)
[[ "$UPDATES" -gt 0 ]] && \
    echo -e "  ${YELLOW}[!] ${UPDATES} pacote(s) com atualização disponível${RESET}"

echo -e "  ${BOLD}${CYAN}────────────────────────────────────────────────────${RESET}"
echo
MOTD

    chmod +x "$MOTD_CUSTOM"
    log "MOTD customizado criado em $MOTD_CUSTOM"
fi

# ── Validar e reiniciar ────────────────────────────────────────────────────
info "Validando configuração..."
sshd -t || die "Configuração inválida — restaure o backup em $BACKUP"

# Garante que a porta nova está liberada no UFW ANTES de reiniciar o sshd.
# Se o sshd reiniciar antes desta regra existir e o UFW já estiver ativo,
# a porta 22 some e a nova ainda não existe — lockout garantido.
info "Abrindo porta ${SSH_PORT} no UFW antes de reiniciar o SSH..."
ufw allow "${SSH_PORT}/tcp" comment 'SSH' 2>/dev/null || true

info "Reiniciando SSH..."
# Ubuntu 24.04 usa socket activation: ssh.socket controla a porta,
# não o sshd_config. Sem sobrescrever o socket, o SSH fica na 22
# mesmo com Port 2222 no sshd_config.
if systemctl is-active --quiet ssh.socket 2>/dev/null || \
   systemctl list-units --full -all 2>/dev/null | grep -q "ssh.socket"; then
    # Ubuntu 24.04: ssh.socket controla a porta. Sem declarar 0.0.0.0 explicitamente
    # o socket escuta só em IPv6, recusando conexões IPv4.
    info "Socket activation detectado — configurando porta ${SSH_PORT} em IPv4 e IPv6..."
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl restart ssh
else
    if systemctl list-units --full -all | grep -q "sshd.service"; then
        systemctl restart sshd
    else
        systemctl restart ssh
    fi
fi

log "SSH escutando na porta $SSH_PORT."
echo
warn "Conecte com: ssh -p ${SSH_PORT} ${ALLOW_USER}@IP_DA_VPS"
warn "Ou adicione ao ~/.ssh/config:"
echo -e "
  ${CYAN}Host vps
      HostName IP_DA_VPS
      User ${ALLOW_USER}
      Port ${SSH_PORT}
      IdentityFile ~/.ssh/vps_key${RESET}
"

step_done "Hardening do SSH (porta ${SSH_PORT})"
