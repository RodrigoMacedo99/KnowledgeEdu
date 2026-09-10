#!/bin/bash
# Seção 25 — Runtime alternativo: k3s (Kubernetes leve)
#
# Prepara a VPS para rodar serviços em Kubernetes via k3s, como ALTERNATIVA ao
# modelo Docker Compose (etapas 8–11, 19, 21). Os dois não disputam a máquina em
# geral, MAS ambos querem as portas 80/443 — então apenas UM deve ser o "edge"
# público de cada vez. Este script instala o k3s, o Helm, o cert-manager (HTTPS)
# e deixa manifests de exemplo; não remove nem desliga o stack Docker.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "25-k3s"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
K3S_DIR="/opt/platform/k3s"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

title "25. Runtime alternativo: k3s (Kubernetes leve)"

warn "Docker (Compose) e k3s são CAMINHOS ALTERNATIVOS para rodar serviços."
warn "Ambos querem as portas 80/443 — use um OU outro como entrada pública."
info "Este script NÃO desliga o stack Docker; ele apenas instala o k3s ao lado."
echo
confirm "Prosseguir com a instalação do k3s?" || die "Cancelado."

# ── 1. Conflito de portas com o edge Docker ────────────────────────────────
DISABLE_TRAEFIK=""
if ss -ltn 2>/dev/null | grep -qE ':(80|443)\b'; then
    warn "As portas 80/443 já estão em uso (provavelmente o Traefik do Docker)."
    if confirm "Instalar o k3s SEM o Traefik dele (--disable traefik) para evitar conflito?"; then
        DISABLE_TRAEFIK="--disable traefik"
        info "k3s será instalado sem ingress próprio. Para o k3s assumir o edge depois,"
        info "pare o edge Docker (docker compose -f /opt/platform/edge/compose.yml down)"
        info "e reative o Traefik do k3s."
    else
        warn "Prosseguindo com o Traefik do k3s — pode falhar ao vincular 80/443 enquanto o Docker os ocupar."
    fi
fi

# ── 2. Instalar o k3s ──────────────────────────────────────────────────────
if command -v k3s &>/dev/null; then
    already_done "k3s $(k3s --version 2>/dev/null | head -1)"
else
    info "Instalando o k3s (kubeconfig protegido em 0600)..."
    # shellcheck disable=SC2086
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 0600 $DISABLE_TRAEFIK \
        || die "Falha ao instalar o k3s."
fi

KUBECTL="k3s kubectl"

# ── 3. Aguardar o nó ficar pronto ──────────────────────────────────────────
info "Aguardando o nó do cluster ficar pronto..."
for _ in $(seq 1 30); do
    $KUBECTL get nodes 2>/dev/null | grep -q ' Ready ' && break
    sleep 2
done
$KUBECTL get nodes 2>/dev/null | grep -q ' Ready ' && log "Cluster no ar." || warn "O nó ainda não está Ready — verifique com 'sudo k3s kubectl get nodes'."

# ── 4. Helm (gerenciador de pacotes do Kubernetes) ─────────────────────────
if command -v helm &>/dev/null; then
    already_done "Helm $(helm version --short 2>/dev/null)"
else
    info "Instalando o Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
        || warn "Falha ao instalar o Helm — instale manualmente depois."
fi

# ── 5. Namespace das aplicações ────────────────────────────────────────────
$KUBECTL get namespace apps &>/dev/null && already_done "namespace 'apps'" || $KUBECTL create namespace apps

# ── 6. Manifests de exemplo ────────────────────────────────────────────────
mkdir -p "$K3S_DIR"
cp "${TEMPLATES_DIR}/k3s/app-example.yaml"   "${K3S_DIR}/"
cp "${TEMPLATES_DIR}/k3s/clusterissuer.yaml" "${K3S_DIR}/"

# ── 7. cert-manager + emissor Let's Encrypt (HTTPS automático) ─────────────
echo
if command -v helm &>/dev/null && confirm "Instalar o cert-manager (HTTPS automático via Let's Encrypt)?"; then
    prompt ACME_EMAIL "E-mail para o Let's Encrypt" ""
    info "Instalando o cert-manager via Helm..."
    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    helm upgrade --install cert-manager jetstack/cert-manager \
        -n cert-manager --create-namespace --set crds.enabled=true \
        || warn "Falha ao instalar o cert-manager."
    info "Aguardando o cert-manager subir..."
    $KUBECTL -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s >/dev/null 2>&1 || true
    sed "s|__EMAIL__|${ACME_EMAIL}|" "${K3S_DIR}/clusterissuer.yaml" | $KUBECTL apply -f - \
        && log "Emissor Let's Encrypt (ClusterIssuer 'letsencrypt') criado." \
        || warn "Não apliquei o ClusterIssuer — rode manualmente após o cert-manager estar pronto."
fi

# ── 8. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ k3s pronto para receber serviços ══${RESET}"
echo -e "  Comandos usam ${CYAN}sudo k3s kubectl ...${RESET} (ou instale o kubectl e exporte o KUBECONFIG)."
echo -e "  Manifests de exemplo em ${CYAN}${K3S_DIR}/${RESET}"
echo
echo -e "${BOLD}Publicar o serviço de exemplo:${RESET}"
echo -e "  1. Edite ${CYAN}${K3S_DIR}/app-example.yaml${RESET} (imagem e domínio)."
echo -e "  2. Aponte o DNS do domínio para o IP da VPS."
echo -e "  3. ${CYAN}sudo k3s kubectl apply -f ${K3S_DIR}/app-example.yaml${RESET}"
echo -e "  4. Acompanhe: ${CYAN}sudo k3s kubectl get pods,ingress -n apps${RESET}"
echo
warn "Guia completo (Docker vs k3s, observabilidade e 2FA no cluster): PT/Servidor/K3S.md"
warn "A API do k3s (porta 6443) NÃO deve ser exposta na internet — o UFW já a mantém fechada."

step_done "k3s (runtime alternativo)"
