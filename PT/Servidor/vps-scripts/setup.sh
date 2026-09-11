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
    [8]="Docker (instalação, redes e segurança)"
    [9]="Edge proxy (Traefik)"
    [10]="TLS/HTTPS (status e diagnóstico)"
    [11]="Segurança do PostgreSQL e backup"
    [12]="Atualizações automáticas de segurança"
    [13]="Monitoramento e logs"
    [14]="Hardening contínuo do kernel e auditoria"
    [15]="Adicionar novo serviço (monorepo)"
    [16]="NTP — Sincronização de tempo (Chrony)"
    [17]="Gerador de CI/CD (GitHub Actions)"
    [18]="Gerenciador de portas"
    [19]="Observabilidade (métricas, logs, alertas)"
    [20]="Camadas extras de segurança"
    [21]="2FA/SSO nos serviços web (Authelia)"
    [22]="Backups automatizados e criptografados"
    [23]="CrowdSec (IPS colaborativo)"
    [24]="Verificação da plataforma (self-check)"
    [25]="Runtime alternativo: k3s"
    [26]="k3s: observabilidade"
    [27]="k3s: 2FA/SSO (Authelia)"
    [28]="Criar usuário operador (além do admin)"
    [29]="k3s: adicionar serviço (monorepo)"
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
    [9]="scripts/09-edge-proxy.sh"
    [10]="scripts/10-ssl.sh"
    [11]="scripts/11-postgres.sh"
    [12]="scripts/12-auto-updates.sh"
    [13]="scripts/13-monitoring.sh"
    [14]="scripts/14-hardening.sh"
    [15]="scripts/15-new-project.sh"
    [16]="scripts/16-ntp.sh"
    [17]="scripts/17-cicd-generator.sh"
    [18]="scripts/18-port-manager.sh"
    [19]="scripts/19-observability.sh"
    [20]="scripts/20-hardening-extra.sh"
    [21]="scripts/21-2fa-web.sh"
    [22]="scripts/22-backups.sh"
    [23]="scripts/23-crowdsec.sh"
    [24]="scripts/24-verify.sh"
    [25]="scripts/25-k3s.sh"
    [26]="scripts/26-k3s-observability.sh"
    [27]="scripts/27-k3s-2fa.sh"
    [28]="scripts/28-operator-user.sh"
    [29]="scripts/29-k3s-new-project.sh"
)

# O setup guiado pergunta o RUNTIME e monta a sequência a partir daí.
# BASE_STEPS é a infraestrutura endurecida, comum a qualquer runtime (sem runtime
# de aplicação). Depois vêm as etapas do runtime escolhido, e a 24 (verificação)
# fecha. Sob demanda (fora do guiado): 13 (monitor), 15 (serviço), 17 (CI/CD),
# 18 (portas).
BASE_STEPS=(1 2 3 4 5 6 7 12 14 16 20 22 23)
DOCKER_STEPS=(8 9 10 11 19 21)
K3S_STEPS=(25 26 27)

# ── Banner ─────────────────────────────────────────────────────────────────
# Usa figlet/toilet se estiverem instalados (visual "VPS MANAGER" completo);
# sem eles, cai num título simples — nunca tenta desenhar ASCII art à mão
# (um pixel torto deixaria o menu pior do que um título liso).
print_banner() {
    echo -e "${CYAN}${BOLD}"
    if command -v toilet &>/dev/null; then
        toilet -f mono12 -F border "VPS MANAGER" 2>/dev/null || echo "VPS MANAGER"
    elif command -v figlet &>/dev/null; then
        figlet -f standard "VPS MANAGER" 2>/dev/null || echo "VPS MANAGER"
    else
        echo "██  VPS MANAGER  ██"
    fi
    echo -e "${RESET}"
    echo -e "  ${CYAN}SEU SERVIDOR${RESET} • ${GREEN}SEU CONTROLE${RESET} • ${YELLOW}MAIS SEGURANÇA${RESET}"
    echo -e "  ${BOLD}SETUP${RESET} · ${BOLD}CONFIGURAÇÃO${RESET} · ${BOLD}MONITORAMENTO${RESET} · ${BOLD}KUBERNETES${RESET}"
}

