#!/usr/bin/env bash
# NX-06 (KURA_BACKLOG_NEXT_ESTANDE): garante as 2 CONTAS DE TUTOR do estande, ambas com pet com foto no app do tutor.
#   principal : Tutor Demo Um  (tutor1-demo@kura.local)      -> Rex + Mimi   (convite registrado por este script)
#   reserva   : Tutor Demo Luna (tutor-demo-luna@kura.local) -> Thor         (conta criada por seed-demo-luna.sh)
# Uma conta de tutor pertence a UM tutor; por isso sao dois tutores diferentes, nao duas contas do mesmo.
# IDEMPOTENTE: se o login ja devolve 200, nada e' feito. Senao reemite o convite (POST /tutores/{id}/convite,
# cancela os anteriores) e registra a conta (POST /auth/register-invite, consentimento LEMBRETES).
# Falha (exit 1) se alguma conta nao logar no fim; nao cria tutor nem pet (isso e' do seed-demo*.sh).
#
# Senhas (NUNCA impressas): DEMO_SENHA (clinica), DEMO_SENHA_TUTOR (principal; default DemoTutor123),
# DEMO_SENHA_TUTOR_RESERVA (reserva; default DemoLuna123 = a que seed-demo-luna.sh grava). Env ou .env.
# Uso:  cd DevOps-Cloud && bash scripts/seed-demo-contas.sh
# Pre-requisitos: bash scripts/seed-demo.sh (+ seed-demo-luna.sh p/ a reserva) ja rodados; compose de pe; curl; python.
# Janela de bloqueio do tutor (medida na NX-06): 5 senhas erradas seguidas bloqueiam a conta por 15 min
# (AUTH_JANELA_BLOQUEIO_MINUTOS, default 15, o compose nao sobrescreve); passada a janela o proximo login destranca.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./scripts/lib-env.sh

API=${API:-http://localhost:8080}
TUTOR_API=${TUTOR_API:-http://localhost:8081}
EMAIL_CLINICA="demo@kura.local"
SENHA_CLINICA=${DEMO_SENHA:-}; [ -z "$SENHA_CLINICA" ] && SENHA_CLINICA=$(ler_chave_env DEMO_SENHA); SENHA_CLINICA=${SENHA_CLINICA:-SenhaDemo123!}
SENHA_PRINCIPAL=${DEMO_SENHA_TUTOR:-}; [ -z "$SENHA_PRINCIPAL" ] && SENHA_PRINCIPAL=$(ler_chave_env DEMO_SENHA_TUTOR); SENHA_PRINCIPAL=${SENHA_PRINCIPAL:-DemoTutor123}
SENHA_RESERVA=${DEMO_SENHA_TUTOR_RESERVA:-}; [ -z "$SENHA_RESERVA" ] && SENHA_RESERVA=$(ler_chave_env DEMO_SENHA_TUTOR_RESERVA); SENHA_RESERVA=${SENHA_RESERVA:-DemoLuna123}
EMAIL_PRINCIPAL="tutor1-demo@kura.local"; NOME_PRINCIPAL="Tutor Demo Um"
EMAIL_RESERVA="tutor-demo-luna@kura.local"

PY=python; command -v python >/dev/null 2>&1 || PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "erro: python/python3 nao encontrado." >&2; exit 2; }
BODY=$(mktemp); PAY=$(mktemp); trap 'rm -f "$BODY" "$PAY"' EXIT
nat() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
json() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[2],encoding="utf-8"))
for p in sys.argv[1].split("."):
    d=d[int(p)] if p.isdigit() else d[p]
sys.stdout.write(str(d))' "$1" "$(nat "$BODY")"; }

http() { # http <metodo> <url> [token]  (corpo em $PAY se nao vazio)  -> codigo
  local args=(-s -o "$BODY" -w '%{http_code}' -X "$1" "$2" -H 'Content-Type: application/json')
  [ -s "$PAY" ] && args+=(--data-binary "@$(nat "$PAY")")
  [ -n "${3:-}" ] && args+=(-H "Authorization: Bearer $3")
  curl "${args[@]}"
}
login_tutor() { printf '{ "email": "%s", "senha": "%s" }' "$1" "$2" > "$PAY"; http POST "$TUTOR_API/api/v1/auth/login"; }

