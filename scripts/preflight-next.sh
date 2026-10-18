#!/usr/bin/env bash
# NX-06 (KURA_BACKLOG_NEXT_ESTANDE): pre-voo do estande NEXT. Imprime PASSOU/FALHOU por item e sai != 0 se algum falhar.
# Itens: 5 servicos kura_* healthy e RestartCount=0; login das 2 contas de tutor; pets com foto (GET 200);
# login da clinica de demo; catalogo da Loja (10 itens, todos com imagem, aviso literal); 1 imagem da Loja
# 200 image/webp sem token; flag D-1 desligada na Luna; DEMO_SENHA propria do evento (diferente da publica).
# Nenhuma senha/token e' impresso. Rapido (< 60 s). Smoke completo (~minutos): --com-smoke.
# Uso:  cd DevOps-Cloud && bash scripts/preflight-next.sh [--com-smoke]
# Senhas: DEMO_SENHA, DEMO_SENHA_TUTOR, DEMO_SENHA_TUTOR_RESERVA (env ou .env; defaults em seed-demo-contas.sh).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./scripts/lib-env.sh

COM_SMOKE=0; [ "${1:-}" = "--com-smoke" ] && COM_SMOKE=1
API=${API:-http://localhost:8080}; TUTOR_API=${TUTOR_API:-http://localhost:8081}
cfg() { local v; eval "v=\${$1:-}"; [ -z "$v" ] && v=$(ler_chave_env "$1"); printf '%s' "${v:-$2}"; }
SENHA_PUBLICA="SenhaDemo123!"
DEMO_SENHA_REAL=$(cfg DEMO_SENHA "")
SENHA_CLINICA=${DEMO_SENHA_REAL:-$SENHA_PUBLICA}
SENHA_PRINCIPAL=$(cfg DEMO_SENHA_TUTOR DemoTutor123); SENHA_RESERVA=$(cfg DEMO_SENHA_TUTOR_RESERVA DemoLuna123)
EMAIL_PRINCIPAL="tutor1-demo@kura.local"; EMAIL_RESERVA="tutor-demo-luna@kura.local"
AVISO_LITERAL='Pré-lançamento: pagamento e entrega serão ativados quando os parceiros logísticos concluírem a integração. Nenhuma cobrança é feita.'

PY=python; command -v python >/dev/null 2>&1 || PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "erro: python/python3 nao encontrado." >&2; exit 2; }
BODY=$(mktemp); PAY=$(mktemp); trap 'rm -f "$BODY" "$PAY"' EXIT
nat() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
NF=0; NP=0
ok()  { echo "PASSOU  $1"; NP=$((NP+1)); }
bad() { echo "FALHOU  $1"; NF=$((NF+1)); }
json() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[2],encoding="utf-8"))
for p in sys.argv[1].split("."):
    d=d[int(p)] if p.isdigit() else d[p]
sys.stdout.write(str(d))' "$1" "$(nat "$BODY")" 2>/dev/null; }
http() { # http <metodo> <url> [token] -> codigo (corpo em $BODY; corpo de envio em $PAY se nao vazio)
  local args=(-s --max-time 15 -o "$BODY" -w '%{http_code}' -X "$1" "$2" -H 'Content-Type: application/json')
  [ -s "$PAY" ] && args+=(--data-binary "@$(nat "$PAY")")
  [ -n "${3:-}" ] && args+=(-H "Authorization: Bearer $3")
  curl "${args[@]}" 2>/dev/null || echo 000
}
login_tutor() { printf '{ "email": "%s", "senha": "%s" }' "$1" "$2" > "$PAY"; http POST "$TUTOR_API/api/v1/auth/login"; }

# 1. servicos
for n in kura_oracle_db kura_dotnet_api kura_java_tutor kura_luna_ai kura_mongo; do
  r=$(docker inspect -f '{{.State.Health.Status}} {{.RestartCount}}' "$n" 2>/dev/null || echo "ausente -")
  if [ "$r" = "healthy 0" ]; then ok "servico $n healthy, RestartCount=0"; else bad "servico $n: '$r' (esperado 'healthy 0')"; fi
done

