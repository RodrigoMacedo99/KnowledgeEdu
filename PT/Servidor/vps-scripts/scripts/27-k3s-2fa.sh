#!/bin/bash
# Seção 27 — 2FA/SSO no k3s (Authelia + forward-auth do Traefik)
#
# Sobe o Authelia no namespace 'operacao' (lista de namespaces aprovada pelo
# projeto), exposto por IngressRoute com HTTPS. Para
# exigir 2FA num serviço, o IngressRoute dele referencia o Middleware 'authelia'
# do PRÓPRIO namespace (templates/k3s/authelia-middleware.yaml). Opcionalmente
# protege o Grafana (etapa 26), no namespace operacao.
#
# Segredos nunca passam por argumento de linha de comando nem pela tela: os
# Secrets são criados a partir de arquivos temporários, e o hash da senha de
# administrador é calculado com a senha entrando por stdin.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/k3s.sh"

require_root
init_log "27-k3s-2fa"

TEMPLATES_DIR="$(cd "$SCRIPT_DIR/../templates" && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
AUTHELIA_IMAGE="authelia/authelia:4.38.19"

title "27. 2FA/SSO no k3s (Authelia)"

command -v k3s &>/dev/null || die "k3s não instalado — rode a etapa 25 primeiro."

# ── 1. Dados (lembra o que já foi digitado antes, exceto segredos) ─────────
prompt AUTH_HOST     "Domínio do portal (ex: auth.seudominio.com)" "$(get_config AUTHELIA_AUTH_HOST)"
prompt COOKIE_DOMAIN "Domínio base compartilhado (ex: seudominio.com)" "$(get_config AUTHELIA_COOKIE_DOMAIN)"
prompt ADMIN_USER    "Usuário administrador do portal" "$(get_config AUTHELIA_ADMIN_USER admin)"
prompt ADMIN_EMAIL   "E-mail do administrador" "$(get_config AUTHELIA_ADMIN_EMAIL)"
prompt_secret ADMIN_PASS "Senha do administrador do portal (não será exibida)"
save_config AUTHELIA_AUTH_HOST "$AUTH_HOST"
save_config AUTHELIA_COOKIE_DOMAIN "$COOKIE_DOMAIN"
save_config AUTHELIA_ADMIN_USER "$ADMIN_USER"
save_config AUTHELIA_ADMIN_EMAIL "$ADMIN_EMAIL"

# ── 2. Namespace ───────────────────────────────────────────────────────────
ensure_namespace operacao

# ── 3. Segredos (chaves aleatórias) ────────────────────────────────────────
# Criados só na primeira vez. Regenerar a STORAGE_ENCRYPTION_KEY faria o Authelia
# deixar de conseguir ler o próprio banco; regenerar a SESSION_SECRET derrubaria
# todas as sessões. Reexecutar a etapa só troca a base de usuários.
if k3s kubectl get secret authelia-secrets -n operacao&>/dev/null; then
    already_done "Chaves do Authelia (Secret authelia-secrets mantido)"
else
    info "Gerando segredos do Authelia..."
    # shellcheck disable=SC2034  # lidas por k8s_secret_from_vars (indireção ${!var})
    AUTHELIA_SESSION_SECRET="$(openssl rand -hex 64)"
    # shellcheck disable=SC2034  # idem
    AUTHELIA_STORAGE_ENCRYPTION_KEY="$(openssl rand -hex 64)"
    # shellcheck disable=SC2034  # idem
    AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="$(openssl rand -hex 64)"
    k8s_secret_from_vars authelia-secrets operacao \
        AUTHELIA_SESSION_SECRET AUTHELIA_STORAGE_ENCRYPTION_KEY \
        AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET
    log "Segredos do Authelia criados."
fi

# ── 4. Hash argon2 da senha (a senha entra por stdin, nunca por argv) ───────
# hash_password_via_docker / hash_password_via_cluster imprimem só o hash.
# O 'sh -c' lê a senha de stdin; o comando do contêiner não contém a senha.
# shellcheck disable=SC2016  # $pw é expandido dentro do contêiner, de propósito
HASH_CMD='read -r pw && authelia crypto hash generate argon2 --password "$pw"'

hash_password_via_docker() {
    printf '%s\n' "$ADMIN_PASS" \
        | docker run --rm -i --entrypoint sh "$AUTHELIA_IMAGE" -c "$HASH_CMD" 2>/dev/null
}

hash_password_via_cluster() {
    printf '%s\n' "$ADMIN_PASS" \
        | k3s kubectl run "authelia-hash-$$" -n operacao--rm -i --restart=Never \
            --image="$AUTHELIA_IMAGE" --command -- sh -c "$HASH_CMD" 2>/dev/null
}

