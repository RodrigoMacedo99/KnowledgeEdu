#!/bin/bash
# Seção 24 — Verificação da plataforma (self-check)
#
# Roda uma bateria de checagens READ-ONLY para confirmar que cada camada subiu e
# está saudável: Docker, redes, Traefik, observabilidade, 2FA, firewall, backups,
# CrowdSec e DNS. Não altera nada — é o "checklist automatizado" pós-deploy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "24-verify"

title "24. Verificação da plataforma (self-check)"

PASS=0; WARN=0; FAIL=0
ok() { echo -e "  ${GREEN}✔${RESET} $*"; PASS=$((PASS+1)); }
wr() { echo -e "  ${YELLOW}!${RESET} $*"; WARN=$((WARN+1)); }
no() { echo -e "  ${RED}✘${RESET} $*"; FAIL=$((FAIL+1)); }

check_container() {
    local re="$1" label="$2" name h
    name="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "$re" | head -1)"
    if [[ -z "$name" ]]; then no "$label: não está rodando"; return; fi
    h="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$name" 2>/dev/null)"
    case "$h" in
        healthy|running) ok "$label ($name: $h)";;
        starting)        wr "$label ($name: iniciando)";;
        *)               no "$label ($name: $h)";;
    esac
}

# ── Docker e redes ─────────────────────────────────────────────────────────
echo -e "${BOLD}Docker e redes:${RESET}"
docker info >/dev/null 2>&1 && ok "Docker daemon ativo" || no "Docker daemon inacessível"
for n in edge observability; do
    docker network inspect "$n" >/dev/null 2>&1 && ok "Rede '$n' existe" || no "Rede '$n' ausente"
done

# ── Edge (Traefik) ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}Edge proxy:${RESET}"
check_container 'socket-proxy' "socket-proxy"
check_container 'traefik'      "Traefik"
if ss -ltn 2>/dev/null | grep -qE ':80\b'; then ok "Porta 80 escutando"; else no "Porta 80 fechada"; fi
if ss -ltn 2>/dev/null | grep -qE ':443\b'; then ok "Porta 443 escutando"; else no "Porta 443 fechada"; fi
if [[ -f /opt/platform/edge/acme.json ]]; then
    [[ "$(stat -c '%a' /opt/platform/edge/acme.json)" == "600" ]] && ok "acme.json com permissão 600" || wr "acme.json sem permissão 600"
fi

# ── Observabilidade ────────────────────────────────────────────────────────
echo -e "\n${BOLD}Observabilidade:${RESET}"
if [[ -f /opt/platform/observability/compose.yml ]]; then
    for s in prometheus grafana loki alloy cadvisor node-exporter alertmanager; do
        check_container "$s" "$s"
    done
else
    wr "Observabilidade não instalada (etapa 19)"
fi

# ── 2FA / Authelia ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}2FA:${RESET}"
[[ -f /opt/platform/auth/compose.yml ]] && check_container 'authelia' "Authelia" || wr "Authelia não instalado (etapa 21)"
if [[ -f /etc/ssh/sshd_config ]] && grep -qE '^AuthenticationMethods .*keyboard-interactive' /etc/ssh/sshd_config; then
    ok "2FA no SSH ativo (AuthenticationMethods)"
else
    wr "2FA no SSH não configurado (etapa 20, opcional)"
fi

# ── Firewall e proteção ────────────────────────────────────────────────────
echo -e "\n${BOLD}Firewall e proteção:${RESET}"
ufw status 2>/dev/null | grep -q "Status: active" && ok "UFW ativo" || no "UFW inativo"
systemctl is-active --quiet fail2ban 2>/dev/null && ok "Fail2Ban ativo" || wr "Fail2Ban inativo"
if command -v cscli &>/dev/null; then
    systemctl is-active --quiet crowdsec 2>/dev/null && ok "CrowdSec ativo" || wr "CrowdSec instalado mas parado"
else
    wr "CrowdSec não instalado (etapa 23)"
fi
sysctl -n kernel.kptr_restrict 2>/dev/null | grep -q 2 && ok "Kernel endurecido (etapa 20)" || wr "Hardening extra do kernel ausente (etapa 20)"

# ── Backups ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Backups:${RESET}"
if crontab -l 2>/dev/null | grep -q '/opt/platform/backups/backup.sh'; then
    ok "Cron de backup configurado"
    latest="$(ls -t /opt/platform/backups/archives/*.age 2>/dev/null | head -1)"
    if [[ -n "$latest" ]]; then
        age_days=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 ))
        [[ "$age_days" -le 1 ]] && ok "Último backup há ${age_days}d" || wr "Último backup há ${age_days}d (verifique)"
    else
        wr "Nenhum arquivo de backup ainda"
    fi
else
    wr "Backups não configurados (etapa 22)"
fi

# ── DNS dos domínios roteados ──────────────────────────────────────────────
echo -e "\n${BOLD}DNS dos domínios:${RESET}"
if command -v dig &>/dev/null; then
    grep -rhoE 'Host\(`[^`]+`\)' /opt/apps/*/*/compose.override.yml 2>/dev/null \
        | grep -oE '`[^`]+`' | tr -d '`' | sort -u | while read -r d; do
        [[ -z "$d" ]] && continue
        [[ -n "$(dig +short "$d" 2>/dev/null)" ]] && echo -e "  ${GREEN}✔${RESET} $d resolve" || echo -e "  ${YELLOW}!${RESET} $d não resolve"
    done
else
    wr "dig não disponível (apt install dnsutils)"
fi

# ── k3s (runtime alternativo, se instalado) ────────────────────────────────
if command -v k3s &>/dev/null; then
    echo -e "\n${BOLD}k3s:${RESET}"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    k3s kubectl get nodes 2>/dev/null | grep -q ' Ready ' && ok "Nó do cluster Ready" || no "Nó do cluster não está Ready"
    k3s kubectl get clusterissuer letsencrypt &>/dev/null && ok "cert-manager (ClusterIssuer letsencrypt)" || wr "ClusterIssuer letsencrypt ausente (etapa 25)"
    if k3s kubectl get ns observability &>/dev/null; then
        pend="$(k3s kubectl get pods -n observability --no-headers 2>/dev/null | grep -cvE 'Running|Completed')"
        [[ "${pend:-0}" -eq 0 ]] && ok "Observabilidade no k3s (pods Running)" || wr "Observabilidade no k3s: ${pend} pod(s) fora de Running"
    else
        wr "Observabilidade no k3s não instalada (etapa 26)"
    fi
    k3s kubectl get deploy authelia -n auth &>/dev/null && ok "Authelia no k3s" || wr "Authelia no k3s não instalado (etapa 27)"
fi

# ── Resumo ─────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}Resumo:${RESET} ${GREEN}${PASS} ok${RESET} · ${YELLOW}${WARN} avisos${RESET} · ${RED}${FAIL} falhas${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
    warn "Há falhas — investigue os itens marcados com ✘."
    exit 1
fi
step_done "Verificação da plataforma (${PASS} ok, ${WARN} avisos)"
