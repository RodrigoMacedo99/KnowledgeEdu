# Segurança da VPS — Defesa em Profundidade

> O mapa das camadas de segurança deste servidor: o que cada uma protege, em que etapa é aplicada e o que **você** ainda precisa fazer manualmente. Pensado para hospedar **dados sigilosos**.

> **Princípio:** nenhuma camada isolada é suficiente. Segurança é a **soma** de barreiras independentes — se uma falhar, a próxima ainda segura. Isto se chama *defense in depth*.

---

## 1. As camadas, do perímetro ao dado

```
Internet
  │
  ▼  ── Rede ────────────────────────────────────────────────
  UFW (firewall)              só 80/443 e a porta SSH abertas      → etapa 5
  Fail2Ban                    bane IPs que insistem em falhar       → etapas 4 e 20
  │
  ▼  ── Acesso ──────────────────────────────────────────────
  SSH hardening               sem senha, sem root, porta trocada    → etapa 3
  2FA (TOTP, opcional)        segundo fator além da chave           → etapa 20
  │
  ▼  ── Borda de aplicação ──────────────────────────────────
  Traefik + TLS               HTTPS forçado, HSTS, headers, rate    → etapa 9
  Authelia (2FA/SSO web)      2FA em qualquer serviço via proxy     → etapa 21
  socket-proxy                Docker exposto em leitura apenas       → etapa 9
  │
  ▼  ── Isolamento ──────────────────────────────────────────
  Usuário por serviço         um comprometido não alcança os outros → etapas 6 e 15
  Redes Docker                banco/worker nunca na rede pública     → etapas 8 e 15
  no-new-privileges           containers não escalam privilégio      → etapas 8 e 20
  userns-remap (opcional)     root do container ≠ root do host       → etapa 20
  │
  ▼  ── Sistema operacional ─────────────────────────────────
  Kernel hardening (sysctl)   spoofing, ptrace, kptr, BPF            → etapas 14 e 20
  AppArmor                    confinamento de processos              → etapa 20
  Core dumps off              não vaza memória (segredos) em disco   → etapa 20
  Blacklist de módulos        filesystems/protocolos raros bloqueados→ etapa 20
  Política de senha           mín. 14 caracteres, 3 classes          → etapa 20
  Atualizações automáticas    correções de segurança sem intervenção → etapa 12
  │
  ▼  ── Detecção e resposta ─────────────────────────────────
  CrowdSec (IPS)              detecta e bane IPs (blocklist colab.)   → etapa 23
  auditd                      registra acesso a arquivos sensíveis   → etapa 20
  AIDE                        detecta alteração de binários/config   → etapa 14
  Observabilidade + alertas   métricas/logs + SLO alerts             → etapa 19
  │
  ▼  ── O dado ──────────────────────────────────────────────
  Backups criptografados      dump + age, retenção, off-site         → etapa 22
  Segredos (.env chmod 640), TLS no banco, LUKS/SOPS                 → manual (§3)
```

---

## 2. O que as etapas automatizam

| Camada | Etapa | Script |
|---|---|---|
| Firewall (UFW) | 5 | `05-ufw.sh` |
| Fail2Ban (SSH + recidive) | 4, 20 | `04-fail2ban.sh`, `20-hardening-extra.sh` |
| SSH hardening | 3 | `03-ssh-hardening.sh` |
| Isolamento por usuário/rede | 6, 8, 15 | `06-…`, `08-docker.sh`, `15-new-project.sh` |
| Edge proxy + TLS + socket-proxy | 9 | `09-edge-proxy.sh` |
| Kernel + auditoria base | 14 | `14-hardening.sh` |
| Atualizações automáticas | 12 | `12-auto-updates.sh` |
| Observabilidade + alertas (SLOs) | 19 | `19-observability.sh` |
| Senha, core dumps, AppArmor, auditd, 2FA SSH, userns | 20 | `20-hardening-extra.sh` |
| 2FA/SSO nos serviços web (Authelia) | 21 | `21-2fa-web.sh` |
| Backups automatizados e criptografados | 22 | `22-backups.sh` |
| CrowdSec (IPS colaborativo) | 23 | `23-crowdsec.sh` |
| Verificação da plataforma (self-check) | 24 | `24-verify.sh` |

---

## 2b. Autenticação de dois fatores (2FA) em duas frentes

O 2FA cobre os dois caminhos de entrada do servidor:

### Acesso administrativo — 2FA no SSH (etapa 20, opt-in)
Além da chave, um código do app autenticador (TOTP). Configuração segura por padrão:
- Usa **`nullok`**: quem ainda não cadastrou o token entra só com a chave — ninguém fica trancado para fora. O 2FA passa a valer por usuário quando ele roda `google-authenticator`.
- O fluxo `keyboard-interactive` do PAM é ajustado para pedir **só o código** (não a senha do Unix), e o `sshd -t` valida antes de aplicar (com rollback automático se falhar).

