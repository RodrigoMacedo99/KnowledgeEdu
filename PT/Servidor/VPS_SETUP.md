# Configuração de Infraestrutura VPS do Zero

> Guia completo para uma VPS **multi-serviço com Docker**: hardening, firewall, isolamento por usuário, **Traefik** como edge proxy com HTTPS automático, **observabilidade** (Prometheus/Grafana/Loki) e boas práticas de segurança para Ubuntu 24.04 LTS.

> **Modelo:** a VPS hospeda vários serviços, cada um um **monorepo com múltiplos containers**. O **Traefik** roteia por domínio via *labels* do Docker (sem escolher portas na mão) e cuida do TLS. Métricas e logs são centralizados no **Grafana**. Nada de configuração por projeto na mão.

---

## Índice

1. [Acesso inicial e atualização do sistema](#1-acesso-inicial-e-atualização-do-sistema)
2. [Criar usuário administrador e desabilitar root](#2-criar-usuário-administrador-e-desabilitar-root)
3. [Hardening do SSH](#3-hardening-do-ssh)
4. [Proteção contra força bruta com Fail2Ban](#4-proteção-contra-força-bruta-com-fail2ban)
5. [Firewall com UFW](#5-firewall-com-ufw)
6. [Grupos e usuários por projeto](#6-grupos-e-usuários-por-projeto)
7. [Estrutura de pastas e permissões](#7-estrutura-de-pastas-e-permissões)
8. [Instalar e configurar o Docker com segurança](#8-instalar-e-configurar-o-docker-com-segurança)
9. [Edge proxy (Traefik)](#9-edge-proxy-traefik)
10. [TLS/HTTPS automático (Let's Encrypt via Traefik)](#10-tlshttps-automático-lets-encrypt-via-traefik)
11. [Segurança do banco de dados PostgreSQL](#11-segurança-do-banco-de-dados-postgresql)
12. [Atualizações automáticas de segurança](#12-atualizações-automáticas-de-segurança)
13. [Observabilidade e logs](#13-observabilidade-e-logs)
14. [Hardening contínuo do servidor](#14-hardening-contínuo-do-servidor)
15. [Adicionar um novo serviço (monorepo multi-container)](#15-adicionar-um-novo-serviço-monorepo-multi-container)
16. [Resumo: fluxo, portas e domínios](#16-resumo-fluxo-portas-e-domínios)

> Existe um menu que automatiza tudo isto: `PT/Servidor/vps-scripts/setup.sh` (rode como root). Os números das etapas batem com as seções deste guia; a observabilidade é a etapa 19.

---

## 1. Acesso inicial e atualização do sistema

### 1.1 Conectar à VPS

```bash
ssh root@IP_DA_VPS
```

- `ssh` — abre uma conexão segura com a VPS via protocolo SSH
- `root` — usuário com permissão total na máquina (usado só neste primeiro acesso)
- `IP_DA_VPS` — substitua pelo endereço IP público fornecido pelo provedor da VPS

### 1.2 Iniciar uma sessão screen (obrigatório)

```bash
screen -S setup
```

- `screen` — multiplexador de terminal: mantém processos rodando mesmo se a conexão SSH cair
- `-S setup` — nomeia a sessão como "setup" para fácil identificação
- Se a conexão cair durante qualquer etapa, reconecte e rode `screen -r setup` para retomar exatamente onde parou

> **Por que isso importa:** sem o screen, uma queda de conexão no meio de um passo longo (como `apt upgrade`) pode deixar o sistema em estado inconsistente ou bloquear o acesso.

### 1.2 Atualizar todos os pacotes do sistema

```bash
apt update && apt upgrade -y
```

- `apt update` — baixa a lista de versões mais recentes dos pacotes disponíveis nos repositórios, mas **não instala nada ainda**
- `apt upgrade` — instala as versões mais recentes de todos os pacotes já instalados no sistema
- `-y` — confirma automaticamente todas as perguntas do instalador sem precisar digitar "yes"
- `&&` — executa o segundo comando **somente se** o primeiro for bem-sucedido

### 1.3 Instalar pacotes essenciais

```bash
apt install -y \
  curl git ufw nano htop \
  fail2ban unattended-upgrades \
  apt-listchanges logwatch auditd
```

- `apt install -y` — instala os pacotes listados, confirmando automaticamente
- `\` — quebra de linha para melhor leitura; o comando continua na linha seguinte
- `curl` — ferramenta para fazer requisições HTTP/HTTPS pelo terminal (usada para baixar scripts e testar APIs)
- `git` — controle de versão para clonar os repositórios do projeto
- `ufw` — Uncomplicated Firewall, interface simplificada para configurar o firewall do Linux
- `nano` — editor de texto simples para editar arquivos de configuração no terminal
- `htop` — monitor de recursos do sistema (CPU, memória, processos) em tempo real
- `fail2ban` — monitora logs e bane IPs que fazem muitas tentativas de acesso indevido
- `unattended-upgrades` — aplica atualizações de segurança automaticamente
- `apt-listchanges` — exibe o que mudou nos pacotes antes de instalar
- `logwatch` — gera relatórios resumidos dos logs do sistema
- `auditd` — registra eventos de segurança do sistema operacional

---

## 2. Criar usuário administrador e desabilitar root

Trabalhar como root o tempo todo é perigoso: qualquer erro de digitação ou script malicioso tem permissão total para destruir o sistema. A boa prática é criar um usuário comum com permissão de sudo.

### 2.1 Criar o usuário admin

```bash
adduser admin
```

- `adduser` — cria um novo usuário interativamente, pedindo nome completo e senha
- `admin` — nome do usuário; pode ser qualquer nome de sua preferência

O sistema pedirá para criar uma senha. **Use uma senha forte.**

### 2.2 Conceder permissão de sudo

```bash
usermod -aG sudo admin
```

- `usermod` — modifica as configurações de um usuário existente
- `-a` — **adiciona** o usuário ao grupo sem removê-lo de outros grupos
- `-G sudo` — especifica o grupo `sudo`, que permite executar comandos como root
- `admin` — nome do usuário a ser modificado

### 2.3 Copiar as chaves SSH do root para o admin

```bash
rsync --archive --chown=admin:admin ~/.ssh /home/admin
```

- `rsync` — ferramenta de sincronização de arquivos
- `--archive` — preserva permissões, datas, links simbólicos e copia subdiretórios recursivamente
- `--chown=admin:admin` — define o dono e grupo dos arquivos copiados como `admin`
- `~/.ssh` — pasta do root que contém as chaves SSH autorizadas
- `/home/admin` — destino: pasta home do novo usuário

### 2.4 Testar o acesso antes de fechar o root

> **Importante:** Abra um **novo terminal** sem fechar o atual. Se o novo acesso falhar, você ainda tem o root aberto para corrigir.

```bash
ssh admin@IP_DA_VPS
sudo whoami
```

- `sudo whoami` — executa `whoami` como root; se retornar `root`, o sudo está funcionando corretamente

### 2.5 Bloquear a senha do root

```bash
sudo passwd -l root
```

- `passwd` — gerencia senhas de usuários
- `-l` — lock: bloqueia a conta impedindo login com senha (a conta continua existindo, mas não pode ser acessada diretamente)

---

## 3. Hardening do SSH

O SSH é a porta de entrada da VPS. Protegê-lo corretamente é a medida de segurança mais importante.

### 3.1 Gerar chave SSH no seu computador local

Execute no **seu computador**, não na VPS:

```bash
ssh-keygen -t ed25519 -C "seu-email@exemplo.com" -f ~/.ssh/vps_key
```

- `ssh-keygen` — gera um par de chaves criptográficas (pública e privada)
- `-t ed25519` — tipo de algoritmo; Ed25519 é moderno, seguro e mais rápido que RSA
- `-C "seu-email@exemplo.com"` — comentário identificador da chave (pode ser qualquer texto)
- `-f ~/.ssh/vps_key` — nome e caminho do arquivo gerado; criará `vps_key` (privada) e `vps_key.pub` (pública)

Serão gerados dois arquivos:
- `~/.ssh/vps_key` — **chave privada**: nunca compartilhe, fica só no seu computador
- `~/.ssh/vps_key.pub` — **chave pública**: é enviada para a VPS

### 3.2 Enviar a chave pública para a VPS

```bash
ssh-copy-id -i ~/.ssh/vps_key.pub admin@IP_DA_VPS
```

- `ssh-copy-id` — copia a chave pública para o arquivo `~/.ssh/authorized_keys` do usuário na VPS
- `-i ~/.ssh/vps_key.pub` — especifica qual chave pública enviar

### 3.3 Editar a configuração do SSH

```bash
sudo nano /etc/ssh/sshd_config
```

- `/etc/ssh/sshd_config` — arquivo de configuração principal do servidor SSH

> **Ubuntu 24.04 / OpenSSH 9.x:** as diretivas `Protocol` e `ChallengeResponseAuthentication` foram removidas. Usar qualquer uma delas impede o sshd de reiniciar. Use a configuração abaixo.

Configurações e o que cada uma faz:

```
# Troca a porta padrão (22) para dificultar scans automáticos da internet
Port 2222

# Impede login direto como root via SSH
PermitRootLogin no

# Desabilita autenticação por senha — apenas chave SSH é aceita
PasswordAuthentication no

# Impede login com senha em branco
PermitEmptyPasswords no

# Substituto de ChallengeResponseAuthentication (removida no OpenSSH 9.x)
KbdInteractiveAuthentication no

# Mantém integração com PAM (sistema de autenticação do Linux)
UsePAM yes

# Habilita autenticação por chave pública
PubkeyAuthentication yes

# Define onde ficam as chaves autorizadas de cada usuário
AuthorizedKeysFile .ssh/authorized_keys

# Tempo máximo (em segundos) para completar o login antes de desconectar
LoginGraceTime 30

# Número máximo de tentativas de autenticação por conexão
MaxAuthTries 3

# Número máximo de sessões simultâneas por conexão
MaxSessions 5

# Controla conexões simultâneas não autenticadas: 3 aceitas, 50% chance de rejeição a partir da 3ª, máx 10
MaxStartups 3:50:10

# Permite SSH apenas para o usuário admin — outros usuários não conseguem conectar
AllowUsers admin

# Desabilita redirecionamento gráfico (não é necessário num servidor)
X11Forwarding no

# Desabilita encaminhamento de portas TCP (evita uso da VPS como túnel não autorizado)
AllowTcpForwarding no

# Desabilita encaminhamento do agente SSH
AllowAgentForwarding no

# Desabilita criação de túneis de rede
PermitTunnel no

# Exibe informações do último login ao conectar
PrintLastLog yes

# Envia pacote a cada 300 segundos para manter a conexão ativa
ClientAliveInterval 300

# Desconecta após 2 pacotes sem resposta (300s x 2 = 10 minutos sem resposta)
ClientAliveCountMax 2
```

### 3.4 Validar e aplicar as mudanças com segurança

```bash
# 1. Valida a sintaxe ANTES de reiniciar — evita lockout por erro de configuração
sudo sshd -t
```

- `sshd -t` — modo de teste: lê e valida o arquivo sem iniciar o serviço; qualquer erro de sintaxe aparece aqui
- Se `sshd -t` retornar erros, corrija o arquivo antes de continuar

```bash
# 2. Libera a nova porta no UFW ANTES de reiniciar o sshd
#    (mesmo que o UFW ainda não esteja ativo, a regra já estará lá quando for)
sudo ufw allow 2222/tcp comment 'SSH'

# 3. Só agora reinicia o sshd
sudo systemctl restart sshd
```

> **Por que essa ordem importa:** se você reiniciar o sshd antes de abrir a porta 2222, e o UFW já estiver ativo (ou for ativado na etapa 5 com a porta 22 bloqueada), você perde o acesso. Abrindo a regra primeiro, o acesso está garantido independente da ordem.

```bash
# 4. Abra um NOVO terminal e teste antes de fechar o atual
ssh -p 2222 admin@IP_DA_VPS
sudo whoami   # deve retornar: root
```

> Só feche o terminal original após confirmar que o novo acesso funciona.

### 3.5 Criar atalho de conexão no seu computador

```bash
nano ~/.ssh/config
```

```
Host vps
    HostName IP_DA_VPS
    User admin
    Port 2222
    IdentityFile ~/.ssh/vps_key
```

- `Host vps` — apelido para essa conexão; permite usar `ssh vps` no lugar do comando completo
- `HostName` — IP ou domínio da VPS
- `User` — usuário padrão dessa conexão
- `Port` — porta configurada no passo anterior
- `IdentityFile` — caminho da chave privada a usar

---

## 4. Proteção contra força bruta com Fail2Ban

O Fail2Ban monitora os logs do sistema e bloqueia automaticamente IPs que fazem muitas tentativas de login em pouco tempo.

### 4.1 Configurar

```bash
sudo nano /etc/fail2ban/jail.local
```

- `jail.local` — arquivo de configuração local; tem prioridade sobre o `jail.conf` padrão, que nunca deve ser editado diretamente

```ini
[DEFAULT]
# Tempo de banimento em segundos (3600 = 1 hora)
bantime  = 3600

# Janela de tempo para contar as tentativas (600 = 10 minutos)
findtime = 600

# Número máximo de tentativas antes de banir
maxretry = 3

# Método de leitura dos logs (systemd = lê o journald, mais confiável em Ubuntu moderno)
backend  = systemd

[sshd]
# Ativa monitoramento do SSH
enabled  = true

# Porta monitorada (deve ser a mesma configurada no sshd_config)
port     = 2222

# Filtro que define o padrão de tentativas falhas a detectar
filter   = sshd

# Arquivo de log monitorado
logpath  = /var/log/auth.log

# Para SSH, permite apenas 3 tentativas
maxretry = 3

# Banimento de 24 horas para tentativas de acesso SSH
bantime  = 86400
```

### 4.2 Ativar e verificar

```bash
# Inicia o Fail2Ban junto com o sistema
sudo systemctl enable fail2ban

# Reinicia para aplicar as novas configurações
sudo systemctl restart fail2ban

# Verifica o status geral
sudo fail2ban-client status

# Verifica especificamente a "jail" do SSH
sudo fail2ban-client status sshd
```

- `fail2ban-client status sshd` — mostra quantas tentativas foram detectadas, quantos IPs estão banidos e por quanto tempo

---

## 5. Firewall com UFW

O UFW (Uncomplicated Firewall) é a interface simplificada do iptables — o sistema de firewall nativo do Linux.

### 5.1 Definir política padrão

```bash
# Bloqueia todo tráfego de entrada que não tenha regra explícita permitindo
sudo ufw default deny incoming

# Permite todo tráfego de saída (a VPS pode acessar a internet normalmente)
sudo ufw default allow outgoing
```

- `default deny incoming` — princípio do menor privilégio: bloqueie tudo e libere só o necessário
- `default allow outgoing` — a VPS precisa acessar repositórios, APIs externas, etc.

### 5.2 Liberar portas essenciais

```bash
# SSH — use a porta configurada no sshd_config
sudo ufw allow 2222/tcp comment 'SSH'

# HTTP — necessário para o Nginx receber requisições e para o Let's Encrypt validar o domínio
sudo ufw allow 80/tcp comment 'HTTP'

# HTTPS — tráfego seguro para todas as aplicações
sudo ufw allow 443/tcp comment 'HTTPS'
```

- `/tcp` — especifica o protocolo TCP (HTTP, HTTPS e SSH usam TCP)
- `comment` — adiciona um rótulo à regra para facilitar a identificação depois

### 5.3 Banco de dados — apenas seu IP

```bash
# Descubra seu IP público no seu computador
curl ifconfig.me

# Na VPS: libera a porta 5432 somente para o seu IP
sudo ufw allow from SEU_IP_PUBLICO to any port 5432 proto tcp comment 'PostgreSQL admin'
```

- `from SEU_IP_PUBLICO` — restringe a regra a uma origem específica
- `to any` — qualquer interface de rede da VPS
- `port 5432` — porta padrão do PostgreSQL

> Para maior segurança, prefira o túnel SSH que não exige abrir porta alguma:
> ```bash
> # No seu computador — redireciona localhost:5432 para o banco da VPS
> ssh -L 5432:localhost:5432 vps
> ```
> - `-L 5432:localhost:5432` — Local port forwarding: tudo que chegar na porta 5432 do seu computador é encaminhado para a porta 5432 do localhost da VPS (dentro do túnel SSH)

### 5.4 Ativar o firewall

```bash
sudo ufw enable

# Visualizar todas as regras ativas com detalhes
sudo ufw status verbose
```

### 5.5 Impedir que o Docker contorne o UFW

Por padrão, o Docker manipula o iptables diretamente e consegue expor portas de containers **mesmo com regras de bloqueio no UFW**. No modelo com Traefik, o Docker **precisa** gerenciar o iptables (para publicar 80/443), então não desligamos isso — fechamos a brecha por dois caminhos combinados:

1. **As aplicações não publicam portas.** O Traefik alcança cada container pela rede `edge`. O único serviço que publica em `0.0.0.0` é o Traefik (80/443). O que precisar de porta de host (ex.: banco para túnel) publica só em `127.0.0.1`.
2. **`ufw-docker`** — faz as regras do UFW valerem também para portas publicadas por containers, como defesa em profundidade:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker \
  -o /usr/local/bin/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker
sudo ufw-docker install
sudo systemctl restart ufw
```

O `daemon.json` (log rotativo, live-restore) é configurado na [seção 8.2](#82-daemonjson--log-rotativo-e-resiliência).

---

## 6. Grupos e usuários por projeto

Cada projeto roda com um usuário de sistema dedicado. Isso garante isolamento: se um projeto for comprometido, o atacante não tem acesso aos arquivos dos outros.

### 6.1 Criar o grupo de aplicações

```bash
sudo groupadd webapps
```

- `groupadd` — cria um novo grupo de usuários
- `webapps` — nome do grupo; todos os usuários de projetos pertencem a ele, permitindo que o admin gerencie os arquivos sem virar root

### 6.2 Criar usuário para o SQL Challenge

```bash
sudo useradd \
  --system \
  --no-create-home \
  --shell /usr/sbin/nologin \
  --gid webapps \
  --comment "SQL Challenge service user" \
  sqlchallenge
```

- `useradd` — cria um novo usuário
- `--system` — cria um usuário de sistema com UID baixo; não aparece na tela de login
- `--no-create-home` — não cria pasta `/home/sqlchallenge`; usuários de serviço não precisam de home
- `--shell /usr/sbin/nologin` — define um shell que rejeita qualquer tentativa de login interativo; mesmo que alguém descubra a senha, não consegue abrir um terminal
- `--gid webapps` — define `webapps` como grupo primário do usuário
- `--comment` — descrição do usuário, visível em `getent passwd`
- `sqlchallenge` — nome do usuário

### 6.3 Adicionar o admin ao grupo webapps

```bash
sudo usermod -aG webapps admin
sudo usermod -aG docker admin
```

- `-aG webapps` — adiciona o admin ao grupo webapps sem remover dos outros grupos; permite editar arquivos dos projetos sem precisar de sudo
- `-aG docker` — permite usar o Docker sem sudo

```bash
# Sair e entrar novamente para os grupos serem aplicados
exit && ssh vps

# Verificar grupos do usuário atual
groups
```

### 6.4 Modelo para qualquer novo projeto

```bash
sudo useradd \
  --system \
  --no-create-home \
  --shell /usr/sbin/nologin \
  --gid webapps \
  --comment "NOME_PROJETO service user" \
  NOME_PROJETO
```

---

## 7. Estrutura de pastas e permissões

A VPS hospeda **vários serviços**, então a árvore de pastas separa duas coisas: a **infraestrutura compartilhada** (o proxy e a observabilidade, que existem uma vez só) e os **serviços** (um por monorepo). Nada aqui é específico de um projeto — os serviços concretos entram na [seção 15](#15-adicionar-um-novo-serviço-monorepo-multi-container).

### 7.1 Estrutura base

```
/opt/
├── platform/                 ← infra compartilhada (uma vez só)
│   ├── edge/                 ← Traefik + docker-socket-proxy (seção 9)
│   ├── observability/        ← Prometheus, Grafana, Loki, Alloy… (seção 13)
│   └── .env                  ← segredos da plataforma (chmod 640)
└── apps/                     ← um subdiretório por serviço (seção 15)
    └── <servico>/
        ├── production/
        │   ├── app/          ← git clone do monorepo (dono: <servico>:webapps)
        │   ├── compose.override.yml  ← labels do Traefik (gerado no servidor)
        │   └── .env
        └── staging/          ← mesma estrutura (opcional)
```

- `/opt/` — fora de `/home` e `/var`, é o lugar padrão no Linux para software próprio.
- `platform` pertence a `root:docker` (o grupo docker lê o `.env` no `docker compose --env-file`).
- Cada serviço em `apps/` tem **usuário e permissões isolados**: se um for comprometido, o atacante não alcança os outros.

### 7.2 Criar a estrutura base

```bash
# Grupo compartilhado das aplicações (idempotente)
sudo groupadd -f webapps

# Raiz dos serviços — root é dono, webapps pode entrar/ler
sudo mkdir -p /opt/apps
sudo chown root:webapps /opt/apps
sudo chmod 750 /opt/apps

# Infra compartilhada
sudo mkdir -p /opt/platform/edge /opt/platform/observability
sudo chown -R root:docker /opt/platform
sudo chmod 750 /opt/platform

# .env da plataforma (preenchido pelas seções 9 e 13) — só root escreve, docker lê
sudo touch /opt/platform/.env
sudo chown root:docker /opt/platform/.env
sudo chmod 640 /opt/platform/.env
```

- `chmod 750` — dono lê/escreve/entra, grupo entra/lê, outros nada.
- `chmod 640` no `.env` — dono lê/escreve, grupo lê, outros nada. O `.env` guarda segredos.

> A pasta de cada serviço (com dono próprio e clone do monorepo) é criada pela [seção 15](#15-adicionar-um-novo-serviço-monorepo-multi-container), não aqui.

---

## 8. Instalar e configurar o Docker com segurança

### 8.1 Instalar o Docker

```bash
# Baixa e executa o script oficial de instalação do Docker
curl -fsSL https://get.docker.com | sh
```

- `curl -fsSL` — baixa um arquivo pela URL
  - `-f` — falha silenciosamente em erros HTTP
  - `-s` — modo silencioso (sem barra de progresso)
  - `-S` — exibe erros mesmo no modo silencioso
  - `-L` — segue redirecionamentos
- `| sh` — passa o conteúdo baixado diretamente para o shell executar

```bash
sudo usermod -aG docker admin
newgrp docker
```

- `newgrp docker` — aplica o novo grupo na sessão atual sem precisar fazer logout

### 8.2 daemon.json — log rotativo e resiliência

```bash
sudo nano /etc/docker/daemon.json
```

```json
{
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

- `live-restore` — os containers continuam rodando durante um restart do daemon.
- `no-new-privileges` — impede escalonamento de privilégio dentro dos containers (padrão seguro).
- `log-opts` — rotaciona os logs (10 MB × 3 arquivos por container) para não lotar o disco.

```bash
sudo systemctl restart docker
```

> **Mudança em relação ao guia antigo:** aqui o Docker **gerencia o iptables** (o padrão). No modelo com Traefik isso é necessário, pois o Traefik publica 80/443. A antiga recomendação de `"iptables": false` impediria isso. A proteção contra exposição indevida agora vem de outra regra: **as aplicações não publicam portas** — o Traefik as alcança pela rede `edge`; o único serviço que publica em `0.0.0.0` é o Traefik (80/443, que é o que queremos público). O que precisar de porta de host (ex.: banco para túnel) publica só em `127.0.0.1`. Para defesa em profundidade, veja o `ufw-docker` no [passo 5.5](#55-impedir-que-o-docker-contorne-o-ufw).

### 8.3 Redes compartilhadas

Duas redes externas conectam tudo. Crie-as uma vez:

```bash
# Traefik ↔ containers públicos
sudo docker network create edge

# Stack de observabilidade + alvos de métricas
sudo docker network create observability
```

- **`edge`** — o Traefik e todo container que precisa ser público entram nela. É por aqui que o roteamento acontece, sem portas de host.
- **`observability`** — Prometheus/Grafana/Loki e os exporters conversam por aqui, isolados da internet.
- Cada serviço mantém ainda uma **rede interna própria** onde ficam banco e workers — que **nunca** entram na `edge`.

### 8.4 Boas práticas no compose de um serviço

```yaml
services:
  api:
    restart: unless-stopped
    networks: [internal]     # alcançável pelo Traefik quando também estiver na 'edge'
    expose: ["3000"]          # visível só entre containers — nunca publicado no host
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
  db:
    restart: unless-stopped
    networks: [internal]     # NUNCA na 'edge' — banco não é público
```

- Note a ausência de `ports:` — quem expõe é o Traefik, pela rede `edge` (via `compose.override.yml`, [seção 15](#15-adicionar-um-novo-serviço-monorepo-multi-container)).
- Veja um exemplo completo de monorepo (web + api + worker + db) em `vps-scripts/templates/app/compose.example.yml`.

---

## 9. Edge proxy (Traefik)

O **Traefik** recebe todo o tráfego em 80/443 e encaminha para o container certo **com base no domínio** — descobrindo as rotas pelas *labels* de cada container. Não há arquivo de configuração por projeto: você só coloca labels no container, e o Traefik aparece com a rota (e o HTTPS) sozinho.

### 9.1 Por que Traefik (e não Nginx) para containers

| | Nginx | Traefik v3 |
|---|---|---|
| Descoberta de serviços | Manual (um arquivo por site) | Automática (labels do Docker) |
| HTTPS | Certbot (processo à parte) | Let's Encrypt embutido |
| Nova rota | Editar arquivo + `reload` | Subir o container com labels |
| Métricas/observabilidade | Add-on | Prometheus + OpenTelemetry embutidos |

Numa VPS com muitos serviços entrando e saindo, a descoberta automática elimina trabalho manual e uma classe inteira de erros.

### 9.2 O socket do Docker é o ponto sensível

Para descobrir rotas, o Traefik precisa **ler** a lista de containers do Docker. Dar a ele o `/var/run/docker.sock` cru equivale a dar **root** na máquina (quem fala com o socket cria containers privilegiados). A solução é o **docker-socket-proxy**: um intermediário que expõe **somente** a API de containers, em **modo leitura**. O Traefik fala com o proxy, nunca com o socket direto.

### 9.3 Configuração

Os templates prontos estão em `vps-scripts/templates/edge/` (`traefik.yml`, `dynamic/security.yml`, `compose.yml`). O script `09-edge-proxy.sh` os instala em `/opt/platform/edge`, pede o e-mail do ACME e as credenciais do dashboard, e sobe a stack. Os pontos-chave:

- **Entrypoints:** `web` (80) redireciona tudo para `websecure` (443).
- **TLS automático:** um `certResolver` Let's Encrypt (`tlsChallenge`) — cada serviço com as labels de TLS recebe e renova o certificado sozinho.
- **Middlewares globais** (em `dynamic/security.yml`): cabeçalhos de segurança + HSTS, rate-limit e compressão, agrupados numa cadeia `secure-chain`.
- **Dashboard nunca público:** protegido por basic-auth **e** allowlist de IP.
- `exposedByDefault=false`: um container só é roteado se declarar `traefik.enable=true`.

### 9.4 Como um serviço declara suas rotas (labels)

O container **não publica porta**; ele entra na rede `edge` e descreve a rota por labels:

```yaml
services:
  api:
    networks: [internal, edge]
    labels:
      - traefik.enable=true
      - traefik.docker.network=edge
      - traefik.http.routers.api.rule=Host(`api.seudominio.com`)
      - traefik.http.routers.api.entrypoints=websecure
      - traefik.http.routers.api.tls.certresolver=le
      - traefik.http.routers.api.middlewares=secure-chain@file
      - traefik.http.services.api.loadbalancer.server.port=3000
```

- `rule=Host(...)` — qual domínio esse container responde.
- `services...server.port` — a porta **interna** do container (não uma porta de host).
- Um monorepo com vários containers públicos declara **um router por container** (ex.: `app.seudominio.com` → web, `api.seudominio.com` → api). O banco e os workers ficam só na rede `internal`, sem labels — invisíveis de fora.

Na prática, a [seção 15](#15-adicionar-um-novo-serviço-monorepo-multi-container) **gera** essas labels num `compose.override.yml` no servidor, para o repositório continuar portátil.

### 9.5 Subir

```bash
sudo bash vps-scripts/scripts/09-edge-proxy.sh
# ou, manualmente:
cd /opt/platform/edge
docker compose --env-file /opt/platform/.env up -d
```

> Ajuste a allowlist de IP do dashboard em `/opt/platform/edge/dynamic/security.yml` (middleware `admin-allowlist`) para o IP do seu escritório/VPN.

---

## 10. TLS/HTTPS automático (Let's Encrypt via Traefik)

Com o Traefik, **não há mais Certbot**: o HTTPS é automático. Assim que um serviço sobe com as labels de TLS e o DNS do domínio aponta para a VPS, o Traefik resolve o desafio ACME, emite o certificado e passa a renová-lo sozinho (bem antes dos 90 dias).

### 10.1 O que você precisa garantir

1. **DNS:** o domínio precisa resolver para o IP da VPS **antes** de o certificado ser emitido — `dig +short api.seudominio.com` deve devolver o IP.
2. **Portas:** 80 e 443 abertas no UFW ([seção 5](#5-firewall-com-ufw)).
3. **Permissão do `acme.json`:** o arquivo que guarda os certificados precisa estar em `chmod 600` (o script já cuida disso).

### 10.2 Verificar o estado

O script `10-ssl.sh` (menu) diagnostica: se o Traefik está rodando, se o `acme.json` tem a permissão certa e quais domínios já têm certificado emitido.

```bash
# Ver os certificados já emitidos
sudo jq -r '.le.Certificates[]?.domain.main' /opt/platform/edge/acme.json

# Acompanhar a emissão em tempo real
docker compose -f /opt/platform/edge/compose.yml logs -f traefik
```

### 10.3 Certificado wildcard (`*.seudominio.com`)

O `tlsChallenge` padrão emite um certificado por domínio. Para um **wildcard**, troque-o por um **dnsChallenge** no `/opt/platform/edge/traefik.yml`, informando as credenciais do seu provedor de DNS (Cloudflare, Route53, etc.):

```yaml
certificatesResolvers:
  le:
    acme:
      email: "voce@exemplo.com"
      storage: /acme/acme.json
      dnsChallenge:
        provider: cloudflare   # ajuste ao seu provedor
```

As credenciais entram como variáveis de ambiente do container do Traefik (ex.: `CF_DNS_API_TOKEN`), guardadas no `/opt/platform/.env`.

---

## 11. Segurança do banco de dados PostgreSQL

### 11.1 Porta vinculada apenas ao localhost

No `docker-compose.yml`, a diferença entre as duas formas é crítica:

```yaml
# ERRADO em produção — expõe o banco para qualquer IP na internet
ports:
  - "5432:5432"

# CORRETO — banco acessível apenas dentro da própria VPS
ports:
  - "127.0.0.1:5432:5432"
```

- `127.0.0.1` — endereço de loopback; significa "somente eu mesmo"; nenhuma conexão externa chega aqui

### 11.2 Gerar senha forte

```bash
openssl rand -base64 32
```

- `openssl rand` — gera bytes aleatórios criptograficamente seguros
- `-base64 32` — converte 32 bytes aleatórios para Base64, resultando em uma string de ~44 caracteres

### 11.3 Acesso remoto via túnel SSH

```bash
# No seu computador — mantém o terminal aberto enquanto usa o banco
ssh -L 5432:localhost:5432 vps
```

- `-L 5432:localhost:5432` — Local port forwarding:
  - `5432` (primeiro) — porta no seu computador
  - `localhost:5432` — destino dentro da VPS (localhost da VPS = banco de dados)
  - Tudo que chega na porta 5432 do seu computador é encaminhado de forma criptografada para a porta 5432 da VPS

### 11.4 Backup automático

```bash
sudo nano /opt/apps/sql-challenge/backup.sh
```

```bash
#!/bin/bash
# Define onde os backups serão armazenados
BACKUP_DIR="/opt/apps/sql-challenge/backups"

# Gera um nome com data e hora para o arquivo
DATE=$(date +%Y%m%d_%H%M%S)

# Cria o diretório se não existir
mkdir -p $BACKUP_DIR

# pg_dump: exporta o banco de dados para SQL
# docker exec: executa o comando dentro do container do banco
# | gzip: comprime a saída antes de salvar no disco
docker exec sql-challenge-db pg_dump \
  -U challenge_user -d db_gestao \
  | gzip > $BACKUP_DIR/db_gestao_$DATE.sql.gz

# Remove backups com mais de 7 dias para não lotar o disco
# -mtime +7: arquivos modificados há mais de 7 dias
# -delete: apaga os arquivos encontrados
find $BACKUP_DIR -name "*.sql.gz" -mtime +7 -delete

echo "Backup concluído: db_gestao_$DATE.sql.gz"
```

```bash
# Torna o script executável
sudo chmod +x /opt/apps/sql-challenge/backup.sh
sudo chown sqlchallenge:webapps /opt/apps/sql-challenge/backup.sh

# Abre o crontab do usuário sqlchallenge
sudo crontab -u sqlchallenge -e
```

```
# Executa o backup todo dia às 3h da manhã
# Formato: minuto hora dia_do_mes mes dia_da_semana comando
0 3 * * * /opt/apps/sql-challenge/backup.sh >> /opt/apps/sql-challenge/backup.log 2>&1
```

- `>> backup.log` — adiciona a saída do script ao arquivo de log (sem sobrescrever)
- `2>&1` — redireciona também os erros para o mesmo arquivo de log

---

## 12. Atualizações automáticas de segurança

```bash
sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```

```
# Define quais repositórios têm permissão para atualizar automaticamente
# Apenas atualizações de segurança — não atualiza tudo automaticamente
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

# Remove pacotes que não são mais necessários após a atualização
Unattended-Upgrade::Remove-Unused-Dependencies "true";

# Reinicia automaticamente se uma atualização exigir
Unattended-Upgrade::Automatic-Reboot "true";

# Horário do reinício automático (escolha um horário de baixo uso)
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
```

```bash
sudo nano /etc/apt/apt.conf.d/20auto-upgrades
```

```
# Atualiza a lista de pacotes todos os dias
APT::Periodic::Update-Package-Lists "1";

# Executa o unattended-upgrades todos os dias
APT::Periodic::Unattended-Upgrade "1";

# Limpa pacotes baixados há mais de 7 dias
APT::Periodic::AutocleanInterval "7";
```

---

## 13. Observabilidade e logs

Duas camadas: os **comandos rápidos** de sempre (para um diagnóstico pontual no terminal) e a **stack de observabilidade** (métricas, logs e dashboards centralizados — o jeito de acompanhar uma VPS com vários serviços de forma contínua).

### 13.1 Stack de observabilidade (Prometheus + Grafana + Loki + Alloy)

Subida pela etapa 19 (`19-observability.sh`) em `/opt/platform/observability`, dá:

- **Prometheus** — coleta e guarda métricas (do Traefik, dos containers via cAdvisor e do host via node-exporter).
- **Grafana** — dashboards; é a única peça acessível de fora, via Traefik e com login.
- **Loki + Grafana Alloy** — agregam os logs de **todos** os containers automaticamente (o Alloy substitui o Promtail, em EOL desde mar/2026).

O passo a passo, os dashboards recomendados e as consultas ficam no guia dedicado: **[`OBSERVABILIDADE.md`](./OBSERVABILIDADE.md)**.

```bash
sudo bash vps-scripts/scripts/19-observability.sh
# Depois, acesse https://grafana.seudominio.com (senha admin gerada em /opt/platform/.env)
```

### 13.2 Comandos rápidos no terminal

```bash
# Tentativas de acesso SSH (login, falhas, bans)
sudo tail -f /var/log/auth.log

# Logs dos containers de um serviço em tempo real
docker compose -f /opt/apps/PROJETO/production/app/compose.yml logs -f

# Logs do Traefik (útil para depurar emissão de certificado / roteamento)
docker compose -f /opt/platform/edge/compose.yml logs -f traefik

# Saúde das stacks da plataforma
docker compose -f /opt/platform/edge/compose.yml ps
docker compose -f /opt/platform/observability/compose.yml ps

# IPs banidos pelo Fail2Ban / desbanir um IP
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip IP_A_DESBANIR

# Recursos: host, containers, disco
htop
docker stats
df -h && du -sh /opt/apps/*
```

> O menu `13-monitoring.sh` reúne esses comandos (incluindo saúde da plataforma e URLs do Grafana/Traefik) mais um kit de diagnóstico de rede.

---

## 14. Hardening contínuo do servidor

Depois da configuração inicial, segurança vira rotina operacional. Este bloco adiciona controles importantes para reduzir superfície de ataque e melhorar rastreabilidade.

### 14.1 Endurecer parâmetros de rede do kernel

```bash
sudo nano /etc/sysctl.d/99-security-hardening.conf
```

```conf
# Mitiga spoofing de IP e tráfego malformado
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1

# Desativa redirects ICMP (evita manipulação de rotas)
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
```

```bash
sudo sysctl --system
```

### 14.2 Auditar uso de privilégios (sudo)

```bash
sudo visudo
```

```conf
# Exige reautenticação frequente para comandos privilegiados
Defaults timestamp_timeout=5

# Registra comandos sudo em arquivo dedicado
Defaults logfile="/var/log/sudo.log"
```

```bash
sudo chmod 600 /var/log/sudo.log
```

### 14.3 Controle de integridade de arquivos com AIDE

```bash
sudo apt install -y aide
sudo aideinit
```

> O primeiro baseline deve ser gerado quando o servidor estiver em estado limpo. Depois disso, rode verificações periódicas e investigue qualquer alteração inesperada em `/etc`, binários e scripts de deploy.

### 14.4 Rotina mínima de segurança (semanal)

- Revisar usuários com shell ativo: `getent passwd | grep -E '/bin/bash|/bin/sh'`
- Revisar chaves autorizadas em `~/.ssh/authorized_keys`
- Conferir portas expostas: `sudo ss -tulpen`
- Validar bans do Fail2Ban: `sudo fail2ban-client status sshd`
- Verificar vulnerabilidades de imagens Docker usadas no deploy (scanner no pipeline)

---

## 15. Adicionar um novo serviço (monorepo multi-container)

Um serviço é **um monorepo com vários containers** (ex.: web + api + worker + db) descritos por um único `compose.yml` no repositório. Você não escolhe portas nem edita o proxy: informa quais containers são públicos e seus domínios, e o servidor gera as labels do Traefik.

### 15.1 Automatizado (recomendado)

```bash
sudo bash vps-scripts/scripts/15-new-project.sh
```

O script pergunta o nome do serviço, a URL do monorepo, se quer staging e **quais containers são públicos** (nome no compose → porta interna → domínio). Ele então:

1. cria o usuário de serviço isolado e a pasta em `/opt/apps/<servico>`;
2. clona o monorepo em `production/app` (e `staging/app`);
3. gera o `compose.override.yml` com as labels do Traefik para cada container público;
4. grava os metadados que a etapa 17 (CI/CD) vai reutilizar.

### 15.2 O que acontece por baixo

O repositório traz o `compose.yml` da aplicação (sem domínios). O servidor adiciona um `compose.override.yml` com as rotas:

```yaml
# /opt/apps/<servico>/production/compose.override.yml  (gerado)
services:
  api:
    networks: [edge]
    labels:
      - traefik.enable=true
      - traefik.docker.network=edge
      - traefik.http.routers.<servico>-production-api.rule=Host(`api.seudominio.com`)
      - traefik.http.routers.<servico>-production-api.entrypoints=websecure
      - traefik.http.routers.<servico>-production-api.tls.certresolver=le
      - traefik.http.routers.<servico>-production-api.middlewares=secure-chain@file
      - traefik.http.services.<servico>-production-api.loadbalancer.server.port=3000
networks:
  edge:
    external: true
```

### 15.3 Subir

```bash
# Edite o .env do ambiente e aponte o DNS de cada domínio para a VPS, então:
cd /opt/apps/<servico>/production/app
docker compose -f compose.yml -f ../compose.override.yml up --build -d
```

O Traefik detecta os containers, emite o HTTPS e começa a rotear — sem reiniciar nada da plataforma.

> Serviços HTTP **não usam porta de host**. Se precisar expor o banco para um túnel SSH de administração, reserve uma porta com o gerenciador de portas (etapa 18) e publique só em `127.0.0.1` no override.

---

## 16. Resumo: fluxo, portas e domínios

### Portas abertas no firewall

| Porta | Origem | Motivo |
|---|---|---|
| 2222/tcp | Qualquer | SSH (porta não-padrão) |
| 80/tcp | Qualquer | HTTP → redireciona para HTTPS (Traefik) |
| 443/tcp | Qualquer | HTTPS (Traefik) |

> **Nenhuma porta de aplicação é exposta.** Só o Traefik publica em 80/443; todo o resto é alcançado por ele pela rede `edge`. Banco/administração, quando necessário, via túnel SSH (bind `127.0.0.1`).

### Fluxo de uma requisição

```
Internet
    │  :443 (HTTPS)
    ▼
Traefik  ── descobre rotas pelas labels dos containers ──┐
    │                                                    │  métricas
    ├── app.dominio1.com  →  rede edge → container web    ├─────────► Prometheus ─► Grafana
    ├── api.dominio1.com  →  rede edge → container api     │             ▲
    └── grafana.dominio   →  rede edge → Grafana           │   logs      │
                                                           └─ Alloy ─► Loki ─┘
   (worker e db ficam só na rede interna de cada serviço — nunca na edge)
```

### Camadas

| Camada | Onde | O que roda |
|---|---|---|
| Plataforma | `/opt/platform/edge` | Traefik + docker-socket-proxy |
| Plataforma | `/opt/platform/observability` | Prometheus, Grafana, Loki, Alloy, cAdvisor, node-exporter |
| Serviços | `/opt/apps/<servico>` | um monorepo por serviço (prod + staging) |

---

> Escrito para **Ubuntu 24.04 LTS**. Automação: `PT/Servidor/vps-scripts/`.
