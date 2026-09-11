#!/bin/bash
# Seção 15 — Adicionar um novo serviço (monorepo multi-container)
#
# Um serviço = um monorepo com VÁRIOS containers (ex.: web + api + worker + db),
# descritos por um único compose.yml no próprio repositório. Esta etapa:
#   • cria o usuário de serviço e a pasta isolada do projeto;
#   • clona o monorepo em produção (e, opcionalmente, staging);
#   • GERA um compose.override.yml no servidor com as labels do Traefik (domínio
#     + HTTPS) para cada container público — o repositório continua portátil,
#     sem domínios nem TLS embutidos.
#
# Roteamento é por domínio (labels do Traefik), então containers HTTP NÃO
# precisam de porta no host. O registro de portas (lib/ports.sh) só entra para
# o que não é HTTP (ex.: expor o banco a um túnel SSH).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/ports.sh"

require_root
init_log "15-new-project"

title "15. Adicionar novo serviço (monorepo multi-container)"

if ! docker network inspect edge &>/dev/null; then
    if command -v k3s &>/dev/null; then
        die "Esta etapa é do runtime Docker. Você está no k3s — use a etapa 29 (Adicionar serviço no k3s)."
    fi
    die "Rede 'edge' não existe — rode as etapas 8 e 9 primeiro."
fi

prompt PROJECT_NAME "Nome do serviço (sem espaços, minúsculas)" ""
prompt_optional REPO_URL "URL do monorepo git (deixe vazio para clonar depois)" ""

echo
info "Recomendado: mantenha um staging isolado para validar antes de produção."
CREATE_STAGING="n"
confirm "Criar também um ambiente de staging?" && CREATE_STAGING="y"

STAGING_BRANCH="develop"
if [[ "$CREATE_STAGING" == "y" ]]; then
    prompt STAGING_BRANCH "Branch que o staging acompanha" "develop"
fi

PROJECT_DIR="/opt/apps/${PROJECT_NAME}"

# ── 1. Usuário de serviço ──────────────────────────────────────────────────
if id "$PROJECT_NAME" &>/dev/null; then
    already_done "Usuário $PROJECT_NAME"
else
    info "Criando usuário de serviço $PROJECT_NAME..."
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --gid webapps --comment "${PROJECT_NAME} service user" "$PROJECT_NAME"
fi

mkdir -p "$PROJECT_DIR"
chown "${PROJECT_NAME}:webapps" "$PROJECT_DIR"
chmod 750 "$PROJECT_DIR"

# ── Coleta os containers públicos (comum a prod e staging) ─────────────────
# Guardamos em arrays paralelos: nome do serviço no compose, subdomínio, porta.
declare -a PUB_SVC PUB_PORT
declare -a PROD_DOMAINS STAGING_DOMAINS

info "Agora informe quais containers do seu compose devem ficar públicos."
info "Deixe o nome do serviço vazio para encerrar."
while true; do
    prompt_optional SVC "Nome do serviço no compose (ex: web, api) — vazio p/ terminar" ""
    [[ -z "$SVC" ]] && break
    prompt SVC_PORT "Porta interna que esse container escuta (ex: 3000, 80)" "3000"
    PUB_SVC+=("$SVC")
    PUB_PORT+=("$SVC_PORT")
done

