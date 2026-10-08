#!/usr/bin/env bash
# REC-05b (KURA_BACKLOG_RECEPCAO.md) — liga/desliga o Cloudflare quick tunnel que da URL
# publica as 3 APIs do compose LOCAL, para os apps hospedados na Vercel
# (kura-clinica.vercel.app / kura-tutor.vercel.app, rewrites /proxy/* dos vercel.json).
#
# Uso:
#   bash scripts/tunnel-up.sh          # sobe gateway + quick tunnel, reescreve os 2 vercel.json
#   bash scripts/tunnel-up.sh down     # derruba o cloudflared DESTE script + gateway (NAO toca nos kura_*)
#
# Pre-requisitos: compose de pe (oracle-db, kura-api, kura-tutor, luna-ai healthy),
# `cloudflared` no PATH (binario unico, SEM conta e SEM login), curl, node.
#
# A URL https://<aleatorio>.trycloudflare.com MUDA A CADA SUBIDA (reexecutar = URL nova =
# redeploy). Por isso o script reescreve os rewrites /proxy/{clinica,tutor,luna} dos
# vercel.json dos checkouts dos apps (CLINICA_APP_DIR, default ../mobile-clinica-rn;
# TUTOR_APP_DIR, default ../mobile-tutor-rn). NAO commita e NAO faz deploy.
#
# SEGURANCA: enquanto ligado, /clinica, /tutor e /luna ficam PUBLICOS na internet
# (qualquer um com a URL). O Oracle nao e roteado (ver tunnel/nginx.conf).
# GUARDA DA SENHA DEMO (I-1 do G2): a senha default da clinica demo esta no repo publico
# (seed-demo.sh). Antes de abrir o tunel o script tenta logar com ela; se o login funcionar,
# RECUSA subir. Defina DEMO_SENHA (env ou .env) e re-semeie, ou aceite o risco com
# TUNNEL_ACEITA_SENHA_PUBLICA=1.
#
# Este script NAO le o .env inteiro (nada de segredo exportado): o docker compose le o .env
# sozinho e `down` funciona sem ele.
set -u
cd "$(dirname "$0")/.." || exit 1
PORTA=8088
# O gateway tem de entrar no MESMO projeto/rede dos kura_* (nome do projeto = nome da pasta
# do clone; um clone com outro nome precisa exportar COMPOSE_PROJECT_NAME).
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-devops-cloud}"
CLINICA_APP_DIR="${CLINICA_APP_DIR:-../mobile-clinica-rn}"
TUTOR_APP_DIR="${TUTOR_APP_DIR:-../mobile-tutor-rn}"
TMPD="${TMPDIR:-${TEMP:-/tmp}}"
LOG="$TMPD/kura-cloudflared.log"
PIDFILE="$TMPD/kura-cloudflared.pid"
# credencial publica default (a mesma de seed-demo.sh); sobrescrevivel para testar a guarda
DEMO_EMAIL_PUBLICO="${DEMO_EMAIL_PUBLICO:-demo@kura.local}"
DEMO_SENHA_PUBLICA_DEFAULT="${DEMO_SENHA_PUBLICA_DEFAULT:-SenhaDemo123!}"

# Mata SO o cloudflared que este script iniciou (PID no arquivo). PID inexistente = segue.
matar_cloudflared() {
  [ -f "$PIDFILE" ] || return 0
  local pid win
  pid=$(cat "$PIDFILE" 2>/dev/null)
  rm -f "$PIDFILE"
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/winpid" ]; then
    win=$(cat "/proc/$pid/winpid")
    command -v taskkill >/dev/null 2>&1 && taskkill //F //PID "$win" >/dev/null 2>&1
  else
    kill "$pid" 2>/dev/null
  fi
  return 0
}

if [ "${1:-}" = "down" ]; then
  matar_cloudflared
  # direto no docker (nao no compose): o compose exige o .env para interpolar, o down nao.
  docker rm -f kura_tunnel_gateway >/dev/null 2>&1
  echo "Gateway removido (se existia)."
  echo "Tunel derrubado. Containers kura_* intocados:"
  docker ps --format '  {{.Names}} {{.Status}}' | grep kura_
  echo "Os vercel.json reescritos continuam modificados nos checkouts: descarte com"
  echo "  git -C $CLINICA_APP_DIR checkout -- vercel.json ; git -C $TUTOR_APP_DIR checkout -- vercel.json"
  exit 0
fi

command -v cloudflared >/dev/null || { echo "FALHA: cloudflared nao esta no PATH"; exit 1; }
for c in kura_oracle_db kura_dotnet_api kura_java_tutor kura_luna_ai; do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)
  [ "$st" = "healthy" ] || { echo "FALHA: $c nao esta healthy (estado: ${st:-ausente}). Suba o compose antes."; exit 1; }
