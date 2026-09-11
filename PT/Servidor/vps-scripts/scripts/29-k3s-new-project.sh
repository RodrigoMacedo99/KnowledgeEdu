#!/bin/bash
# Seção 29 — Adicionar um serviço no k3s (equivalente k8s da etapa 15)
#
# No k3s um serviço é descrito por manifests (Deployment + Service + Ingress),
# não por compose. Aqui você informa cada container público (imagem de registry,
# porta e domínio) e o script gera e aplica os manifests, com HTTPS automático
# (cert-manager) e, opcionalmente, 2FA (middleware do Authelia da etapa 27).
#
# As imagens vêm de um REGISTRY (ex.: ghcr.io/usuario/app:tag) — no k8s não se
# faz build no host; o build/push é papel do CI (etapa 17 adaptada, ou manual).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "29-k3s-new-project"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KC="k3s kubectl"

title "29. Adicionar serviço no k3s (monorepo)"

command -v k3s &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."

prompt SERVICE "Nome do serviço (vira o namespace; minúsculas/dígitos/-)" ""
[[ "$SERVICE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Nome inválido (RFC1123): use minúsculas, dígitos e '-'."

prompt_optional REPO "URL do monorepo (clonado em /opt/apps/${SERVICE}/app p/ referência) — vazio p/ pular" ""

# ── Namespace ──────────────────────────────────────────────────────────────
$KC create namespace "$SERVICE" --dry-run=client -o yaml | $KC apply -f - >/dev/null
log "Namespace '${SERVICE}' pronto."

# ── Clone de referência (opcional) ─────────────────────────────────────────
MANIFEST_DIR="/opt/apps/${SERVICE}/k3s"
mkdir -p "$MANIFEST_DIR"
if [[ -n "$REPO" && ! -d "/opt/apps/${SERVICE}/app" ]]; then
    info "Clonando monorepo para referência..."
    git clone "$REPO" "/opt/apps/${SERVICE}/app" || warn "Falha ao clonar — siga sem o clone."
fi

# ── 2FA disponível? ────────────────────────────────────────────────────────
HAS_AUTHELIA="n"
$KC get middleware authelia -n auth &>/dev/null && HAS_AUTHELIA="y"
HAS_ISSUER="n"
$KC get clusterissuer letsencrypt &>/dev/null && HAS_ISSUER="y"
[[ "$HAS_ISSUER" == "n" ]] && warn "ClusterIssuer 'letsencrypt' ausente — o HTTPS não será emitido (rode a etapa 25)."

# ── Loop dos containers públicos ───────────────────────────────────────────
count=0
while true; do
    echo
    prompt_optional CNAME "Nome do container/app (ex: web, api) — vazio p/ terminar" ""
    [[ -z "$CNAME" ]] && break
    [[ "$CNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { warn "Nome inválido (RFC1123)."; continue; }
    prompt IMAGE "Imagem do registry (ex: ghcr.io/usuario/${SERVICE}-${CNAME}:latest)" ""
    prompt CPORT "Porta que o container escuta" "3000"
    prompt CDOMAIN "Domínio público deste container" "${CNAME}.exemplo.com"

    # Monta o bloco de anotações só com o que existir (evita 'annotations:' vazio).
    ann_lines=()
    [[ "$HAS_ISSUER" == "y" ]] && ann_lines+=("cert-manager.io/cluster-issuer: letsencrypt")
    if [[ "$HAS_AUTHELIA" == "y" ]] && confirm "Exigir 2FA (Authelia) neste serviço?"; then
        ann_lines+=("traefik.ingress.kubernetes.io/router.middlewares: auth-authelia@kubernetescrd")
    fi
    META_ANN=""
    if [[ ${#ann_lines[@]} -gt 0 ]]; then
        META_ANN="  annotations:"$'\n'
        for a in "${ann_lines[@]}"; do META_ANN+="    ${a}"$'\n'; done
    fi

    MF="${MANIFEST_DIR}/${CNAME}.yaml"
    cat > "$MF" <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CNAME}
  namespace: ${SERVICE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${CNAME} }
  template:
    metadata:
      labels: { app: ${CNAME} }
    spec:
      containers:
        - name: ${CNAME}
          image: ${IMAGE}
          ports:
            - containerPort: ${CPORT}
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "1", memory: "512Mi" }
          securityContext:
            allowPrivilegeEscalation: false
---
apiVersion: v1
kind: Service
metadata:
  name: ${CNAME}
  namespace: ${SERVICE}
spec:
  selector: { app: ${CNAME} }
  ports:
    - port: 80
      targetPort: ${CPORT}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${CNAME}
  namespace: ${SERVICE}
  annotations:
${ISSUER_ANN}
${MW}
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["${CDOMAIN}"]
      secretName: ${CNAME}-tls
  rules:
    - host: ${CDOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${CNAME}
                port: { number: 80 }
EOF
    # Remove linhas de anotação vazias (quando não há issuer/middleware).
    sed -i '/^$/d' "$MF"
    $KC apply -f "$MF" && log "Aplicado: ${CNAME} → https://${CDOMAIN}" || warn "Falha ao aplicar ${CNAME}."
    count=$((count+1))
done

chown -R root:root "$MANIFEST_DIR" 2>/dev/null || true

echo
echo -e "${BOLD}${GREEN}══ Serviço '${SERVICE}' no k3s ══${RESET}"
echo -e "  Manifests: ${CYAN}${MANIFEST_DIR}/${RESET}   Containers públicos: ${CYAN}${count}${RESET}"
echo -e "  Acompanhe: ${CYAN}sudo k3s kubectl get pods,ingress -n ${SERVICE}${RESET}"
echo
warn "Aponte o DNS de cada domínio para a VPS para o cert-manager emitir o HTTPS."
warn "Imagens privadas exigem um imagePullSecret no namespace (kubectl create secret docker-registry)."
warn "O banco de dados no k8s (StatefulSet/operador) é um passo à parte — mantenha-o só na rede interna."

step_done "Serviço ${SERVICE} no k3s (${count} container(es) público(s))"