[[ ${#PUB_SVC[@]} -eq 0 ]] && warn "Nenhum container público informado — o override não terá rotas (você pode editar depois)."

# ── Gera o compose.override.yml de um ambiente ─────────────────────────────
# $1 = env_dir, $2 = env_name, $3... = domínios (um por serviço público, na ordem).
generate_override() {
    local env_dir="$1" env_name="$2"; shift 2
    local -a domains=("$@")
    local override="${env_dir}/compose.override.yml"

    {
        echo "# Gerado pela etapa 15 — labels do Traefik para '${PROJECT_NAME}' (${env_name})."
        echo "# NÃO commite este arquivo: ele carrega os domínios deste servidor."
        echo "# Se um serviço precisa falar com outros containers, liste também aqui a"
        echo "# rede interna que ele usa no compose.yml (além da 'edge')."
        echo "services:"
        local i
        for i in "${!PUB_SVC[@]}"; do
            local svc="${PUB_SVC[$i]}" port="${PUB_PORT[$i]}" domain="${domains[$i]}"
            local router="${PROJECT_NAME}-${env_name}-${svc}"
            cat <<EOF
  ${svc}:
    networks:
      - edge
    labels:
      - traefik.enable=true
      - traefik.docker.network=edge
      - traefik.http.routers.${router}.rule=Host(\`${domain}\`)
      - traefik.http.routers.${router}.entrypoints=websecure
      - traefik.http.routers.${router}.tls.certresolver=le
      - traefik.http.routers.${router}.middlewares=secure-chain@file
      - traefik.http.services.${router}.loadbalancer.server.port=${port}
EOF
        done
        echo "networks:"
        echo "  edge:"
        echo "    external: true"
    } > "$override"

    chown "${PROJECT_NAME}:webapps" "$override"
    chmod 640 "$override"
    log "compose.override.yml gerado em ${override}."
}

# ── Provisiona um ambiente (produção ou staging) ───────────────────────────
provision_environment() {
    local env_name="$1"
    local env_dir="${PROJECT_DIR}/${env_name}"
    local -a domains=()

    info "Provisionando ambiente '${env_name}'..."
    mkdir -p "$env_dir"
    chown "${PROJECT_NAME}:webapps" "$env_dir"
    chmod 750 "$env_dir"

    # Clone do monorepo
    if [[ -n "$REPO_URL" && ! -d "${env_dir}/app" ]]; then
        info "Clonando monorepo em ${env_name}..."
        sudo -u "$PROJECT_NAME" git clone "$REPO_URL" "${env_dir}/app"
        chown -R "${PROJECT_NAME}:webapps" "${env_dir}/app"
    fi

    # Valida se há um compose no repo
    if [[ -d "${env_dir}/app" ]]; then
        if [[ -f "${env_dir}/app/compose.yml" ]]; then
            log "compose.yml encontrado no repositório."
        elif [[ -f "${env_dir}/app/docker-compose.yml" ]]; then
            warn "Repositório usa 'docker-compose.yml' (nome antigo). Funciona, mas prefira 'compose.yml'."
        else
            warn "Nenhum compose.yml no repositório — adicione um (veja templates/app/compose.example.yml)."
        fi
    fi

    # .env do ambiente
    local env_file="${env_dir}/.env"
    if [[ -f "$env_file" ]]; then
        already_done ".env de ${env_name}"
    else
        info "Criando .env vazio para ${env_name}..."
        touch "$env_file"
        chown "${PROJECT_NAME}:webapps" "$env_file"
        chmod 640 "$env_file"
        [[ -d "${env_dir}/app" && ! -e "${env_dir}/app/.env" ]] && ln -s "$env_file" "${env_dir}/app/.env"
        warn "Edite as variáveis: sudo nano ${env_file}"
    fi

    # Domínios de cada container público
    local i
    for i in "${!PUB_SVC[@]}"; do
        local svc="${PUB_SVC[$i]}"
        local suggested="${svc}.${env_name}.exemplo.com"
        [[ "$env_name" == "production" ]] && suggested="${svc}.exemplo.com"
        prompt DOM "Domínio para o container '${svc}' (${env_name})" "$suggested"
        domains+=("$DOM")
    done

    [[ ${#PUB_SVC[@]} -gt 0 ]] && generate_override "$env_dir" "$env_name" "${domains[@]}"

    # Exporta os domínios coletados para os metadados
    if [[ "$env_name" == "production" ]]; then
        PROD_DOMAINS=("${domains[@]}")
    else
        STAGING_DOMAINS=("${domains[@]}")
    fi
}

echo
confirm "Criar o serviço '${PROJECT_NAME}' agora?" || die "Operação cancelada."

# ── 2. Produção ────────────────────────────────────────────────────────────
provision_environment "production"

# ── 3. Staging (opcional) ──────────────────────────────────────────────────
if [[ "$CREATE_STAGING" == "y" ]]; then
    provision_environment "staging"
fi

# ── 4. Porta de host opcional (só para não-HTTP, ex.: túnel de banco) ──────
DB_HOST_PORT=""
if confirm "Expor uma porta de banco em 127.0.0.1 (para túnel SSH de administração)?"; then
    DB_HOST_PORT=$(allocate_port "$PROJECT_NAME" "db" 5432)
    info "Porta reservada para o banco (bind 127.0.0.1): ${DB_HOST_PORT}"
    warn "Adicione no seu compose.override.yml, no serviço do banco:"
    warn "    ports: [\"127.0.0.1:${DB_HOST_PORT}:5432\"]"
fi

# ── 5. Metadados (lidos pela etapa 17 — CI/CD) ─────────────────────────────
PRIMARY_DOMAIN="${PROD_DOMAINS[0]:-}"
STAGING_PRIMARY_DOMAIN="${STAGING_DOMAINS[0]:-}"
cat > "${PROJECT_DIR}/.project.env" <<EOF
MAIN_BRANCH=main
STAGING_ENABLED=${CREATE_STAGING}
STAGING_BRANCH=${STAGING_BRANCH}
PRIMARY_DOMAIN=${PRIMARY_DOMAIN}
STAGING_PRIMARY_DOMAIN=${STAGING_PRIMARY_DOMAIN}
DB_HOST_PORT=${DB_HOST_PORT}
EOF
chown "${PROJECT_NAME}:webapps" "${PROJECT_DIR}/.project.env"
chmod 640 "${PROJECT_DIR}/.project.env"

# ── 6. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ Serviço '${PROJECT_NAME}' criado ══${RESET}"
echo -e "  Pasta:    ${CYAN}${PROJECT_DIR}${RESET}"
[[ -n "$PRIMARY_DOMAIN" ]] && echo -e "  Produção: ${CYAN}https://${PRIMARY_DOMAIN}${RESET}"
echo
warn "Próximos passos:"
warn "  1. Edite o .env de cada ambiente."
warn "  2. Aponte o DNS de cada domínio para o IP da VPS."
warn "  3. Suba: cd ${PROJECT_DIR}/production/app && docker compose -f compose.yml -f ../compose.override.yml up --build -d"
warn "  4. Gere o CI/CD com a etapa 17 (já lê estes metadados)."

step_done "Serviço ${PROJECT_NAME} (monorepo multi-container)"
