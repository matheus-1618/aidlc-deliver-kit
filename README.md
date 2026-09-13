# AI-DLC Deliver Kit

Estende o Collaborative AI-DLC com a **última milha**: da ideia ao software
verificado em produção, com cada decisão, execução e evidência rastreada
dentro do intent. Provado ponta a ponta em 2026-09-11 (site no ar, sensor
blocking PASS, teardown auditado a zero).

> **Vai encaixar no que você já tem deployado?** Leia o
> [Guia de Integração](docs/INTEGRATION.md) — cenários de adaptação (OIDC/role/
> esteira/IaC existentes), tabela completa de variáveis e segredos (PAT), e a
> verificação prova-de-vida de cada etapa.

## A esteira

```
issue (dor real) ─► intent [scope deliver]
  intent-capture ─► requirements-analysis ─► code-generation
       ─► release-gate      gate HUMANO: PR + invariantes do flavor + custo → A/B
       ─► deploy-execute    agente merga via MCP; acompanha o GitHub Actions;
                            falha → diagnóstico parkeado → retry re-disparado
                            pelo próprio agente (actions_run_trigger)
       ─► deploy-verify     verificação independente da URL; manifest no repo
                            + grafo; sensor BLOCKING valida
  teardown: destroy-production (manual, TTL noturno, ou pedido no intent)
            — o job FALHA se a auditoria por tag achar 1 recurso sobrando
```

**Divisão de responsabilidade**: a plataforma decide e registra; o GitHub
Actions executa; a conta alvo confia no OIDC. Credencial de deploy não existe
nem no PR, nem na plataforma, nem no runtime.

## Estrutura

```
bootstrap/           terraform da CONTA ALVO: role OIDC por-repo (cobre sub
                     clássico E immutable-subject), bucket de tfstate.
                     A policy é escopada por prefixo deliver-*
workflows/           deploy.yml.tmpl + destroy.yml.tmpl — instancie com
                     sed (placeholders __AWS_REGION__ __DEPLOY_ROLE_ARN__
                     __TFSTATE_BUCKET__ __SITE_DIR__ __ENV_TAG__)
blocks/
  agents/            persona Release Manager (nunca segura credencial)
  knowledge/         os FLAVORS — static-site e lambda-backend: estrutura
                     canônica, template terraform verbatim, invariantes,
                     contrato de outputs, schema do manifest
  stages/            release-gate, deploy-execute, deploy-verify (prompts)
  sensors/           deliver-flavor-conformance (blocking, PRÉ-merge) e
                     deliver-manifest (blocking, PÓS-deploy)
scripts/register.py  registra TUDO na plataforma via API (idempotente) e
                     binda o workflow no projeto
```

## Instalação (conta e plataforma do cliente)

1. **Conta alvo**: `cd bootstrap && terraform apply -var 'github_repos=["org/repo"]'`
   (`-var create_oidc_provider=true` se a conta não tem o provider do GitHub)
2. **Repo**: instancie os dois workflows de `workflows/` em `.github/workflows/`
3. **MCP**: registre o GitHub MCP no projeto da plataforma —
   `PUT /api/projects/{id}/custom-mcp-servers` com
   `{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_PAT}","X-MCP-Toolsets":"repos,pull_requests,actions"}}}`
   e o PAT (fine-grained, só o repo: contents+PRs write, actions read/write)
   em `PUT .../custom-mcp-servers/secrets`. Sem o header `X-MCP-Toolsets`
   os tools de Actions NÃO aparecem.
4. **Plataforma**: `AIDLC_API=... AIDLC_TOKEN=... DELIVER_ENV_TAG=deliver-<repo> \
   ./scripts/register.py --project-id <id>`
5. **Dor real**: escreva uma issue com a dor + critérios + flavor sugerido,
   e crie o intent com scope `deliver` a partir dela.

## Garantias

- **Pré-merge**: sensor `deliver-flavor-conformance` (blocking) valida o
  `infra/main.tf` contra os invariantes do flavor — código fora do molde não
  chega nem na decisão humana
- **Decisão**: o release é um gate humano com PR, invariantes e custo na mesa
- **Pós-deploy**: sensor `deliver-manifest` (blocking) exige o manifest com
  URL https, HTTP 200 verificado e inventário de recursos
- **Estrutural**: a role de deploy só cria recursos `deliver-*`; nenhum flavor
  expõe IP público (CloudFront é a única face)
- **Fim de vida**: teardown com auditoria por tag que só fica verde provando
  ZERO recursos

## Trocar o mecanismo de deploy

O miolo é o `deploy.yml`. Para CodePipeline/vending/Terraform Cloud: mantenha
o CONTRATO (deploy-outputs JSON com status/url/commit/run_url + outputs
site_bucket/distribution_id/site_url) e troque a implementação. A plataforma
não muda uma linha.
