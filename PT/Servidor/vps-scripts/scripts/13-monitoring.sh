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
echo -e "${BOLD}Diagnóstico de rede:${RESET}"
echo "  11) Interfaces de rede            (ip addr / ifconfig)"
echo "  12) Tabela de rotas               (ip route / netstat -r)"
echo "  13) Conexões TCP ativas           (netstat -an)"
echo "  14) Testar conectividade          (ping)"
echo "  15) Rastrear rota até destino     (traceroute)"
echo "  16) Resolver DNS de domínio       (nslookup / dig)"
echo "  17) Verificar DNS do domínio VPS  (dig rápido)"
echo
echo "   0) Sair"
echo

read -rp "$(echo -e "${CYAN}Opção:${RESET} ")" choice

case "$choice" in
    1) tail -f /var/log/auth.log ;;
    2) tail -f /var/log/nginx/access.log ;;
    3) tail -f /var/log/nginx/error.log ;;
    4)
        prompt COMPOSE_PATH "Caminho do docker-compose.yml" "/opt/apps/sql-challenge/backend/docker-compose.yml"
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
    # ── Diagnóstico de rede (Redes II — SENAI CIMATEC) ───────────────────
    11)
        echo -e "\n${BOLD}Interfaces de rede:${RESET}"
        ip addr show
        echo
        echo -e "${BOLD}Resumo (ip -brief):${RESET}"
        ip -brief addr
        ;;
    12)
        echo -e "\n${BOLD}Tabela de rotas:${RESET}"
        ip route show
        echo
        echo -e "${BOLD}netstat -r:${RESET}"
        netstat -r 2>/dev/null || ss -r
        ;;
    13)
        echo -e "\n${BOLD}Conexões TCP ativas:${RESET}"
        netstat -an 2>/dev/null || ss -an
        echo
        echo -e "${BOLD}Estatísticas de sockets:${RESET}"
        ss -s
        ;;
    14)
        prompt PING_TARGET "Host para testar (IP ou domínio)" "8.8.8.8"
        echo
        ping -c 4 "$PING_TARGET"
        echo
        info "Teste de loopback:"
        ping -c 2 127.0.0.1
        ;;
    15)
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
    16)
        prompt DNS_TARGET "Domínio para resolver" ""
        echo
        echo -e "${BOLD}nslookup:${RESET}"
        nslookup "$DNS_TARGET" 2>/dev/null || warn "nslookup não disponível — instale: apt install dnsutils"
        echo
        echo -e "${BOLD}dig (detalhado):${RESET}"
        dig "$DNS_TARGET" 2>/dev/null || warn "dig não disponível — instale: apt install dnsutils"
        ;;
    17)
        info "Instalando dnsutils se necessário..."
        apt install -y dnsutils -qq 2>/dev/null || true
        echo
        echo -e "${BOLD}Verificação rápida de DNS dos domínios configurados no Nginx:${RESET}"
        for site in /etc/nginx/sites-enabled/*; do
            domain=$(grep -E "server_name" "$site" 2>/dev/null | grep -v localhost | awk '{print $2}' | tr -d ';' | head -1)
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
