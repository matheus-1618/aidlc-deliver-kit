# Guia de Integração — AI-DLC Deliver Kit

Este guia responde: **"eu já tenho coisas deployadas do meu lado — como encaixo
o kit nelas?"**. Ele complementa o README (que descreve a instalação limpa)
com os cenários de adaptação, a tabela completa de variáveis e segredos, e a
verificação de cada etapa.

O princípio que guia toda decisão de integração:

> **A plataforma decide e registra; o SEU mecanismo de deploy executa; a SUA
> conta confia no OIDC.** O kit não substitui a sua esteira — ele a torna
> conduzível e rastreável de dentro de um intent. Tudo que é "seu" (pipeline,
> IaC, conta, repo) permanece seu; o que o kit exige é um CONTRATO, não uma
> ferramenta.

---

## 1. Pré-requisitos

| O quê | Detalhe |
|---|---|
| Plataforma Collaborative AI-DLC no ar | Testado no upstream `main` @ `bcd94d3` (set/2026). Em v2.0.0 funciona com uma diferença: a seleção de CLI é por projeto, não por intent |
| Acesso `platform-admin` | A autoria de blocos/workflows é restrita a esse grupo do Cognito |
| Egress do runtime → `api.githubcopilot.com` | O MCP do GitHub é um servidor HTTP remoto. Em rede fechada, allowlist esse domínio (não há VPC endpoint) |
| Repo GitHub com Actions habilitado | Onde o produto nasce e a pipeline roda |
| Conta AWS alvo + permissão de bootstrap | IAM (role/policy), S3 (bucket de state). Uma vez só, por conta |
| Quem cria PAT no GitHub | Fine-grained PAT exige permissão sobre o repo (owner ou org admin, dependendo da política da org) |

---

## 2. Mapa de encaixe — "eu já tenho X"

### 2.1 "Já tenho OIDC provider do GitHub na conta"

Comum (só pode existir UM `token.actions.githubusercontent.com` por conta).
Use `-var create_oidc_provider=false` no bootstrap — a role referencia o
provider existente. Confirme que a audience dele inclui `sts.amazonaws.com`:

```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::<CONTA>:oidc-provider/token.actions.githubusercontent.com \
  --query ClientIDList
```

### 2.2 "Já tenho uma role de deploy para o Actions"

Duas opções, em ordem de preferência:

- **Criar a role do kit ao lado da sua** (recomendado): a role do kit é
  escopada ao prefixo `deliver-*` — ela não alcança nada do que você já tem,
  e o blast radius do fluxo fica auditável separadamente.
- **Reusar a sua role**: adicione os repos do fluxo à trust policy (atenção ao
  formato do sub — ver §5.1) e garanta as permissões do flavor escolhido. Nesse
  caso adapte `DEPLOY_ROLE_ARN` nos workflows e ignore a role do bootstrap.

### 2.3 "Já tenho a MINHA esteira de deploy (Actions próprio, CodePipeline, Terraform Cloud…)"

**Este é o encaixe mais importante — e o kit foi desenhado para ele.** Você
NÃO precisa adotar o `deploy.yml` do kit. O que a plataforma consome é um
contrato de três pontos:

1. **Gatilho**: o deploy dispara com merge na branch default (é o que o
   `deploy-execute` provoca ao mergear o PR).
2. **Observabilidade**: a plataforma acompanha via API do GitHub Actions
   (`actions_list`/`actions_get`/`get_job_logs`). Se o seu Actions apenas
   *dispara* um CodePipeline, o job do Actions deve **esperar e refletir** o
   resultado (ex.: `aws codepipeline get-pipeline-execution` em loop até
   terminal), senão o run fica verde antes do deploy real.
3. **Saídas**: em algum step do job de deploy, imprima o bloco
   `deploy-outputs` (JSON) no log/summary:

```json
{"status":"deployed","url":"...","site_bucket":"...","distribution_id":"...","commit":"...","run_url":"...","deployed_at":"..."}
```

   As chaves `url`, `commit` e `run_url` são obrigatórias para qualquer
   flavor; as demais seguem o flavor (o sensor de manifest confere).

