#!/bin/bash
# Seção 9 — Nginx como reverse proxy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "09-nginx"

title "9. Nginx como reverse proxy"

# ── Instalar ───────────────────────────────────────────────────────────────
if command -v nginx &>/dev/null; then
    already_done "Nginx $(nginx -v 2>&1)"
else
    info "Instalando Nginx..."
    DEBIAN_FRONTEND=noninteractive apt install -y nginx
    systemctl enable nginx
    systemctl start nginx
fi

# ── Remover site padrão ───────────────────────────────────────────────────
[[ -L /etc/nginx/sites-enabled/default ]] && rm /etc/nginx/sites-enabled/default && log "Site padrão removido."

# ── Cabeçalhos globais de segurança ───────────────────────────────────────
SEC_HEADERS="/etc/nginx/conf.d/security-headers.conf"
if [[ -f "$SEC_HEADERS" ]]; then
    already_done "security-headers.conf"
else
    info "Criando cabeçalhos de segurança globais..."
    cat > "$SEC_HEADERS" <<'EOF'
add_header X-Content-Type-Options    "nosniff"                              always;
add_header X-Frame-Options           "DENY"                                 always;
add_header X-XSS-Protection          "1; mode=block"                        always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains"  always;
add_header Referrer-Policy           "strict-origin-when-cross-origin"      always;
EOF
fi

# ── Configurar o SQL Challenge ─────────────────────────────────────────────
prompt DOMAIN      "Domínio da API (ex: api.seudominio.com)" ""
prompt BACKEND_PORT "Porta interna do backend"                "3000"

SITE_FILE="/etc/nginx/sites-available/sql-challenge"

if [[ -f "$SITE_FILE" ]]; then
    already_done "Site sql-challenge no Nginx"
else
    info "Criando configuração do Nginx para sql-challenge..."
    cat > "$SITE_FILE" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 10M;
    proxy_read_timeout   60s;
    proxy_connect_timeout 10s;
    server_tokens        off;

    location / {
        proxy_pass             http://localhost:${BACKEND_PORT};
        proxy_http_version     1.1;
        proxy_set_header Upgrade            \$http_upgrade;
        proxy_set_header Connection         'upgrade';
        proxy_set_header Host               \$host;
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  \$scheme;
        proxy_cache_bypass                  \$http_upgrade;
    }
}
EOF

    ln -sf "$SITE_FILE" /etc/nginx/sites-enabled/sql-challenge
fi

info "Testando configuração do Nginx..."
nginx -t || die "Configuração inválida — verifique $SITE_FILE"

info "Recarregando Nginx..."
systemctl reload nginx

step_done "Nginx (domínio: ${DOMAIN:-não definido}, porta: ${BACKEND_PORT})"