# 2. contas de tutor + pets com foto
conta_tutor() { # conta_tutor <rotulo> <email> <senha>
  local c tk r id url
  c=$(login_tutor "$2" "$3")
  if [ "$c" != "200" ]; then bad "conta $1 ($2): login HTTP $c"; return; fi
  ok "conta $1 ($2): login 200"; tk=$(json accessToken)
  : > "$PAY"; c=$(http GET "$TUTOR_API/api/v1/tutor/pets" "$tk")
  r=$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8")); d=d.get("content") or [] if isinstance(d,dict) else d
f=[p for p in d if p.get("dsFotoThumbUrl")]
print(len(f), f[0].get("idPet") if f else "-")' "$(nat "$BODY")" 2>/dev/null)
  id=${r#* }
  if [ "$c" != "200" ] || [ "${r%% *}" = "0" ] || [ -z "$r" ]; then bad "conta $1: GET /tutor/pets HTTP $c, pets com foto = ${r%% *}"; return; fi
  c=$(http GET "$TUTOR_API/api/v1/tutor/pets/$id" "$tk"); url=$(json dsFotoUrl)
  c=$(curl -s --max-time 15 -o /dev/null -w '%{http_code} %{content_type}' "$url" 2>/dev/null)
  case "$c" in "200 image/webp"*) ok "conta $1: ${r%% *} pet(s) com foto; GET da foto do pet $id = $c" ;; *) bad "conta $1: GET da foto do pet $id = '$c'" ;; esac
}
conta_tutor principal "$EMAIL_PRINCIPAL" "$SENHA_PRINCIPAL"
conta_tutor reserva "$EMAIL_RESERVA" "$SENHA_RESERVA"

# 3. clinica
printf '{ "dsEmail": "demo@kura.local", "dsSenha": "%s" }' "$SENHA_CLINICA" > "$PAY"
c=$(http POST "$API/api/v1/auth/login"); TKC=""; if [ "$c" = "200" ]; then ok "login da clinica demo@kura.local 200"; TKC=$(json accessToken); else bad "login da clinica demo@kura.local HTTP $c"; fi

# 4. Loja (com o token da conta principal)
TK=""; c=$(login_tutor "$EMAIL_PRINCIPAL" "$SENHA_PRINCIPAL"); [ "$c" = "200" ] && TK=$(json accessToken)
: > "$PAY"; c=$(http GET "$TUTOR_API/api/v1/loja/catalogo?size=50" "$TK")
if [ "$c" != "200" ]; then bad "catalogo da Loja: HTTP $c (Mongo fora?)"; IMG=""
else
  r=$(AVISO="$AVISO_LITERAL" "$PY" -c 'import json,sys,os
d=json.load(open(sys.argv[1],encoding="utf-8")); it=d.get("content") or []
semimg=[i for i in it if not (i.get("imagem") or {}).get("url")]
print(len(it), len(semimg), "S" if d.get("aviso")==os.environ["AVISO"] else "N", (it[0].get("imagem") or {}).get("url","") if it else "")' "$(nat "$BODY")" 2>/dev/null)
  set -- $r; IMG=${4:-}
  if [ "${1:-0}" = "10" ] && [ "${2:-1}" = "0" ]; then ok "catalogo da Loja: 10 itens, todos com imagem"; else bad "catalogo da Loja: ${1:-?} itens, ${2:-?} sem imagem (esperado 10 / 0)"; fi
  if [ "${3:-N}" = "S" ]; then ok "catalogo da Loja: aviso literal de pre-lancamento"; else bad "catalogo da Loja: aviso literal ausente/diferente"; fi
fi
if [ -n "${IMG:-}" ]; then
  c=$(curl -s --max-time 15 -o /dev/null -w '%{http_code} %{content_type}' "$TUTOR_API$IMG" 2>/dev/null)
  case "$c" in "200 image/webp"*) ok "imagem da Loja sem token: $c" ;; *) bad "imagem da Loja sem token: '$c'" ;; esac
else bad "imagem da Loja: nenhuma URL para testar"; fi

# 5. flag D-1 desligada na Luna (ausente = desligada, e' o default)
f=$(docker exec kura_luna_ai printenv LEMBRETE_CONFIRMACAO_HABILITADO 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z')
case "${f:-false}" in false|0|"") ok "flag LEMBRETE_CONFIRMACAO_HABILITADO desligada na Luna (valor: '${f:-ausente}')" ;; *) bad "flag LEMBRETE_CONFIRMACAO_HABILITADO LIGADA na Luna ('$f')" ;; esac

# 6. DEMO_SENHA propria do evento (nunca imprime nenhuma das duas)
if [ -z "$DEMO_SENHA_REAL" ]; then bad "DEMO_SENHA nao definida: a clinica usa a senha publica padrao"
elif [ "$DEMO_SENHA_REAL" = "$SENHA_PUBLICA" ]; then bad "DEMO_SENHA igual a senha publica padrao"
else ok "DEMO_SENHA do evento difere da senha publica padrao"; fi

