#!/bin/bash
# Seção 18 — Gerenciador de portas da VPS
#
# Como cada projeto (etapa 15) e seu CI/CD (etapa 17) recebem portas alocadas
# automaticamente pelo registro central (lib/ports.sh), este script existe só
# para dar visibilidade e permitir manutenção manual: ver o que está
# reservado, checar uma porta específica e liberar reservas de projetos
# decomissionados.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/ports.sh"

require_root
init_log "18-port-manager"

title "18. Gerenciador de portas"

show_port_menu() {
    echo -e "  ${YELLOW}1${RESET}) Listar todas as portas reservadas"
    echo -e "  ${YELLOW}2${RESET}) Verificar uma porta específica"
    echo -e "  ${YELLOW}3${RESET}) Liberar a reserva de um projeto/ambiente"
    echo -e "  ${YELLOW}0${RESET}) Voltar"
    echo
}

while true; do
    show_port_menu
    read -rp "$(echo -e "${YELLOW}Escolha uma opção:${RESET} ")" choice

    case "$choice" in
        1)
            echo
            list_ports
            echo
            ;;
        2)
            echo
            prompt PORT_TO_CHECK "Qual porta verificar?" ""
            owner=$(find_port_owner "$PORT_TO_CHECK")
            if [[ -n "$owner" ]]; then
                log "Porta ${PORT_TO_CHECK} está reservada para: ${owner}"
            elif port_is_free "$PORT_TO_CHECK"; then
                log "Porta ${PORT_TO_CHECK} está livre (sem reserva e sem processo escutando)."
            else
                warn "Porta ${PORT_TO_CHECK} está em uso por um processo, mas sem reserva no registro."
                warn "Verifique com: ss -ltnp | grep ':${PORT_TO_CHECK}'"
            fi
            echo
            ;;
        3)
            echo
            list_ports
            echo
            prompt PROJECT_TO_RELEASE "Nome do projeto"  ""
            prompt ENV_TO_RELEASE     "Ambiente (production/staging/production-green)" ""
            current_port=$(get_port "$PROJECT_TO_RELEASE" "$ENV_TO_RELEASE")
            if [[ -z "$current_port" ]]; then
                warn "Não há porta reservada para ${PROJECT_TO_RELEASE}:${ENV_TO_RELEASE}."
            elif confirm "Liberar a porta ${current_port} de ${PROJECT_TO_RELEASE}:${ENV_TO_RELEASE}? Isso só remove o registro, não para containers."; then
                release_port "$PROJECT_TO_RELEASE" "$ENV_TO_RELEASE"
                log "Porta ${current_port} liberada. Ela pode ser reutilizada por outro projeto agora."
            fi
            echo
            ;;
        0)
            break
            ;;
        *)
            warn "Opção inválida."
            ;;
    esac
done

step_done "Gerenciador de portas"
