#!/bin/bash
# Seção 25 — Runtime alternativo: k3s (Kubernetes leve)
#
# Prepara a VPS para rodar serviços em Kubernetes via k3s, como ALTERNATIVA ao
# modelo Docker Compose (etapas 8–11, 19, 21). Os dois não disputam a máquina em
# geral, MAS ambos querem as portas 80/443 — então apenas UM deve ser o "edge"
# público de cada vez. Este script instala o k3s e o Helm em versões FIXADAS e
# verificadas por sha256, configura o HTTPS pelo próprio Traefik do k3s (ACME /
# Let's Encrypt, sem cert-manager) e cria os namespaces dos projetos. Não remove
# nem desliga o stack Docker.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"

require_root
init_log "25-k3s"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
K3S_DIR="/opt/platform/k3s"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL="k3s kubectl"

# Versões fixadas. Nada é baixado sem versão e checksum. Para atualizar, confirme
# o tag, o commit do install.sh e o sha256 publicados e troque os valores juntos.
K3S_VERSION="v1.37.2+k3s1"
K3S_INSTALL_COMMIT="f6973cb850e9b245585363d15bde80904ac862fd"   # commit do tag acima
K3S_INSTALL_SHA256="ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b"
HELM_VERSION="v3.22.1"
HELM_SHA256="896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea"

title "25. Runtime alternativo: k3s (Kubernetes leve)"

warn "Docker (Compose) e k3s são CAMINHOS ALTERNATIVOS para rodar serviços."
warn "Ambos querem as portas 80/443 — use um OU outro como entrada pública."
info "Este script NÃO desliga o stack Docker; ele apenas instala o k3s ao lado."
echo
confirm "Prosseguir com a instalação do k3s?" || die "Cancelado."

# ── 1. Conflito de portas com o edge Docker ────────────────────────────────
DISABLE_TRAEFIK="n"
if ss -ltn 2>/dev/null | grep -qE ':(80|443)\b'; then
    warn "As portas 80/443 já estão em uso (provavelmente o Traefik do Docker)."
    if confirm "Instalar o k3s SEM o Traefik dele (--disable traefik) para evitar conflito?"; then
        DISABLE_TRAEFIK="y"
        info "k3s será instalado sem ingress próprio. Para o k3s assumir o edge depois,"
        info "pare o edge Docker (docker compose -f /opt/platform/edge/compose.yml down)"
        info "e reative o Traefik do k3s."
    else
        warn "Prosseguindo com o Traefik do k3s — pode falhar ao vincular 80/443 enquanto o Docker os ocupar."
    fi
fi

# ── 2. Instalar o k3s (install.sh verificado por sha256, versão fixada) ────
# install_k3s: baixa o install.sh pelo COMMIT (não por branch), confere o sha256 e só
# então o executa com INSTALL_K3S_VERSION. O próprio instalador confere o binário.
install_k3s() {
    local installer
    installer="$(mktemp)"
    if ! curl -sfL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_INSTALL_COMMIT}/install.sh" -o "$installer"; then
        rm -f "$installer"
        die "Não consegui baixar o instalador do k3s."
    fi
    if ! echo "${K3S_INSTALL_SHA256}  ${installer}" | sha256sum -c --quiet -; then
        rm -f "$installer"
        die "install.sh do k3s não confere com o sha256 fixado — instalação abortada."
    fi
    local k3s_args=(--write-kubeconfig-mode 0600)
    [[ "$DISABLE_TRAEFIK" == "y" ]] && k3s_args+=(--disable traefik)
    INSTALL_K3S_VERSION="$K3S_VERSION" sh "$installer" "${k3s_args[@]}" \
        || { rm -f "$installer"; die "Falha ao instalar o k3s ${K3S_VERSION}."; }
    rm -f "$installer"
}

if command -v k3s &>/dev/null; then
    already_done "k3s $(k3s --version 2>/dev/null | head -1)"
else
    info "Instalando o k3s ${K3S_VERSION} (kubeconfig protegido em 0600)..."
    install_k3s
fi