info "Gerando hash argon2 da senha..."
HASH_OUTPUT=""
if command -v docker &>/dev/null; then
    HASH_OUTPUT="$(hash_password_via_docker)" || HASH_OUTPUT=""
else
    HASH_OUTPUT="$(hash_password_via_cluster)" || HASH_OUTPUT=""
fi
HASH="$(awk '/Digest:/ {print $2}' <<< "$HASH_OUTPUT")"
[[ -n "$HASH" ]] || die "Falha ao gerar o hash da senha."

# ── 5. Base de usuários (arquivo temporário, apagado após o uso) ───────────
USERS_TMP="$(mktemp)"
chmod 600 "$USERS_TMP"
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
k3s kubectl create secret generic authelia-users -n operacao\
    --from-file=users_database.yml="$USERS_TMP" \
    --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null
shred -u "$USERS_TMP" 2>/dev/null || rm -f "$USERS_TMP"

# ── 6. Manifests do Authelia ───────────────────────────────────────────────
info "Aplicando o Authelia..."
sed -e "s|__DOMAIN__|${COOKIE_DOMAIN}|g" -e "s|__AUTH_HOST__|${AUTH_HOST}|g" \
    "${TEMPLATES_DIR}/k3s/authelia.yaml" | k3s kubectl apply -f - >/dev/null
k3s kubectl -n operacaorollout status deploy/authelia --timeout=180s >/dev/null 2>&1 \
    || warn "Authelia ainda subindo — verifique com 'sudo k3s kubectl -n operacaoget pods'."

# ── 7. Proteger o Grafana (opcional) ───────────────────────────────────────
# O Middleware precisa estar no MESMO namespace da rota (operacao).
echo
if confirm "Proteger o Grafana (etapa 26) com o Authelia agora?"; then
    if k3s kubectl get ingressroute grafana -n "$PLATFORM_NAMESPACE" &>/dev/null; then
        sed "s|__NAMESPACE__|${PLATFORM_NAMESPACE}|g" "${TEMPLATES_DIR}/k3s/authelia-middleware.yaml" \
            | k3s kubectl apply -f - >/dev/null
        # A rota do Grafana já tem middlewares (security-headers). O patch ACRESCENTA
        # 'authelia' à lista; um 'add' no caminho da lista inteira a substituiria.
        existing_mw="$(k3s kubectl get ingressroute grafana -n "$PLATFORM_NAMESPACE" \
            -o jsonpath='{.spec.routes[0].middlewares}' 2>/dev/null || true)"
        if [[ "$existing_mw" == *'"name":"authelia"'* ]]; then
            already_done "Grafana já protegido pelo Authelia"
        else
            if [[ -n "$existing_mw" && "$existing_mw" != "null" ]]; then
                mw_patch='[{"op":"add","path":"/spec/routes/0/middlewares/-","value":{"name":"authelia"}}]'
            else
                mw_patch='[{"op":"add","path":"/spec/routes/0/middlewares","value":[{"name":"authelia"}]}]'
            fi
            k3s kubectl patch ingressroute grafana -n "$PLATFORM_NAMESPACE" --type=json \
                -p="$mw_patch" >/dev/null
            log "Grafana agora exige login no Authelia (2FA)."
        fi
        warn "Se o overlay do infra for aplicado de novo (kubectl apply -k), a rota volta sem o Authelia. Rode esta etapa de novo."
    else
        warn "IngressRoute do Grafana não encontrado em ${PLATFORM_NAMESPACE} (rode a etapa 26)."
    fi
fi

# ── 8. Resumo ──────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}══ 2FA/SSO no k3s pronto ══${RESET}"
echo -e "  Portal: ${CYAN}https://${AUTH_HOST}${RESET}   Usuário: ${CYAN}${ADMIN_USER}${RESET}"
echo
echo -e "${BOLD}Proteger um serviço com 2FA:${RESET} no IngressRoute dele, em ${CYAN}spec.routes[]${RESET}:"
echo -e "  ${CYAN}middlewares:${RESET}"
echo -e "  ${CYAN}  - name: authelia${RESET}      (o Middleware precisa estar no mesmo namespace)"
echo
warn "Aponte o DNS de ${AUTH_HOST} para o IP da VPS."
warn "Sem SMTP, o link de cadastro do 2FA fica no pod (arquivo de notificação):"
warn "  sudo k3s kubectl -n operacaoexec deploy/authelia -- cat /data/notification.txt"

step_done "2FA/SSO no k3s (Authelia, portal: ${AUTH_HOST})"
