# CI/CD com GitHub Actions — Do Conceito ao Deploy Automático

> Guia completo de integração e entrega contínua: o que é CI/CD, como funcionam os pipelines do GitHub Actions, como configurar lint, testes, build de Docker e deploy automático em produção.

---

## Índice

1. [O que é CI/CD e por que importa](#1-o-que-é-cicd-e-por-que-importa)
2. [Como funciona o GitHub Actions](#2-como-funciona-o-github-actions)
3. [Estrutura de um workflow](#3-estrutura-de-um-workflow)
4. [Sintaxe YAML — os blocos principais](#4-sintaxe-yaml--os-blocos-principais)
5. [Pipeline de CI — lint, testes e build](#5-pipeline-de-ci--lint-testes-e-build)
6. [Pipeline de CD — deploy automático na VPS](#6-pipeline-de-cd--deploy-automático-na-vps)
7. [Secrets e variáveis de ambiente](#7-secrets-e-variáveis-de-ambiente)
8. [Build e push de imagem Docker](#8-build-e-push-de-imagem-docker)
9. [Estratégias avançadas](#9-estratégias-avançadas)
10. [Depurando pipelines com falha](#10-depurando-pipelines-com-falha)
11. [Referência rápida de sintaxe](#11-referência-rápida-de-sintaxe)

---

## 1. O que é CI/CD e por que importa

### Integração Contínua (CI)

**CI — Continuous Integration** é a prática de integrar as mudanças de código com frequência (várias vezes ao dia) e verificar automaticamente se cada mudança:

- Não quebra a compilação/build
- Passa nos testes automatizados
- Segue os padrões de código (lint)

Sem CI, bugs só são descobertos tarde — às vezes só em produção. Com CI, você descobre em segundos após o push.

### Entrega Contínua (CD)

**CD — Continuous Delivery/Deployment** é a automatização do processo de publicar a aplicação após a CI passar. Pode significar:

- **Continuous Delivery**: gera o artefato de deploy automaticamente, mas alguém aprova manualmente antes de ir para produção
- **Continuous Deployment**: vai direto para produção sem aprovação manual

### O fluxo completo

```
desenvolvedor faz push
        ↓
GitHub Actions executa CI:
  → instala dependências
  → roda lint
  → roda testes
  → faz build
        ↓
  [CI passou?]
   ↙         ↘
 Não          Sim
  ↓            ↓
notifica     CD executa:
o autor      → build da imagem Docker
             → push para registry
             → deploy na VPS
                  ↓
             aplicação atualizada
             em produção
```

---

## 2. Como funciona o GitHub Actions

O GitHub Actions executa **workflows** definidos em arquivos YAML dentro da pasta `.github/workflows/` do repositório.

### Componentes

| Componente | O que é |
|---|---|
| **Workflow** | O arquivo YAML completo que define um pipeline |
| **Event** | O gatilho que dispara o workflow (push, pull request, etc.) |
| **Job** | Um conjunto de steps que roda em uma máquina (runner) |
| **Step** | Uma tarefa individual dentro de um job |
| **Action** | Um step reutilizável publicado no GitHub Marketplace |
| **Runner** | A máquina virtual onde o job executa |

### Runners disponíveis

| Runner | Sistema | Custo |
|---|---|---|
| `ubuntu-latest` | Ubuntu 22.04 LTS | Gratuito (2000 min/mês em repos privados) |
| `windows-latest` | Windows Server | Gratuito |
| `macos-latest` | macOS | Gratuito (uso limitado) |
| Self-hosted | Sua própria máquina | Gratuito (você paga a infra) |

---

## 3. Estrutura de um workflow

```
.github/
└── workflows/
    ├── ci.yml       ← roda em todo pull request
    └── cd.yml       ← roda ao fazer merge na main
```

### Arquivo mínimo

```yaml
# .github/workflows/ci.yml

name: CI                          # nome que aparece no GitHub

on:                               # eventos que disparam o workflow
  push:
    branches: [main, dev]
  pull_request:
    branches: [main]

jobs:                             # lista de jobs
  build:                          # nome do job
    runs-on: ubuntu-latest        # runner

    steps:                        # lista de steps

      - name: Checkout do código  # nome descritivo do step
        uses: actions/checkout@v4 # action reutilizável do marketplace

      - name: Instalar Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Instalar dependências
        run: npm ci               # comando shell a executar
```

---

## 4. Sintaxe YAML — os blocos principais

### on — eventos gatilho

```yaml
on:
  # Dispara em push para as branches listadas
  push:
    branches: [main, develop]
    paths:                         # só dispara se esses arquivos mudaram
      - 'src/**'
      - 'package.json'

  # Dispara quando um PR é aberto, atualizado ou sincronizado
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]

  # Dispara manualmente pelo GitHub UI
  workflow_dispatch:
    inputs:
      environment:
        description: 'Ambiente de deploy'
        required: true
        default: 'staging'
        type: choice
        options:
          - staging
          - production

  # Agendamento (cron) — roda todos os dias às 3h
  schedule:
    - cron: '0 3 * * *'
```

### jobs — definição dos jobs

```yaml
jobs:
  meu-job:
    name: Nome amigável do job
    runs-on: ubuntu-latest

    # Só executa se o job anterior passou
    needs: outro-job

    # Estratégia de matriz — roda o job em múltiplas configurações
    strategy:
      matrix:
        node-version: [18, 20, 22]

    # Condição para executar o job
    if: github.ref == 'refs/heads/main'

    # Timeout máximo em minutos
    timeout-minutes: 30

    # Permissões de acesso ao repositório
    permissions:
      contents: read
      packages: write

    steps:
      - name: Exemplo
        run: echo "Rodando no Node ${{ matrix.node-version }}"
```

### steps — ações e comandos

```yaml
steps:
  # Executar uma action do marketplace
  - name: Checkout
    uses: actions/checkout@v4
    with:
      fetch-depth: 0   # parâmetros da action

  # Executar comandos shell
  - name: Rodar testes
    run: |
      npm ci
      npm test
    working-directory: ./backend   # diretório onde o comando roda
    env:
      NODE_ENV: test               # variáveis de ambiente para este step

  # Usar secrets
  - name: Login no Docker Hub
    run: echo "${{ secrets.DOCKER_PASSWORD }}" | docker login -u "${{ secrets.DOCKER_USERNAME }}" --password-stdin

  # Condicional
  - name: Notificar falha
    if: failure()
    run: echo "O pipeline falhou!"

  # Capturar output de um step
  - name: Gerar versão
    id: versao
    run: echo "tag=$(git describe --tags --abbrev=0)" >> $GITHUB_OUTPUT

  - name: Usar o output
    run: echo "Versão é ${{ steps.versao.outputs.tag }}"
```

### Contextos e expressões

```yaml
# Contextos disponíveis nos workflows
${{ github.sha }}           # hash do commit
${{ github.ref }}           # ref completa (refs/heads/main)
${{ github.ref_name }}      # nome da branch ou tag (main)
${{ github.actor }}         # quem fez o push
${{ github.repository }}    # owner/repo
${{ github.event_name }}    # nome do evento (push, pull_request)

${{ secrets.NOME }}         # secret configurado no repositório
${{ vars.NOME }}            # variável de ambiente do repositório
${{ env.NOME }}             # variável definida no workflow

${{ runner.os }}            # sistema operacional do runner
${{ job.status }}           # status do job (success, failure, cancelled)
```

---

## 5. Pipeline de CI — lint, testes e build

```yaml
# .github/workflows/ci.yml

name: CI

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  # ─── Job 1: Qualidade de código ─────────────────────────────────
  lint:
    name: Lint e formatação
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Configurar Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'   # cacheia node_modules entre execuções

      - name: Instalar dependências
        run: npm ci

      - name: Verificar lint (ESLint)
        run: npm run lint

      - name: Verificar formatação (Prettier)
        run: npm run format:check

  # ─── Job 2: Testes ──────────────────────────────────────────────
  test:
    name: Testes automatizados
    runs-on: ubuntu-latest
    needs: lint   # só executa se o lint passou

    # Serviços auxiliares (containers rodando junto ao job)
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: test_user
          POSTGRES_PASSWORD: test_pass
          POSTGRES_DB: test_db
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Configurar Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Instalar dependências
        run: npm ci

      - name: Executar migrações de teste
        run: npm run db:migrate:test
        env:
          DATABASE_URL: postgresql://test_user:test_pass@localhost:5432/test_db

      - name: Rodar testes com cobertura
        run: npm run test:coverage
        env:
          NODE_ENV: test
          DATABASE_URL: postgresql://test_user:test_pass@localhost:5432/test_db

      - name: Publicar relatório de cobertura
        uses: actions/upload-artifact@v4
        with:
          name: coverage-report
          path: coverage/

  # ─── Job 3: Build ───────────────────────────────────────────────
  build:
    name: Build da aplicação
    runs-on: ubuntu-latest
    needs: test

    steps:
      - uses: actions/checkout@v4

      - name: Configurar Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Instalar dependências
        run: npm ci

      - name: Compilar TypeScript
        run: npm run build

      - name: Verificar tamanho do build
        run: du -sh dist/

      - name: Salvar artefato de build
        uses: actions/upload-artifact@v4
        with:
          name: build-dist
          path: dist/
          retention-days: 7
```

---

## 6. Pipeline de CD — deploy automático na VPS

```yaml
# .github/workflows/cd.yml

name: CD — Deploy em Produção

on:
  push:
    branches: [main]   # só deploya na main

jobs:
  deploy:
    name: Deploy na VPS
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Deploy via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          port: ${{ secrets.VPS_PORT }}
          script: |
            # Navegar até o diretório da aplicação
            cd ${{ secrets.VPS_APP_PATH }}

            # Atualizar o código
            git pull origin main

            # Reconstruir e reiniciar os containers
            docker compose up --build -d

            # Remover imagens antigas (libera espaço)
            docker image prune -f

            # Verificar se os containers estão saudáveis
            docker compose ps

      - name: Notificar sucesso
        if: success()
        run: echo "Deploy realizado com sucesso em $(date)"

      - name: Notificar falha por e-mail
        if: failure()
        uses: dawidd6/action-send-mail@v3
        with:
          server_address: smtp.gmail.com
          server_port: 465
          username: ${{ secrets.MAIL_USERNAME }}
          password: ${{ secrets.MAIL_PASSWORD }}
          subject: "FALHA no deploy — ${{ github.repository }}"
          body: |
            O deploy falhou no commit ${{ github.sha }}.
            Autor: ${{ github.actor }}
            Branch: ${{ github.ref_name }}
            Veja os detalhes em: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          to: ${{ secrets.MAIL_USERNAME }}
          from: GitHub Actions
```

---

## 7. Secrets e variáveis de ambiente

Secrets são valores sensíveis (senhas, tokens, chaves SSH) que ficam armazenados com segurança no GitHub — não aparecem nos logs.

### Como configurar

No repositório: **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

### Tipos

| Tipo | Escopo | Onde configurar |
|---|---|---|
| Repository secret | Um repositório | Settings do repo |
| Environment secret | Um ambiente (staging/prod) | Settings > Environments |
| Organization secret | Todos os repos da org | Settings da organização |

### Usando secrets no workflow

```yaml
steps:
  - name: Usar secret
    env:
      API_KEY: ${{ secrets.API_KEY }}
    run: |
      curl -H "Authorization: Bearer $API_KEY" https://api.exemplo.com

  # Nunca faça isso — expõe o secret no log
  - run: echo "${{ secrets.API_KEY }}"  # ERRADO
```

### Variáveis (não-secretas)

Para valores que não são sensíveis (ex: nome do ambiente, URL pública):

**Settings** → **Secrets and variables** → **Actions** → **Variables**

```yaml
steps:
  - run: echo "Deploying to ${{ vars.ENVIRONMENT }}"
```

---

## 8. Build e push de imagem Docker

```yaml
# .github/workflows/docker.yml

name: Build e Push Docker Image

on:
  push:
    branches: [main]
    tags: ['v*.*.*']   # também dispara em tags de versão

jobs:
  docker:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      # Configura suporte a multi-plataforma (amd64, arm64)
      - name: Configurar QEMU
        uses: docker/setup-qemu-action@v3

      # Configura o Docker Buildx (builder avançado)
      - name: Configurar Docker Buildx
        uses: docker/setup-buildx-action@v3

      # Login no GitHub Container Registry (ghcr.io)
      - name: Login no GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
          # GITHUB_TOKEN é gerado automaticamente — não precisa configurar

      # Gera as tags da imagem automaticamente
      - name: Extrair metadados da imagem
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,prefix=sha-

      # Constrói e faz push da imagem
      - name: Build e Push
        uses: docker/build-push-action@v5
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha       # usa o cache do GitHub Actions
          cache-to: type=gha,mode=max
```

---

## 9. Estratégias avançadas

### Matrix — testar em múltiplas versões

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node-version: [18, 20, 22]
        os: [ubuntu-latest, windows-latest]
      fail-fast: false   # continua mesmo se uma combinação falhar

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node-version }}
      - run: npm test
```

### Environments — aprovação manual antes do deploy

```yaml
jobs:
  deploy-prod:
    runs-on: ubuntu-latest
    environment:
      name: production         # nome do ambiente no GitHub
      url: https://meusite.com  # aparece no GitHub após o deploy

    steps:
      - run: echo "Deploying to production..."
```

Configure o ambiente em **Settings** → **Environments** → **production** → adicione revisores obrigatórios. O workflow vai pausar e esperar aprovação antes de continuar.

### Reuso de workflows

```yaml
# .github/workflows/reutilizavel.yml
on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying to ${{ inputs.environment }}"
```

```yaml
# .github/workflows/prod.yml
jobs:
  chamar-workflow:
    uses: ./.github/workflows/reutilizavel.yml
    with:
      environment: production
    secrets: inherit   # passa todos os secrets para o workflow chamado
```

### Cache de dependências

```yaml
- name: Cache do npm
  uses: actions/cache@v4
  with:
    path: ~/.npm
    key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-node-

- name: Instalar dependências
  run: npm ci
```

O `hashFiles` gera um hash do `package-lock.json` — se o arquivo não mudou, as dependências são restauradas do cache (muito mais rápido que `npm ci`).

---

## 10. Depurando pipelines com falha

### Ver o log detalhado

No GitHub: **Actions** → clique no workflow → clique no job → expanda o step com falha.

### Ativar debug logging

Crie um secret chamado `ACTIONS_STEP_DEBUG` com valor `true`. O GitHub vai exibir logs muito mais detalhados na próxima execução.

### Executar novamente apenas os jobs com falha

No GitHub: **Actions** → workflow com falha → **Re-run failed jobs** (reaproveita o cache, economiza tempo).

### Testar localmente com act

[`act`](https://github.com/nektos/act) permite rodar workflows do GitHub Actions localmente:

```bash
# Instalar act
brew install act   # macOS
# ou baixe o binário em github.com/nektos/act/releases

# Rodar o workflow de CI
act push

# Rodar um job específico
act push -j build

# Listar os jobs disponíveis
act -l
```

### Erros comuns e soluções

| Erro | Causa provável | Solução |
|---|---|---|
| `Error: Process completed with exit code 1` | Comando falhou | Verifique o log do step |
| `Resource not accessible by integration` | Permissão insuficiente | Adicione `permissions` ao job |
| `secret not found` | Secret não configurado | Verifique Settings → Secrets |
| `No space left on device` | Runner sem espaço | Adicione step de limpeza antes |
| Container de serviço não sobe | Health check falhou | Aumente `--health-retries` ou `start_period` |

---

## 11. Referência rápida de sintaxe

### Gatilhos comuns

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
  schedule:
    - cron: '0 0 * * 1'   # toda segunda-feira à meia-noite
```

### Condicionais

```yaml
if: github.ref == 'refs/heads/main'
if: github.event_name == 'push'
if: success()
if: failure()
if: always()
if: contains(github.event.head_commit.message, '[skip ci]')
```

### Outputs entre steps

```yaml
- id: meu-step
  run: echo "resultado=valor" >> $GITHUB_OUTPUT

- run: echo ${{ steps.meu-step.outputs.resultado }}
```

### Outputs entre jobs

```yaml
jobs:
  job1:
    outputs:
      versao: ${{ steps.gerar.outputs.versao }}
    steps:
      - id: gerar
        run: echo "versao=1.2.3" >> $GITHUB_OUTPUT

  job2:
    needs: job1
    steps:
      - run: echo ${{ needs.job1.outputs.versao }}
```

### Actions mais usadas

| Action | O que faz |
|---|---|
| `actions/checkout@v4` | Faz checkout do repositório |
| `actions/setup-node@v4` | Instala e configura o Node.js |
| `actions/setup-python@v5` | Instala e configura o Python |
| `actions/cache@v4` | Cacheia pastas entre execuções |
| `actions/upload-artifact@v4` | Salva arquivos como artefatos |
| `actions/download-artifact@v4` | Baixa artefatos de outros jobs |
| `docker/build-push-action@v5` | Build e push de imagens Docker |
| `appleboy/ssh-action@v1` | Executa comandos via SSH |

---

> Continue para [Agentes/AGENTES_IA.md](../Agentes/AGENTES_IA.md) para aprender a construir agentes de IA que podem ser integrados em seus pipelines e aplicações.
