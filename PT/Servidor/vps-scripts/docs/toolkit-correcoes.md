# Correções do toolkit de setup da VPS

Branch: `fix/toolkit-vps-k3s`, já mesclada na `main` (mesmo commit, `91ff721`). Um commit por
defeito, mensagens em português. Nada foi executado em servidor real.

## Como foi validado

- **Sintaxe e lint:** `bash -n` em todos os scripts alterados (19 arquivos); `shellcheck`
  sem erro em todos. Os avisos que restam são de linhas que já existiam (SC2010 em 07 e 17).
- **Harness de sandbox** (fora do repositório, em área de scratch): copia o toolkit,
  redireciona `/etc`, `/opt`, `/var/log`, `/var/backups`, `/home` e `/root` para uma pasta
  temporária, troca a checagem de root e substitui `ufw`, `kubectl`, `k3s`, `helm`, `docker`,
  `age`, `openssl s_client`, `unattended-upgrade`, `apt-config`, `setfacl` e `curl` por stubs
  que registram as chamadas. Respostas dos prompts vêm de arquivo. Cada script alterado roda
  até o fim com `set -u`, sem "variável não associada".
- **Antes e depois:** para os defeitos de segredo e de firewall, o mesmo teste foi rodado
  contra a versão anterior (`git archive HEAD`) e contra a versão nova.
- **Manifests:** `kubectl kustomize` (cliente v1.37.2) e `kubeconform -strict` com schemas
  do catálogo da comunidade para Traefik. Helm renderizado com `kube-prometheus-stack 93.4.0`,
  `loki 7.6.0` e `alloy 1.16.0` (versões fixadas).
- **Buscas proibidas** (no estado atual): nenhum `chmod 755` em diretório de segredo, nenhum
  `cat` de chave privada, nenhuma senha ou token em `echo`/`printf` para a tela, nenhum
  `latest` como tag (só texto de validação e um comentário), e `curl | sh` sem versão em
  dois pontos fora da lista (ver pendências).

### Limites da validação

- Não há cluster k3s de teste: os manifests foram validados por schema e render, não aplicados.
- Não houve teste real de SMTP, Telegram, Docker em produção nem da restauração do backup.
- Os pacotes `age` e `kubectl` do pod de backup (Alpine) e a imagem `alpine:3.22` ainda
  precisam ser confirmados na primeira execução.

## Incidente durante a validação (leia)

Durante um teste da etapa 25 o harness deixou o `k3s` real do próprio host ser chamado
(`k3s kubectl`, em modo de validação). A chamada falhou antes de enviar qualquer objeto
(`failed to download openapi`), então o esperado é que nada tenha sido criado. **Não consegui
confirmar isso**: o kubeconfig do host é legível só por root e não tenho acesso a ele.
Este host tem um serviço `k3s` ativo (escutando em 6443 e 80).

Ação recomendada: confirme se este host é de produção e rode, com sudo,
`sudo k3s kubectl get ns` e procure por `sdi sga siepe sigma sgoa sca mensageria operacao edge`.
Nenhum deles deveria ter sido criado por este trabalho. O harness foi corrigido para não
alcançar binários reais (o `PATH` da sandbox não inclui mais `/usr/local/bin`).

## Defeitos da lista original (1–13)

