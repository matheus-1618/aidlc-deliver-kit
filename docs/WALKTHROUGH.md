# Walkthrough — do sample vanilla ao primeiro deploy conduzido pela plataforma

Roteiro **imperativo e sequencial**. Ponto de partida: você já tem o
[sample-collaborative-ai-dlc](https://github.com/aws-samples/sample-collaborative-ai-dlc)
deployado na sua conta (via `install.sh`) e consegue logar na UI como admin.
Ponto de chegada: um intent que nasce de uma ideia e termina com **um site no
ar, verificado, com manifest e teardown auditado** — tudo conduzido pela
plataforma.

Escrito para ser executado por você **ou pelo seu assistente de IA**: cada
passo diz o que rodar, o que esperar, e o que existe no mundo depois dele.
Se algo falhar, o passo aponta a seção de troubleshooting do
[INTEGRATION.md](INTEGRATION.md).

> Adaptações (já tenho OIDC/role/esteira/GitHub App/IaC próprios) NÃO estão
> aqui — este é o caminho limpo. Para encaixes, use o INTEGRATION.md §2.

---

## Passo 0 — Colete estes valores antes de começar

Preencha esta tabela. TODOS os passos referenciam estes nomes em
`<MAIUSCULAS>` — substitua sempre.

| Placeholder | O que é | Onde achar |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | Conta AWS onde a plataforma roda (e onde o demo vai deployar) | `aws sts get-caller-identity` |
| `<AWS_REGION>` | Região do seu deployment | O que você passou no `install.sh` |
| `<AIDLC_API>` | URL base da API da plataforma | Saída do `install.sh status` (API Gateway, ex.: `https://xxxx.execute-api.<região>.amazonaws.com/dev`) |
| `<USER_POOL_ID>` / `<CLIENT_ID>` | Cognito do deployment | `install.sh status` ou console Cognito |
| `<ADMIN_EMAIL>` / `<ADMIN_PASSWORD>` | Usuário platform-admin | O que você criou no install |
| `<GITHUB_ORG>` / `<GITHUB_REPO>` | O repo GitHub do demo | Você escolhe no Passo 2 |
| `<APP_URL>` | URL do frontend (CloudFront) | `install.sh status` |

Ferramentas na máquina: `git`, `gh` (autenticado: `gh auth status`),
`terraform >= 1.5`, `aws` CLI com credencial da conta, `python3`.

---

## Passo 1 — Clone o kit e faça o bootstrap da conta (5 min)

```bash
git clone <URL_DESTE_KIT> aidlc-deliver-kit && cd aidlc-deliver-kit/bootstrap

# A conta já tem OIDC provider do GitHub? (vazio = não tem)
aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[?contains(Arn, `token.actions`)]' --output text
```

- Saiu **vazio** → use `create_oidc_provider=true` abaixo.
- Saiu um ARN → use `false`.

```bash
terraform init
terraform apply \
  -var 'github_repos=["<GITHUB_ORG>/<GITHUB_REPO>"]' \
  -var 'aws_region=<AWS_REGION>' \
  -var 'create_oidc_provider=false'   # ou true, conforme acima
```

Digite `yes`. **Você acabou de criar**: a role `aidlc-deliver-github-actions`
(que o GitHub Actions vai assumir — só a partir DESSE repo) e um bucket de
tfstate para os ambientes.

**Guarde as 3 saídas** (vai usá-las no Passo 2):

```bash
terraform output
# deploy_role_arn = "arn:aws:iam::<AWS_ACCOUNT_ID>:role/aidlc-deliver-github-actions"
# tfstate_bucket  = "aidlc-deliver-tfstate-xxxxxxxx"
# aws_region      = "<AWS_REGION>"
```

✅ **Checkpoint**: `terraform output deploy_role_arn` imprime um ARN.

---

## Passo 2 — Prepare o repo do demo com a pipeline (10 min)

Crie um repo novo (ou use um vazio; brownfield → INTEGRATION §2.5):

```bash
gh repo create <GITHUB_ORG>/<GITHUB_REPO> --private --clone && cd <GITHUB_REPO>
mkdir -p .github/workflows
```

Instancie os dois workflows a partir dos templates do kit (substitua os 3
valores pelos outputs do Passo 1):

```bash
KIT=../aidlc-deliver-kit
sed -e 's|__AWS_REGION__|<AWS_REGION>|g' \
    -e 's|__DEPLOY_ROLE_ARN__|<deploy_role_arn>|g' \
    -e 's|__TFSTATE_BUCKET__|<tfstate_bucket>|g' \
    -e 's|__SITE_DIR__|site|g' \
    $KIT/workflows/deploy.yml.tmpl > .github/workflows/deploy.yml

sed -e 's|__AWS_REGION__|<AWS_REGION>|g' \
    -e 's|__DEPLOY_ROLE_ARN__|<deploy_role_arn>|g' \
    -e 's|__TFSTATE_BUCKET__|<tfstate_bucket>|g' \
    -e 's|__ENV_TAG__|deliver-<GITHUB_REPO>|g' \
    $KIT/workflows/destroy.yml.tmpl > .github/workflows/destroy.yml

# nenhum placeholder pode sobrar:
grep -rn "__" .github/workflows/ && echo "SOBROU PLACEHOLDER — corrija" || echo "ok"

git add .github && git commit -m "ci: deliver pipeline (deploy gated + teardown auditado)" && git push
```

**Você acabou de criar**: a esteira do repo. `deploy-production` roda em push
na `main` mas tem um guard — **enquanto não existir `infra/main.tf`, ele
termina verde sem fazer nada** (é esperado; quem cria a infra é o intent).

✅ **Checkpoint**: aba Actions do repo → run `deploy-production` do seu push →
**verde** (no-op). Se falhou em "Assume deploy role" → INTEGRATION §5.1.

⚠ **Anote**: o valor `deliver-<GITHUB_REPO>` que você usou em `__ENV_TAG__`.
Ele reaparece no Passo 5 como `DELIVER_ENV_TAG` — precisam ser IDÊNTICOS.

---

## Passo 3 — Crie o PAT e registre o MCP do GitHub no projeto (10 min)

### 3a. O projeto na plataforma

Na UI (`<APP_URL>`): crie (ou abra) o projeto e **conecte o repo
`<GITHUB_ORG>/<GITHUB_REPO>`** a ele (o fluxo normal de bind do sample).
Pegue o `<PROJECT_ID>`: está na URL (`/space/<PROJECT_ID>/...`) ou via API no
passo 3d.

### 3b. O PAT

GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate:

- Repository access: **Only select repositories** → só `<GITHUB_REPO>`
- Permissions → Contents: **Read and write**; Pull requests: **Read and
  write**; Actions: **Read and write** (Metadata: read vem junto)
- Expiração: 30–90 dias

Copie o token (`github_pat_...`). Ele será o ÚNICO segredo do fluxo.

### 3c. Token de admin da plataforma

```bash
pip install pycognito 2>/dev/null
python3 - <<'PY' > /tmp/aidlc-token
from pycognito import Cognito
u = Cognito('<USER_POOL_ID>', '<CLIENT_ID>',
            username='<ADMIN_EMAIL>', user_pool_region='<AWS_REGION>')
u.authenticate(password='<ADMIN_PASSWORD>')
print(u.id_token, end='')
PY
export AIDLC_API="<AIDLC_API>"
export AIDLC_TOKEN=$(cat /tmp/aidlc-token)
```

(Expira em ~1h — se mais tarde a API responder erro de auth, re-rode.)

### 3d. Registre o servidor MCP e o segredo

```bash
# lista projetos, se precisar do id:
curl -s -H "Authorization: $AIDLC_TOKEN" "$AIDLC_API/api/projects" | python3 -m json.tool | head -20

# o servidor (repare: o header carrega ${GITHUB_PAT} LITERAL — a plataforma resolve do SSM)
curl -s -X PUT -H "Authorization: $AIDLC_TOKEN" -H "Content-Type: application/json" \
  -d '{"customMcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_PAT}","X-MCP-Toolsets":"repos,pull_requests,actions"}}}}' \
  "$AIDLC_API/api/projects/<PROJECT_ID>/custom-mcp-servers"
# esperado: {"saved":true}

# o segredo (cole o PAT do 3b no lugar):
curl -s -X PUT -H "Authorization: $AIDLC_TOKEN" -H "Content-Type: application/json" \
  -d '{"mcpSecrets":{"GITHUB_PAT":"github_pat_SEU_TOKEN_AQUI"}}' \
  "$AIDLC_API/api/projects/<PROJECT_ID>/custom-mcp-servers/secrets"
# esperado: {"saved":true}
```

### 3e. PROVE que funciona (de dentro do runtime!)

```bash
curl -s -X POST -H "Authorization: $AIDLC_TOKEN" -H "Content-Type: application/json" \
  -d '{"projectId":"<PROJECT_ID>","mcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_PAT}","X-MCP-Toolsets":"repos,pull_requests,actions"}}}}' \
  "$AIDLC_API/api/agents/verify-mcp" | python3 -m json.tool | head -20
```

✅ **Checkpoint**: `"ok": true` e a lista de tools contém
`merge_pull_request`, `actions_list`, `actions_run_trigger`, `get_job_logs`.
Essa chamada executa NO container do agente — ela prova egress + PAT + config
de uma vez. Falhou? → INTEGRATION §5.2 (header) ou §5.8 (rede).

---

## Passo 4 — Suba a metodologia: blocos, workflow e scope (5 min)

```bash
cd ../aidlc-deliver-kit   # (ou onde clonou o kit)
export DELIVER_ENV_TAG="deliver-<GITHUB_REPO>"   # IDÊNTICO ao __ENV_TAG__ do Passo 2
python3 scripts/register.py --project-id <PROJECT_ID>
```

Saída esperada: uma linha `[ok]` para cada item (agent, 2 knowledge, 3
artifacts, 2 sensors, 3 stages, scope, workflow, scopeRef, 3 placements,
membership, bind do projeto) e `pronto.` no fim.

**Você acabou de criar na plataforma**: a persona Release Manager, os 2
flavors (static-site e lambda-backend), os sensores blocking
(conformance pré-merge + manifest pós-deploy), as 3 stages novas
(release-gate, deploy-execute, deploy-verify), o scope `deliver` e o workflow
`aidlc-deliver` (fork do aidlc-v2) — **já bindado ao seu projeto**.

✅ **Checkpoint**:

```bash
curl -s -H "Authorization: $AIDLC_TOKEN" \
  "$AIDLC_API/api/workflows/aidlc-deliver/execution-preview?scope=deliver" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print('valid:', d['valid'], '| erros:', len(d['errors']), '| stages:', len(d['plan']['stages']))"
# esperado: valid: True | erros: 0 | stages: 9
```

(2 warnings `scope_absent_*` são por desenho do scope lean — ignore.)

---

## Passo 5 — Rode o primeiro intent (30–40 min de run, ~4 interações suas)

Tudo na UI (`<APP_URL>`), projeto do Passo 3:

1. **New Intent**. Título ÚNICO (a branch deriva dele — títulos repetidos
   colidem branch). Ex.: `Status page: primeira entrega deliver`
2. Scope: **deliver** (já é o default do workflow). CLI: **claude**
3. Prompt — use este molde (o "MUST follow" é o que amarra o flavor):

   ```
   Build a small, polished single-page static website about <SEU TEMA>.
   Structure and infrastructure MUST follow the "Deliver Flavor: static-site"
   knowledge exactly: site content under site/ (plain HTML+CSS, no build
   step) and infra/main.tf using the flavor's Terraform template verbatim.
   Do not modify anything under .github/workflows/.
   ```

4. **Start**. Agora acompanhe o grid; o run vai te chamar nestes momentos:

| Quando | O que aparece | O que fazer |
|---|---|---|
| ~5 min | Gate de validação do `requirements-analysis` | Revisar e **Approve** |
| ~15 min | **release-gate**: "Release PR #1 to production?" com PR, invariantes conferidos, custo e rollback | Ler (é a decisão de release!) e responder **A** (Yes) |
| logo após | Gate de validação do release-gate | **Approve** |
| ~25 min | `deploy-execute` roda sozinho: merga o PR, acompanha o Actions | Nada — assista. Na aba Actions do repo o run `deploy-production` roda de verdade |
| ~30 min | **deploy-verify** parkeia com a URL viva | Abrir a URL 🎉 e dar o ack final |

✅ **Checkpoint**: intent **SUCCEEDED**; a URL CloudFront responde 200; o
artefato `environment-manifest` no intent lista bucket/distribution/commit/run;
o sensor `deliver-flavor-conformance` aparece verde no release-gate.

Se o Actions falhar no meio: a stage parkeia com o diagnóstico e a opção de
retry — **aprove o retry no gate** (o agente re-dispara sozinho). Não clique
em nada no GitHub.

---

## Passo 6 — Derrube provando zero (5 min)

Na aba Actions do repo → **destroy-production** → Run workflow. (Ou peça o
teardown num intent — o agente tem `actions_run_trigger`.)

✅ **Checkpoint**: o job termina verde e o step "Auditoria por tag" imprime
`Recursos remanescentes: 0`. A URL para de responder. Se o job FALHAR na
auditoria, ele lista exatamente o que sobrou — isso é feature, não bug.

Rede de segurança: o cron noturno (03:00) derruba qualquer ambiente que ficar
de pé — demo não atravessa a madrugada.

---

## O que você tem agora

- Uma esteira onde **a ideia entra por um intent e sai como software no ar**,
  com decisão humana registrada, execução pela SUA pipeline (OIDC, zero
  segredo de nuvem na plataforma), verificação independente, manifest
  auditável e teardown provado a zero
- Flavors como catálogo: um markdown novo em `blocks/knowledge/` + uma entrada
  no `register.py` = um novo arquétipo de infra disponível para os intents
- Para encaixar no que você JÁ tem (esteira própria, GitHub App, IaC padrão):
  [INTEGRATION.md](INTEGRATION.md) §2
