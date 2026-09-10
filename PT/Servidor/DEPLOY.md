# Roteiro de Deploy — SQL Challenge Backend

> Guia completo para subir o backend e o banco de dados em uma VPS, e conectar remotamente para administração.

> **Contexto:** este é o **exemplo concreto** de um serviço específico. O modelo de infraestrutura **genérico e atual** — VPS multi-serviço com **Traefik** (proxy por labels + HTTPS automático), **observabilidade** e serviços como **monorepo multi-container** — está em [`VPS_SETUP.md`](./VPS_SETUP.md). Onde este roteiro menciona Nginx/Certbot ou expor portas no host, **prefira o fluxo com Traefik** do VPS_SETUP: o container entra na rede `edge` com labels e o HTTPS é automático — sem porta publicada e sem Certbot. Para provisionar um serviço novo de forma automatizada, use a etapa 15 (`vps-scripts/scripts/15-new-project.sh`).

---

## Índice

1. [Pré-requisitos](#1-pré-requisitos)
2. [Acesso inicial à VPS](#2-acesso-inicial-à-vps)
3. [Instalar Docker e Docker Compose](#3-instalar-docker-e-docker-compose)
4. [Clonar os repositórios](#4-clonar-os-repositórios)
5. [Configurar o ambiente (.env)](#5-configurar-o-ambiente-env)
6. [Subir os containers](#6-subir-os-containers)
7. [Executar os scripts SQL](#7-executar-os-scripts-sql)
8. [Conectar ao banco remotamente](#8-conectar-ao-banco-remotamente)
9. [Validar a API](#9-validar-a-api)
10. [Configurar o CD automático](#10-configurar-o-cd-automático)
11. [Comandos úteis de manutenção](#11-comandos-úteis-de-manutenção)
12. [Solução de problemas comuns](#12-solução-de-problemas-comuns)

---

## 1. Pré-requisitos

Antes de começar, certifique-se de ter em mãos:

| Item | Descrição |
|---|---|
| VPS | Ubuntu 24.04 LTS |
| Acesso SSH | Usuário `admin` com permissão sudo, porta `2222` |
| IP da VPS | Endereço IP público da máquina |
| Repositórios | Acesso ao GitHub da organização `sql-challenge` |

> **Recomendado antes do deploy:** aplicar o hardening base do guia [`VPS_SETUP.md`](./VPS_SETUP.md) (SSH, UFW, Fail2Ban, Nginx e atualização automática de segurança).

---

## 2. Acesso inicial à VPS

Conecte à VPS pelo terminal do seu computador:

```bash
ssh -p 2222 admin@IP_DA_VPS
```

Se tiver o atalho configurado em `~/.ssh/config`:

```bash
ssh vps
```

Após o acesso, atualize o sistema:

```bash
sudo apt update && sudo apt upgrade -y
```

---

## 3. Instalar Docker e Docker Compose

### 3.1 Instalar o Docker

```bash
# Baixar e executar o script oficial de instalação
curl -fsSL https://get.docker.com | sh

# Adicionar seu usuário ao grupo docker (evita usar sudo em todo comando)
sudo usermod -aG docker $USER

# Aplicar a mudança de grupo sem precisar sair e entrar novamente
newgrp docker
```

### 3.2 Verificar a instalação

```bash
docker --version
docker compose version
```

A saída esperada é algo como:
```
Docker version 29.x.x, build xxxxxxx
Docker Compose version v2.x.x
```

---

## 4. Clonar os repositórios

Os repositórios ficam em `/opt/apps/sql-challenge/`, com o usuário de serviço `sqlchallenge` como dono (configurado na etapa 7 do VPS_SETUP).

```bash
sudo -u sqlchallenge git clone https://github.com/sql-challenge/sql-challenge-backend.git /opt/apps/sql-challenge/backend

sudo -u sqlchallenge git clone https://github.com/sql-challenge/sql-challenge-frontend.git /opt/apps/sql-challenge/frontend

sudo -u sqlchallenge git clone https://github.com/sql-challenge/sql-challenge-modelagem_de_dados.git /opt/apps/sql-challenge/modelagem
```

Corrigir permissões após o clone:

```bash
chown -R sqlchallenge:webapps /opt/apps/sql-challenge/
find /opt/apps/sql-challenge -type d -exec chmod 750 {} \;
find /opt/apps/sql-challenge -type f -exec chmod 640 {} \;
```

---

## 5. Configurar o ambiente (.env)

O `.env` fica em `/opt/apps/sql-challenge/.env` com um link simbólico para dentro do backend (configurado na etapa 7 do VPS_SETUP). Para editar:

```bash
sudo nano /opt/apps/sql-challenge/.env
```

Preencha com os valores reais de produção:

```env
# ─── PostgreSQL ───────────────────────────────────────────────
POSTGRES_USER=challenge_user
POSTGRES_PASSWORD=SUA_SENHA_FORTE_AQUI
POSTGRES_DB=db_gestao
DB_PORT=5432

# ─── API ──────────────────────────────────────────────────────
PORT=3000
NODE_ENV=production
DATABASE_URL=postgresql://challenge_user:SUA_SENHA_FORTE_AQUI@db:5432/db_gestao?sslmode=disable

# ─── Firebase (autenticação de usuários) ──────────────────────
apiKey=
authDomain=
projectId=
storageBucket=
messagingSenderId=
appId=
measurementId=

# ─── CORS / Frontend ──────────────────────────────────────────
FRONTEND_URL=http://URL_OU_IP_DO_FRONTEND
FRONTEND_PORT=3000
```

> **Atenção:** Use uma senha forte para `POSTGRES_PASSWORD`. Nunca use a senha padrão do `.env.example` em produção.

Salve o arquivo: `Ctrl+O` → `Enter` → `Ctrl+X`

---

## 6. Subir os containers

### 6.1 Build e inicialização

```bash
cd /opt/apps/sql-challenge/backend
docker compose up --build -d
```

O `-d` sobe os containers em background. O `--build` garante que a imagem do backend seja reconstruída com o código mais recente.

### 6.2 Verificar se os containers estão rodando

```bash
docker compose ps
```

A saída esperada:

```
NAME                  STATUS          PORTS
sql-challenge-api     Up              0.0.0.0:3000->3000/tcp
sql-challenge-db      Up (healthy)    127.0.0.1:5432->5432/tcp
```

> Em produção, prefira expor somente `80/443` no Nginx e manter API/DB sem exposição pública direta.

### 6.3 Verificar os logs do backend

```bash
docker compose logs api
```

Você deve ver:
```
✅ Conectado ao PostgreSQL com sucesso!
🚀 Servidor rodando em http://localhost:3000
```

Se aparecer erro de conexão com o banco, aguarde alguns segundos e verifique novamente — o PostgreSQL pode ainda estar inicializando.

---

## 7. Executar os scripts SQL

Os scripts devem ser executados **na ordem abaixo**. Todos rodam dentro do container do banco de dados.

### 7.1 Estrutura de gestão + criação do schema `magical_world`

```bash
docker exec -i sql-challenge-db psql -U challenge_user -d db_gestao \
  < /opt/apps/sql-challenge/modelagem/PostgreSQL/Script/gestão/ddl_structure.sql
```

O que esse script faz:
- Cria o schema `magical_world`
- Cria todas as tabelas de gestão: `Desafio`, `Capitulo`, `Objetivo`, `Dica`, `Visao`, `Consulta`, `Log`
- Cria a função e triggers de auditoria

### 7.2 Estrutura do banco do jogo

```bash
docker exec -i sql-challenge-db psql -U challenge_user -d db_gestao \
  < "/opt/apps/sql-challenge/modelagem/Games/magical world/ddl_game.sql"
```

O que esse script faz:
- Cria todas as tabelas do jogo dentro do schema `magical_world`: `Feudo`, `Pessoa`, `Cidade`, `Artefato`, `Ataques`, etc.

### 7.3 Views do jogo

```bash
docker exec -i sql-challenge-db psql -U challenge_user -d db_gestao \
  < "/opt/apps/sql-challenge/modelagem/Games/magical world/vw_ddl_game.sql"
```

O que esse script faz:
- Cria todas as views que o jogador pode consultar durante os capítulos: `regioes_reinos`, `ataques_raw`, `grimorio_final`, etc.

### 7.4 Dados do jogo

```bash
# Dados principais
docker exec -i sql-challenge-db psql -U challenge_user -d db_gestao \
  < "/opt/apps/sql-challenge/modelagem/Games/magical world/dml_gama.sql"

# Correções e patches
docker exec -i sql-challenge-db psql -U challenge_user -d db_gestao \
  < "/opt/apps/sql-challenge/modelagem/Games/magical world/dml_gama_patch.sql"
```

O que esses scripts fazem:
- Populam todas as tabelas do jogo com os dados do Mundo Mágico
- Aplicam correções nos dados (categorias de artefatos, posse de itens, etc.)

### 7.5 Dados de gestão

```bash
docker exec -i sql-challenge-db psql -U challenge_user -d db_gestao \
  < /opt/apps/sql-challenge/modelagem/PostgreSQL/Script/cadastro_games/dml_magical_world.sql
```

O que esse script faz:
- Popula as tabelas de gestão com o conteúdo do jogo "Mistério do Mundo Mágico"
- Insere os 5 capítulos, objetivos, dicas, consultas-solução e as referências às views

### 7.6 Verificar se os dados foram inseridos corretamente

```bash
docker exec -it sql-challenge-db psql -U challenge_user -d db_gestao -c "
  SELECT 'desafios' AS tabela, COUNT(*) FROM Desafio
  UNION ALL SELECT 'capitulos', COUNT(*) FROM Capitulo
  UNION ALL SELECT 'objetivos', COUNT(*) FROM Objetivo
  UNION ALL SELECT 'dicas', COUNT(*) FROM Dica
  UNION ALL SELECT 'visoes', COUNT(*) FROM Visao
  UNION ALL SELECT 'consultas', COUNT(*) FROM Consulta;
"
```

Resultado esperado:
```
  tabela   | count
-----------+-------
 desafios  |     1
 capitulos |     5
 objetivos |    26
 dicas     |    15
 visoes    |    23
 consultas |     5
```

---

## 8. Conectar ao banco remotamente

Existem duas formas de conectar ao banco da VPS a partir do seu computador.

### Opção A — Túnel SSH (recomendado)

Mais seguro. A porta do banco não fica exposta na internet.

No seu computador (não na VPS):

```bash
ssh -L 5432:localhost:5432 usuario@IP_DA_VPS
```

Mantenha esse terminal aberto. Enquanto ele estiver ativo, você pode conectar qualquer cliente de banco de dados em `localhost:5432`.

**Configuração no DBeaver / TablePlus / psql:**
```
Host:     localhost
Port:     5432
Database: db_gestao
User:     challenge_user
Password: SUA_SENHA_FORTE_AQUI
```

### Opção B — Liberar porta no firewall

Mais simples, mas expõe a porta 5432. Recomendado apenas para desenvolvimento.

Na VPS, libere o acesso somente do seu IP:

```bash
# Descobrir seu IP público (no seu computador)
curl ifconfig.me

# Na VPS, liberar apenas o seu IP
sudo ufw allow from SEU_IP_PUBLICO to any port 5432
sudo ufw enable
sudo ufw status
```

**Configuração no DBeaver / TablePlus / psql:**
```
Host:     IP_DA_VPS
Port:     5432
Database: db_gestao
User:     challenge_user
Password: SUA_SENHA_FORTE_AQUI
```

---

## 9. Validar a API

Com tudo rodando, teste os principais endpoints:

```bash
# Listar desafios
curl http://IP_DA_VPS:3000/api/desafios

# Buscar capítulo 1
curl http://IP_DA_VPS:3000/api/capitulo/1

# View completa do capítulo 1 (objetivos, dicas, consulta)
curl http://IP_DA_VPS:3000/api/capitulo/view/1

# Listar visões do capítulo 1
curl "http://IP_DA_VPS:3000/api/visoes?id_capitulo=1"

# Executar a visão 1 (regioes_reinos) e ver os dados do jogo
curl http://IP_DA_VPS:3000/api/visoes/1/dados
```

A resposta de `/api/visoes/1/dados` deve retornar as regiões do Mundo Mágico diretamente do schema `magical_world`.

---

## 10. Configurar o CD automático

O pipeline de CD já está configurado no arquivo `.github/workflows/cd.yml`. Quando houver push na branch `main`, o GitHub Actions se conecta à VPS via SSH e faz o deploy automaticamente.

### 10.1 Gerar chave SSH para o GitHub Actions

Na VPS:

```bash
# Gerar o par de chaves
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_actions -N ""

# Autorizar a chave pública na VPS
cat ~/.ssh/github_actions.pub >> ~/.ssh/authorized_keys

# Exibir a chave privada (copiar para o GitHub)
cat ~/.ssh/github_actions
```

### 10.2 Configurar os secrets no GitHub

Acesse o repositório no GitHub → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret | Valor |
|---|---|
| `VPS_HOST` | IP da VPS |
| `VPS_USER` | Usuário SSH (ex: `ubuntu`) |
| `VPS_SSH_KEY` | Conteúdo da chave privada (`~/.ssh/github_actions`) |
| `VPS_PORT` | `22` (padrão SSH) |
| `VPS_APP_PATH` | `/home/$USER/sql-challenge-backend` |
| `MAIL_USERNAME` | Email Gmail remetente para notificações de CI |
| `MAIL_PASSWORD` | Senha de app do Gmail |

### 10.3 Endurecer o acesso SSH do GitHub Actions

No `~/.ssh/authorized_keys` da VPS, restrinja a chave de deploy com opções:

```text
from="IP_FIXO_OU_FAIXA_CONFIÁVEL",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA...
```

- `from=` limita origem da chave (ideal com runner self-hosted de egress fixo).
- `no-port-forwarding` e `no-agent-forwarding` reduzem o abuso da sessão.
- `no-pty` evita shell interativo.

Também valide o host no workflow com `known_hosts` (evita MITM):

```bash
ssh-keyscan -H IP_DA_VPS >> ~/.ssh/known_hosts
```

### 10.4 Testar o CD

Faça um push na `main` e acompanhe em **Actions** no GitHub. O pipeline deve:
1. Conectar à VPS via SSH
2. Executar `git pull origin main`
3. Executar `docker compose up --build -d`
4. Limpar imagens antigas
5. Exibir o status dos containers

---

## 11. Comandos úteis de manutenção

### Reiniciar os containers

```bash
docker compose restart
```

### Ver logs em tempo real

```bash
# Todos os containers
docker compose logs -f

# Só o backend
docker compose logs -f api

# Só o banco
docker compose logs -f db
```

### Parar os containers

```bash
docker compose down
```

### Parar e apagar os dados do banco

```bash
# CUIDADO: apaga o volume do PostgreSQL
docker compose down -v
```

### Acessar o banco direto pelo terminal da VPS

```bash
docker exec -it sql-challenge-db psql -U challenge_user -d db_gestao
```

### Verificar uso de disco e memória

```bash
# Containers e uso de recursos
docker stats

# Espaço em disco
df -h
```

### Atualizar o backend manualmente

```bash
cd /home/$USER/sql-challenge-backend
git pull origin dev
docker compose up --build -d
```

---

## 12. Solução de problemas comuns

### Container da API não sobe

```bash
docker compose logs api
```

Causas comuns:
- `DATABASE_URL` incorreta no `.env`
- Banco ainda não terminou de inicializar — aguarde e tente `docker compose restart api`

### Banco não aceita conexão remota

Verifique se a porta está exposta:
```bash
docker compose ps
# Em produção segura, a coluna PORTS deve mostrar 127.0.0.1:5432->5432/tcp
```

Verifique o firewall:
```bash
sudo ufw status
```

### Scripts SQL falham ao executar

Verifique se os scripts estão sendo executados na ordem correta (seção 7). Execute um por vez e observe os erros antes de prosseguir.

### API retorna erro de SSL

Confirme que o `.env` tem `NODE_ENV=production` e que a `DATABASE_URL` usa `sslmode=disable` (o SSL é gerenciado pelo Docker internamente, não pela string de conexão).

### Views retornam vazio

Verifique se os scripts foram executados na ordem correta e se o schema `magical_world` foi criado:

```bash
docker exec -it sql-challenge-db psql -U challenge_user -d db_gestao -c "\dn"
```

Deve aparecer os schemas `public` e `magical_world`.

---

> Qualquer dúvida durante o processo, consulte a equipe ou abra uma issue no repositório.