| # | Arquivo | Commit | O que mudou | Validação | Pendente |
|---|---|---|---|---|---|
| 1 | `29-k3s-new-project.sh` | `892711b` | Remove `${ISSUER_ANN}`/`${MW}` (eram variáveis não definidas). Exige tag fixa ou digest. Probes, requests/limits e seccomp. `Ingress` vira `IngressRoute` (`certResolver letsencrypt`). Gera `Namespace` e `kustomization.yaml`; **não aplica**. Namespace limitado à lista decidida (`lib/k3s.sh`). Novos: `lib/k3s.sh`, `templates/k3s/authelia-middleware.yaml`. | Rodada no harness com `latest` recusada e 2FA; `kustomize` e `kubeconform` válidos (8 recursos); nenhuma chamada `apply`. | — |
| 2 | `17-cicd-generator.sh` | `d7c88ff` | Job de deploy passa a executar o script de deploy (antes `script: exit`). Chave privada não é mais gerada na VPS nem impressa: o operador gera o par na máquina e cola só a pública, com `command=` fixo. `trivy-action@ed142fd0…` (v0.36.0) e `ssh-action@0ff4204d…` (v1.2.5) fixados por SHA. | Workflow gerado validado como YAML; nenhuma chave no log; `authorized_keys` com `command=`. | Actions `checkout`, `setup-*` e `gitleaks` continuam por tag (fora da lista). |
| 3 | `22-backups.sh`, `templates/backups/backup.sh`, `templates/backups/cronjob.yaml` | `8998c7d` | Sem geração nem impressão de chave privada `age`; só `age1…` validada. Backup vira `CronJob` no namespace `operacao`. Sem `|| true` mascarando erro (um `pg_dump` que falha faz o job terminar com erro). `grep` que abortava sem pods virou `awk`. Dump em texto (`--format=plain`). RBAC por `RoleBinding` em cada namespace. | Job rodado com kubectl simulado: sucesso e falha de `pg_dump` (exit 1). Template validado. | Ver nota T-41 e rclone. |
| 4 | `28-operator-user.sh`, `templates/k3s/operador-rbac.yaml` | `4cbd562`, `a44c4fe` | Não copia mais o `k3s.yaml` (admin). Cria `ServiceAccount operador-<usuário>` com `ClusterRole operador-leitura` (`get/list/watch`, sem Secrets, sem `pods/exec`). Token vai direto para o kubeconfig (600, umask 077). Remove o kubeconfig admin antigo. | Kubeconfig 600, sem cópia do admin, token fora do log; RBAC renderizado sem verbos de escrita nem `secrets`. | Rotação do token não é automática. |
| 5 | `26-k3s-observability.sh`, `templates/k3s/values/monitoring.yaml`, `templates/k3s/grafana-ingressroute.yaml`, `lib/k3s.sh` | `90842cc` | Senha do Grafana em Secret `grafana-admin` (chaves `admin-user`/`admin-password`); sai o `--set`. Gerada uma vez: reexecução não troca. Grafana por `IngressRoute`. Namespace `operacao`. Charts fixados. `helm` passa a falhar de verdade (`--wait`). `k8s_secret_from_vars` aceita `CHAVE=VARIAVEL`. | `helm template` dos três charts com o values gerado; Secret criado sem valor no argv; helper testado com `=` e `#` no valor. | — |
| 6 | `27-k3s-2fa.sh`, `templates/k3s/authelia.yaml` | `bfe6ccb` | Senha do admin entra no hash por stdin (não como argumento). Chaves do Authelia criadas só na primeira vez (antes eram regeneradas, o que quebraria o banco). Grafana protegido com Middleware no próprio namespace. Ingress com cert-manager vira `IngressRoute`. Imagem `4.38.19` (verificada no registry). | Secret criado a partir de arquivo; nenhum vazamento de senha no log; manifests validados. | — |
| 7 | `24-verify.sh` | `5911f95` | Namespace `operacao`. Checa `HelmChartConfig` do Traefik (ACME) em vez de ClusterIssuer. Backup por `CronJob` (`lastSuccessfulTime`), com aviso se ainda existir cron de host antigo. Domínios lidos de `IngressRoute`. | Rodada no harness sem erro de variável. | — |
| 8 | `25-k3s.sh`, `templates/k3s/traefik-acme.yaml`, `templates/k3s/clusterissuer.yaml` | `cc14eb2` | k3s v1.37.2+k3s1 pelo `install.sh` do commit `f6973cb8…`, conferido por sha256 (`ed01f89f…`) antes de rodar. Helm v3.22.1 com tarball conferido por sha256 (`896cf636…`). cert-manager e namespace `apps` removidos. ACME do Traefik via `HelmChartConfig` (resolvedor `letsencrypt`, HTTP-01, `/data/acme.json` persistente). `clusterissuer.yaml` marcado NÃO USAR. | Caminho de instalação testado com o instalador real verificado (sha ok). `HelmChartConfig` sem schema no catálogo (`skipped`), mas o `valuesContent` foi conferido como YAML. | `K3S.md` ainda descreve cert-manager e `apps` (fora do toolkit). |
| 9 | `05-ufw.sh`, `03-ssh-hardening.sh` | `be767c5` | SSH liberado só para os IPs da equipe (antes aberto ao mundo). Antes de ativar o UFW, confere a regra da porta SSH (`ufw show added`). A etapa 3 só reinicia o SSH com regra presente (antes `ufw allow … \|\| true` e reinício mesmo sem regra). | Com UFW ativo e sem regra: para antes do restart. Com a regra: segue. Sem IP válido: para antes de qualquer `ufw allow`. | IPv6 não tratado no campo da equipe. |
| 10 | `12-auto-updates.sh` | `f84fddf` | Mantém 03:30 e torna explícito `Automatic-Reboot-WithUsers`. Confere a configuração efetiva (`apt-config dump`): um arquivo que mude o horário faz a etapa parar. | Caso normal passa; `06:00` em arquivo extra é recusado com a mensagem. | — |
| 11 | `19-observability.sh`, `11-postgres.sh`, `templates/observability/compose.yml` | `51ab016`, `c14e707` | Token do Telegram e URL do webhook saem do YAML: arquivos 400, dono 65534, `bot_token_file`/`url_file` (existem na v0.28.0 fixada, verificado no código-fonte). Senha do Grafana não é impressa. `11` não gera nem mostra senha de banco. | Antes: o token aparecia no `alertmanager.yml` e a senha era impressa. Depois: nada disso aparece. | Docker mantém secrets em `.env` (600), não em Secret (ver pendências). |
| 12 | `07-folder-structure.sh`, `09-edge-proxy.sh` | `d9030d7` | `/opt/platform` continua em 750. O `.env` com segredos não é mais criado pela etapa 7; as etapas que gravam nele (9, 19, 21) o criam com 600. | Antes: `.env` criado; depois: não criado, `750` mantido. | Docker ainda usa `.env`. |
| 13 | `templates/k3s/*` | `892711b`, `bfe6ccb`, `cc14eb2`, `90842cc`, `c8e0c56` | `app-example.yaml`: probes, sem imagem de demo, tag fixa, IngressRoute, namespace previsto. `authelia.yaml`: probes, requests, sem Ingress com cert-manager, sem Middleware (vem por namespace). Middleware entre namespaces resolvido com cópia por namespace (sem `allowCrossNamespace`). | `kubeconform -strict` nos templates renderizados (exceto HelmChartConfig, sem schema). | — |