done

# --no-deps: sobe SO o gateway; nunca recria os kura_*.
docker compose --profile tunnel up -d --no-deps tunnel-gateway || exit 1
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -sf "http://localhost:$PORTA/clinica/health" >/dev/null && break
  sleep 1
done
curl -sf "http://localhost:$PORTA/clinica/health" >/dev/null || { echo "FALHA: gateway local nao respondeu"; exit 1; }

# --- guarda da senha demo publica (ANTES de abrir qualquer tunel) ---
LOGIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"dsEmail\":\"$DEMO_EMAIL_PUBLICO\",\"dsSenha\":\"$DEMO_SENHA_PUBLICA_DEFAULT\"}" \
  "http://localhost:$PORTA/clinica/api/v1/auth/login")
if [ "$LOGIN_CODE" = "200" ]; then
  if [ "${TUNNEL_ACEITA_SENHA_PUBLICA:-}" = "1" ]; then
    echo "AVISO: a clinica demo ($DEMO_EMAIL_PUBLICO) aceita a senha PUBLICA do repo; seguindo por TUNNEL_ACEITA_SENHA_PUBLICA=1."
    echo "       Qualquer pessoa com a URL do tunel le os dados da demo."
  else
    echo "FALHA: o login $DEMO_EMAIL_PUBLICO com a senha PUBLICA do repo (seed-demo.sh) deu 200."
    echo "       Com o tunel aberto, qualquer pessoa com a URL entraria na clinica demo."
    echo "       Troque: defina DEMO_SENHA (env ou .env) e re-semeie (seed-demo.sh) - ou 'docker compose down -v'"
    echo "       e semeie de novo. Para aceitar o risco: TUNNEL_ACEITA_SENHA_PUBLICA=1 bash scripts/tunnel-up.sh"
    exit 1
  fi
fi

matar_cloudflared
sleep 1
: >"$LOG"
nohup cloudflared tunnel --no-autoupdate --url "http://localhost:$PORTA" >"$LOG" 2>&1 &
CF_PID=$!
echo "$CF_PID" >"$PIDFILE"

falhar() {  # $1 = mensagem
  echo "FALHA: $1"
  echo "---- ultimas linhas do log do cloudflared ($LOG) ----"
  tail -n 15 "$LOG"
  echo "-----------------------------------------------------"
  matar_cloudflared
  exit 1
}

URL=""
for i in $(seq 1 40); do
  # exclui api.trycloudflare.com (aparece na linha de ERRO do proprio cloudflared)
  URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" | grep -v '^https://api\.' | head -1)
  [ -n "$URL" ] && break
  kill -0 "$CF_PID" 2>/dev/null || break   # cloudflared ja morreu: nao espera os 40s
  sleep 1
done
[ -n "$URL" ] || falhar "cloudflared nao anunciou uma URL do quick tunnel"
# DNS do trycloudflare leva alguns segundos para propagar.
OK=""
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/clinica/health")" = "200" ] && { OK=1; break; }
  sleep 2
done
[ -n "$OK" ] || falhar "o tunel anunciou $URL mas /clinica/health nao respondeu 200 (vercel.json NAO reescritos)"
echo "Tunel no ar: $URL"

FALHOU=0
reescrever() {  # $1 = diretorio do app
  [ -f "$1/vercel.json" ] || { echo "  AVISO: $1/vercel.json nao existe - nao reescrito"; return; }
  node -e '
const fs = require("fs");
const [p, url] = process.argv.slice(1);
const s = fs.readFileSync(p, "utf8");
const pat = /("source":\s*"\/proxy\/(clinica|tutor|luna)\/:path\*",\s*"destination":\s*")[^"]*(")/g;
let n = 0;
const novo = s.replace(pat, (m, a, nome, c) => { n++; return a + url + "/" + nome + "/:path*" + c; });
JSON.parse(novo);
if (n === 0) { console.error("  FALHA: nenhum rewrite /proxy/* em " + p); process.exit(1); }
fs.writeFileSync(p, novo);
console.log("  " + p + ": " + n + " rewrites /proxy/* reescritos");
' "$1/vercel.json" "$URL" || FALHOU=1
}
echo "Reescrevendo os vercel.json locais (sem commit):"
reescrever "$CLINICA_APP_DIR"
reescrever "$TUTOR_APP_DIR"
[ "$FALHOU" = 0 ] || { echo "FALHA ao reescrever vercel.json"; exit 1; }
echo
echo "PROXIMO PASSO (deploy, manual - o script nao faz): em CADA app, a partir do checkout"
echo "com o vercel.json reescrito:  vercel deploy --prod"
echo "(um deploy disparado por push no git volta a usar o vercel.json COMMITADO.)"
echo "Derrubar: bash scripts/tunnel-up.sh down"
