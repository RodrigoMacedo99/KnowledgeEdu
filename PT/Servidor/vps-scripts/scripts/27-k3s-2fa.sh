#!/bin/bash
# Seção 27 — 2FA/SSO no k3s (Authelia + forward-auth do Traefik)
#
# Sobe o Authelia no cluster e cria o Middleware do Traefik que os Ingress
# referenciam para exigir login com 2FA — o equivalente Kubernetes da etapa 21.
# Opcionalmente já protege o Grafana (etapa 26).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "27-k3s-2fa"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KC="k3s kubectl"
AUTHELIA_IMAGE="authelia/authelia:4.38"

title "27. 2FA/SSO no k3s (Authelia)"

command -v k3s &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."
command -v docker &>/dev/null || die "Docker é usado só para gerar o hash da senha — instale-o (etapa 8) ou gere o hash manualmente."
$KC get clusterissuer letsencrypt &>/dev/null || warn "ClusterIssuer 'letsencrypt' ausente — o HTTPS do portal só sai com o cert-manager (etapa 25)."

# ── 1. Dados ───────────────────────────────────────────────────────────────
prompt AUTH_HOST     "Domínio do portal (ex: auth.seudominio.com)" ""
prompt COOKIE_DOMAIN "Domínio base compartilhado (ex: seudominio.com)" ""
prompt ADMIN_USER    "Usuário administrador do portal" "admin"
prompt ADMIN_EMAIL   "E-mail do administrador" ""
prompt_secret ADMIN_PASS "Senha do administrador do portal"

# ── 2. Namespace ───────────────────────────────────────────────────────────
$KC create namespace auth --dry-run=client -o yaml | $KC apply -f - >/dev/null

# ── 3. Segredos (chaves aleatórias) ────────────────────────────────────────
info "Gerando segredos do Authelia..."
$KC create secret generic authelia-secrets -n auth \
    --from-literal=AUTHELIA_SESSION_SECRET="$(openssl rand -hex 64)" \
    --from-literal=AUTHELIA_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 64)" \
    --from-literal=AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="$(openssl rand -hex 64)" \
    --dry-run=client -o yaml | $KC apply -f - >/dev/null

# ── 4. Base de usuários (com hash argon2 da senha) ─────────────────────────
info "Gerando hash argon2 da senha..."
HASH="$(docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$ADMIN_PASS" 2>/dev/null | awk '/Digest:/ {print $2}')"
[[ -z "$HASH" ]] && die "Falha ao gerar o hash da senha."

USERS_TMP="$(mktemp)"
cat > "$USERS_TMP" <<EOF
users:
  ${ADMIN_USER}:
    disabled: false
    displayname: 'Administrador'
    password: '${HASH}'
    email: '${ADMIN_EMAIL}'
    groups:
      - 'admins'
EOF
$KC create secret generic authelia-users -n auth \
    --from-file=users_database.yml="$USERS_TMP" \
    --dry-run=client -o yaml | $KC apply -f - >/dev/null
shred -u "$USERS_TMP" 2>/dev/null || rm -f "$USERS_TMP"

# ── 5. Manifests do Authelia ───────────────────────────────────────────────
info "Aplicando o Authelia..."
sed -e "s|__DOMAIN__|${COOKIE_DOMAIN}|g" -e "s|__AUTH_HOST__|${AUTH_HOST}|g" \
    "${TEMPLATES_DIR}/k3s/authelia.yaml" | $KC apply -f -
$KC -n auth rollout status deploy/authelia --timeout=120s >/dev/null 2>&1 || warn "Authelia ainda subindo — verifique com '$KC -n auth get pods'."

# ── 6. Proteger o Grafana (opcional) ───────────────────────────────────────
echo
if confirm "Proteger o Grafana (etapa 26) com o Authelia agora?"; then
    GIN="$($KC get ingress -n observability -o name 2>/dev/null | grep -i grafana | head -1)"
    if [[ -n "$GIN" ]]; then
        $KC annotate -n observability "$GIN" \
            traefik.ingress.kubernetes.io/router.middlewares=auth-authelia@kubernetescrd --overwrite \
            && log "Grafana agora exige login no Authelia."
    else
        warn "Ingress do Grafana não encontrado (rode a etapa 26)."
    fi
fi

# ── 7. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ 2FA/SSO no k3s pronto ══${RESET}"
echo -e "  Portal: ${CYAN}https://${AUTH_HOST}${RESET}   Usuário: ${CYAN}${ADMIN_USER}${RESET}"
echo
echo -e "${BOLD}Proteger qualquer Ingress com 2FA${RESET} — adicione a anotação:"
echo -e "  ${CYAN}traefik.ingress.kubernetes.io/router.middlewares: auth-authelia@kubernetescrd${RESET}"
echo
warn "Aponte o DNS de ${AUTH_HOST} para o IP da VPS."
warn "Sem SMTP, o link de cadastro do 2FA fica no arquivo /data/notification.txt do pod:"
warn "  $KC -n auth exec deploy/authelia -- cat /data/notification.txt"

step_done "2FA/SSO no k3s (Authelia, portal: ${AUTH_HOST})"