printf '{ "dsEmail": "%s", "dsSenha": "%s" }' "$EMAIL_CLINICA" "$SENHA_CLINICA" > "$PAY"
[ "$(http POST "$API/api/v1/auth/login")" = "200" ] || { echo "ERRO: login da clinica $EMAIL_CLINICA falhou. Rode antes: bash scripts/seed-demo.sh" >&2; exit 1; }
TOKEN=$(json accessToken); ID_VETERINARIO=$(json usuario.id)

# --- principal -----------------------------------------------------------------
c=$(login_tutor "$EMAIL_PRINCIPAL" "$SENHA_PRINCIPAL")
if [ "$c" = "200" ]; then
  echo "pula   principal ($EMAIL_PRINCIPAL): login ja devolve 200"
elif [ "$c" = "423" ]; then
  echo "ERRO: conta principal BLOQUEADA (423: 5 senhas erradas, janela de 15 min). Aguarde e rode de novo; nao reemito convite." >&2; exit 1
else
  echo "info   principal: login devolveu $c — reemitindo convite e registrando"
  : > "$PAY"; c=$(http GET "$API/api/v1/tutores" "$TOKEN")
  [ "$c" = "200" ] || { echo "ERRO: GET /tutores devolveu $c" >&2; exit 1; }
  ID_TUTOR=$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
if isinstance(d,dict): d=d.get("items") or d.get("content") or []
for t in d:
    if t.get("nmTutor")==sys.argv[2]: print(t.get("id", t.get("idTutor"))); break' "$(nat "$BODY")" "$NOME_PRINCIPAL")
  [ -n "${ID_TUTOR:-}" ] || { echo "ERRO: tutor '$NOME_PRINCIPAL' nao existe (rode seed-demo.sh)" >&2; exit 1; }
  : > "$PAY"; c=$(http POST "$API/api/v1/tutores/$ID_TUTOR/convite" "$TOKEN")
  [ "$c" = "201" ] || { echo "ERRO: reemissao do convite devolveu $c" >&2; exit 1; }
  INVITE=$(json invite.nrToken)
  printf '{ "token": "%s", "senha": "%s", "aceites": [ { "tipo": "LEMBRETES", "versaoTermo": "v1.0", "aceito": true } ] }' "$INVITE" "$SENHA_PRINCIPAL" > "$PAY"
  c=$(http POST "$TUTOR_API/api/v1/auth/register-invite"); INVITE=""
  if [ "$c" = "201" ]; then echo "ok     principal registrado (201)"
  else echo "ERRO: register-invite devolveu $c" >&2; head -c 300 "$BODY" >&2; echo >&2; exit 1; fi
fi

