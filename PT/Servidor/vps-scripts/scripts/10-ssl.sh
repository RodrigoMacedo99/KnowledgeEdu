#!/bin/bash
# Seção 10 — TLS / HTTPS (status e diagnóstico)
#
# Com o Traefik (etapa 9), o HTTPS é AUTOMÁTICO: cada serviço com as labels de
# TLS recebe e renova o certificado Let's Encrypt sozinho. Não há mais certbot.
# Esta etapa não emite nada — ela só ajuda a diagnosticar quando um certificado
# não aparece.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "10-ssl"

EDGE_DIR="/opt/platform/edge"
ACME_FILE="${EDGE_DIR}/acme.json"

title "10. TLS / HTTPS (status e diagnóstico)"

info "O HTTPS é gerenciado pelo Traefik. Esta etapa apenas verifica o estado."
echo

# ── Traefik está rodando? ──────────────────────────────────────────────────
if docker ps --format '{{.Names}}' | grep -q 'traefik'; then
    log "Container do Traefik está rodando."
else
    error "Traefik não está rodando — rode a etapa 9."
fi

# ── Permissões do acme.json ────────────────────────────────────────────────
if [[ -f "$ACME_FILE" ]]; then
    perms="$(stat -c '%a' "$ACME_FILE")"
    if [[ "$perms" == "600" ]]; then
        log "acme.json com permissão correta (600)."
    else
        warn "acme.json está ${perms} — o Traefik exige 600. Corrigindo..."
        chmod 600 "$ACME_FILE"
    fi

    # ── Certificados já emitidos ───────────────────────────────────────────
    echo
    echo -e "${BOLD}Domínios com certificado emitido:${RESET}"
    if command -v jq &>/dev/null; then
        jq -r '.le.Certificates[]?.domain.main' "$ACME_FILE" 2>/dev/null | sed 's/^/  ✔ /' \
            || echo "  (nenhum ainda)"
    else
        grep -oE '"main":"[^"]+"' "$ACME_FILE" 2>/dev/null | sed 's/"main":"/  ✔ /; s/"//' \
            || echo "  (nenhum ainda — instale jq para um relatório melhor: apt install -y jq)"
    fi
else
    error "acme.json não existe em ${ACME_FILE} — rode a etapa 9."
fi

# ── Dicas de troubleshooting ───────────────────────────────────────────────
echo
echo -e "${BOLD}Se um certificado não é emitido:${RESET}"
echo -e "  • Confirme que o DNS do domínio aponta para o IP da VPS (dig +short DOMÍNIO)."
echo -e "  • As portas 80 e 443 precisam estar abertas no UFW (etapa 5)."
echo -e "  • Veja os logs: ${CYAN}docker compose -f ${EDGE_DIR}/compose.yml logs -f traefik${RESET}"
echo -e "  • Para certificado ${BOLD}wildcard${RESET} (*.dominio), troque o tlsChallenge por"
echo -e "    um dnsChallenge no ${CYAN}${EDGE_DIR}/traefik.yml${RESET} (exige credenciais do provedor de DNS)."

step_done "TLS / HTTPS (diagnóstico)"
