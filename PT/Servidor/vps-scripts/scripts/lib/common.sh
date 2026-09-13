#!/bin/bash
# Funções compartilhadas por todos os scripts de setup

set -euo pipefail

# ── Cores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Logging ────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/vps-setup.log"

log()    { echo -e "${GREEN}[✔]${RESET} $*" | tee -a "$LOG_FILE"; }
info()   { echo -e "${BLUE}[→]${RESET} $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[✘]${RESET} $*" | tee -a "$LOG_FILE"; }
title()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}\n" | tee -a "$LOG_FILE"; }
die()    { error "$*"; exit 1; }

# ── Pré-requisitos ─────────────────────────────────────────────────────────
require_root() {
    [[ "$EUID" -eq 0 ]] || die "Este script deve ser executado como root (use sudo)."
}

require_ubuntu() {
    grep -qi "ubuntu" /etc/os-release 2>/dev/null || die "Este script requer Ubuntu."
}

require_command() {
    command -v "$1" &>/dev/null || die "Comando não encontrado: $1"
}

# ── Utilitários ────────────────────────────────────────────────────────────
confirm() {
    local prompt="${1:-Continuar?}"
    read -rp "$(echo -e "${YELLOW}[?]${RESET} ${prompt} [s/N] ")" answer
    [[ "${answer,,}" =~ ^(s|sim|y|yes)$ ]]
}

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" [${default}]"
    read -rp "$(echo -e "${CYAN}[?]${RESET} ${prompt_text}${display_default}: ")" value
    value="${value:-$default}"
    [[ -z "$value" ]] && die "Valor obrigatório não fornecido: $var_name"
    printf -v "$var_name" '%s' "$value"
}

# Como prompt(), mas aceita ficar em branco — para campos onde vazio é uma
# resposta válida (ex: "deixe vazio para pular"), em que exigir um valor
# obrigaria o usuário a digitar algo só para satisfazer a validação.
prompt_optional() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" [${default}]"
    read -rp "$(echo -e "${CYAN}[?]${RESET} ${prompt_text}${display_default}: ")" value
    value="${value:-$default}"
    printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    read -rsp "$(echo -e "${CYAN}[?]${RESET} ${prompt_text}: ")" value
    echo
    [[ -z "$value" ]] && die "Valor obrigatório não fornecido: $var_name"
    printf -v "$var_name" '%s' "$value"
}

step_done() {
    echo -e "${GREEN}${BOLD}[✔] $* concluído.${RESET}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | DONE | $*" >> "$LOG_FILE"
    # Marca a etapa como concluída (número extraído por init_log) — é o que
    # permite o setup guiado ('a') pular na próxima vez o que já foi feito.
    [[ -n "${CURRENT_STEP_NUM:-}" ]] && mark_step_completed "$CURRENT_STEP_NUM"
}

already_done() {
    warn "$* — já configurado, pulando."
}

# ── Registro de etapas concluídas (para o setup guiado pular o que já foi
# feito) ─────────────────────────────────────────────────────────────────────
# "Concluída" aqui significa "o script chegou ao fim sem 'die'" — a mesma
# régua que o resto do codebase já usa para distinguir erro fatal (die, para
# tudo) de aviso recuperável (warn, segue em frente). Não é garantia de saúde
# atual (para isso existe a etapa 24) — é só "você já passou por aqui".
COMPLETED_STEPS_FILE="/etc/vps-setup/completed_steps"

mark_step_completed() {
    local step="$1"
    mkdir -p "$(dirname "$COMPLETED_STEPS_FILE")"
    touch "$COMPLETED_STEPS_FILE"
    grep -qxF "$step" "$COMPLETED_STEPS_FILE" 2>/dev/null || echo "$step" >> "$COMPLETED_STEPS_FILE"
}

step_is_completed() {
    local step="$1"
    [[ -f "$COMPLETED_STEPS_FILE" ]] && grep -qxF "$step" "$COMPLETED_STEPS_FILE" 2>/dev/null
}

# ── Registro de configuração (lembra escolhas NÃO-secretas entre execuções)
# ─────────────────────────────────────────────────────────────────────────────
# NUNCA guarde senhas/segredos aqui — esses já têm seus lugares seguros
# (/opt/platform/.env, Secrets do k3s). Isto é só para domínios, e-mails,
# nomes de container etc. — coisas que, se um script precisar rodar de novo,
# você não quer digitar do zero outra vez.
VPS_CONFIG_FILE="/etc/vps-setup/config.env"

save_config() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$VPS_CONFIG_FILE")"
    touch "$VPS_CONFIG_FILE"
    if grep -q "^${key}=" "$VPS_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$VPS_CONFIG_FILE"
    else
        echo "${key}=\"${value}\"" >> "$VPS_CONFIG_FILE"
    fi
    chmod 600 "$VPS_CONFIG_FILE"
}

# get_config CHAVE [PADRÃO] — imprime o valor já salvo, ou o padrão se não
# houver nenhum. Uso típico: prompt VAR "texto" "$(get_config CHAVE padrao)"
get_config() {
    local key="$1" default="${2:-}"
    [[ -f "$VPS_CONFIG_FILE" ]] || { echo "$default"; return; }
    local value
    value="$(grep "^${key}=" "$VPS_CONFIG_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//')"
    echo "${value:-$default}"
}

# ── Inicialização do log ───────────────────────────────────────────────────
init_log() {
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps-setup.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | START | $*" >> "$LOG_FILE"
    # Extrai o número da etapa do prefixo "NN-nome" (convenção já usada em todo
    # script) — é com ele que step_done() marca a conclusão. "10#" força base
    # 10 na conversão (sem isso, "08"/"09" quebram — não são dígitos octais
    # válidos) e normaliza "02" -> "2", batendo com os arrays de etapas do
    # setup.sh (que usam números sem zero à esquerda). Prefixos não-numéricos
    # (ex.: o próprio "setup-manager" do setup.sh) deixam vazio, sem marcar nada.
    local raw="${1%%-*}"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        CURRENT_STEP_NUM="$((10#$raw))"
    else
        CURRENT_STEP_NUM=""
    fi
}