# --- NX-08: vacina a vencer para Rex (+10 dias) e Mimi (+20 dias) -----------------
# A aba Saude do app do tutor le GET /api/v1/tutor/pets/{id}/vacinas (VW_VACINAS_VENCENDO: proxima dose nos
# proximos 30 dias, por pet). Sem vacina semeada a aba abre vazia. A data e' RELATIVA a hoje (UTC), por isso
# o seed precisa ser re-rodado no dia do evento. Pela API do .NET, como a clinica registra: POST
# /eventos-clinicos/vacinas. IDEMPOTENTE: se o pet ja tem proxima dose futura (GET /pets/{id}/proximas-vacinas
# nao vazio), nao cria outra.
FALHAS=0
vacina_pet() { # vacina_pet <nome_pet> <dias> <nome_vacina>
  local nome=$1 dias=$2 vac=$3 c id n dt agora payload
  : > "$PAY"; c=$(http GET "$API/api/v1/pets?pageSize=100" "$TOKEN")
  [ "$c" = "200" ] || { echo "FALHA  vacina $nome: GET /pets HTTP $c"; FALHAS=$((FALHAS+1)); return; }
  id=$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
for p in d:
    if p.get("nmPet")==sys.argv[2] and any(t.get("nmTutor")==sys.argv[3] for t in p.get("tutores",[])): print(p["id"]); break' "$(nat "$BODY")" "$nome" "$NOME_PRINCIPAL")
  [ -n "$id" ] || { echo "FALHA  vacina: pet $nome do tutor '$NOME_PRINCIPAL' nao existe (rode seed-demo.sh)"; FALHAS=$((FALHAS+1)); return; }
  : > "$PAY"; c=$(http GET "$API/api/v1/pets/$id/proximas-vacinas" "$TOKEN")
  n=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1],encoding="utf-8"))))' "$(nat "$BODY")" 2>/dev/null)
  if [ "$c" = "200" ] && [ "${n:-0}" -gt 0 ]; then echo "pula   vacina $nome (pet $id): ja tem $n proxima(s) dose(s)"; return; fi
  agora=$("$PY" -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))')
  dt=$("$PY" -c "import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=$dias)).strftime('%Y-%m-%dT%H:%M:%S.%fZ'))")
  printf '{ "idPet": %s, "idVeterinario": %s, "dtEvento": "%s", "dsObservacao": "Reforco anual - demo do estande (NX-08).", "nmVacina": "%s", "nrLote": "LOTE-DEMO-NX08", "dsFabricante": "Fabricante Demo", "dtProximaDose": "%s" }'     "$id" "$ID_VETERINARIO" "$agora" "$vac" "$dt" > "$PAY"
  c=$(http POST "$API/api/v1/eventos-clinicos/vacinas" "$TOKEN")
  if [ "$c" = "201" ]; then echo "ok     vacina $vac em $nome (pet $id): proxima dose em $dias dias"
  else echo "FALHA  vacina $nome: POST /eventos-clinicos/vacinas HTTP $c"; FALHAS=$((FALHAS+1)); fi
}
vacina_pet Rex 10 V10
vacina_pet Mimi 20 Triplice-Felina

# --- verificacao final das duas contas ------------------------------------------
verifica() { # verifica <rotulo> <email> <senha>
  local rot=$1 c tk r n nf nomes id urlfoto
  c=$(login_tutor "$2" "$3")
  if [ "$c" != "200" ]; then echo "FALHA  $rot ($2): login HTTP $c"; FALHAS=$((FALHAS+1)); return; fi
  tk=$(json accessToken)
  : > "$PAY"; c=$(http GET "$TUTOR_API/api/v1/tutor/pets" "$tk")
  if [ "$c" != "200" ]; then echo "FALHA  $rot: GET /tutor/pets HTTP $c"; FALHAS=$((FALHAS+1)); return; fi
  # a lista traz dsFotoThumbUrl; o detalhe traz dsFotoUrl (1080)
  r=$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
if isinstance(d,dict): d=d.get("content") or d.get("items") or []
f=[p for p in d if p.get("dsFotoThumbUrl")]
print(len(d), len(f), f[0].get("idPet") if f else "-", ",".join(str(p.get("nmPet")) for p in d))' "$(nat "$BODY")")
  n=$(echo "$r" | cut -d' ' -f1); nf=$(echo "$r" | cut -d' ' -f2); id=$(echo "$r" | cut -d' ' -f3); nomes=$(echo "$r" | cut -d' ' -f4-)
  if [ "$nf" -lt 1 ]; then echo "FALHA  $rot: nenhum pet com foto ($n pet(s): $nomes)"; FALHAS=$((FALHAS+1)); return; fi
  c=$(http GET "$TUTOR_API/api/v1/tutor/pets/$id" "$tk"); urlfoto=$(json dsFotoUrl)
  c=$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$urlfoto")
  case "$c" in "200 image/webp"*) echo "ok     $rot: login 200, $n pet(s) [$nomes], $nf com foto; GET da foto do pet $id = $c" ;;
    *) echo "FALHA  $rot: GET da foto do pet $id = $c"; FALHAS=$((FALHAS+1)) ;; esac
}
verifica principal "$EMAIL_PRINCIPAL" "$SENHA_PRINCIPAL"
verifica reserva "$EMAIL_RESERVA" "$SENHA_RESERVA"
echo "resumo: falhas=$FALHAS"
[ "$FALHAS" -eq 0 ]
