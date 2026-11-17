#!/bin/bash
# Constantes e helpers compartilhados pelos scripts do k3s (etapas 25–29).
# Ficam num lugar só para que uma decisão (namespace, versão) mude em um único
# arquivo. Não é executado sozinho: é carregado com 'source' depois do common.sh.
# shellcheck disable=SC2034  # as constantes são consumidas pelos scripts que fazem source

# Namespaces dos projetos, decididos para este servidor. 'apps' e
# 'observability' NÃO são usados.
PROJECT_NAMESPACES=(sdi sga siepe sigma sgoa sca mensageria operacao edge)

# Namespace da plataforma: observabilidade, backups e acesso do operador.
PLATFORM_NAMESPACE="operacao"

# Nome do resolvedor ACME configurado no Traefik do k3s (etapa 25). Os
# IngressRoute o referenciam em 'tls.certResolver'.
ACME_RESOLVER="letsencrypt"

is_project_namespace() {
    local ns="$1" candidate
    for candidate in "${PROJECT_NAMESPACES[@]}"; do
        [[ "$candidate" == "$ns" ]] && return 0
    done
    return 1
}

# Cria o namespace sem alterar nada se ele já existir (idempotente).
ensure_namespace() {
    local ns="$1"
    k3s kubectl create namespace "$ns" --dry-run=client -o yaml \
        | k3s kubectl apply -f - >/dev/null
}

# k8s_secret_from_vars <nome> <namespace> SPEC [SPEC...]
# SPEC é VARIAVEL (a chave do Secret tem o mesmo nome) ou CHAVE=VARIAVEL (para
# chaves com hífen, como 'admin-password'). Os valores vão para um arquivo
# temporário 600 (--from-env-file), e não para a linha de comando — argv fica
# visível a outros processos via 'ps'. O arquivo é apagado ao final, com ou sem erro.
k8s_secret_from_vars() {
    local name="$1" ns="$2" spec key var envfile rc
    shift 2
    envfile="$(mktemp)"
    chmod 600 "$envfile"
    for spec in "$@"; do
        if [[ "$spec" == *=* ]]; then
            key="${spec%%=*}"; var="${spec#*=}"
        else
            key="$spec"; var="$spec"
        fi
        printf '%s=%s\n' "$key" "${!var}" >> "$envfile"
    done
    k3s kubectl create secret generic "$name" -n "$ns" \
        --from-env-file="$envfile" --dry-run=client -o yaml \
        | k3s kubectl apply -f - >/dev/null
    rc=$?
    shred -u "$envfile" 2>/dev/null || rm -f "$envfile"
    return "$rc"
}
