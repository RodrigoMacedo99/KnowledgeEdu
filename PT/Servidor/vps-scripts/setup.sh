#!/bin/bash
# VPS Setup Manager — orquestrador principal
# Baseado em VPS_SETUP.md | Ubuntu 24.04 LTS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/common.sh"

# ── Verificações iniciais ──────────────────────────────────────────────────
require_root
require_ubuntu
init_log "setup-manager"

# ── Gum: interface de menu interativa (Charm — https://github.com/charmbracelet/gum)
# Um binário só, instalado pelo repositório oficial (apt, assinado por GPG). Dá
# navegação por setas, busca por texto e caixas com borda colorida — sem a gente
# calcular padding/alinhamento na mão (era a fonte dos bugs visuais anteriores).
# Se a instalação falhar por qualquer motivo, o script CONTINUA funcionando no
# menu de texto simples (fallback abaixo) — o Gum nunca é obrigatório.
ensure_gum() {
    command -v gum &>/dev/null && return 0
    info "Instalando o Gum (interface de menu interativa)..."
    mkdir -p /etc/apt/keyrings
    if curl -fsSL https://repo.charm.sh/apt/gpg.key 2>/dev/null | gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null \
        && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list \
        && apt-get update -qq 2>/dev/null \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y gum >/dev/null 2>&1; then
        log "Gum instalado."
    else
        warn "Não consegui instalar o Gum — usando o menu de texto simples (sem prejuízo funcional)."
    fi
}
ensure_gum
HAS_GUM=0
command -v gum &>/dev/null && HAS_GUM=1

# Paleta (códigos de cor ANSI 256, usados pelo Gum): 51 ciano, 42 verde-água,
# 214 laranja/dourado, 213 magenta — o mesmo espírito neon do menu de texto.
G_BORDER=51
G_ACCENT=42
G_HILITE=214
G_MAGENTA=213

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
# Configurável, sem hardcode: se existir /etc/vps-setup/menu-banner.txt (e não
# estiver vazio), ele é exibido — troque o conteúdo por qualquer ASCII art sua
# (ex.: gerada em https://patorjk.com/software/taag/ ou com 'figlet'/'toilet').
# Sem esse arquivo, cai num padrão genérico.
MENU_BANNER_FILE="/etc/vps-setup/menu-banner.txt"

banner_title() {
    if [[ -s "$MENU_BANNER_FILE" ]]; then
        cat "$MENU_BANNER_FILE"
    elif command -v toilet &>/dev/null; then
        toilet -f mono12 -F border "VPS MANAGER" 2>/dev/null || echo "VPS MANAGER"
    elif command -v figlet &>/dev/null; then
        figlet -f standard "VPS MANAGER" 2>/dev/null || echo "VPS MANAGER"
    else
        echo "VPS MANAGER"
    fi
}

print_banner() {
    if (( HAS_GUM )); then
        local tagline sub
        tagline="$(gum style --foreground "$G_BORDER" 'SEU SERVIDOR')$(gum style ' • ')$(gum style --foreground "$G_ACCENT" 'SEU CONTROLE')$(gum style ' • ')$(gum style --bold --foreground "$G_HILITE" 'MAIS SEGURANÇA')"
        sub="$(gum style --bold 'SETUP · CONFIGURAÇÃO · MONITORAMENTO · KUBERNETES')"
        gum style \
            --border double --border-foreground "$G_BORDER" \
            --padding "1 3" --margin "1 0" --align center \
            "$(gum style --bold --foreground "$G_BORDER" "$(banner_title)")" \
            "" "$tagline" "$sub"
    else
        echo -e "${CYAN}${BOLD}"
        banner_title
        echo -e "${RESET}"
        echo -e "  ${CYAN}SEU SERVIDOR${RESET} • ${GREEN}SEU CONTROLE${RESET} • ${YELLOW}MAIS SEGURANÇA${RESET}"
        echo -e "  ${BOLD}SETUP${RESET} · ${BOLD}CONFIGURAÇÃO${RESET} · ${BOLD}MONITORAMENTO${RESET} · ${BOLD}KUBERNETES${RESET}"
    fi
    [[ -s "$MENU_BANNER_FILE" ]] || echo -e "  ${CYAN}Personalize este banner:${RESET} edite ${BOLD}${MENU_BANNER_FILE}${RESET}"
}

