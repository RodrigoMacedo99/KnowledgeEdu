#!/bin/bash
# Seção 5 — Firewall com UFW

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "05-ufw"

title "5. Configuração do Firewall (UFW)"

prompt SSH_PORT "Porta SSH configurada" "2222"
# SSH só para os IPs da equipe (decisão do projeto): nunca aberto ao mundo.
prompt TEAM_IPS "IP(s) da equipe com acesso SSH (IPv4 ou CIDR, separados por espaço)" "$(get_config TEAM_IPS)"
TEAM_IP_PATTERN='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
for ip in $TEAM_IPS; do
    [[ "$ip" =~ $TEAM_IP_PATTERN ]] || die "IP inválido: ${ip}"
done
save_config TEAM_IPS "$TEAM_IPS"

info "Definindo política padrão: bloquear entradas, permitir saídas..."
ufw default deny incoming
ufw default allow outgoing

info "Liberando SSH na porta ${SSH_PORT} somente para a equipe..."
for ip in $TEAM_IPS; do
    ufw allow from "$ip" to any port "$SSH_PORT" proto tcp comment 'SSH equipe'
done

# Regra de SSH presente? 'ufw show added' lista as regras mesmo com o UFW inativo
# ('ufw status' não lista regras enquanto estiver inativo).
ssh_rule_present() {
    ufw show added 2>/dev/null | grep -qE "(port ${SSH_PORT}\b|${SSH_PORT}/tcp)"
}

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
    # Sem regra de SSH, ativar o UFW derruba o acesso remoto: checa antes.
    ssh_rule_present || die "Não há regra liberando a porta ${SSH_PORT}/tcp. UFW NÃO ativado (evita perder o SSH)."
    # E sem chave pública de algum usuário, a equipe ficaria sem como entrar.
    shopt -s nullglob
    key_found="n"
    for home_dir in /home/*/; do
        has_authorized_key "$(basename "$home_dir")" && key_found="y"
    done
    shopt -u nullglob
    [[ "$key_found" == "y" ]] || die "Nenhum usuário com chave pública SSH instalada. UFW NÃO ativado."
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
