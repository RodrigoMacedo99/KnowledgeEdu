#!/bin/bash
# VPS Setup Manager — orquestrador principal
# Baseado em VPS_SETUP.md | Ubuntu 24.04 LTS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/common.sh"

# ── Verificações iniciais ──────────────────────────────────────────────────
require_root
require_ubuntu
init_log "setup-manager"

# ── Ordem de execução recomendada ─────────────────────────────────────────
declare -A STEP_NAMES=(
    [1]="Atualização do sistema e pacotes essenciais"
    [2]="Usuário administrador e bloqueio do root"
    [3]="Hardening do SSH"
    [4]="Proteção contra força bruta (Fail2Ban)"
    [5]="Firewall (UFW)"
    [6]="Grupos e usuários por projeto"
    [7]="Estrutura de pastas e permissões"
    [8]="Docker (instalação e configuração segura)"
    [9]="Nginx como reverse proxy"
    [10]="SSL com Let's Encrypt"
    [11]="Segurança do PostgreSQL e backup"
    [12]="Atualizações automáticas de segurança"
    [13]="Monitoramento e logs"
    [14]="Hardening contínuo do kernel e auditoria"
    [15]="Adicionar novo projeto"
    [16]="NTP — Sincronização de tempo (Chrony)"
)

declare -A STEP_SCRIPTS=(
    [1]="scripts/01-update.sh"
    [2]="scripts/02-admin-user.sh"
    [3]="scripts/03-ssh-hardening.sh"
    [4]="scripts/04-fail2ban.sh"
    [5]="scripts/05-ufw.sh"
    [6]="scripts/06-groups-users.sh"
    [7]="scripts/07-folder-structure.sh"
    [8]="scripts/08-docker.sh"
    [9]="scripts/09-nginx.sh"
    [10]="scripts/10-ssl.sh"
    [11]="scripts/11-postgres.sh"
    [12]="scripts/12-auto-updates.sh"
    [13]="scripts/13-monitoring.sh"
    [14]="scripts/14-hardening.sh"
    [15]="scripts/15-new-project.sh"
    [16]="scripts/16-ntp.sh"
)

# ── Menu principal ─────────────────────────────────────────────────────────
show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              VPS SETUP MANAGER — Ubuntu 24.04 LTS           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${BOLD}Setup completo (etapas 1–14):${RESET}"
    echo -e "    ${YELLOW}a${RESET}) Executar setup completo em sequência"
    echo
    echo -e "  ${BOLD}Etapas individuais:${RESET}"
    for i in $(seq 1 16); do
        printf "    ${YELLOW}%2d${RESET}) %s\n" "$i" "${STEP_NAMES[$i]}"
    done
    echo
    echo -e "    ${YELLOW} 0${RESET}) Sair"
    echo
    echo -e "  Log em: ${CYAN}/var/log/vps-setup.log${RESET}"
    echo
}

# ── Executar uma etapa ────────────────────────────────────────────────────
run_step() {
    local step="$1"
    local script="${SCRIPT_DIR}/${STEP_SCRIPTS[$step]}"

    if [[ ! -f "$script" ]]; then
        error "Script não encontrado: $script"
        return 1
    fi

    chmod +x "$script"
    echo
    echo -e "${BOLD}${CYAN}─── Iniciando etapa ${step}: ${STEP_NAMES[$step]} ───${RESET}"
    echo
    bash "$script"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo
        echo -e "${GREEN}${BOLD}[✔] Etapa ${step} concluída com sucesso.${RESET}"
    else
        echo
        echo -e "${RED}${BOLD}[✘] Etapa ${step} encerrada com erro (código: ${exit_code}).${RESET}"
        echo -e "     Verifique o log: ${CYAN}/var/log/vps-setup.log${RESET}"
    fi
    echo
    read -rp "Pressione Enter para voltar ao menu..." _
}

# ── Setup completo ────────────────────────────────────────────────────────
run_full_setup() {
    echo
    warn "O setup completo executará as etapas 1 a 14 em sequência."
    warn "Você será solicitado a fornecer informações em cada etapa."
    echo
    confirm "Iniciar setup completo?" || return

    for i in $(seq 1 16); do
        echo
        echo -e "${BOLD}${CYAN}════ Etapa ${i}/14: ${STEP_NAMES[$i]} ════${RESET}"
        echo
        bash "${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            error "Etapa $i falhou (código: $exit_code)."
            confirm "Continuar para a próxima etapa mesmo assim?" || break
        fi
    done

    echo
    echo -e "${GREEN}${BOLD}══ Setup concluído! ══${RESET}"
    echo
    echo -e "Próximos passos:"
    echo -e "  • Edite os arquivos ${CYAN}.env${RESET} de cada projeto"
    echo -e "  • Suba os containers: ${CYAN}docker compose up --build -d${RESET}"
    echo -e "  • Use a etapa ${YELLOW}15${RESET} para adicionar novos projetos"
    echo -e "  • Consulte o log em: ${CYAN}/var/log/vps-setup.log${RESET}"
    echo
}

# ── Loop do menu ──────────────────────────────────────────────────────────
while true; do
    show_menu
    read -rp "$(echo -e "${YELLOW}Escolha uma opção:${RESET} ")" choice

    case "$choice" in
        a|A) run_full_setup ;;
        [1-9]|1[0-5]) run_step "$choice" ;;
        0) echo -e "\n${GREEN}Saindo.${RESET}"; exit 0 ;;
        *) warn "Opção inválida." ; sleep 1 ;;
    esac
done
