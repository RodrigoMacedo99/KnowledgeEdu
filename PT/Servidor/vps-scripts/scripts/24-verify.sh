#!/bin/bash
# Seção 24 — Verificação da plataforma (self-check)
#
# Bateria de checagens READ-ONLY para confirmar que cada camada subiu e está
# saudável. Detecta o runtime (Docker e/ou k3s) e só checa o que se aplica.
# Não altera nada.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

require_root
init_log "24-verify"

# Um verificador NUNCA deve abortar por causa de uma checagem que falha — ele
# precisa rodar todas e resumir. Por isso desligamos errexit/pipefail aqui.
set +e +o pipefail

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
        *)               no "$label ($name: ${h:-desconhecido})";;
    esac
}

# ── Runtime Docker (pulado no caminho k3s) ──────────────────────────────────
echo -e "${BOLD}Runtime Docker:${RESET}"
if command -v docker &>/dev/null && docker info >/dev/null 2>&1; then
    ok "Docker daemon ativo"
    for n in edge observability; do
        docker network inspect "$n" >/dev/null 2>&1 && ok "Rede '$n' existe" || no "Rede '$n' ausente"
    done
    echo -e "\n${BOLD}Edge proxy (Docker):${RESET}"
    check_container 'socket-proxy' "socket-proxy"
    check_container 'traefik'      "Traefik"
    if [[ -f /opt/platform/edge/acme.json ]]; then
        [[ "$(stat -c '%a' /opt/platform/edge/acme.json 2>/dev/null)" == "600" ]] && ok "acme.json com permissão 600" || wr "acme.json sem permissão 600"
    fi
    echo -e "\n${BOLD}Observabilidade (Docker):${RESET}"
    if [[ -f /opt/platform/observability/compose.yml ]]; then
        for s in prometheus grafana loki alloy cadvisor node-exporter alertmanager; do
            check_container "$s" "$s"
        done
    else
        wr "Observabilidade Docker não instalada (etapa 19)"
    fi
    echo -e "\n${BOLD}2FA web (Docker):${RESET}"
    [[ -f /opt/platform/auth/compose.yml ]] && check_container 'authelia' "Authelia (Docker)" || wr "Authelia Docker não instalado (etapa 21)"
else
    wr "Docker não está em uso — ok se você escolheu o runtime k3s (ver seção k3s abaixo)."
fi

# ── k3s (pulado no caminho Docker) ──────────────────────────────────────────
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

# ── Portas públicas (qualquer runtime) ──────────────────────────────────────
echo -e "\n${BOLD}Portas públicas:${RESET}"
ss -ltn 2>/dev/null | grep -qE ':80\b'  && ok "Porta 80 escutando"  || wr "Porta 80 não escutando (o edge/ingress já subiu?)"
ss -ltn 2>/dev/null | grep -qE ':443\b' && ok "Porta 443 escutando" || wr "Porta 443 não escutando (o edge/ingress já subiu?)"

# ── Acesso (SSH 2FA) ────────────────────────────────────────────────────────
echo -e "\n${BOLD}Acesso:${RESET}"
if grep -qE '^AuthenticationMethods .*keyboard-interactive' /etc/ssh/sshd_config 2>/dev/null; then
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
[[ "$(sysctl -n kernel.kptr_restrict 2>/dev/null)" == "2" ]] && ok "Kernel endurecido (etapa 20)" || wr "Hardening extra do kernel ausente (etapa 20)"

# ── Backups ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Backups:${RESET}"
if crontab -l 2>/dev/null | grep -q '/opt/platform/backups/backup.sh'; then
    ok "Cron de backup configurado"
    latest="$(ls -t /opt/platform/backups/archives/*.age 2>/dev/null | head -1)"
    if [[ -n "$latest" ]]; then
        age_days=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 ))
        [[ "$age_days" -le 1 ]] && ok "Último backup há ${age_days}d" || wr "Último backup há ${age_days}d (verifique)"
    else
        wr "Nenhum arquivo de backup ainda (o cron roda no horário definido)"
    fi
else
    wr "Backups não configurados (etapa 22)"
fi

# ── DNS dos domínios roteados (Docker e/ou k3s) ─────────────────────────────
echo -e "\n${BOLD}DNS dos domínios:${RESET}"
domains="$(
    {
        grep -rhoE 'Host\(`[^`]+`\)' /opt/apps/*/*/compose.override.yml 2>/dev/null | grep -oE '`[^`]+`' | tr -d '`'
        command -v k3s &>/dev/null && k3s kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null
    } | sort -u
)"
if [[ -z "$domains" ]]; then
    wr "Nenhum domínio roteado encontrado ainda"
elif ! command -v dig &>/dev/null; then
    wr "dig não disponível (apt install dnsutils)"
else
    while read -r d; do
        [[ -z "$d" ]] && continue
        [[ -n "$(dig +short "$d" 2>/dev/null)" ]] && ok "$d resolve" || wr "$d não resolve (aponte o DNS para a VPS)"
    done <<< "$domains"
fi

# ── Resumo ─────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}Resumo:${RESET} ${GREEN}${PASS} ok${RESET} · ${YELLOW}${WARN} avisos${RESET} · ${RED}${FAIL} falhas${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
    warn "Há falhas — investigue os itens marcados com ✘."
fi
step_done "Verificação da plataforma (${PASS} ok, ${WARN} avisos, ${FAIL} falhas)"
