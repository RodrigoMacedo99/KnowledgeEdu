# Configuração de Infraestrutura VPS do Zero

> Guia completo com hardening, firewall, isolamento por usuário, múltiplos domínios, SSL e boas práticas de segurança para Ubuntu 24.04 LTS.

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
9. [Nginx como reverse proxy](#9-nginx-como-reverse-proxy)
10. [SSL com Let's Encrypt e renovação automática](#10-ssl-com-lets-encrypt-e-renovação-automática)
11. [Segurança do banco de dados PostgreSQL](#11-segurança-do-banco-de-dados-postgresql)
12. [Atualizações automáticas de segurança](#12-atualizações-automáticas-de-segurança)
13. [Monitoramento e logs](#13-monitoramento-e-logs)
14. [Hardening contínuo do servidor](#14-hardening-contínuo-do-servidor)
15. [Adicionar um novo projeto](#15-adicionar-um-novo-projeto)
16. [Resumo: portas, usuários e domínios](#16-resumo-portas-usuários-e-domínios)

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

Por padrão, o Docker manipula o iptables diretamente e consegue expor portas de containers **mesmo com regras de bloqueio no UFW**. Isso é um problema de segurança grave.

```bash
sudo nano /etc/docker/daemon.json
```

```json
{
  "iptables": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

- `"iptables": false` — impede que o Docker modifique as regras do firewall diretamente; todo acesso externo passa obrigatoriamente pelo Nginx
- `"log-driver": "json-file"` — formato de log dos containers
- `"max-size": "10m"` — cada arquivo de log tem no máximo 10 MB antes de rotacionar
- `"max-file": "3"` — mantém no máximo 3 arquivos de log por container (evita lotar o disco)

```bash
sudo systemctl restart docker
```

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

### 7.1 Estrutura base

```
/opt/apps/
├── sql-challenge/
│   ├── backend/        ← repositório (dono: sqlchallenge:webapps  chmod 750)
│   └── .env            ← variáveis   (dono: sqlchallenge:webapps  chmod 640)
├── projeto-dois/
│   ├── app/
│   └── .env
└── projeto-tres/
    ├── app/
    └── .env
```

- `/opt/apps/` — diretório padrão para aplicações de terceiros no Linux; fora do `/home` e do `/var`, mantendo organização clara
- Cada projeto tem sua própria subpasta com dono e permissões isolados

### 7.2 Criar a estrutura para o SQL Challenge

```bash
# Cria a pasta do projeto (e subpastas se necessário com -p)
sudo mkdir -p /opt/apps/sql-challenge

# Define sqlchallenge como dono e webapps como grupo da pasta
sudo chown sqlchallenge:webapps /opt/apps/sql-challenge

# chmod 750:
# 7 = dono pode ler, escrever e executar (entrar na pasta)
# 5 = grupo pode ler e executar (entrar, mas não criar arquivos)
# 0 = outros não têm nenhum acesso
sudo chmod 750 /opt/apps/sql-challenge
```

```bash
# Clona o repositório como o usuário sqlchallenge
# sudo -u sqlchallenge: executa o comando como se fosse o usuário sqlchallenge
sudo -u sqlchallenge git clone \
  https://github.com/sql-challenge/sql-challenge-backend.git \
  /opt/apps/sql-challenge/backend
```

```bash
# Cria o arquivo .env de produção
sudo nano /opt/apps/sql-challenge/.env

# Define o dono correto
sudo chown sqlchallenge:webapps /opt/apps/sql-challenge/.env

# chmod 640:
# 6 = dono pode ler e escrever
# 4 = grupo pode apenas ler
# 0 = outros não têm acesso
# O .env contém senhas — não pode ser lido por qualquer usuário do sistema
sudo chmod 640 /opt/apps/sql-challenge/.env

# Cria um link simbólico do .env dentro do projeto
# Assim o Docker Compose encontra o .env no lugar esperado
sudo ln -s /opt/apps/sql-challenge/.env /opt/apps/sql-challenge/backend/.env
```

- `ln -s` — cria um link simbólico (atalho); o arquivo `.env` fisicamente existe em `/opt/apps/sql-challenge/.env` mas o projeto o enxerga em `backend/.env`

### 7.3 Verificar as permissões

```bash
ls -la /opt/apps/
ls -la /opt/apps/sql-challenge/
```

- `ls -la` — lista arquivos com detalhes (`-l`) incluindo arquivos ocultos (`-a`)

Resultado esperado:

```
drwxr-x--- sqlchallenge webapps  sql-challenge/   ← 750
drwxr-x--- sqlchallenge webapps  backend/         ← 750
-rw-r----- sqlchallenge webapps  .env             ← 640
```

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

### 8.2 Boas práticas no docker-compose.yml

Em produção, as portas dos containers **não devem ser expostas diretamente** — apenas o Nginx acessa:

```yaml
services:
  api:
    restart: unless-stopped
    # 'expose' torna a porta visível apenas entre containers na mesma rede Docker
    # Diferente de 'ports', não expõe para o host nem para a internet
    expose:
      - "3000"
    deploy:
      resources:
        limits:
          # Limita o uso de CPU a 50% de um núcleo
          cpus: '0.5'
          # Limita a memória RAM a 512 MB
          memory: 512M

  db:
    restart: unless-stopped
    ports:
      # "127.0.0.1:5432:5432" vincula a porta SOMENTE ao localhost da VPS
      # Sem esse prefixo ("5432:5432"), a porta ficaria acessível para qualquer IP
      - "127.0.0.1:5432:5432"
```

```bash
cd /opt/apps/sql-challenge/backend

# --build: reconstrói a imagem com o código mais recente
# -d: sobe em background (detached mode)
docker compose up --build -d

# Verifica se os containers estão rodando e com status "healthy"
docker compose ps

# Acompanha os logs do backend em tempo real
docker compose logs api
```

---

## 9. Nginx como reverse proxy

O Nginx recebe todo o tráfego externo nas portas 80/443 e encaminha para o container correto com base no domínio. Nenhuma porta de aplicação fica exposta diretamente na internet.

### 9.1 Instalar

```bash
sudo apt install -y nginx
sudo systemctl enable nginx   # inicia automaticamente ao ligar a VPS
sudo systemctl start nginx

# Remove o site padrão que vem com o Nginx
sudo rm /etc/nginx/sites-enabled/default
```

### 9.2 Cabeçalhos globais de segurança

```bash
sudo nano /etc/nginx/conf.d/security-headers.conf
```

```nginx
# Impede que o browser "adivinhe" o tipo do arquivo — evita ataques MIME sniffing
add_header X-Content-Type-Options    "nosniff"                              always;

# Impede que a página seja carregada dentro de um iframe — previne ataques de clickjacking
add_header X-Frame-Options           "DENY"                                 always;

# Ativa o filtro XSS nativo do browser e bloqueia a página se detectar ataque
add_header X-XSS-Protection          "1; mode=block"                        always;

# HSTS: força o browser a usar HTTPS por 1 ano após o primeiro acesso seguro
# includeSubDomains: aplica também nos subdomínios
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains"  always;

# Controla quais informações de origem são enviadas ao acessar outros sites
add_header Referrer-Policy           "strict-origin-when-cross-origin"      always;
```

- `always` — envia o cabeçalho em **todas** as respostas, incluindo erros (4xx, 5xx)

### 9.3 Configuração do SQL Challenge

```bash
sudo nano /etc/nginx/sites-available/sql-challenge
```

```nginx
server {
    # Escuta na porta 80 (HTTP)
    listen 80;

    # Nome do domínio que essa configuração atende
    server_name api.seudominio.com;

    # Tamanho máximo do corpo de uma requisição (uploads, JSON grandes)
    client_max_body_size 10M;

    # Tempo máximo para o backend responder antes de retornar erro 504
    proxy_read_timeout 60s;

    # Tempo máximo para estabelecer conexão com o backend
    proxy_connect_timeout 10s;

    # Oculta a versão do Nginx nas páginas de erro (dificulta exploração de vulnerabilidades)
    server_tokens off;

    location / {
        # Encaminha as requisições para o container do backend
        proxy_pass http://localhost:3000;

        # Usa HTTP 1.1 para suportar conexões persistentes e WebSockets
        proxy_http_version 1.1;

        # Necessário para WebSockets funcionarem corretamente
        proxy_set_header Upgrade            $http_upgrade;
        proxy_set_header Connection         'upgrade';

        # Repassa o domínio original ao backend (necessário para CORS funcionar)
        proxy_set_header Host               $host;

        # IP real do cliente (sem isso o backend vê o IP do Nginx, não do usuário)
        proxy_set_header X-Real-IP          $remote_addr;

        # Cadeia de IPs por onde a requisição passou (proxies intermediários)
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;

        # Informa ao backend se a conexão original era HTTP ou HTTPS
        proxy_set_header X-Forwarded-Proto  $scheme;

        # Ignora cache para conexões com Upgrade (WebSocket)
        proxy_cache_bypass                  $http_upgrade;
    }
}
```

```bash
# Ativa o site criando um link simbólico na pasta sites-enabled
sudo ln -s /etc/nginx/sites-available/sql-challenge /etc/nginx/sites-enabled/

# Testa se a sintaxe do arquivo está correta — sempre faça isso antes de recarregar
sudo nginx -t

# Recarrega o Nginx aplicando as novas configurações sem derrubar conexões ativas
sudo systemctl reload nginx
```

- `sites-available` — contém todas as configurações de sites (ativos ou não)
- `sites-enabled` — contém apenas links simbólicos para os sites ativos
- Essa separação permite desativar um site removendo o link sem apagar a configuração

### 9.4 Modelo para novos projetos

```bash
sudo nano /etc/nginx/sites-available/NOME_PROJETO
```

```nginx
server {
    listen 80;
    server_name dominio.do.projeto.com;

    client_max_body_size 10M;
    server_tokens off;

    location / {
        # Cada projeto usa uma porta diferente internamente
        proxy_pass            http://localhost:PORTA_DO_PROJETO;
        proxy_http_version    1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/NOME_PROJETO /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## 10. SSL com Let's Encrypt e renovação automática

O Let's Encrypt fornece certificados SSL gratuitos com validade de 90 dias, renovados automaticamente.

### 10.1 Instalar o Certbot

```bash
sudo apt install -y certbot python3-certbot-nginx
```

- `certbot` — ferramenta que solicita e gerencia certificados SSL junto ao Let's Encrypt
- `python3-certbot-nginx` — plugin que permite ao Certbot configurar o Nginx automaticamente

### 10.2 Gerar o certificado

```bash
sudo certbot --nginx -d api.seudominio.com
```

- `--nginx` — usa o plugin do Nginx; edita automaticamente o arquivo de configuração para HTTPS
- `-d api.seudominio.com` — domínio para o qual o certificado será emitido (deve apontar para o IP da VPS no DNS)

O Certbot irá:
1. Verificar que o domínio aponta para a VPS via HTTP
2. Emitir o certificado
3. Atualizar o arquivo do Nginx com as configurações HTTPS
4. Configurar redirecionamento automático de HTTP para HTTPS

### 10.3 Verificar a renovação automática

```bash
# Verifica se o timer de renovação está ativo
sudo systemctl status certbot.timer

# Simula uma renovação para garantir que funciona (não emite certificado novo)
sudo certbot renew --dry-run
```

- Os certificados são renovados automaticamente quando faltam menos de 30 dias para expirar
- `--dry-run` — executa todo o processo de renovação sem de fato emitir um certificado novo

### 10.4 Resultado após o Certbot

O arquivo do Nginx é atualizado automaticamente:

```nginx
# Bloco HTTPS adicionado pelo Certbot
server {
    listen 443 ssl;
    server_name api.seudominio.com;

    # Caminhos dos certificados gerados pelo Let's Encrypt
    ssl_certificate     /etc/letsencrypt/live/api.seudominio.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.seudominio.com/privkey.pem;

    # Configurações de segurança SSL recomendadas pelo Let's Encrypt
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / { ... }
}

# Redirecionamento HTTP → HTTPS adicionado pelo Certbot
server {
    listen 80;
    server_name api.seudominio.com;
    return 301 https://$host$request_uri;
}
```

- `return 301` — redirecionamento permanente; avisa ao browser e aos buscadores que o endereço mudou definitivamente para HTTPS

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

## 13. Monitoramento e logs

```bash
# Acompanha tentativas de acesso SSH (login, falhas, bans)
# -f: segue o arquivo em tempo real (ctrl+c para sair)
sudo tail -f /var/log/auth.log

# Requisições recebidas pelo Nginx (IP, horário, rota, código de resposta)
sudo tail -f /var/log/nginx/access.log

# Erros do Nginx (configuração inválida, backend inacessível, etc.)
sudo tail -f /var/log/nginx/error.log

# Logs dos containers em tempo real
docker compose -f /opt/apps/sql-challenge/backend/docker-compose.yml logs -f

# Todos os IPs atualmente banidos pelo Fail2Ban
sudo fail2ban-client status sshd

# Desbanir um IP bloqueado por engano
sudo fail2ban-client set sshd unbanip IP_A_DESBANIR

# Monitor interativo de CPU, memória e processos da VPS
htop

# Uso de CPU, memória e rede de cada container em tempo real
docker stats

# Espaço disponível em disco por partição
df -h

# Quanto cada projeto está usando de disco
du -sh /opt/apps/*
```

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

## 15. Adicionar um novo projeto

```bash
# ─── 1. Usuário de serviço ─────────────────────────────────────────────────
# Cria usuário isolado sem acesso a login
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --gid webapps NOME_PROJETO

# ─── 2. Pasta e permissões ────────────────────────────────────────────────
sudo mkdir -p /opt/apps/NOME_PROJETO
sudo chown NOME_PROJETO:webapps /opt/apps/NOME_PROJETO
sudo chmod 750 /opt/apps/NOME_PROJETO

# ─── 3. Repositório ───────────────────────────────────────────────────────
# Clona como o usuário do projeto para garantir que os arquivos têm o dono correto
sudo -u NOME_PROJETO git clone URL_DO_REPO /opt/apps/NOME_PROJETO/app

# ─── 4. Variáveis de ambiente ─────────────────────────────────────────────
sudo nano /opt/apps/NOME_PROJETO/.env
sudo chown NOME_PROJETO:webapps /opt/apps/NOME_PROJETO/.env
sudo chmod 640 /opt/apps/NOME_PROJETO/.env
sudo ln -s /opt/apps/NOME_PROJETO/.env /opt/apps/NOME_PROJETO/app/.env

# ─── 5. Containers ────────────────────────────────────────────────────────
cd /opt/apps/NOME_PROJETO/app
docker compose up --build -d

# ─── 6. Nginx ─────────────────────────────────────────────────────────────
sudo nano /etc/nginx/sites-available/NOME_PROJETO
sudo ln -s /etc/nginx/sites-available/NOME_PROJETO /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ─── 7. SSL ───────────────────────────────────────────────────────────────
sudo certbot --nginx -d dominio.do.projeto.com

# ─── 8. Backup ────────────────────────────────────────────────────────────
sudo nano /opt/apps/NOME_PROJETO/backup.sh
sudo chmod +x /opt/apps/NOME_PROJETO/backup.sh
sudo crontab -u NOME_PROJETO -e
```

---

## 16. Resumo: portas, usuários e domínios

### Projetos

| Projeto | Usuário | Pasta | Porta API | Porta DB |
|---|---|---|---|---|
| SQL Challenge | sqlchallenge | /opt/apps/sql-challenge | 3000 | 5432 |
| Projeto Dois | projetodois | /opt/apps/projeto-dois | 3001 | 5433 |
| Projeto Três | projetotres | /opt/apps/projeto-tres | 3002 | 5434 |

### Portas abertas no firewall

| Porta | Origem | Motivo |
|---|---|---|
| 2222/tcp | Qualquer | SSH (porta não-padrão) |
| 80/tcp | Qualquer | HTTP → redireciona para HTTPS |
| 443/tcp | Qualquer | HTTPS (Nginx) |
| 5432/tcp | Seu IP | PostgreSQL (administração remota) |

> Nenhuma porta de API fica exposta diretamente. Todo tráfego externo passa pelo Nginx na 443.

### Fluxo de uma requisição

```
Internet
    │
    ▼
VPS :443 (HTTPS)
    │
    ▼
Nginx (reverse proxy)
    │
    ├── api.dominio1.com  →  localhost:3000  →  sql-challenge-api
    ├── api.dominio2.com  →  localhost:3001  →  projeto-dois-api
    └── api.dominio3.com  →  localhost:3002  →  projeto-tres-api
```

---

> Escrito para **Ubuntu 24.04 LTS**.
