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
  ▼  ── Auditoria ───────────────────────────────────────────
  auditd                      registra acesso a arquivos sensíveis   → etapa 20
  AIDE                        detecta alteração de binários/config   → etapa 14
  Observabilidade             métricas e logs centralizados          → etapa 19
  │
  ▼  ── O dado ──────────────────────────────────────────────
  Segredos em .env (chmod 640), TLS no banco, backups criptografados → manual (§3)
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
| Observabilidade | 19 | `19-observability.sh` |
| Senha, core dumps, AppArmor, auditd, 2FA, userns | 20 | `20-hardening-extra.sh` |

---

## 3. Camadas que dependem de você

Automação não cobre tudo. Para **dados sigilosos**, estas são essenciais:

### 3.1 Criptografia em repouso (disco)
Full-disk encryption (LUKS) protege os dados se o disco for copiado/roubado. É definida na **provisão** da VPS — a maioria dos provedores oferece a opção ao criar a máquina. Não dá para aplicar bem depois do sistema instalado.

### 3.2 Segredos versionados
Nunca commite `.env` em texto puro. Criptografe com **SOPS + age**:
```bash
# Gera uma chave age e criptografa o .env antes de commitar
age-keygen -o age.key
sops --encrypt --age $(grep -oP 'public key: \K.*' age.key) .env > .env.enc
```
Guarde a chave privada fora do repositório (cofre de segredos / gerenciador).

### 3.3 Backups criptografados e off-site
```bash
docker exec <db> pg_dump -U user db | gzip | gpg --encrypt -r voce@exemplo.com > backup.sql.gz.gpg
```
Envie para armazenamento externo (outro provedor/região). Teste a restauração periodicamente.

### 3.4 Banco de dados
- Senha `scram-sha-256` (padrão no Postgres moderno), forte e única.
- TLS na conexão da aplicação com o banco.
- Porta **nunca** exposta na internet — administração só por túnel SSH (`ssh -L`).

### 3.5 WAF / IPS colaborativo (opcional, recomendado)
**CrowdSec** com um *bouncer* no Traefik bloqueia IPs maliciosos com base em inteligência compartilhada — uma camada a mais na borda.

---

## 4. Rotina mínima

- **Semanal:** revisar bans (`fail2ban-client status`), portas abertas (`ss -tulpen`), atualizações pendentes.
- **A cada deploy:** scan de vulnerabilidade das imagens (Trivy no CI — etapa 17).
- **Mensal:** conferir alterações do AIDE, revisar `~/.ssh/authorized_keys` e usuários com shell.
- **Sempre:** o `.env` da plataforma e o `acme.json` em `chmod 600/640`; segredos fora do Git.

---

> Faz par com [`VPS_SETUP.md`](./VPS_SETUP.md) (aplicação passo a passo) e [`../Cyberseguranca/CYBERSEGURANCA.md`](../Cyberseguranca/CYBERSEGURANCA.md) (fundamentos de segurança para dev). Escrito para **Ubuntu 24.04 LTS**.
