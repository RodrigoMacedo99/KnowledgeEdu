#!/bin/bash
# Seção 29 — Adicionar um serviço no k3s (equivalente k8s da etapa 15)
#
# Gera os manifests de um serviço em /opt/apps/<servico>/k3s/: Namespace,
# Deployment (com probes e requests/limits), Service e IngressRoute do Traefik
# (HTTPS via Let's Encrypt, etapa 25) e, se pedido, o Middleware do Authelia
# (2FA, etapa 27). O script NÃO aplica nada no cluster: você revisa os arquivos
# e aplica com  kubectl apply -k /opt/apps/<servico>/k3s
#
# As imagens vêm de um REGISTRY. Exige tag fixa (nunca 'latest') ou digest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"

require_root
init_log "29-k3s-new-project"

title "29. Adicionar serviço no k3s (monorepo)"

command -v k3s &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."

prompt SERVICE "Nome do serviço = namespace (previstos: ${PROJECT_NAMESPACES[*]})" ""
is_project_namespace "$SERVICE" || die "'${SERVICE}' não é um namespace previsto para projetos."

prompt_optional REPO "URL do monorepo (clonado em /opt/apps/${SERVICE}/app p/ referência) — vazio p/ pular" ""

MANIFEST_DIR="/opt/apps/${SERVICE}/k3s"
mkdir -p "$MANIFEST_DIR"
if [[ -n "$REPO" && ! -d "/opt/apps/${SERVICE}/app" ]]; then
    info "Clonando monorepo para referência..."
    git clone "$REPO" "/opt/apps/${SERVICE}/app" || warn "Falha ao clonar — siga sem o clone."
fi

# Leitura apenas: detecta se o Authelia (etapa 27) existe para oferecer o 2FA.
HAS_AUTHELIA="n"
k3s kubectl get deploy authelia -n auth &>/dev/null && HAS_AUTHELIA="y"

# validate_image <imagem> — aceita tag fixa ou digest; rejeita ausência de tag e 'latest'.
validate_image() {
    local image="$1" last tag
    [[ "$image" == *@sha256:* ]] && return 0
    last="${image##*/}"
    [[ "$last" == *:* ]] || return 1
    tag="${last##*:}"
    [[ -n "$tag" && "$tag" != "latest" ]]
}

# write_container_manifest <arquivo> <nome> <imagem> <porta> <health> <domínio> <2fa y|n>
write_container_manifest() {
    local file="$1" cname="$2" image="$3" cport="$4" health="$5" domain="$6" use_2fa="$7"
    local middlewares=""
    if [[ "$use_2fa" == "y" ]]; then
        middlewares="      middlewares:
        - name: authelia"
    fi
    cat > "$file" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${cname}
  namespace: ${SERVICE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${cname} }
  template:
    metadata:
      labels: { app: ${cname} }
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: ${cname}
          image: ${image}
          ports:
            - containerPort: ${cport}
          readinessProbe:
            httpGet: { path: ${health}, port: ${cport} }
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: ${health}, port: ${cport} }
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests: { cpu: "50m", memory: "64Mi" }
            limits:   { cpu: "1", memory: "512Mi" }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
---
apiVersion: v1
kind: Service
metadata:
  name: ${cname}
  namespace: ${SERVICE}
spec:
  selector: { app: ${cname} }
  ports:
    - port: 80
      targetPort: ${cport}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: ${cname}
  namespace: ${SERVICE}
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(\`${domain}\`)
${middlewares}
      services:
        - name: ${cname}
          port: 80
  tls:
    certResolver: ${ACME_RESOLVER}
EOF
}

write_namespace_manifest() {
    cat > "${MANIFEST_DIR}/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${SERVICE}
EOF
}

# write_kustomization <recursos...> — lista os arquivos gerados para 'kubectl apply -k'.
write_kustomization() {
    {
        echo "apiVersion: kustomize.config.k8s.io/v1beta1"
        echo "kind: Kustomization"
        echo "resources:"
        printf '  - %s\n' "$@"
    } > "${MANIFEST_DIR}/kustomization.yaml"
}

# ── Loop dos containers públicos ───────────────────────────────────────────
count=0
resources=("namespace.yaml")
need_middleware="n"
while true; do
    echo
    prompt_optional CNAME "Nome do container/app (ex: web, api) — vazio p/ terminar" ""
    [[ -z "$CNAME" ]] && break
    [[ "$CNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { warn "Nome inválido (RFC1123)."; continue; }
    while true; do
        prompt IMAGE "Imagem com tag fixa (ex: ghcr.io/usuario/${SERVICE}-${CNAME}:1.4.2)" ""
        validate_image "$IMAGE" && break
        warn "Imagem sem tag ou com 'latest' — informe uma versão fixa."
    done
    while true; do
        prompt CPORT "Porta que o container escuta" "3000"
        [[ "$CPORT" =~ ^[0-9]{1,5}$ ]] && (( CPORT >= 1 && CPORT <= 65535 )) && break
        warn "Porta inválida (1–65535)."
    done
    prompt HEALTH_PATH "Rota de health check do container" "/health"
    prompt CDOMAIN "Domínio público deste container" "${CNAME}.exemplo.com"

    USE_2FA="n"
    if [[ "$HAS_AUTHELIA" == "y" ]] && confirm "Exigir 2FA (Authelia) neste serviço?"; then
        USE_2FA="y"
        need_middleware="y"
    fi

    write_container_manifest "${MANIFEST_DIR}/${CNAME}.yaml" "$CNAME" "$IMAGE" "$CPORT" "$HEALTH_PATH" "$CDOMAIN" "$USE_2FA"
    resources+=("${CNAME}.yaml")
    count=$((count+1))
done

write_namespace_manifest
if [[ "$need_middleware" == "y" ]]; then
    sed "s|__NAMESPACE__|${SERVICE}|" "${TEMPLATES_DIR}/k3s/authelia-middleware.yaml" \
        > "${MANIFEST_DIR}/authelia-middleware.yaml"
    resources+=("authelia-middleware.yaml")
fi
write_kustomization "${resources[@]}"

chown -R root:root "$MANIFEST_DIR" 2>/dev/null || true

echo
echo -e "${BOLD}${GREEN}══ Manifests de '${SERVICE}' gerados (nada foi aplicado) ══${RESET}"
echo -e "  Diretório: ${CYAN}${MANIFEST_DIR}/${RESET}   Containers públicos: ${CYAN}${count}${RESET}"
echo -e "  Revise os arquivos e aplique com: ${CYAN}sudo k3s kubectl apply -k ${MANIFEST_DIR}${RESET}"
echo
warn "Aponte o DNS de cada domínio para a VPS: o Traefik emite o HTTPS no primeiro acesso."
warn "Imagens privadas exigem um imagePullSecret no namespace (crie-o à parte, sem colar o token no terminal)."
warn "runAsNonRoot exige imagem que não rode como root — ajuste a imagem se o pod não subir."
warn "O banco de dados no k8s (StatefulSet/operador) é um passo à parte — mantenha-o só na rede interna."

step_done "Manifests do serviço ${SERVICE} no k3s (${count} container(es) público(s), não aplicados)"