# ── Menu principal ─────────────────────────────────────────────────────────
# Duas colunas lado a lado quando o terminal é largo o bastante; senão, cai
# para uma coluna só (mesmo conteúdo, sem quebrar a borda da caixa). A largura
# é medida em CARACTERES (${#var}), não bytes — com acentuação (ção, ã, é...)
# medir por bytes desalinharia as bordas entre linhas.
show_menu() {
    clear
    print_banner
    echo

    # Linhas da coluna esquerda: cabeçalho do setup guiado + etapas 1–14.
    local -a left=(
        "${GREEN}⚙${RESET}  ${BOLD}Setup guiado${RESET} (escolhe o runtime e monta tudo):"
        "   ${YELLOW}a)${RESET} Executar setup completo"
        ""
        "${GREEN}▤${RESET}  ${BOLD}Etapas individuais:${RESET}"
        ""
    )
    local -a left_plain=(
        "  Setup guiado (escolhe o runtime e monta tudo):"
        "   a) Executar setup completo"
        ""
        "  Etapas individuais:"
        ""
    )
    local i plain
    for i in $(seq 1 14); do
        plain="$(printf '%2d) %s' "$i" "${STEP_NAMES[$i]}")"
        left_plain+=("$plain")
        left+=("$(printf '%s%2d)%s %s' "$YELLOW" "$i" "$RESET" "${STEP_NAMES[$i]}")")
    done

    # Coluna direita: etapas 15–29 + Sair.
    local -a right=() right_plain=()
    for i in $(seq 15 29); do
        plain="$(printf '%2d) %s' "$i" "${STEP_NAMES[$i]}")"
        right_plain+=("$plain")
        right+=("$(printf '%s%2d)%s %s' "$YELLOW" "$i" "$RESET" "${STEP_NAMES[$i]}")")
    done
    right_plain+=("" " 0) Sair")
    right+=("" "$(printf '%s%2d)%s Sair' "$YELLOW" 0 "$RESET")")

    # Largura de cada coluna = maior linha PLANA (sem cor) daquela coluna.
    local lw=0 rw=0 n
    for plain in "${left_plain[@]}"; do (( ${#plain} > lw )) && lw=${#plain}; done
    for plain in "${right_plain[@]}"; do (( ${#plain} > rw )) && rw=${#plain}; done

    local term_width box_width
    term_width="$(tput cols 2>/dev/null || echo 80)"
    box_width=$(( lw + rw + 3 ))   # +3 = margem entre colunas ("  ")

    if (( term_width >= box_width + 4 )); then
        # ── Layout de duas colunas ──────────────────────────────────────────
        local rows=${#left[@]}
        (( ${#right[@]} > rows )) && rows=${#right[@]}
        for (( n=0; n<rows; n++ )); do
            local lp="${left_plain[n]:-}" ltext="${left[n]:-}"
            local rtext="${right[n]:-}"
            local pad=$(( lw - ${#lp} ))
            (( pad < 0 )) && pad=0
            # '%b' interpreta as sequências \033[...m guardadas como texto nas
            # cores (RED/GREEN/... em common.sh usam aspas simples — só viram
            # cor de verdade via 'echo -e' ou 'printf %b'; '%s' as imprimiria
            # literalmente, que foi o bug visto em produção).
            printf '%b' "$ltext"
            printf '%*s' "$pad" ''
            printf '%b\n' "   ${rtext}"
        done
    else
        # ── Fallback: terminal estreito — uma coluna só, sem quebrar nada ──
        for n in "${!left[@]}"; do echo -e "${left[n]}"; done
        for n in "${!right[@]}"; do echo -e "${right[n]}"; done
    fi

    echo
    echo -e "  Log em: ${CYAN}/var/log/vps-setup.log${RESET}"
    echo -e "  ${CYAN}INFRAESTRUTURA${RESET} • ${GREEN}AUTOMAÇÃO${RESET} • ${YELLOW}LIBERDADE${RESET}"
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

# ── Setup guiado ──────────────────────────────────────────────────────────
run_full_setup() {
    echo
    echo -e "  ${BOLD}Qual runtime de aplicação você quer nesta VPS?${RESET}"
    echo -e "    ${YELLOW}1${RESET}) Docker Compose ${GREEN}(recomendado)${RESET} — Traefik, observabilidade e 2FA no modelo Compose"
    echo -e "    ${YELLOW}2${RESET}) k3s (Kubernetes leve) — a mesma capacidade no modelo Kubernetes"
    echo -e "    ${YELLOW}3${RESET}) Apenas a base endurecida (sem runtime de aplicação)"
    echo
    read -rp "$(echo -e "${YELLOW}Escolha [1]:${RESET} ")" rt
    rt="${rt:-1}"

    local -a plan=("${BASE_STEPS[@]}")
    local label=""
    case "$rt" in
        1) plan+=("${DOCKER_STEPS[@]}"); label="Docker Compose"; export VPS_RUNTIME="docker" ;;
        2) plan+=("${K3S_STEPS[@]}");    label="k3s";            export VPS_RUNTIME="k3s" ;;
        3) label="somente base";         export VPS_RUNTIME="base" ;;
        *) warn "Opção inválida."; sleep 1; return ;;
    esac
    plan+=(24)   # verificação final, sempre por último

    echo
    warn "Runtime: ${BOLD}${label}${RESET}. Sequência de etapas: ${plan[*]}"
    warn "As etapas 15 (novo serviço) e 17 (CI/CD) são sob demanda — rode-as depois."
    warn "Você será solicitado a fornecer informações em cada etapa."
    echo
    confirm "Iniciar setup completo (${label})?" || return

    local total=${#plan[@]} n=0
    for i in "${plan[@]}"; do
        n=$((n + 1))
        echo
        echo -e "${BOLD}${CYAN}════ Etapa ${i} (${n}/${total}): ${STEP_NAMES[$i]} ════${RESET}"
        echo
        bash "${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            error "Etapa $i falhou (código: $exit_code)."
            confirm "Continuar para a próxima etapa mesmo assim?" || break
        fi
    done

    echo
    echo -e "${GREEN}${BOLD}══ Setup (${label}) concluído! ══${RESET}"
    echo
    echo -e "Próximos passos:"
    echo -e "  • Aponte o DNS do dashboard do Traefik e do Grafana para o IP da VPS"
    echo -e "  • Use a etapa ${YELLOW}15${RESET} para adicionar um novo serviço (monorepo multi-container)"
    echo -e "  • Use a etapa ${YELLOW}17${RESET} para gerar o CI/CD (GitHub Actions) de um serviço"
    echo -e "  • Use a etapa ${YELLOW}12${RESET} do monitor (opção 12) para ver as URLs do Grafana/Traefik"
    echo -e "  • Consulte o log em: ${CYAN}/var/log/vps-setup.log${RESET}"
    echo
}

# ── Loop do menu ──────────────────────────────────────────────────────────
while true; do
    show_menu
    read -rp "$(echo -e "${YELLOW}Escolha uma opção:${RESET} ")" choice

    case "$choice" in
        a|A) run_full_setup ;;
        [1-9]|1[0-9]|2[0-9]) run_step "$choice" ;;
        0) echo -e "\n${GREEN}Saindo.${RESET}"; exit 0 ;;
        *) warn "Opção inválida." ; sleep 1 ;;
    esac
done