## Defeitos do segundo lote (observados no servidor)

| # | Arquivo | Commit | O que mudou | Validação | Pendente |
|---|---|---|---|---|---|
| 1 | `07-folder-structure.sh`, `lib/common.sh` (`grant_container_read`) | `d9030d7`, `51ab016` | Sem `755`. Pacote `acl` garantido. Para um contêiner não-root, `grant_container_read` dá `u:<uid>:x` nos diretórios até `/opt/platform` e `u:<uid>:r` só no arquivo. | `setfacl` chamado com UID 65534 nos diretórios do `alertmanager.yml`. | Procedimento só para Docker; no k3s não se usa ACL no host. |
| 2 | `19-observability.sh` | `51ab016` | Ver defeito 11 acima. Em k3s o segredo vai para Secret (já feito na etapa 26). | Antes/depois, token e senha. | — |
| 3 | `21-2fa-web.sh`, `templates/auth/compose.yml` | `feb4135` | SMTP testado com `AUTH LOGIN` (`openssl s_client`, STARTTLS na 587, TLS na 465) antes de gravar qualquer config. Até 3 tentativas; depois, escolha explícita entre modo arquivo ou abortar sem gravar. Modo registrado em `config.env` (`AUTHELIA_NOTIFIER_MODE`). Senha SMTP por stdin e só no `.env` (600). Hash do admin por stdin. Imagem `4.38.19`. | Antes: notificador SMTP gravado sem nenhum teste (0 chamadas ao `openssl`). Depois: credencial ruim cai no modo arquivo; credencial boa grava SMTP; nenhuma senha no log. | SMTP da SendPulse em Secret no k3s: não implementado (T-23 não está no repositório). |
| 4 | `12-auto-updates.sh` | `495e072` | Backup vai para `/var/backups/vps-setup` (700); `.bak` antigos em `apt.conf.d` são movidos. `unattended-upgrade --dry-run` ao final; falha ou "Ignoring file" reprova a etapa. | Antes: 2 `.bak` em `apt.conf.d`; depois: 0 e 2 movidos. Dry-run com falha ou com arquivo ignorado: exit 1. | Dry-run foi simulado; testar no host. |
| 5 | `03-ssh-hardening.sh`, `05-ufw.sh`, `lib/common.sh` (`has_authorized_key`) | `1750a6e` (+ `be767c5`) | Etapa 3 só reinicia o sshd se o usuário permitido tiver chave pública. Etapa 5 exige ao menos um usuário com chave antes de ativar o UFW. | Antes: SSH reiniciado sem chave (2 reinícios). Depois: parado antes do restart; com chave, segue. | — |

