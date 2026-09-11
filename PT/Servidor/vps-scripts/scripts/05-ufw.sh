#!/bin/bash
# Seção 5 — Firewall com UFW

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "05-ufw"

title "5. Configuração do Firewall (UFW)"

prompt SSH_PORT "Porta SSH configurada" "2222"

info "Definindo política padrão: bloquear entradas, permitir saídas..."
ufw default deny incoming
ufw default allow outgoing

info "Liberando SSH na porta ${SSH_PORT}..."
ufw allow "${SSH_PORT}/tcp" comment 'SSH'

info "Liberando HTTP (80) e HTTPS (443)..."
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# ── PostgreSQL — apenas IP admin (opcional) ────────────────────────────────
echo
if confirm "Liberar porta PostgreSQL (5432) para um IP específico?"; then
    prompt_optional ADMIN_IP "Seu IP público (deixe vazio para pular)"
    if [[ -n "${ADMIN_IP:-}" ]]; then
        ufw allow from "$ADMIN_IP" to any port 5432 proto tcp comment 'PostgreSQL admin'
        log "PostgreSQL liberado para $ADMIN_IP"
    else
        info "Nenhum IP informado — porta 5432 não será aberta (prefira túnel SSH: ssh -L 5432:localhost:5432)."
    fi
fi

# ── Ativar ─────────────────────────────────────────────────────────────────
echo
warn "O UFW será ativado agora. Certifique-se de que a porta SSH ${SSH_PORT} está correta."
if confirm "Ativar o firewall?"; then
    ufw --force enable
    log "UFW ativo."
else
    warn "UFW não ativado — execute manualmente: sudo ufw enable"
fi

info "Regras ativas:"
ufw status verbose

# ── Docker × UFW ────────────────────────────────────────────────────────────
# A convivência Docker/UFW é tratada na etapa 8 (daemon.json com iptables
# gerenciado — necessário para o Traefik publicar 80/443 — e o ufw-docker como
# defesa em profundidade). Esta etapa NÃO mexe no daemon.json de propósito: no
# modelo com Traefik, forçar 'iptables: false' aqui quebraria a publicação das
# portas. Ver seções 5.5 e 8 do VPS_SETUP.md.
info "Docker × UFW é configurado na etapa 8 (não altero o daemon.json aqui)."

step_done "Firewall UFW"
