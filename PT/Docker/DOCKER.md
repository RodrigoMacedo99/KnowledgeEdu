# Docker — Do Zero ao Deploy em Produção

> Guia completo sobre containers: o que são, como funcionam, como criar imagens, orquestrar serviços com Docker Compose e aplicar boas práticas em produção.

---

## Índice

1. [O que é Docker e por que usar](#1-o-que-é-docker-e-por-que-usar)
2. [Instalação](#2-instalação)
3. [Conceitos fundamentais](#3-conceitos-fundamentais)
4. [Imagens — construindo com Dockerfile](#4-imagens--construindo-com-dockerfile)
5. [Containers — ciclo de vida](#5-containers--ciclo-de-vida)
6. [Volumes — persistência de dados](#6-volumes--persistência-de-dados)
7. [Redes — comunicação entre containers](#7-redes--comunicação-entre-containers)
8. [Docker Compose — orquestrando múltiplos serviços](#8-docker-compose--orquestrando-múltiplos-serviços)
9. [Variáveis de ambiente e arquivos .env](#9-variáveis-de-ambiente-e-arquivos-env)
10. [Multi-stage build — imagens menores e mais seguras](#10-multi-stage-build--imagens-menores-e-mais-seguras)
11. [Boas práticas de produção](#11-boas-práticas-de-produção)
12. [Multi-serviço em produção: Traefik e observabilidade](#12-multi-serviço-em-produção-traefik-e-observabilidade)
13. [GitOps com Docker](#13-gitops-com-docker)
14. [Comandos de referência rápida](#14-comandos-de-referência-rápida)

---

## 1. O que é Docker e por que usar

### O problema que o Docker resolve

Imagine que você desenvolve uma aplicação Node.js no seu computador Windows, mas ela vai rodar num servidor Linux. O servidor tem uma versão diferente do Node. Uma biblioteca que você usa funciona de um jeito no Windows e de outro no Linux. Resultado: **funciona na minha máquina, quebra em produção**.

O Docker resolve isso **empacotando a aplicação junto com tudo o que ela precisa para rodar**: o runtime, as bibliotecas, as configurações, as variáveis de ambiente. Esse pacote é chamado de **container**.

### Container vs. Máquina Virtual

| | Container | Máquina Virtual |
|---|---|---|
| O que isola | Processo com sistema de arquivos próprio | Sistema operacional completo |
| Tamanho | MB | GB |
| Tempo de inicialização | Segundos | Minutos |
| Compartilha kernel do host | Sim | Não |
| Isolamento | Bom | Total |

O container **não é uma VM**. Ele usa o kernel do sistema operacional do host mas tem seu próprio sistema de arquivos, processos e rede. É muito mais leve e rápido.

### Por que usar?

- **Ambientes idênticos** em desenvolvimento, homologação e produção
- **Isolamento** — cada aplicação roda sem interferir nas outras
- **Portabilidade** — roda em qualquer máquina com Docker instalado
- **Escalabilidade** — containers são fáceis de replicar
- **CI/CD** — pipelines reproduzíveis e previsíveis

---

## 2. Instalação

### Linux (Ubuntu/Debian)

```bash
# Baixar e executar o script oficial de instalação
curl -fsSL https://get.docker.com | sh
```

- `curl` — ferramenta para fazer requisições HTTP pelo terminal
- `-fsSL` — flags combinadas: `-f` falha silenciosamente em erro HTTP, `-s` modo silencioso, `-S` mostra erros mesmo em modo silencioso, `-L` segue redirecionamentos
- `| sh` — passa o conteúdo baixado direto para o shell executar

```bash
# Adicionar seu usuário ao grupo docker para não precisar de sudo
sudo usermod -aG docker $USER

# Aplicar a mudança sem precisar fazer logout/login
newgrp docker
```

- `usermod -aG docker $USER` — adiciona (`-a` = append, `-G` = grupo) o usuário atual ao grupo `docker`
- `$USER` — variável de ambiente que contém o nome do usuário logado
- `newgrp docker` — muda o grupo primário da sessão atual para `docker`

### Verificar a instalação

```bash
docker --version
# Docker version 26.x.x, build xxxxxxx

docker compose version
# Docker Compose version v2.x.x
```

---

## 3. Conceitos fundamentais

### 3.1 Imagem

Uma **imagem** é um template somente-leitura que descreve o ambiente de execução da aplicação. Ela contém o sistema de arquivos base, as dependências instaladas, o código da aplicação e o comando que inicia a aplicação.

Pense na imagem como uma **receita de bolo**: ela descreve todos os ingredientes e o passo a passo, mas ainda não é o bolo.

Imagens são construídas a partir de um arquivo chamado `Dockerfile`.

### 3.2 Container

Um **container** é uma imagem em execução. Você pode criar vários containers a partir da mesma imagem — cada um será um processo isolado independente.

Continuando a analogia: se a imagem é a receita, o container é o bolo que você fez seguindo a receita.

### 3.3 Registry

Um **registry** é um repositório de imagens. O registry público padrão é o [Docker Hub](https://hub.docker.com), onde você encontra imagens oficiais de Node.js, PostgreSQL, Nginx, Redis, etc.

```bash
# Baixar uma imagem do Docker Hub
docker pull node:20-alpine

# node:20-alpine significa:
# - node       → nome da imagem
# - 20         → versão do Node.js
# - alpine     → variante baseada no Alpine Linux (mais leve)
```

### 3.4 Layer (camada)

Imagens são construídas em **camadas**. Cada instrução no Dockerfile gera uma camada. Camadas são reutilizadas entre imagens e cacheadas durante o build — isso torna builds subsequentes muito mais rápidos.

```
[camada 4] COPY . .              ← código da aplicação
[camada 3] RUN npm install       ← dependências instaladas
[camada 2] COPY package.json .   ← arquivo de dependências
[camada 1] FROM node:20-alpine   ← sistema base
```

Se você muda só o código (camada 4), as camadas 1, 2 e 3 são reutilizadas do cache.

---

## 4. Imagens — construindo com Dockerfile

O `Dockerfile` é um arquivo de texto com instruções para construir uma imagem.

### Exemplo: aplicação Node.js

```dockerfile
# 1. Imagem base — ponto de partida
FROM node:20-alpine

# 2. Definir o diretório de trabalho dentro do container
WORKDIR /app

# 3. Copiar os arquivos de dependências ANTES do código
#    (aproveita o cache — se package.json não mudou, npm install não roda de novo)
COPY package.json package-lock.json ./

# 4. Instalar as dependências
RUN npm ci --only=production

# 5. Copiar o restante do código
COPY . .

# 6. Expor a porta que a aplicação usa (apenas documentação — não abre a porta no host)
EXPOSE 3000

# 7. Comando que inicia a aplicação quando o container sobe
CMD ["node", "src/index.js"]
```

### Instruções principais do Dockerfile

| Instrução | O que faz |
|---|---|
| `FROM` | Define a imagem base |
| `WORKDIR` | Define o diretório de trabalho (cria se não existir) |
| `COPY` | Copia arquivos do host para dentro da imagem |
| `ADD` | Como COPY, mas também extrai `.tar` e aceita URLs |
| `RUN` | Executa um comando durante o build (instala pacotes, compila código) |
| `ENV` | Define variáveis de ambiente na imagem |
| `ARG` | Define variáveis disponíveis apenas durante o build |
| `EXPOSE` | Documenta qual porta a aplicação usa (não abre a porta) |
| `CMD` | Comando padrão ao iniciar o container (pode ser sobrescrito) |
| `ENTRYPOINT` | Comando que sempre executa ao iniciar (não pode ser sobrescrito facilmente) |

### Construir e executar

```bash
# Construir a imagem
docker build -t minha-api:1.0 .
```

- `build` — constrói a imagem
- `-t minha-api:1.0` — nomeia (`-t` = tag) a imagem como `minha-api` na versão `1.0`
- `.` — contexto de build: diretório atual (onde está o Dockerfile)

```bash
# Iniciar um container a partir da imagem
docker run -d -p 3000:3000 --name api minha-api:1.0
```

- `run` — cria e inicia um container
- `-d` — modo detached (roda em background)
- `-p 3000:3000` — mapeia a porta: `PORTA_HOST:PORTA_CONTAINER`
- `--name api` — nome do container
- `minha-api:1.0` — imagem a usar

### .dockerignore

Assim como o `.gitignore`, o `.dockerignore` lista arquivos que não devem ser enviados para o contexto de build:

```
node_modules
.env
.env.*
.git
*.log
dist
coverage
```

Isso evita enviar `node_modules` (pesado e desnecessário — será instalado durante o build) e o `.env` (que contém segredos).

---

## 5. Containers — ciclo de vida

```bash
# Listar containers em execução
docker ps

# Listar todos (incluindo os parados)
docker ps -a

# Parar um container (envia SIGTERM, aguarda, depois SIGKILL)
docker stop api

# Iniciar um container parado
docker start api

# Reiniciar
docker restart api

# Remover um container (precisa estar parado)
docker rm api

# Remover um container em execução (forçado)
docker rm -f api

# Ver os logs de um container
docker logs api

# Acompanhar logs em tempo real
docker logs -f api

# Executar um comando dentro do container em execução
docker exec -it api sh

# -i = interativo (mantém stdin aberto)
# -t = aloca um pseudo-TTY (terminal)
# sh = shell a abrir (use bash se disponível)
```

### Inspecionar um container

```bash
# Ver todas as informações do container (JSON)
docker inspect api

# Ver apenas o IP do container
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' api
```

---

## 6. Volumes — persistência de dados

Por padrão, tudo dentro de um container é **efêmero** — se o container for removido, os dados somem. Volumes resolvem isso.

### Tipos de montagem

#### Named Volume (recomendado para dados de produção)

```bash
# Criar um volume
docker volume create dados_postgres

# Usar o volume ao criar um container
docker run -d \
  -v dados_postgres:/var/lib/postgresql/data \
  --name db \
  postgres:16
```

- `-v dados_postgres:/var/lib/postgresql/data` — monta o volume `dados_postgres` no caminho `/var/lib/postgresql/data` dentro do container
- O Docker gerencia onde esse volume fica no host (em `/var/lib/docker/volumes/`)

```bash
# Listar volumes
docker volume ls

# Inspecionar um volume
docker volume inspect dados_postgres

# Remover um volume (CUIDADO: apaga os dados)
docker volume rm dados_postgres
```

#### Bind Mount (recomendado para desenvolvimento)

```bash
# Montar uma pasta do host dentro do container
docker run -d \
  -v /home/user/projeto:/app \
  --name api \
  minha-api:1.0
```

- `/home/user/projeto:/app` — monta a pasta `/home/user/projeto` do host no caminho `/app` do container
- Útil em desenvolvimento: mudanças no código do host refletem instantaneamente no container

---

## 7. Redes — comunicação entre containers

Containers na mesma rede Docker podem se comunicar pelo **nome do container**, como se fosse um hostname DNS interno.

### Tipos de rede

| Tipo | Quando usar |
|---|---|
| `bridge` (padrão) | Comunicação entre containers no mesmo host |
| `host` | Container compartilha a rede do host (sem isolamento) |
| `none` | Container sem rede |

### Criar e usar redes

```bash
# Criar uma rede
docker network create minha-rede

# Iniciar containers na mesma rede
docker run -d --network minha-rede --name db postgres:16
docker run -d --network minha-rede --name api minha-api:1.0

# Agora "api" pode se conectar em "db:5432" pelo nome
```

```bash
# Listar redes
docker network ls

# Inspecionar uma rede
docker network inspect minha-rede

# Conectar um container existente a uma rede
docker network connect minha-rede api
```

---

## 8. Docker Compose — orquestrando múltiplos serviços

Quando sua aplicação tem mais de um serviço (API + banco de dados, por exemplo), gerenciar cada container manualmente fica impraticável. O **Docker Compose** permite definir todos os serviços em um único arquivo YAML e subi-los com um comando.

### Estrutura do docker-compose.yml

```yaml
# Exemplo: API Node.js + PostgreSQL

services:
  # ─── Banco de dados ───────────────────────────────────────────
  db:
    image: postgres:16-alpine        # imagem do Docker Hub
    container_name: meu-db
    restart: unless-stopped          # reinicia automaticamente, exceto se parado manualmente
    environment:
      POSTGRES_USER: app_user
      POSTGRES_PASSWORD: senha_forte
      POSTGRES_DB: meu_banco
    volumes:
      - dados_postgres:/var/lib/postgresql/data  # dados persistentes
    networks:
      - app-network
    healthcheck:                      # verifica se o banco está pronto para aceitar conexões
      test: ["CMD-SHELL", "pg_isready -U app_user -d meu_banco"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ─── API ──────────────────────────────────────────────────────
  api:
    build:
      context: .                     # constrói a imagem a partir do Dockerfile local
      dockerfile: Dockerfile
    container_name: minha-api
    restart: unless-stopped
    ports:
      - "3000:3000"                  # expõe a porta 3000 para o host
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://app_user:senha_forte@db:5432/meu_banco
    depends_on:
      db:
        condition: service_healthy   # aguarda o banco estar healthy antes de subir
    networks:
      - app-network

# ─── Volumes ──────────────────────────────────────────────────────
volumes:
  dados_postgres:

# ─── Redes ────────────────────────────────────────────────────────
networks:
  app-network:
    driver: bridge
```

### Campos principais do docker-compose.yml

| Campo | O que define |
|---|---|
| `image` | Imagem do Docker Hub a usar |
| `build` | Constrói a imagem a partir de um Dockerfile local |
| `container_name` | Nome fixo do container |
| `restart` | Política de reinicialização (`no`, `always`, `unless-stopped`, `on-failure`) |
| `ports` | Mapeamento de portas `HOST:CONTAINER` |
| `environment` | Variáveis de ambiente passadas para o container |
| `volumes` | Montagem de volumes |
| `networks` | Redes às quais o serviço pertence |
| `depends_on` | Ordem de inicialização e condição de dependência |
| `healthcheck` | Comando para verificar se o serviço está saudável |

### Comandos do Docker Compose

```bash
# Subir todos os serviços em background
docker compose up -d

# Subir e reconstruir as imagens (necessário após alterar o código)
docker compose up --build -d

# Parar todos os serviços
docker compose down

# Parar e remover os volumes (CUIDADO: apaga os dados)
docker compose down -v

# Ver o status dos serviços
docker compose ps

# Ver logs de todos os serviços
docker compose logs

# Ver logs de um serviço específico em tempo real
docker compose logs -f api

# Executar um comando em um serviço em execução
docker compose exec api sh

# Reiniciar um serviço específico
docker compose restart api

# Escalar um serviço (3 instâncias)
docker compose up -d --scale api=3
```

---

## 9. Variáveis de ambiente e arquivos .env

Nunca coloque senhas e segredos diretamente no `docker-compose.yml`. Use um arquivo `.env`:

### .env

```env
POSTGRES_USER=app_user
POSTGRES_PASSWORD=minha_senha_forte_aqui
POSTGRES_DB=meu_banco
API_PORT=3000
NODE_ENV=production
```

### docker-compose.yml usando .env

```yaml
services:
  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}

  api:
    build: .
    ports:
      - "${API_PORT}:3000"
    environment:
      NODE_ENV: ${NODE_ENV}
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
```

O Docker Compose lê automaticamente o arquivo `.env` no mesmo diretório do `docker-compose.yml`.

> **Importante:** adicione `.env` ao `.gitignore` e `.dockerignore`. Nunca suba segredos para o repositório.

---

## 10. Multi-stage build — imagens menores e mais seguras

Em muitas aplicações (TypeScript, Go, Java), há uma etapa de **compilação** que gera artefatos para produção. O problema: as ferramentas de build (compiladores, `devDependencies`) são pesadas e não precisam estar na imagem final.

O **multi-stage build** resolve isso: você usa uma imagem grande para compilar e copia apenas o resultado para uma imagem pequena.

### Exemplo: TypeScript para produção

```dockerfile
# ─── Estágio 1: Build ─────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Instalar TODAS as dependências (incluindo devDependencies)
COPY package.json package-lock.json ./
RUN npm ci

# Copiar o código e compilar
COPY . .
RUN npm run build
# Resultado: pasta /app/dist com o JavaScript compilado


# ─── Estágio 2: Produção ──────────────────────────────────────────
FROM node:20-alpine AS production

WORKDIR /app

# Instalar apenas dependências de produção
COPY package.json package-lock.json ./
RUN npm ci --only=production

# Copiar SOMENTE o código compilado do estágio anterior
COPY --from=builder /app/dist ./dist

# Usuário não-root para segurança
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3000
CMD ["node", "dist/index.js"]
```

**Resultado:** a imagem final contém apenas o runtime do Node.js + as dependências de produção + o código compilado. Tudo o que é TypeScript, `ts-node`, `@types/*` fica fora.

---

## 11. Boas práticas de produção

### Use tags específicas, nunca `latest`

```dockerfile
# Ruim — "latest" pode mudar e quebrar o build
FROM node:latest

# Bom — versão previsível e reproduzível
FROM node:20.14-alpine3.19
```

### Execute como usuário não-root

```dockerfile
# Criar usuário sem privilégios
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Definir permissões da pasta
RUN chown -R appuser:appgroup /app

# Mudar para o usuário
USER appuser
```

### Limite os recursos do container

```yaml
# docker-compose.yml
services:
  api:
    deploy:
      resources:
        limits:
          cpus: '0.50'      # no máximo 50% de 1 CPU
          memory: 256M      # no máximo 256 MB de RAM
        reservations:
          memory: 128M      # garante 128 MB mínimos
```

### Configure health checks

```yaml
services:
  api:
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 30s    # verifica a cada 30 segundos
      timeout: 10s     # considera falha se não responder em 10s
      retries: 3       # marca unhealthy após 3 falhas consecutivas
      start_period: 40s # aguarda 40s antes de começar a verificar
```

### Use restart policies

```yaml
services:
  api:
    restart: unless-stopped
    # "unless-stopped" reinicia automaticamente após crash ou reboot do servidor
    # mas não reinicia se você parou manualmente com "docker compose down"
```

### Limpe imagens e containers não utilizados

```bash
# Remover containers parados, redes não utilizadas, imagens sem tag e cache de build
docker system prune

# Remover também volumes não utilizados (CUIDADO)
docker system prune --volumes

# Ver quanto espaço o Docker está usando
docker system df
```

---

## 12. Multi-serviço em produção: Traefik e observabilidade

Quando uma máquina hospeda **vários serviços** em containers, dois problemas aparecem: (1) como rotear o tráfego para o container certo com HTTPS, sem editar configuração na mão a cada deploy; e (2) como enxergar métricas e logs de tudo num lugar só. As respostas modernas são um **edge proxy nativo de containers** e um **stack de observabilidade**.

### 12.1 Edge proxy por labels (Traefik)

Em vez de um arquivo de proxy por serviço, o **Traefik** descobre as rotas lendo *labels* dos próprios containers. O container não publica porta no host: ele entra numa rede compartilhada (`edge`) e se descreve por labels.

```yaml
services:
  api:
    networks: [internal, edge]
    labels:
      - traefik.enable=true
      - traefik.docker.network=edge
      - traefik.http.routers.api.rule=Host(`api.exemplo.com`)
      - traefik.http.routers.api.entrypoints=websecure
      - traefik.http.routers.api.tls.certresolver=le      # HTTPS automático (Let's Encrypt)
      - traefik.http.services.api.loadbalancer.server.port=3000
```

- Sem `ports:` — o Traefik alcança o container pela rede `edge`. Só o Traefik publica 80/443.
- Um monorepo com vários containers públicos declara **um router por container**; banco/worker ficam só na rede interna.
- O Traefik nunca fala com o socket do Docker direto: usa um **docker-socket-proxy** em modo leitura (dar o socket cru a um container equivale a dar root no host).

### 12.2 Redes: público vs. privado

```yaml
networks:
  edge:       { external: true }   # compartilhada: Traefik ↔ containers públicos
  internal:   { driver: bridge }   # privada do serviço: db e workers vivem aqui
```

A regra de ouro: **o banco nunca entra na `edge`**. Se não tem label do Traefik e não está na `edge`, não é alcançável de fora — é assim que se mantém a superfície de ataque mínima.

### 12.3 Observabilidade

Um stack padrão para containers: **Prometheus** (métricas, modelo *pull*), **Grafana** (dashboards), **Loki + Grafana Alloy** (logs de todos os containers) e os exporters **cAdvisor** (por container) e **node-exporter** (host). O Traefik já expõe métricas RED (Rate/Errors/Duration) para o Prometheus raspar.

O passo a passo completo — do zero ao Grafana no ar, com hardening e automação — está nos guias de infraestrutura: [`VPS_SETUP.md`](../Servidor/VPS_SETUP.md) e [`OBSERVABILIDADE.md`](../Servidor/OBSERVABILIDADE.md).

---

## 13. GitOps com Docker

GitOps aplica o princípio de que **o Git é a fonte de verdade da infraestrutura**. Em Docker, isso significa que a versão da imagem, o `docker-compose.yml` e as regras de deploy ficam versionadas e auditáveis em repositórios.

### 13.1 Fluxo recomendado (imagem imutável + repositório de infraestrutura)

1. O pipeline de CI gera a imagem com tag imutável (ex.: SHA do commit):
```bash
docker build -t ghcr.io/org/minha-api:${GITHUB_SHA} .
docker push ghcr.io/org/minha-api:${GITHUB_SHA}
```
2. Um repositório de infraestrutura (`infra-live`) guarda o `docker-compose.yml` de produção.
3. O deploy ocorre via PR que atualiza apenas a tag da imagem:
```yaml
services:
  api:
    image: ghcr.io/org/minha-api:9c2a6b0
```
4. Após merge na `main` do repositório de infraestrutura, o servidor sincroniza o estado e aplica:
```bash
docker compose pull
docker compose up -d --remove-orphans
```

### 13.2 Estrutura mínima de repositórios

```text
app-repo/
  └── Dockerfile

infra-live/
  ├── meu-servico/
  │   ├── docker-compose.yml
  │   └── .env.example
  └── environments/
      ├── staging/
      └── production/
```

### 13.3 Segurança no fluxo GitOps

- Use **tags imutáveis** (SHA), nunca `latest`.
- Proteja a branch principal com **review obrigatório**.
- Use **Deploy Key somente leitura** no servidor para o repositório de infraestrutura.
- Restrinja segredos a runtime (`.env` no servidor, secret manager, ou variáveis injetadas no pipeline), sem versionar credenciais no Git.
- Prefira aprovação explícita para produção (`environment protection rules`) antes do merge/deploy.

### 13.4 Exemplo de sincronização pull-based com Docker Compose

```bash
# /opt/gitops/sync.sh
#!/usr/bin/env bash
set -euo pipefail

cd /opt/infra-live/meu-servico
git fetch origin
git reset --hard origin/main
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
```

Execute esse script por `systemd timer` ou cron. Assim, o servidor sempre converge para o estado definido no Git, com histórico completo de quem alterou o quê e quando.

---

## 14. Comandos de referência rápida

### Imagens

```bash
docker images                          # listar imagens locais
docker pull nginx:alpine               # baixar imagem do Docker Hub
docker build -t nome:tag .             # construir imagem
docker rmi nome:tag                    # remover imagem
docker image prune                     # remover imagens sem tag (dangling)
```

### Containers

```bash
docker ps                              # listar containers em execução
docker ps -a                           # listar todos os containers
docker run -d -p 8080:80 nginx         # criar e iniciar container
docker stop id_ou_nome                 # parar container
docker start id_ou_nome               # iniciar container parado
docker rm id_ou_nome                   # remover container
docker logs -f nome                    # acompanhar logs
docker exec -it nome sh                # abrir shell no container
docker inspect nome                    # inspecionar detalhes
```

### Volumes

```bash
docker volume ls                       # listar volumes
docker volume create nome              # criar volume
docker volume inspect nome             # inspecionar volume
docker volume rm nome                  # remover volume
```

### Redes

```bash
docker network ls                      # listar redes
docker network create nome             # criar rede
docker network inspect nome            # inspecionar rede
docker network connect rede container  # conectar container à rede
```

### Docker Compose

```bash
docker compose up -d                   # subir serviços em background
docker compose up --build -d           # subir e reconstruir imagens
docker compose down                    # parar e remover containers
docker compose down -v                 # parar e remover volumes também
docker compose ps                      # status dos serviços
docker compose logs -f                 # acompanhar logs
docker compose exec serviço sh         # abrir shell em um serviço
docker compose restart serviço         # reiniciar um serviço
```

---

> Continue para [CI-CD/GITHUB_ACTIONS.md](../CI-CD/GITHUB_ACTIONS.md) para aprender a automatizar o build e deploy das suas imagens Docker em pipelines de CI/CD.
