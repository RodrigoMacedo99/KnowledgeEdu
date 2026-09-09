#!/bin/bash
# Seção 13 — Monitoramento e logs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "13-monitoring"

title "13. Monitoramento e logs"

# ── Menu de ações de monitoramento ────────────────────────────────────────
echo -e "${BOLD}Logs e sistema:${RESET}"
echo "   1) Tentativas de acesso SSH      (auth.log)"
echo "   2) Acessos recebidos pelo Nginx  (access.log)"
echo "   3) Erros do Nginx                (error.log)"
echo "   4) Logs dos containers Docker    (docker-compose logs)"
echo "   5) IPs banidos pelo Fail2Ban     (fail2ban status)"
echo "   6) Recursos do sistema           (htop)"
echo "   7) Recursos dos containers       (docker stats)"
echo "   8) Uso de disco por projeto      (du / df)"
echo "   9) Portas abertas no servidor    (ss)"
echo "  10) Sincronização de tempo        (chrony)"
echo
echo -e "${BOLD}Plataforma (Traefik + Observabilidade):${RESET}"
echo "  11) Saúde da plataforma           (docker compose ps edge/observability)"
echo "  12) Dashboards e URLs             (Grafana / Traefik)"
echo
echo -e "${BOLD}Diagnóstico de rede:${RESET}"
echo "  21) Interfaces de rede            (ip addr / ifconfig)"
echo "  22) Tabela de rotas               (ip route / netstat -r)"
echo "  23) Conexões TCP ativas           (netstat -an)"
echo "  24) Testar conectividade          (ping)"
echo "  25) Rastrear rota até destino     (traceroute)"
echo "  26) Resolver DNS de domínio       (nslookup / dig)"
echo "  27) Verificar DNS do domínio VPS  (dig rápido)"
echo
echo "   0) Sair"
echo

read -rp "$(echo -e "${CYAN}Opção:${RESET} ")" choice

case "$choice" in
    1) tail -f /var/log/auth.log ;;
    2) tail -f /var/log/nginx/access.log ;;
    3) tail -f /var/log/nginx/error.log ;;
    4)
        prompt COMPOSE_PATH "Caminho do compose.yml" "/opt/apps/PROJETO/production/app/compose.yml"
        docker compose -f "$COMPOSE_PATH" logs -f
        ;;
    5)
        fail2ban-client status sshd
        echo
        info "Para desbanir um IP: sudo fail2ban-client set sshd unbanip IP"
        ;;
    6) htop ;;
    7) docker stats ;;
    8)
        echo -e "\n${BOLD}Uso de disco por projeto:${RESET}"
        du -sh /opt/apps/* 2>/dev/null
        echo -e "\n${BOLD}Espaço em disco:${RESET}"
        df -h
        ;;
    9)
        echo -e "\n${BOLD}Portas abertas e processos:${RESET}"
        ss -tulpen
        ;;
    10)
        echo -e "\n${BOLD}Status da sincronização NTP (Chrony):${RESET}"
        chronyc tracking 2>/dev/null || warn "Chrony não instalado — rode o script 16-ntp.sh"
        echo
        chronyc sources -v 2>/dev/null || true
        echo
        info "Hora atual do servidor: $(date)"
        ;;
    # ── Plataforma ───────────────────────────────────────────────────────
    11)
        echo -e "\n${BOLD}Edge proxy (Traefik):${RESET}"
        docker compose -f /opt/platform/edge/compose.yml ps 2>/dev/null || warn "Edge não instalado (etapa 9)."
        echo -e "\n${BOLD}Observabilidade:${RESET}"
        docker compose -f /opt/platform/observability/compose.yml ps 2>/dev/null || warn "Observabilidade não instalada (etapa 19)."
        ;;
    12)
        echo -e "\n${BOLD}URLs da plataforma (lidas de /opt/platform/.env):${RESET}"
        if [[ -f /opt/platform/.env ]]; then
            grep -E '^(TRAEFIK_DASHBOARD_HOST|GRAFANA_HOST)=' /opt/platform/.env | while IFS='=' read -r k v; do
                echo -e "  ${CYAN}https://${v}${RESET}  (${k})"
            done
        else
            warn "/opt/platform/.env não encontrado — rode as etapas 9 e 19."
        fi
        ;;
    # ── Diagnóstico de rede (Redes II — SENAI CIMATEC) ───────────────────
    21)
        echo -e "\n${BOLD}Interfaces de rede:${RESET}"
        ip addr show
        echo
        echo -e "${BOLD}Resumo (ip -brief):${RESET}"
        ip -brief addr
        ;;
    22)
        echo -e "\n${BOLD}Tabela de rotas:${RESET}"
        ip route show
        echo
        echo -e "${BOLD}netstat -r:${RESET}"
        netstat -r 2>/dev/null || ss -r
        ;;
    23)
        echo -e "\n${BOLD}Conexões TCP ativas:${RESET}"
        netstat -an 2>/dev/null || ss -an
        echo
        echo -e "${BOLD}Estatísticas de sockets:${RESET}"
        ss -s
        ;;
    24)
        prompt PING_TARGET "Host para testar (IP ou domínio)" "8.8.8.8"
        echo
        ping -c 4 "$PING_TARGET"
        echo
        info "Teste de loopback:"
        ping -c 2 127.0.0.1
        ;;
    25)
        prompt TRACE_TARGET "Destino para traceroute" "8.8.8.8"
        echo
        if command -v traceroute &>/dev/null; then
            traceroute "$TRACE_TARGET"
        else
            info "Instalando traceroute..."
            apt install -y traceroute -qq
            traceroute "$TRACE_TARGET"
        fi
        ;;
    26)
        prompt DNS_TARGET "Domínio para resolver" ""
        echo
        echo -e "${BOLD}nslookup:${RESET}"
        nslookup "$DNS_TARGET" 2>/dev/null || warn "nslookup não disponível — instale: apt install dnsutils"
        echo
        echo -e "${BOLD}dig (detalhado):${RESET}"
        dig "$DNS_TARGET" 2>/dev/null || warn "dig não disponível — instale: apt install dnsutils"
        ;;
    27)
        info "Instalando dnsutils se necessário..."
        apt install -y dnsutils -qq 2>/dev/null || true
        echo
        echo -e "${BOLD}Verificação rápida de DNS dos domínios roteados pelo Traefik:${RESET}"
        # Extrai os Host(`...`) dos compose.override.yml de cada serviço.
        grep -rhoE 'Host\(`[^`]+`\)' /opt/apps/*/*/compose.override.yml /opt/platform/.env 2>/dev/null \
            | grep -oE '`[^`]+`' | tr -d '`' | sort -u | while read -r domain; do
            [[ -z "$domain" ]] && continue
            ip=$(dig +short "$domain" 2>/dev/null | tail -1)
            if [[ -n "$ip" ]]; then
                echo -e "  ${GREEN}✔${RESET} ${domain} → ${ip}"
            else
                echo -e "  ${RED}✘${RESET} ${domain} → não resolvido"
            fi
        done
        ;;
    0) exit 0 ;;
    *) warn "Opção inválida." ;;
esac
