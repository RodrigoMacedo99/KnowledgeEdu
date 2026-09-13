#!/bin/bash
# Seção 6 — Grupos e usuários por projeto

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "06-groups-users"

title "6. Grupos e usuários por projeto"

prompt ADMIN_USER "Nome do usuário admin" "admin"

# ── Grupo webapps ──────────────────────────────────────────────────────────
if getent group webapps &>/dev/null; then
    already_done "Grupo webapps"
else
    info "Criando grupo webapps..."
    groupadd webapps
fi

# Cada serviço recebe seu PRÓPRIO usuário de sistema, criado sob demanda pela
# etapa 15 (novo serviço) — não há usuário de exemplo fixo aqui. O grupo
# webapps acima é o que todos eles compartilham.

# ── Admin nos grupos webapps e docker ─────────────────────────────────────
info "Adicionando '$ADMIN_USER' aos grupos webapps e docker..."
usermod -aG webapps "$ADMIN_USER"
if getent group docker &>/dev/null; then
    usermod -aG docker "$ADMIN_USER"
else
    warn "Grupo docker não existe ainda — será adicionado após instalar o Docker (etapa 8)."
fi

log "Grupos do usuário '$ADMIN_USER': $(groups "$ADMIN_USER")"
warn "Faça logout e login novamente para os grupos serem aplicados na sessão."

step_done "Grupos e usuários"