# ── Menu principal (fallback de texto — sem Gum) ────────────────────────────
# Duas colunas lado a lado quando o terminal é largo o bastante; senão, cai
# para uma coluna só (mesmo conteúdo, sem quebrar a borda da caixa). A largura
# é medida em CARACTERES (${#var}), não bytes — com acentuação (ção, ã, é...)
# medir por bytes desalinharia as bordas entre linhas.
show_menu_plain() {
    clear
    print_banner
    echo

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

    local -a right=() right_plain=()
    for i in $(seq 15 29); do
        plain="$(printf '%2d) %s' "$i" "${STEP_NAMES[$i]}")"
        right_plain+=("$plain")
        right+=("$(printf '%s%2d)%s %s' "$YELLOW" "$i" "$RESET" "${STEP_NAMES[$i]}")")
    done
    right_plain+=("" " 0) Sair")
    right+=("" "$(printf '%s%2d)%s Sair' "$YELLOW" 0 "$RESET")")

    local lw=0 rw=0 n
    for plain in "${left_plain[@]}"; do (( ${#plain} > lw )) && lw=${#plain}; done
    for plain in "${right_plain[@]}"; do (( ${#plain} > rw )) && rw=${#plain}; done

    local term_width box_width
    term_width="$(tput cols 2>/dev/null || echo 80)"
    box_width=$(( lw + rw + 3 ))

    if (( term_width >= box_width + 4 )); then
        local rows=${#left[@]}
        (( ${#right[@]} > rows )) && rows=${#right[@]}
        for (( n=0; n<rows; n++ )); do
            local lp="${left_plain[n]:-}" ltext="${left[n]:-}"
            local rtext="${right[n]:-}"
            local pad=$(( lw - ${#lp} ))
            (( pad < 0 )) && pad=0
            printf '%b' "$ltext"
            printf '%*s' "$pad" ''
            printf '%b\n' "   ${rtext}"
        done
    else
        for n in "${!left[@]}"; do echo -e "${left[n]}"; done
        for n in "${!right[@]}"; do echo -e "${right[n]}"; done
    fi

    echo
    echo -e "  Log em: ${CYAN}/var/log/vps-setup.log${RESET}"
    echo -e "  ${CYAN}INFRAESTRUTURA${RESET} • ${GREEN}AUTOMAÇÃO${RESET} • ${YELLOW}LIBERDADE${RESET}"
    echo
}

# ── Menu principal (Gum) — navegação por setas + busca por texto ───────────
# 'gum filter' já É o "mostrar + ler a escolha" num passo só: renderiza a lista,
# deixa digitar para filtrar/buscar, e devolve a linha escolhida (ou vazio se
# Esc/Ctrl+C). Extraímos o identificador (a, NN ou 0) do início da linha.
build_menu_lines() {
    printf '%s\n' " a)  Executar setup completo (escolhe o runtime e monta tudo)"
    local i
    for i in $(seq 1 29); do
        printf '%2d)  %s\n' "$i" "${STEP_NAMES[$i]}"
    done
    printf '%s\n' " 0)  Sair"
}

get_choice_gum() {
    clear
    print_banner
    echo
    local selection
    selection="$(build_menu_lines | gum filter \
        --placeholder 'Digite para buscar… (↑↓ navega, Enter escolhe, Esc cancela)' \
        --height 18 --width 90 \
        --indicator '▶' \
        --indicator.foreground "$G_HILITE" \
        --match.foreground "$G_MAGENTA" \
        --header 'ETAPAS — busque por nome ou número' \
        --header.foreground "$G_BORDER")"
    [[ -z "$selection" ]] && { echo ""; return; }
    selection="${selection%%)*}"
    echo "${selection// /}"
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
    if (( HAS_GUM )); then
        gum style --bold --foreground "$G_BORDER" "─── Iniciando etapa ${step}: ${STEP_NAMES[$step]} ───"
    else
        echo -e "${BOLD}${CYAN}─── Iniciando etapa ${step}: ${STEP_NAMES[$step]} ───${RESET}"
    fi
    echo
    bash "$script"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo
        if (( HAS_GUM )); then
            gum style --bold --foreground "$G_ACCENT" "[✔] Etapa ${step} concluída com sucesso."
        else
            echo -e "${GREEN}${BOLD}[✔] Etapa ${step} concluída com sucesso.${RESET}"
        fi
    else
        echo
        echo -e "${RED}${BOLD}[✘] Etapa ${step} encerrada com erro (código: ${exit_code}).${RESET}"
        echo -e "     Verifique o log: ${CYAN}/var/log/vps-setup.log${RESET}"
    fi
    echo
    read -rp "Pressione Enter para voltar ao menu..." _
}

# ── Confirmação (usa 'gum confirm' quando disponível) ───────────────────────
ask_confirm() {
    local msg="$1"
    if (( HAS_GUM )); then
        gum confirm --prompt.foreground "$G_BORDER" --selected.background "$G_BORDER" "$msg"
    else
        confirm "$msg"
    fi
}

# ── Setup guiado ──────────────────────────────────────────────────────────
run_full_setup() {
    echo
    local rt
    if (( HAS_GUM )); then
        local rt_label
        rt_label="$(gum choose --header 'Qual runtime de aplicação você quer nesta VPS?' \
            --header.foreground "$G_BORDER" --cursor.foreground "$G_HILITE" --selected.foreground "$G_ACCENT" \
            'Docker Compose — Traefik, observabilidade e 2FA (recomendado)' \
            'k3s (Kubernetes leve) — a mesma capacidade no modelo Kubernetes' \
            'Apenas a base endurecida (sem runtime de aplicação)')"
        case "$rt_label" in
            'Docker Compose — Traefik, observabilidade e 2FA (recomendado)') rt=1 ;;
            'k3s (Kubernetes leve) — a mesma capacidade no modelo Kubernetes') rt=2 ;;
            'Apenas a base endurecida (sem runtime de aplicação)') rt=3 ;;
            *) warn "Nenhuma opção escolhida."; sleep 1; return ;;
        esac
    else
        echo -e "  ${BOLD}Qual runtime de aplicação você quer nesta VPS?${RESET}"
        echo -e "    ${YELLOW}1${RESET}) Docker Compose ${GREEN}(recomendado)${RESET} — Traefik, observabilidade e 2FA no modelo Compose"
        echo -e "    ${YELLOW}2${RESET}) k3s (Kubernetes leve) — a mesma capacidade no modelo Kubernetes"
        echo -e "    ${YELLOW}3${RESET}) Apenas a base endurecida (sem runtime de aplicação)"
        echo
        read -rp "$(echo -e "${YELLOW}Escolha [1]:${RESET} ")" rt
        rt="${rt:-1}"
    fi

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
    ask_confirm "Iniciar setup completo (${label})?" || return

    local total=${#plan[@]} n=0
    for i in "${plan[@]}"; do
        n=$((n + 1))
        echo
        if (( HAS_GUM )); then
            gum style --bold --foreground "$G_BORDER" "════ Etapa ${i} (${n}/${total}): ${STEP_NAMES[$i]} ════"
        else
            echo -e "${BOLD}${CYAN}════ Etapa ${i} (${n}/${total}): ${STEP_NAMES[$i]} ════${RESET}"
        fi
        echo
        bash "${SCRIPT_DIR}/${STEP_SCRIPTS[$i]}"
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            error "Etapa $i falhou (código: $exit_code)."
            ask_confirm "Continuar para a próxima etapa mesmo assim?" || break
        fi
    done

    echo
    if (( HAS_GUM )); then
        gum style --border double --border-foreground "$G_ACCENT" --padding "1 2" --bold --foreground "$G_ACCENT" \
            "══ Setup (${label}) concluído! ══"
    else
        echo -e "${GREEN}${BOLD}══ Setup (${label}) concluído! ══${RESET}"
    fi
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
    if (( HAS_GUM )); then
        choice="$(get_choice_gum)"
        [[ -z "$choice" ]] && continue   # Esc/Ctrl+C no gum filter — só redesenha
    else
        show_menu_plain
        read -rp "$(echo -e "${YELLOW}Escolha uma opção:${RESET} ")" choice
    fi

    case "$choice" in
        a|A) run_full_setup ;;
        [1-9]|1[0-9]|2[0-9]) run_step "$choice" ;;
        0) echo -e "\n${GREEN}Saindo.${RESET}"; exit 0 ;;
        *) warn "Opção inválida." ; sleep 1 ;;
    esac
done