## Pendências (não corrigidas nesta rodada)

1. **`curl | sh` sem versão** em `08-docker.sh` (`get.docker.com`) e `23-crowdsec.sh`
   (`packagecloud … | bash`). Violam o critério de validação, mas não estavam na lista e a
   troca por repositório apt pinado precisa de teste em host real.
2. **T-41** (citado no defeito 3): o identificador não existe no repositório. Interpretei
   "trocar por CronJob" como o design implementado. Confirme.
3. **T-23** (credenciais SMTP da SendPulse em Secret): não está no repositório. Não implementado.
4. **Docker ainda usa `/opt/platform/.env`** (modo 600) para segredos (etapas 9, 19 e 21).
   Os dados da plataforma em k3s vão para Secrets, mas o caminho Docker não tem Secret.
   Decidir se o Docker continua no toolkit.
5. **Cópia off-site (rclone)** dos backups não foi migrada para o `CronJob`.
6. **Pod de backup**: `alpine:3.22` sem digest; `age` e `kubectl` vêm do Alpine em tempo de
   execução. Fixar digest e versões de pacote antes de produção.
7. **Token do operador** é de longa duração (Secret de ServiceAccount). Não há rotação automática.
8. **`K3S.md` e `VPS_SETUP.md`** ainda descrevem cert-manager, o namespace `apps` e o `Ingress`.
   Fora do toolkit, mas desatualizados.
9. **Ações de terceiros** em `17-cicd-generator.sh` (`checkout`, `setup-node`, `gitleaks`) continuam por tag.
10. **IPv6** não é tratado no campo de IPs da equipe (`05`).
11. **Sem teste em host real**: SMTP, Telegram, restauração de backup e aplicação dos manifests
    num cluster.
12. **Backup de Secrets**: o export inclui Secrets (necessários para restaurar). Quem tem a
    chave privada `age` lê tudo. Essa chave precisa ficar off-site, de forma verificada.

## Não alterado (fora de escopo)

`subir-canvas`, projetos pessoais do servidor de teste, migração SGOA/SIGMA, e qualquer
manifest do k3s em `infra`.

## Verificação de 19/11/2026

Revisão dos blockers que estavam listados no T-57 contra o estado atual da `main`:

| Script | Defeito listado | Situação |
|---|---|---|
| 17 | imprime chave privada | Corrigido: só instruções de `ssh-keygen`, sem impressão da chave |
| 22 | gera chave privada no servidor | Corrigido: só orienta gerar a chave fora do servidor |
| 26 | senha do Grafana na linha de comando | Corrigido: senha vai por arquivo temporário com permissão 600 |
| 28 | copia kubeconfig de administrador | Corrigido: kubeconfig de leitura por ServiceAccount |
| 29 | aborta por variável não definida | Não reproduzido: rodou até o fim, código 0, gerou manifests sem aplicar |

O 29 foi executado num container Ubuntu 24.04 descartável, com `k3s` e `kubectl` simulados
e respostas do prompt pela entrada padrão. Os passos que mexem no sistema (SSH, UFW,
reinício automático, fail2ban, k3s real) não podem ser validados em container. Continuam sem
teste em host real.