### Acesso aos serviços web — Authelia (etapa 21)
Um portal de login único que o Traefik consulta por *forward-auth*. Para exigir 2FA em **qualquer** serviço web, basta adicionar um middleware ao router dele:
```
traefik.http.routers.<router>.middlewares=secure-chain@file,authelia@docker
```
A própria etapa 21 já coloca o **dashboard do Traefik** e o **Grafana** atrás do Authelia por padrão; para os demais (staging, painéis internos) basta a label acima. Tudo com o mesmo login (senha + 2FA TOTP/WebAuthn). Suporta regras de acesso por domínio/grupo e bloqueia força bruta no próprio portal.

O **Grafana** ainda é configurado para **login único (SSO)**: ele confia no cabeçalho `Remote-User` que o Authelia injeta (auth proxy), então o acesso é um login só — sem repetir no Grafana. Isso é seguro porque o Grafana só é alcançável via Traefik+Authelia e a confiança no cabeçalho é restrita à rede `edge`; o login local de admin do Grafana continua como reserva.

> Guarde os códigos de recuperação gerados no cadastro. Sem SMTP configurado, links de registro/reset vão para `/opt/platform/auth/notification.txt`.

---

## 3. Camadas que dependem de você

A maior parte já é automatizada (§2). O que **inerentemente** depende de você e do provedor:

### 3.1 Criptografia em repouso (disco) — provisão
Full-disk encryption (LUKS) protege os dados se o disco for copiado/roubado. É definida na **provisão** da VPS — a maioria dos provedores oferece a opção ao criar a máquina. Não dá para aplicar bem depois do sistema instalado.

### 3.2 Custódia da chave de backup e teste de restauração
Os backups (etapa 22) já são automáticos e cifrados com `age`. O que **só você** pode garantir:
- Guardar a **chave privada** `age` **off-site** (nunca no próprio servidor) — sem ela não há restauração.
- **Testar a restauração** periodicamente: `age -d -i chave.txt backup.age | tar xzf -`. Backup nunca restaurado não é backup.
- Configurar o destino off-site (rclone) para uma região/provedor diferente.

### 3.3 Segredos versionados (SOPS + age)
Nunca commite `.env` em texto puro. Antes de subir ao Git, criptografe:
```bash
age-keygen -o age.key
sops --encrypt --age "$(grep -oP 'public key: \K.*' age.key)" .env > .env.enc
```
Guarde a chave privada fora do repositório (cofre/gerenciador de segredos).

### 3.4 Banco de dados
- Senha `scram-sha-256` (padrão no Postgres moderno), forte e única.
- TLS na conexão da aplicação com o banco.
- Porta **nunca** exposta na internet — administração só por túnel SSH (`ssh -L`).

### 3.5 Validação ponta a ponta
Rode a **etapa 24** (`24-verify.sh`) após o deploy — ela confere cada camada (Traefik, observabilidade, 2FA, firewall, backups, CrowdSec, DNS). Nenhuma automação substitui rodar de fato na sua VPS e ver o self-check verde.

---

## 4. Rotina mínima

- **Pós-deploy / semanal:** rodar a etapa 24 (`24-verify.sh`) e conferir bans (`cscli decisions list`, `fail2ban-client status`) e portas (`ss -tulpen`).
- **A cada deploy:** scan de vulnerabilidade das imagens (Trivy no CI — etapa 17).
- **Mensal:** **testar a restauração** de um backup; conferir AIDE; revisar `~/.ssh/authorized_keys` e usuários com shell.
- **Sempre:** `.env` e `acme.json` em `chmod 600/640`; segredos fora do Git; chave privada de backup só off-site.

---

## 5. LGPD e dados sigilosos

Segurança técnica é necessária, mas não basta para conformidade legal. Se o servidor trata dados pessoais (LGPD):

- **Minimização:** colете e retenha só o necessário; defina prazos de retenção (inclusive para logs no Loki e backups).
- **Base legal e finalidade:** registre por que cada dado é tratado.
- **Criptografia:** em trânsito (TLS, já automático) e em repouso (LUKS + backups cifrados, §3).
- **Controle de acesso:** 2FA (etapas 20/21), menor privilégio e trilha de auditoria (`auditd`, etapa 20).
- **Registro de acessos:** os logs centralizados (Loki) ajudam a responder "quem acessou o quê".
- **Resposta a incidentes:** tenha um plano; a observabilidade + CrowdSec dão a detecção, mas a comunicação ao titular/ANPD em caso de vazamento é processo, não script.
- **Terceiros:** provedores de VPS/e-mail/off-site são operadores — verifique contratos e localização dos dados.

> Isto é orientação técnica, não aconselhamento jurídico. Para dados sensíveis, valide o tratamento com quem responde pela conformidade.

---

> Faz par com [`VPS_SETUP.md`](./VPS_SETUP.md) (aplicação passo a passo) e [`../Cyberseguranca/CYBERSEGURANCA.md`](../Cyberseguranca/CYBERSEGURANCA.md) (fundamentos de segurança para dev). Escrito para **Ubuntu 24.04 LTS**.
