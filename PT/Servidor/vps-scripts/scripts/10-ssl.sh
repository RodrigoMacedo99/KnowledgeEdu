#!/bin/bash
# Seção 10 — SSL com Let's Encrypt e renovação automática

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "10-ssl"

title "10. SSL com Let's Encrypt"

prompt DOMAIN "Domínio para emitir o certificado (ex: api.seudominio.com)" ""
prompt EMAIL  "E-mail para notificações do Let's Encrypt"                   ""

# ── Instalar Certbot ──────────────────────────────────────────────────────
if command -v certbot &>/dev/null; then
    already_done "Certbot $(certbot --version 2>&1)"
else
    info "Instalando Certbot e plugin Nginx..."
    DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx
fi

# ── Emitir certificado ────────────────────────────────────────────────────
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
if [[ -d "$CERT_PATH" ]]; then
    already_done "Certificado para $DOMAIN"
else
    info "Emitindo certificado para $DOMAIN..."
    certbot --nginx \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        --redirect
fi

# ── Verificar timer de renovação automática ───────────────────────────────
info "Status do timer de renovação automática:"
systemctl status certbot.timer --no-pager || warn "Timer não encontrado — verificando cron..."

info "Testando renovação (dry-run)..."
certbot renew --dry-run --quiet && log "Renovação automática funcionando."

step_done "SSL para $DOMAIN"
