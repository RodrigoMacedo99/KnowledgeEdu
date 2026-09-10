# Observabilidade — Métricas, Logs e Dashboards

> Como enxergar o que acontece dentro de uma VPS que roda vários serviços em containers: métricas com **Prometheus**, dashboards com **Grafana**, logs com **Loki + Grafana Alloy**, e os exporters que alimentam tudo (**cAdvisor**, **node-exporter**). Do conceito ao stack rodando.

---

## Índice

1. [Por que observabilidade](#1-por-que-observabilidade)
2. [Os três pilares](#2-os-três-pilares)
3. [As peças do stack](#3-as-peças-do-stack)
4. [Como as peças se conectam](#4-como-as-peças-se-conectam)
5. [Subir o stack](#5-subir-o-stack)
6. [Dashboards essenciais](#6-dashboards-essenciais)
7. [Consultas que você vai usar](#7-consultas-que-você-vai-usar)
8. [Alertas e SLOs](#8-alertas-e-slos)
9. [Segurança do stack](#9-segurança-do-stack)

---

## 1. Por que observabilidade

Monitoramento responde "está no ar?". Observabilidade responde "**por que** está lento/quebrado?" — mesmo para um problema que você nunca viu antes. Com vários serviços na mesma máquina, olhar `docker logs` de cada container um por um não escala. Você precisa de:

- **Métricas** — números ao longo do tempo (requisições/s, latência, uso de CPU). Baratas de guardar, ótimas para gráficos e alertas.
- **Logs** — o texto de cada evento. Caros de guardar, indispensáveis para investigar um caso específico.
- **Traces** — o caminho de uma requisição atravessando vários serviços. (Deixamos o caminho pronto via OpenTelemetry, mas o foco aqui é métricas + logs.)

> Alinhamento com o `CLAUDE.md` do projeto: logs estruturados em JSON, métricas RED expostas em `/metrics` e SLOs de disponibilidade/erro/latência. Este stack é o que torna esses SLOs mensuráveis.

---

## 2. Os três pilares

| Pilar | Pergunta que responde | Ferramenta aqui |
|---|---|---|
| Métricas | Quantas requisições? Qual a latência p99? CPU? | Prometheus → Grafana |
| Logs | O que exatamente aconteceu nesse erro às 14h03? | Loki (coletado pelo Alloy) → Grafana |
| Traces | Onde a requisição gastou tempo entre os serviços? | OTLP via Alloy (opcional) |

**RED** é o conjunto mínimo de métricas por serviço: **R**ate (requisições/s), **E**rrors (taxa de erro), **D**uration (latência). O Traefik expõe as três nativamente — por isso ele é o coração das métricas de tráfego.

---

## 3. As peças do stack

Todas sobem juntas via `vps-scripts/templates/observability/compose.yml` (etapa 19).

- **Prometheus** — banco de séries temporais. A cada 15s ele "raspa" (`scrape`) os alvos configurados em `prometheus.yml` e guarda os números. Modelo *pull*: é o Prometheus que vai buscar, não os serviços que empurram.
- **Grafana** — a camada visual. Lê do Prometheus (métricas) e do Loki (logs) e desenha dashboards. É a **única** peça acessível de fora — via Traefik, com login.
- **Loki** — o "Prometheus dos logs": indexa por *labels* (serviço, container) em vez do texto inteiro, o que o torna leve e barato.
- **Grafana Alloy** — o coletor. Descobre todos os containers, lê os logs deles e envia ao Loki. Substitui o Promtail (EOL desde mar/2026) e fala OpenTelemetry, então serve também de porta de entrada para métricas e traces OTLP.
- **cAdvisor** — expõe métricas **por container**: CPU, memória, rede, disco de cada um.
- **node-exporter** — expõe métricas **do host**: CPU, RAM, disco, load da própria VPS.

---

## 4. Como as peças se conectam

```
                    raspa métricas (pull, 15s)
Prometheus ◄──────── Traefik (:8082/metrics)   ← Rate/Errors/Duration
    ▲       ◄──────── cAdvisor (:8080)          ← métricas por container
    │       ◄──────── node-exporter (:9100)     ← métricas do host
    │
    │ datasource
    ▼
 Grafana ──datasource──► Loki ◄──push── Alloy ◄──lê logs── (todos os containers)
    ▲
    │  HTTPS + login (via Traefik, rede edge)
  você
```

- Prometheus, Loki, Alloy e os exporters vivem só na rede **`observability`** — nenhum é publicado na internet.
- O Prometheus também entra na rede **`edge`** só para alcançar as métricas do Traefik.
- O Grafana entra na `edge` para o Traefik roteá-lo com HTTPS.
- O Alloy descobre os containers pelo **docker-socket-proxy** (leitura apenas), o mesmo padrão de segurança do Traefik.

---

## 5. Subir o stack

Pré-requisitos: etapas 7 (pastas), 8 (Docker + redes) e 9 (Traefik) já feitas.

```bash
sudo bash vps-scripts/scripts/19-observability.sh
```

O script pede o domínio do Grafana, gera a senha admin (guardada em `/opt/platform/.env`), provisiona os datasources automaticamente e sobe tudo. Depois:

1. Aponte o DNS do domínio do Grafana para o IP da VPS (o Traefik precisa disso para emitir o certificado).
2. Acesse `https://grafana.seudominio.com` e entre com `admin` + a senha gerada.

```bash
# Ver a senha, se precisar
sudo grep GF_SECURITY_ADMIN_PASSWORD /opt/platform/.env

# Conferir que subiu tudo
docker compose -f /opt/platform/observability/compose.yml ps
```

---

## 6. Dashboards essenciais

O Grafana importa dashboards da comunidade por **ID** (Dashboards → New → Import):

| ID | Dashboard | Mostra |
|---|---|---|
| `1860` | Node Exporter Full | CPU, RAM, disco, rede do host |
| `19792` | cAdvisor / Docker | recursos por container |
| `17346` | Traefik v3 | Rate, Errors, Duration por router/serviço |

Ao importar, selecione o datasource **Prometheus**. Salve o JSON em `/opt/platform/observability/grafana/provisioning/dashboards/` para versioná-lo — assim ele volta sozinho se o Grafana for recriado.

Para logs, use **Explore → Loki**: sem dashboard, você já consulta os logs de qualquer container por label.

---

## 7. Consultas que você vai usar

**PromQL (métricas)** — no Explore com datasource Prometheus:

```promql
# Requisições por segundo por serviço (Rate)
sum(rate(traefik_service_requests_total[5m])) by (service)

# Taxa de erro 5xx (Errors)
sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) by (service)

# Latência p99 por serviço (Duration)
histogram_quantile(0.99, sum(rate(traefik_service_request_duration_seconds_bucket[5m])) by (le, service))

# Memória por container
container_memory_usage_bytes{name!=""}
```

**LogQL (logs)** — no Explore com datasource Loki:

```logql
# Todos os logs de um container
{container="meuservico-production-api"}

# Só erros
{container="meuservico-production-api"} |= "error"

# Erros HTTP 5xx no Traefik (logs em JSON)
{container="edge-traefik-1"} | json | DownstreamStatus >= 500
```

---

## 8. Alertas e SLOs

Os SLOs mínimos do projeto (`CLAUDE.md`): disponibilidade 99.9%, taxa de erro < 0.1%, p99 < 2s. O caminho recomendado:

1. Comece **observando** os painéis por algumas semanas para conhecer o normal do seu tráfego.
2. Configure alertas no Grafana (Alerting) sobre as métricas RED do Traefik — ex.: p99 > 2s por 5 min, ou taxa de erro > 0.1%.
3. Para roteamento de alertas (e-mail, Slack, on-call), adicione depois um **Alertmanager** ou use o Grafana Alerting com contact points. (Fora do escopo do stack base — deixado como próximo passo.)

---

## 9. Segurança do stack

- **Nada é público, exceto o Grafana** — e ele exige login (signup e acesso anônimo desligados). Prometheus, Loki, cAdvisor e node-exporter só existem na rede `observability`.
- **Senha admin forte** gerada automaticamente, guardada só no `/opt/platform/.env` (chmod 640).
- **Socket do Docker em leitura apenas** para o Alloy (docker-socket-proxy), nunca o socket cru.
- **Limites de recursos** em cada container para a observabilidade não competir por RAM/CPU com as aplicações.
- Considere restringir o Grafana também por IP (middleware `admin-allowlist@file` do Traefik) se ele não precisa ser acessível de qualquer lugar.

---

> Escrito para **Ubuntu 24.04 LTS**. Faz par com [`VPS_SETUP.md`](./VPS_SETUP.md) (a etapa 19 sobe este stack).