# 7. NX-08 (I-1): o DIA da clinica — o Hoje precisa de >= 4 agendamentos na data de hoje (fuso SP = UTC-3, sem horario de
# verao desde 2019). PREFLIGHT_DATA_HOJE=AAAA-MM-DD existe so' para provar por mutacao que o check morde (nao altera dado).
HOJE=${PREFLIGHT_DATA_HOJE:-$(date -u -d '3 hours ago' +%F)}
if [ -z "$TKC" ]; then bad "Hoje da clinica: sem token (login da clinica falhou)"
else
  : > "$PAY"; c=$(http GET "$API/api/v1/agenda?dataInicio=$HOJE&dataFim=$HOJE" "$TKC")
  n=$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(len([a for a in d.get("agendamentos",[]) if a.get("dsStatus")!="CANCELADO"]))' "$(nat "$BODY")" 2>/dev/null)
  if [ "$c" = "200" ] && [ "${n:-0}" -ge 4 ] 2>/dev/null; then ok "Hoje da clinica ($HOJE): $n agendamentos (>= 4)"
  else bad "Hoje da clinica ($HOJE): HTTP $c, ${n:-?} agendamentos (esperado >= 4) — rode seed-demo.sh no dia"; fi
  # fila da Luna: mesmo intervalo do chip de 7 dias do app (inicio = hoje-6, fim = hoje+1, exclusivo)
  INI7=$(date -u -d "$HOJE -6 days" +%F); FIM7=$(date -u -d "$HOJE +1 day" +%F)
  : > "$PAY"; c=$(http GET "$API/api/v1/luna/triagens?dataInicio=$INI7&dataFim=$FIM7&pageSize=100" "$TKC")
  n=$("$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8")); print(len(d.get("items",[])))' "$(nat "$BODY")" 2>/dev/null)
  if [ "$c" = "200" ] && [ "${n:-0}" -ge 1 ] 2>/dev/null; then ok "fila da Luna ($INI7..$HOJE): $n triagem(ns) (>= 1)"
  else bad "fila da Luna ($INI7..$HOJE): HTTP $c, ${n:-?} triagens (esperado >= 1) — rode seed-demo-luna.sh"; fi
fi

# 8. NX-08 (I-2): senhas dos tutores definidas e diferentes do default publico. Compara strings; NAO tenta login com o
# default (cada login errado conta para o bloqueio de 5 tentativas / 15 min). Nada e' impresso.
for par in "DEMO_SENHA_TUTOR:DemoTutor123" "DEMO_SENHA_TUTOR_RESERVA:DemoLuna123"; do
  k=${par%%:*}; def=${par#*:}; v=$(cfg "$k" "")
  if [ -z "$v" ]; then bad "$k nao definida (env/.env): a conta usaria a senha padrao publica"
  elif [ "$v" = "$def" ]; then bad "$k igual a senha padrao publica do script"
  else ok "$k definida e diferente do default"; fi
done

# 9. AVISO (nao conta como falha): listener em [::1]:8080/8081 que nao e' o Docker. No Windows o wslrelay escuta em ::1
# e pode servir resposta diferente da do 127.0.0.1; "localhost" resolve para ::1 primeiro em alguns clientes.
if command -v netstat >/dev/null 2>&1; then
  for porta in 8080 8081; do
    pid=$(netstat -ano 2>/dev/null | tr -d '' | grep -E "\[::1\]:${porta}[[:space:]].*LISTENING" | awk '{print $NF}' | head -1)
    [ -z "$pid" ] && continue
    nome=$(tasklist //FI "PID eq $pid" //NH 2>/dev/null | tr -d '' | awk 'NF{print $1; exit}')
    case "$nome" in
      com.docker*|docker*|vpnkit*) ;;
      *) echo "AVISO   [::1]:$porta ouvido por '${nome:-pid $pid}' (nao e' o Docker): suba os apps com EXPO_PUBLIC_API_BASE_URL=http://127.0.0.1:$porta" ;;
    esac
  done
fi

# 10. smoke opcional
if [ "$COM_SMOKE" = 1 ]; then
  out=$(bash scripts/smoke-contratos.sh 2>&1); rc=$?
  linha=$(printf '%s\n' "$out" | grep -E 'smoke-contratos.sh: ' | tail -1)
  if [ "$rc" = 0 ]; then ok "smoke-contratos.sh: $linha"; else bad "smoke-contratos.sh EXIT=$rc: $linha"; fi
fi

echo "resumo: PASSOU=$NP FALHOU=$NF"
[ "$NF" -eq 0 ]