# ── 3. Aguardar o nó ficar pronto ──────────────────────────────────────────
info "Aguardando o nó do cluster ficar pronto..."
for _ in $(seq 1 30); do
    $KUBECTL get nodes 2>/dev/null | grep -q ' Ready ' && break
    sleep 2
done
$KUBECTL get nodes 2>/dev/null | grep -q ' Ready ' && log "Cluster no ar." || warn "O nó ainda não está Ready — verifique com 'sudo k3s kubectl get nodes'."

# ── 4. Helm (versão fixada, verificada por sha256) ─────────────────────────
# install_helm: tarball oficial da versão fixada, conferido antes de extrair.
install_helm() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if ! curl -sfL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "${tmp_dir}/helm.tgz"; then
        rm -rf "$tmp_dir"
        die "Não consegui baixar o Helm ${HELM_VERSION}."
    fi
    if ! echo "${HELM_SHA256}  ${tmp_dir}/helm.tgz" | sha256sum -c --quiet -; then
        rm -rf "$tmp_dir"
        die "Tarball do Helm não confere com o sha256 fixado — instalação abortada."
    fi
    tar -xzf "${tmp_dir}/helm.tgz" -C "$tmp_dir" linux-amd64/helm
    install -m 755 "${tmp_dir}/linux-amd64/helm" /usr/local/bin/helm
    rm -rf "$tmp_dir"
}

if command -v helm &>/dev/null && helm version --short 2>/dev/null | grep -q "^${HELM_VERSION}"; then
    already_done "Helm ${HELM_VERSION}"
else
    info "Instalando o Helm ${HELM_VERSION}..."
    install_helm
fi

# ── 5. Namespaces dos projetos (lista decidida em lib/k3s.sh) ──────────────
for ns in "${PROJECT_NAMESPACES[@]}"; do
    ensure_namespace "$ns"
done
log "Namespaces prontos: ${PROJECT_NAMESPACES[*]}"

# ── 6. HTTPS pelo Traefik do k3s (ACME / Let's Encrypt, sem cert-manager) ───
mkdir -p "$K3S_DIR"
cp "${TEMPLATES_DIR}/k3s/app-example.yaml" "${K3S_DIR}/"
echo
if [[ "$DISABLE_TRAEFIK" == "y" ]]; then
    warn "Traefik do k3s desativado — o ACME não foi configurado. Configure-o depois de assumir a porta 80/443."
else
    prompt ACME_EMAIL "E-mail para o Let's Encrypt (avisos de expiração)" "$(get_config ACME_EMAIL)"
    [[ "$ACME_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "E-mail inválido."
    save_config ACME_EMAIL "$ACME_EMAIL"
    sed "s|__ACME_EMAIL__|${ACME_EMAIL}|g" "${TEMPLATES_DIR}/k3s/traefik-acme.yaml" > "${K3S_DIR}/traefik-acme.yaml"
    $KUBECTL apply -f "${K3S_DIR}/traefik-acme.yaml" >/dev/null
    log "Traefik com ACME configurado (resolvedor ${ACME_RESOLVER}; certificados em /data/acme.json)."
fi

# ── 7. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ k3s pronto para receber serviços ══${RESET}"
echo -e "  Comandos usam ${CYAN}sudo k3s kubectl ...${RESET} (ou instale o kubectl e exporte o KUBECONFIG)."
echo -e "  Namespaces dos projetos: ${CYAN}${PROJECT_NAMESPACES[*]}${RESET}"
echo -e "  Manifests de exemplo em ${CYAN}${K3S_DIR}/${RESET}"
echo
echo -e "${BOLD}Publicar um serviço:${RESET} use a etapa 29 (gera os manifests) e revise antes de aplicar."
echo -e "  Exemplo de referência: ${CYAN}${K3S_DIR}/app-example.yaml${RESET}"
echo
warn "Guia completo (Docker vs k3s, observabilidade e 2FA no cluster): PT/Servidor/K3S.md"
warn "A API do k3s (porta 6443) NÃO deve ser exposta na internet — o UFW já a mantém fechada."

step_done "k3s ${K3S_VERSION} + Helm ${HELM_VERSION} (runtime alternativo)"
