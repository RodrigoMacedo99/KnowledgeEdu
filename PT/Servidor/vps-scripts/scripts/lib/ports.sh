#!/bin/bash
# Registro central de portas — evita colisão entre projetos/ambientes na VPS.
#
# Como a VPS hospeda múltiplos projetos, cada um com ambiente de produção e
# (opcionalmente) staging, a porta interna de cada um não pode ser escolhida
# à mão sem risco de dois projetos caírem na mesma porta. Este arquivo é a
# fonte única de verdade: uma linha por reserva, no formato
# "projeto:ambiente:porta", protegida por flock para a alocação ficar segura
# mesmo se dois scripts rodarem ao mesmo tempo.

PORT_REGISTRY_DIR="/opt/apps"
PORT_REGISTRY_FILE="${PORT_REGISTRY_DIR}/.ports.registry"
PORT_REGISTRY_LOCK="${PORT_REGISTRY_DIR}/.ports.lock"

PORT_RANGE_START=1024
PORT_RANGE_END=65000

_ports_init() {
    mkdir -p "$PORT_REGISTRY_DIR"
    touch "$PORT_REGISTRY_FILE" "$PORT_REGISTRY_LOCK"
}

# Porta já reservada no registro OU já em uso por algum processo do sistema.
port_is_free() {
    local port="$1"
    grep -qE ":${port}\$" "$PORT_REGISTRY_FILE" 2>/dev/null && return 1
    if command -v ss &>/dev/null; then
        [[ "$(ss -ltn "sport = :${port}" 2>/dev/null | wc -l)" -gt 1 ]] && return 1
    fi
    return 0
}

# allocate_port <projeto> <ambiente> [porta_preferida]
# Idempotente: se já existe reserva para esse projeto+ambiente, devolve a
# mesma porta em vez de alocar outra. Imprime a porta alocada em stdout.
allocate_port() {
    local project="$1" env="$2" preferred="${3:-$PORT_RANGE_START}"
    _ports_init

    (
        flock -x 200

        local existing
        existing=$(awk -F: -v p="$project" -v e="$env" '$1==p && $2==e {port=$3} END {print port}' "$PORT_REGISTRY_FILE")
        if [[ -n "$existing" ]]; then
            echo "$existing"
            exit 0
        fi

        local candidate="$preferred"
        while ! port_is_free "$candidate"; do
            candidate=$((candidate + 1))
            if (( candidate > PORT_RANGE_END )); then
                echo "ERRO: nenhuma porta livre no intervalo ${PORT_RANGE_START}-${PORT_RANGE_END}" >&2
                exit 1
            fi
        done

        echo "${project}:${env}:${candidate}" >> "$PORT_REGISTRY_FILE"
        echo "$candidate"
    ) 200>"$PORT_REGISTRY_LOCK"
}

# get_port <projeto> <ambiente> — devolve a porta já reservada, ou nada.
get_port() {
    local project="$1" env="$2"
    _ports_init
    awk -F: -v p="$project" -v e="$env" '$1==p && $2==e {port=$3} END {print port}' "$PORT_REGISTRY_FILE"
}

# find_port_owner <porta> — devolve "projeto:ambiente" que reservou essa
# porta no registro, ou nada se ela não estiver reservada por nenhum projeto.
find_port_owner() {
    local port="$1"
    _ports_init
    awk -F: -v port="$port" '$3==port {print $1":"$2}' "$PORT_REGISTRY_FILE"
}

# release_port <projeto> <ambiente> — remove a reserva (uso: decomissionar).
release_port() {
    local project="$1" env="$2"
    _ports_init
    (
        flock -x 200
        sed -i "/^${project}:${env}:/d" "$PORT_REGISTRY_FILE"
    ) 200>"$PORT_REGISTRY_LOCK"
}

# list_ports — imprime a tabela de portas reservadas, ordenada por porta.
list_ports() {
    _ports_init
    printf "%-24s %-16s %s\n" "PROJETO" "AMBIENTE" "PORTA"
    if [[ ! -s "$PORT_REGISTRY_FILE" ]]; then
        echo "(nenhuma porta reservada ainda)"
        return 0
    fi
    sort -t: -k3 -n "$PORT_REGISTRY_FILE" | while IFS=: read -r p e port; do
        printf "%-24s %-16s %s\n" "$p" "$e" "$port"
    done
}