Checklist de adaptação de uma esteira existente:
- [ ] merge na default dispara o deploy (ou um wrapper Actions que dispara o
      seu mecanismo e espera)
- [ ] o job imprime `deploy-outputs` com as chaves do flavor
- [ ] existe um caminho de teardown disparável por `workflow_dispatch`
      (para o TTL e para o decommission via intent)
- [ ] o job de teardown termina com a auditoria por tag (copie o step do
      `destroy.yml.tmpl` — é ele que transforma "destruído" em "provado zero")

### 2.4 "Já tenho meus padrões de IaC (módulos, tags, nomenclatura)"

Os padrões viram um **flavor seu**. Copie um dos markdowns de
`blocks/knowledge/` e ajuste:

- estrutura canônica do repo (onde vive o IaC de vocês)
- o template (pode referenciar módulos internos em vez de recursos crus)
- os **invariantes** — a parte valiosa: nomeie o que NUNCA pode acontecer
  (recurso público, tag ausente, prefixo errado…)
- o contrato de outputs que a SUA pipeline emite

E ajuste o espelho determinístico: `blocks/sensors/deliver-flavor-conformance.ts`
valida os invariantes ANTES do merge — troque os checks pelos seus. Registre os
dois com uma entrada nova no `register.py`. **Flavor sem sensor é promessa;
flavor com sensor é garantia.**

### 2.5 "O repo já tem código/deploy legado (brownfield)"

Funciona — o guard dos workflows faz no-op enquanto a estrutura canônica não
existe, e `__SITE_DIR__` aponta para onde o conteúdo já mora. Cuidado
específico: **se o repo tem outro mecanismo de deploy vivo** (ex.: Amplify
conectado, webhook antigo), o merge do intent vai acordá-lo em paralelo.
Desative ou remova o mecanismo legado antes do primeiro intent, ou o ambiente
sobe duas vezes por caminhos diferentes.

### 2.6 "Já tenho bucket de tfstate"

Use o seu: pule o bucket do bootstrap e aponte `__TFSTATE_BUCKET__` para ele.
A key é namespaced por repo (`<org>/<repo>/terraform.tfstate`), então um
bucket compartilhado não colide.

### 2.7 "Uso GitHub Enterprise Server (on-prem)"

