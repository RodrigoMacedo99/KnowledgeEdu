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
}

already_done() {
    warn "$* — já configurado, pulando."
}

# ── Inicialização do log ───────────────────────────────────────────────────
init_log() {
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps-setup.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | START | $*" >> "$LOG_FILE"
}
