#!/usr/bin/env bash
# preflight.sh — valida TODA suposição do walkthrough ANTES do passo 1.
# Feito para executores humanos E assistentes de IA: cada suposição silenciosa
# vira um PASS/FAIL alto e acionável. Saída != 0 = não comece a instalação.
#
# Uso:
#   export AIDLC_API=... USER_POOL_ID=... CLIENT_ID=... AWS_REGION=... \
#          ADMIN_EMAIL=... ADMIN_PASSWORD=... GITHUB_REPO=org/repo
#   ./scripts/preflight.sh
set -u

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n      → %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n      → %s\n' "$1" "$2"; WARN=$((WARN+1)); }

echo "== 1. Ferramentas locais =="
for t in git gh terraform aws python3 curl; do
  command -v "$t" >/dev/null && ok "$t" || bad "$t ausente" "instale antes de continuar"
done
TFV=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "0")
python3 -c "import sys; a=[int(x) for x in '$TFV'.split('.')[:2]]; sys.exit(0 if a>=[1,5] else 1)" 2>/dev/null \
  && ok "terraform $TFV (>= 1.5)" || bad "terraform $TFV" "precisa >= 1.5"
python3 -c "import pycognito" 2>/dev/null && ok "pycognito instalado" \
  || warn "pycognito ausente" "pip install pycognito (em macOS moderno use um venv: python3 -m venv .venv && .venv/bin/pip install pycognito)"

echo "== 2. Credenciais =="
gh auth status >/dev/null 2>&1 && ok "gh autenticado ($(gh api user --jq .login 2>/dev/null))" \
  || bad "gh não autenticado" "gh auth login"
ACC=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
[ -n "${ACC:-}" ] && ok "credencial AWS (conta $ACC)" || bad "credencial AWS" "configure AWS_PROFILE/credenciais"

echo "== 3. Variáveis do walkthrough =="
MISSING=0
for v in AIDLC_API USER_POOL_ID CLIENT_ID AWS_REGION ADMIN_EMAIL ADMIN_PASSWORD GITHUB_REPO; do
  if [ -z "${!v:-}" ]; then bad "\$$v não setada" "export $v=... (Passo 0 do walkthrough)"; MISSING=1
  else ok "\$$v setada"; fi
done
[ $MISSING -eq 1 ] && { echo; echo "Sete as variáveis e rode de novo."; exit 1; }

echo "== 4. Login na plataforma (Cognito SRP) =="
TOKEN=$(python3 - <<PY 2>/dev/null
from pycognito import Cognito
u = Cognito("$USER_POOL_ID", "$CLIENT_ID", username="$ADMIN_EMAIL", user_pool_region="$AWS_REGION")
u.authenticate(password="$ADMIN_PASSWORD")
print(u.id_token, end="")
PY
)
if [ -n "${TOKEN:-}" ]; then ok "autenticou; id_token obtido"
else bad "autenticação Cognito falhou" "confira USER_POOL_ID/CLIENT_ID/credenciais (e pycognito)"; echo; exit 1; fi
api() { curl -s -o /tmp/pf-body -w '%{http_code}' -m 20 -H "Authorization: $TOKEN" "$@"; }

echo "== 5. Rotas da plataforma que o kit consome (drift de versão!) =="
# Cada probe distingue 'rota existe' de 'rota não existe' (404/403 de gateway).
C=$(api "$AIDLC_API/api/projects")
[ "$C" = "200" ] && ok "GET /api/projects ($C)" || bad "GET /api/projects → $C" "API base errada ou usuário sem acesso"
C=$(api "$AIDLC_API/api/workflows")
[ "$C" = "200" ] && ok "GET /api/workflows ($C) — autoria de workflow presente" \
  || bad "GET /api/workflows → $C" "deployment sem as APIs de workflow: atualize a plataforma (upstream main >= set/2026)"
C=$(api "$AIDLC_API/api/blocks/stage")
[ "$C" = "200" ] && ok "GET /api/blocks/stage ($C) — block library presente" \
  || bad "GET /api/blocks/stage → $C" "APIs de blocos ausentes: atualize a plataforma"
C=$(api -X POST -H "Content-Type: application/json" -d '{}' "$AIDLC_API/api/agents/verify-mcp")
case "$C" in
  200|400|409) ok "POST /api/agents/verify-mcp existe ($C)";;
  403)     warn "verify-mcp → 403" "rota existe mas exige platform-admin/projeto — confira o grupo do usuário";;
  *)       bad "POST /api/agents/verify-mcp → $C" "rota ausente = plataforma anterior à seleção de credencial hierárquica. ATUALIZE (upstream main >= set/2026); sem ela o Passo 3e não valida e o fluxo é às cegas";;
esac
C=$(api "$AIDLC_API/api/workflows/aidlc-v2")
[ "$C" = "200" ] && ok "workflow base aidlc-v2 presente" || bad "GET /api/workflows/aidlc-v2 → $C" "seed da metodologia não rodou? install.sh status"

echo "== 6. GitHub =="
gh api "repos/$GITHUB_REPO" --jq .full_name >/dev/null 2>&1 && ok "repo $GITHUB_REPO acessível" \
  || warn "repo $GITHUB_REPO inacessível" "será criado no Passo 2? ok. Senão: confira o nome/permissão"
SUB=$(gh api "repos/$GITHUB_REPO/actions/oidc/customization/sub" --jq '.use_immutable_subject' 2>/dev/null)
if [ "$SUB" = "true" ]; then ok "immutable subject ATIVO (o bootstrap do kit já cobre — só não recorte a trust policy)"
elif [ "$SUB" = "false" ]; then ok "sub claim clássico"
else warn "não li a config de sub do repo" "se o AssumeRole falhar depois: INTEGRATION §5.1"; fi
OIDC=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[?contains(Arn, `token.actions`)]' --output text 2>/dev/null)
[ -n "$OIDC" ] && ok "OIDC provider do GitHub JÁ existe na conta → use create_oidc_provider=false" \
  || ok "sem OIDC provider do GitHub → use create_oidc_provider=true"

echo "== 7. Egress do runtime (indireto) =="
C=$(curl -s -o /dev/null -w '%{http_code}' -m 10 https://api.githubcopilot.com/ 2>/dev/null)
[ -n "$C" ] && [ "$C" != "000" ] && ok "api.githubcopilot.com alcançável DESTA máquina ($C)" \
  || warn "api.githubcopilot.com não alcançável desta máquina" "não conclui nada sobre o runtime — a prova real é o verify-mcp (Passo 3e)"
echo "      (o teste definitivo de egress DO RUNTIME é o Passo 3e do walkthrough)"

echo
echo "== RESULTADO: $PASS pass, $WARN warn, $FAIL fail =="
[ $FAIL -eq 0 ] && echo "Preflight OK — siga para o Passo 1 do walkthrough." || echo "Corrija os FAIL antes de começar."
exit $FAIL
