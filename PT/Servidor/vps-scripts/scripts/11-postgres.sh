#!/bin/bash
# Seção 11 — Segurança do PostgreSQL
#
# Checagens e ajuda genéricas para QUALQUER serviço que use Postgres — não
# assume um projeto específico. O backup em si NÃO é feito aqui: é a etapa 22
# (server-wide, criptografado, cobre todos os bancos automaticamente) — ver
# o aviso no fim deste script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "11-postgres"

title "11. Segurança do PostgreSQL"

# ── Verificar binding de porta em TODOS os serviços já criados ─────────────
# Varre os compose de cada serviço (etapa 15) atrás do erro clássico: expor
# 5432 para qualquer IP em vez de só localhost.
echo
info "Verificando binding de porta do Postgres nos serviços existentes..."
FOUND_ANY="n"
for compose_file in /opt/apps/*/*/app/compose.yml /opt/apps/*/*/compose.override.yml; do
    [[ -f "$compose_file" ]] || continue
    FOUND_ANY="y"
    if grep -qE '"?5432:5432"?' "$compose_file" && ! grep -qE '127\.0\.0\.1:5432:5432' "$compose_file"; then
        warn "PROBLEMA em ${compose_file}: porta 5432 pode estar exposta sem binding ao localhost."
        warn "  DE:   - \"5432:5432\""
        warn "  PARA: - \"127.0.0.1:5432:5432\""
    fi
done
if [[ "$FOUND_ANY" == "n" ]]; then
    info "Nenhum serviço encontrado ainda em /opt/apps — rode a etapa 15 para criar um."
else
    log "Verificação concluída."
fi

echo
info "Regra geral para QUALQUER serviço com banco: nunca publique a porta do"
info "banco para 0.0.0.0. Publique só em 127.0.0.1 (ou nem publique — acesse"
info "via túnel SSH) e mantenha o banco fora da rede 'edge'."

# ── Gerar senha forte (utilitário, para qualquer novo banco) ───────────────
echo
info "Gerando uma senha segura (use no .env de qualquer serviço com banco):"
DB_PASSWORD=$(openssl rand -base64 32)
echo -e "${GREEN}Senha gerada:${RESET} ${BOLD}${DB_PASSWORD}${RESET}"
echo
warn "Copie esta senha para o .env do serviço (ex.: POSTGRES_PASSWORD)."
warn "Ela não é salva em nenhum arquivo por segurança — gere outra quando precisar."

# ── Túnel SSH para administração remota ────────────────────────────────────
echo
info "Para acessar qualquer banco remotamente sem expor porta nenhuma:"
echo -e "  ${CYAN}ssh -L 5432:localhost:PORTA_DO_BANCO vps${RESET}"
echo -e "  (troque PORTA_DO_BANCO pela porta reservada — veja a etapa 18)"

# ── Backup: aponta para o sistema genérico (etapa 22) ──────────────────────
echo
warn "Backup NÃO é configurado aqui. A etapa 22 já cobre TODOS os bancos do"
warn "servidor automaticamente (Docker e k3s), criptografados e com retenção —"
warn "não é preciso configurar nada por projeto. Se ainda não rodou, rode agora:"
warn "  etapa 22 — Backups automatizados e criptografados"

step_done "Segurança do PostgreSQL"