O MCP remoto (`api.githubcopilot.com`) atende github.com. Para GHES, o
caminho é o [github-mcp-server](https://github.com/github/github-mcp-server)
self-hosted apontando para a sua instância — registre a URL dele no lugar da
remota. O resto do kit não muda.

---

## 3. Variáveis e segredos — referência completa

### 3.1 Bootstrap (terraform, conta alvo)

| Variável | Obrigatória | Exemplo | Nota |
|---|---|---|---|
| `github_repos` | sim | `["org/repo"]` | Trust da role é POR REPO (least privilege) |
| `aws_region` | não (us-west-2) | `sa-east-1` | Região dos ambientes provisionados |
| `create_oidc_provider` | não (false) | `true` | `true` só se a conta não tem o provider |
| `project_tag` | não | `aidlc-deliver` | Tag do ENCANAMENTO (role, bucket de state) |

Outputs consumidos adiante: `deploy_role_arn`, `tfstate_bucket`, `aws_region`.

### 3.2 Workflows (placeholders dos templates)

Instancie com sed:

```bash
sed -e 's|__AWS_REGION__|us-west-2|g' \
    -e 's|__DEPLOY_ROLE_ARN__|arn:aws:iam::<CONTA>:role/aidlc-deliver-github-actions|g' \
    -e 's|__TFSTATE_BUCKET__|<output do bootstrap>|g' \
    -e 's|__SITE_DIR__|site|g' \
    workflows/deploy.yml.tmpl > .github/workflows/deploy.yml
sed -e 's|__AWS_REGION__|...|g' -e 's|__DEPLOY_ROLE_ARN__|...|g' \
    -e 's|__TFSTATE_BUCKET__|...|g' -e 's|__ENV_TAG__|deliver-<repo>|g' \
    workflows/destroy.yml.tmpl > .github/workflows/destroy.yml
```

| Placeholder | O que é |
|---|---|
| `__AWS_REGION__` | Região do deploy |
| `__DEPLOY_ROLE_ARN__` | Output `deploy_role_arn` do bootstrap (ou a sua role, §2.2) |
| `__TFSTATE_BUCKET__` | Output `tfstate_bucket` (ou o seu, §2.6) |
| `__SITE_DIR__` | Diretório do conteúdo estático (`site`; brownfield: onde já mora) |
| `__ENV_TAG__` | Tag do AMBIENTE, por repo (ex.: `deliver-meu-repo`). É o filtro da auditoria de teardown — **diferente** do `project_tag` do bootstrap, senão a auditoria acusa o próprio encanamento |

⚠ O valor de `__ENV_TAG__` precisa ser o MESMO em três lugares: no
`destroy.yml`, no `default_tags` do flavor (o register.py substitui via
`DELIVER_ENV_TAG`) e, por consequência, em tudo que o terraform criar.

### 3.3 GitHub PAT (o único segredo do fluxo)

Crie um **fine-grained PAT** em GitHub → Settings → Developer settings →
Fine-grained tokens:

| Campo | Valor |
|---|---|
| Repository access | **Only select repositories** → só o(s) repo(s) do fluxo |
| Contents | Read and write (criar branch de release/arquivos) |
| Pull requests | Read and write (abrir e mergear o PR) |
| Actions | Read and write (ler runs/logs; `write` habilita o re-run/dispatch do retry e do teardown) |
| Metadata | Read (implícito) |
| Expiração | Curta (30–90 dias) + rotação; o secret roda em SSM SecureString |

Não use PAT clássico de escopo largo, nem token OAuth de usuário: o PAT é
visível a TODAS as stages do intent (limitação atual da plataforma — MCP é por
projeto, não por stage), então o escopo do token É o raio de dano.

### 3.4 Registro na plataforma (register.py + MCP)

| Variável | Como obter |
|---|---|
| `AIDLC_API` | URL do API Gateway do deployment (ex.: `https://xxxx.execute-api.<região>.amazonaws.com/<env>`) |
| `AIDLC_TOKEN` | Id token do Cognito de um usuário platform-admin (a UI usa o mesmo; via SDK: auth SRP no user pool do deployment) |
| `DELIVER_ENV_TAG` | O `__ENV_TAG__` da §3.2 — o register.py injeta nos flavors |
| `--project-id` | Id do projeto na plataforma (o register.py binda o workflow nele) |

MCP no projeto (owner/admin do projeto):

```bash
# 1. o servidor (config NÃO carrega o segredo — só a referência ${GITHUB_PAT})
curl -X PUT -H "Authorization: $AIDLC_TOKEN" -H "Content-Type: application/json" \
  -d '{"customMcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_PAT}","X-MCP-Toolsets":"repos,pull_requests,actions"}}}}' \
  "$AIDLC_API/api/projects/<PROJECT_ID>/custom-mcp-servers"

# 2. o segredo (vai para SSM SecureString, nunca volta em GET)
curl -X PUT -H "Authorization: $AIDLC_TOKEN" -H "Content-Type: application/json" \
  -d '{"mcpSecrets":{"GITHUB_PAT":"github_pat_..."}}' \
  "$AIDLC_API/api/projects/<PROJECT_ID>/custom-mcp-servers/secrets"
```

⚠ **O header `X-MCP-Toolsets: repos,pull_requests,actions` não é opcional**:
sem ele o servidor remoto não expõe os tools de Actions e o `deploy-execute`
fica sem `actions_list`/`actions_run_trigger`.

---

## 4. Instalação com verificação por etapa

Cada etapa tem um "prova de vida" — não avance sem ele.

| # | Etapa | Prova de vida |
|---|---|---|
| 1 | Bootstrap terraform na conta alvo | `terraform output deploy_role_arn` responde |
| 2 | Workflows no repo | Push de qualquer coisa na default: run do `deploy-production` fica **verde em no-op** (guard: sem `infra/main.tf`, skip) |
| 3 | PAT + MCP no projeto | `POST $AIDLC_API/api/agents/verify-mcp` com `{"projectId":"...","mcpServers":{...igual §3.4...}}` → `ok: true` e a lista de tools contendo `merge_pull_request`, `actions_list`, `actions_run_trigger`, `get_job_logs`. **Esta chamada roda DE DENTRO do runtime** — valida egress e auth de uma vez |
| 4 | `register.py --project-id <id>` | Saída toda `[ok]`; depois `GET /api/workflows/aidlc-deliver/execution-preview?scope=deliver` → `valid: true`, 0 erros (2 warnings `scope_absent_*` são por desenho do scope lean) |
| 5 | Primeiro intent | Issue de dor real → New Intent → scope `deliver` → CLI claude → gates na UI → URL viva no gate final |
| 6 | Teardown | `destroy-production` (dispatch) → job verde **inclui** a auditoria por tag = zero recursos |

---

## 5. Troubleshooting (as pegadinhas que já custaram tempo)

### 5.1 `Not authorized to perform sts:AssumeRoleWithWebIdentity`

90% das vezes é o formato do **sub claim**. Repos podem ter *immutable
subject* habilitado e emitir `repo:org@ID/repo@ID:...` — o wildcard clássico
não casa. Verifique:

```bash
gh api repos/ORG/REPO/actions/oidc/customization/sub
```

O bootstrap do kit já cobre as DUAS formas. Se você reusa role própria (§2.2),
adicione o padrão `repo:org@*/repo@*:*` à trust policy.

### 5.2 O agente não tem os tools de Actions

Faltou o header `X-MCP-Toolsets` (§3.4). Rode o verify-mcp e confira a lista.

### 5.3 "Select an agent CLI before starting the intent"

No upstream atual o CLI vai **no body do start**:
`POST .../intents/<id>/start {"agentCli":"claude"}`. (Em v2.0.0 é config do
projeto.)

### 5.4 Gate respondido dá 409 "already answered"

Pode ser corrida com a resposta JÁ aplicada — confira o estado do gate antes de
re-tentar. E lembre: stage com `humanValidation` tem DOIS gates (a *question*
do agente + a *validation* da stage).

### 5.5 Sensor blocking "não apareceu"

PASS não gera evento visível (só *flagged*). A prova de execução está nos
registros `SENSOR#` da tabela `…-v2-executions-…` do DynamoDB, ou na stage
segurada quando FALHA.

### 5.6 Pipeline re-executada some do watcher

Re-run de um run falho sobe `run_attempt` no MESMO run id. A stage
`deploy-execute` (v2+) já lê o attempt mais novo — se você customizou a stage,
preserve essa regra.

### 5.7 Auditoria de teardown acusa recursos que "deviam" existir

O filtro é a tag `__ENV_TAG__`. Se o encanamento (role/state) compartilha a
mesma tag do ambiente, a auditoria nunca zera — ver o ⚠ da §3.2.

### 5.8 Rede fechada / proxy corporativo

O runtime precisa alcançar `api.githubcopilot.com` e `github.com` (allowlist;
não há VPC endpoint). Proxies que bufferizam SSE degradam o agente — idle
timeout de saída ≥ 120s.

---

## 6. O que o kit NÃO cobre (limitações honestas)

- **Tool por stage**: o MCP é por projeto — todas as stages do intent enxergam
  o PAT. Mitigação: escopo mínimo do fine-grained (§3.3). Solução de verdade é
  feature upstream (per-stage tool binding).
- **Visão viva cross-intent do ambiente**: o manifest registra o estado POR
  entrega (grafo + git). Uma aba "Environments" agregada é proposta upstream
  (o padrão já existe na plataforma para build environments).
- **Aprovação de release não é delegável a automação**: o release-gate é gate
  de DECISÃO — auto-approve nele quebra o desenho (e provavelmente a sua
  auditoria).
