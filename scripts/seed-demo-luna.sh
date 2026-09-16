#!/usr/bin/env bash
# Seed de demonstracao da Luna — IDEMPOTENTE DE VERDADE (LU-15,
# KURA_BACKLOG_LUNA_AI). Ao contrario de scripts/seed-demo.sh (que FALHA de
# proposito se a clinica ja existir — decisao documentada la, TASK-58), este
# script pode ser rodado 2x seguidas e deixa o MESMO estado: nenhuma linha
# nova na segunda vez. Ver lu-15-report.md (workspace de planejamento) para a
# prova (contagens da 1a e da 2a execucao).
#
# O QUE ESTE SCRIPT FAZ (via HTTP real, endpoints reais — nunca INSERT a mao,
# exceto 1 UPDATE declarado abaixo, que nao tem NENHUM endpoint HTTP em
# nenhum dos 2 apps):
#   1. Reaproveita a clinica de demo (scripts/seed-demo.sh, precisa ja ter
#      rodado) — login com as credenciais fixas dela.
#   2. Um tutor novo NA MESMA clinica, com CPF fixo (marcador, ver abaixo),
#      registrado por convite (POST /auth/register-invite) com consentimento
#      LEMBRETES aceito — mesmo caminho que o app do tutor usa.
#   3. Um pet "Thor" (Cao/Labrador) vinculado a esse tutor.
#   4. Uma vacina aplicada em Thor com proxima dose em 3 dias (dentro da
#      janela de 7 dias que o LU-04 usa pra elegibilidade de lembrete).
#   5. 3 triagens pre-existentes (1 ALTA, 1 MEDIA, 1 BAIXA) para a fila do
#      app ("Fila da Luna", LU-09) nao nascer vazia — persistidas via
#      POST /api/v1/luna/interactions + POST /api/v1/luna/triage
#      (X-Api-Key), o MESMO par de endpoints que o InboundMessageService da
#      Luna chama depois de classificar uma mensagem real. As 3 mensagens e
#      seus valores de urgencia/score/sintomas vieram do motor de triagem
#      REAL (TriageEngine.classificar, luna/src/ai/triage_engine.py),
#      rodado localmente contra 3 mensagens do corpus rotulado
#      (luna/tests/fixtures/triagem_corpus_v1.jsonl) — nao sao numeros
#      inventados. Ver lu-15-report.md para a transcricao da rodada.
#
# ═══════════════════════════════════════════════════════════════════════════
# ACHADO registrado durante esta task (fora de escopo mudar codigo — LU-15 e
# so seed): TUTOR.DS_WHATSAPP (V1__initial_schema.sql:92, coluna nullable,
# distinta de TUTOR.DS_TELEFONE) e a coluna que VW_VACINAS_VENCENDO (V21) le
# para decidir pra onde mandar o lembrete de vacina (vacina_repo.py ->
# notification_service.py: sem ela, "falhas += 1", nunca ORA-, mas o
# lembrete real NAO sai). NENHUM endpoint HTTP de nenhum dos 2 backends
# escreve essa coluna — TutorCreateDto/TutorUpdateDto (.NET) so tem
# NrTelefone (mapeado para DS_TELEFONE, TutorConfiguration.cs:38-39); o
# Tutor.java do lado Java e read-only (comentario na propria V1: "TUTOR
# (.NET owns — Java read-only)") e so tem GETTER para dsWhatsapp. Por isso,
# e SO para esta coluna, este script faz um UPDATE declarado via
# `docker exec` no container kura_luna_ai (mesmo padrao do probe_sql.py do
# brief-comum: um script Python que instancia Settings() do proprio
# container para falar com o Oracle do compose) — nao ha outro caminho. E
# idempotente por construcao (mesmo WHERE ID_TUTOR=:id, mesmo valor).
# ═══════════════════════════════════════════════════════════════════════════
#
# Uso:
#   cd DevOps-Cloud
#   DEMO_WHATSAPP=<numero-do-apresentador-com-DDI> bash scripts/seed-demo-luna.sh
#
# DEMO_WHATSAPP: numero E.164 (ex.: 5511999998888) do WHATSAPP REAL de quem
# vai apresentar — NUNCA versionado, NUNCA impresso no log inteiro (so os 4
# ultimos digitos, ou nada). Sem a variavel: o script AINDA semeia tutor,
# pet, vacina e as 3 triagens (a fila do app funciona igual), mas avisa
# claramente que TUTOR.DS_WHATSAPP fica sem valor e o lembrete de vacina e a
# acao "Responder no WhatsApp" ficam sem numero de destino nesta demo.
#
# Pre-requisitos: os mesmos do smoke-contratos.sh — compose de pe (4/4
# healthy), curl, python (ou python3), docker no PATH. scripts/seed-demo.sh
# ja deve ter rodado (este script reaproveita a clinica dele).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

API=${API:-http://localhost:8080}
TUTOR_API=${TUTOR_API:-http://localhost:8081}

# Mesma logica de leitura do smoke-contratos.sh: aceita override por env var,
# senao le do .env deste repo (mesmo arquivo que o compose usa).
LUNA_API_KEY=${LUNA_API_KEY:-}
if [ -z "$LUNA_API_KEY" ] && [ -f .env ]; then
  LUNA_API_KEY=$(grep -m1 '^LUNA_API_KEY=' .env | cut -d= -f2-)
fi
if [ -z "$LUNA_API_KEY" ]; then
  echo "erro: LUNA_API_KEY nao definido (nem env var, nem .env) — necessario para semear as triagens." >&2
  exit 2
fi

PY=python
command -v python >/dev/null 2>&1 || PY=python3
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "erro: nem 'python' nem 'python3' encontrados no PATH." >&2
  exit 2
fi

BODY_FILE=$(mktemp)
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE"' EXIT

# ─── helpers (mesma logica de smoke-contratos.sh/seed-demo.sh) ─────────────
chamar() {  # chamar <nome> <esperado> <metodo> <url> <payload> [token] — FATAL
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5 token=${6:-}
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url" -H 'Content-Type: application/json')
  if [ -n "$payload" ]; then
    printf '%s' "$payload" > "$PAYLOAD_FILE"
    args+=(--data-binary "@$PAYLOAD_FILE")
  fi
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  local code; code=$(curl "${args[@]}")
  if [ "$code" != "$esperado" ]; then
    echo "ERRO   $nome: esperado $esperado, obtido $code" >&2
    head -c 500 "$BODY_FILE" >&2; echo >&2
    exit 1
  fi
  echo "ok     $nome ($code)"
}

# Igual a chamar(), mas NAO fatal — devolve o codigo em $ULTIMO_CODIGO para o
# chamador decidir o que fazer (usado nos checks de idempotencia).
chamar_ok() {  # chamar_ok <nome> <metodo> <url> <payload> [token]
  local nome=$1 metodo=$2 url=$3 payload=$4 token=${5:-}
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url" -H 'Content-Type: application/json')
  if [ -n "$payload" ]; then
    printf '%s' "$payload" > "$PAYLOAD_FILE"
    args+=(--data-binary "@$PAYLOAD_FILE")
  fi
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  ULTIMO_CODIGO=$(curl "${args[@]}")
  echo "ok     $nome ($ULTIMO_CODIGO)"
}

chamar_apikey() {  # chamar_apikey <nome> <esperado> <metodo> <url> <payload>
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url" -H 'Content-Type: application/json' -H "X-Api-Key: $LUNA_API_KEY")
  if [ -n "$payload" ]; then
    printf '%s' "$payload" > "$PAYLOAD_FILE"
    args+=(--data-binary "@$PAYLOAD_FILE")
  fi
  local code; code=$(curl "${args[@]}")
  if [ "$code" != "$esperado" ]; then
    echo "ERRO   $nome: esperado $esperado, obtido $code" >&2
    head -c 500 "$BODY_FILE" >&2; echo >&2
    exit 1
  fi
  echo "ok     $nome ($code)"
}

campo() {  # campo <caminho.pontilhado> — le do ULTIMO BODY_FILE
  "$PY" -c '
import json, sys
with open(sys.argv[2], "r", encoding="utf-8") as f:
    data = json.load(f)
cur = data
for p in sys.argv[1].split("."):
    cur = cur[int(p)] if p.isdigit() else cur[p]
sys.stdout.write(str(cur))
' "$1" "$BODY_FILE"
}

# Acha o primeiro item de um array JSON (top-level) cujo campo `chave` == `valor`;
# imprime o campo `campo_saida` desse item, ou vazio se nao achar nada.
achar_em_lista() {  # achar_em_lista <chave> <valor> <campo_saida>
  "$PY" -c '
import json, sys
chave, valor, campo_saida = sys.argv[1], sys.argv[2], sys.argv[3]
with open(sys.argv[4], "r", encoding="utf-8") as f:
    data = json.load(f)
for item in data:
    if str(item.get(chave)) == valor:
        sys.stdout.write(str(item.get(campo_saida, "")))
        sys.exit(0)
' "$1" "$2" "$3" "$BODY_FILE"
}

tamanho_lista() {  # tamanho de um array JSON top-level no ultimo BODY_FILE
  "$PY" -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
sys.stdout.write(str(len(data)))
' "$BODY_FILE"
}

# Conta, no envelope {items:[...]} de GET /luna/triagens, quantos items tem
# tutor.id == id_tutor. Usado como prova de idempotencia (nao conta triagens
# de OUTROS tutores que a clinica de demo ja tenha).
contar_triagens_do_tutor() {  # contar_triagens_do_tutor <id_tutor>
  "$PY" -c '
import json, sys
id_tutor = sys.argv[1]
with open(sys.argv[2], "r", encoding="utf-8") as f:
    data = json.load(f)
n = sum(1 for it in data.get("items", []) if str(it.get("tutor", {}).get("id")) == id_tutor)
sys.stdout.write(str(n))
' "$1" "$BODY_FILE"
}

agora_iso() { "$PY" -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))'; }
dt_mais_dias_iso() { "$PY" -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=$1)).strftime('%Y-%m-%dT%H:%M:%S.%fZ'))"; }

AGORA=$(agora_iso)
AGORA_MAIS_3=$(dt_mais_dias_iso 3)

# ─── 0. DEMO_WHATSAPP — nunca versionado, nunca impresso inteiro ───────────
DEMO_WHATSAPP=${DEMO_WHATSAPP:-}
if [ -z "$DEMO_WHATSAPP" ]; then
  echo "aviso  DEMO_WHATSAPP nao definido — semeando tutor/pet/vacina/triagens SEM numero de"
  echo "       WhatsApp real. TUTOR.DS_WHATSAPP ficara sem valor: o lembrete de vacina desta"
  echo "       demo vai contar como 'falha' (sem canal de envio) e a acao 'Responder no"
  echo "       WhatsApp' nao tera para onde mandar. A fila da Luna e as triagens funcionam"
  echo "       normalmente (nao dependem de WhatsApp)."
  TEM_WHATSAPP="N"
else
  DEMO_WHATSAPP_MASCARADO="****${DEMO_WHATSAPP: -4}"
  echo "ok     DEMO_WHATSAPP definido (final $DEMO_WHATSAPP_MASCARADO) — TUTOR.DS_WHATSAPP sera setado"
  TEM_WHATSAPP="S"
fi
echo

# ─── credenciais fixas da clinica de demo (scripts/seed-demo.sh) ───────────
EMAIL_ACESSO="demo@kura.local"
SENHA_CLINICA="SenhaDemo123!"

# CPF marcador — faixa 99000, mesmo algoritmo (modulo 11) de
# smoke-contratos.sh:gerar_cpf, a partir da raiz fixa [9,9,0,0,0,1,2,3,4].
# Fixo de proposito (idempotencia): 2a execucao busca por este CPF antes de
# criar qualquer coisa.
CPF_TUTOR_LUNA="99000123488"
NM_TUTOR_LUNA="Tutor Demo Luna WhatsApp"

echo "=== seed-demo-luna.sh — preparando dados de demonstracao da Luna ==="
echo

# ─── 1. Login na clinica de demo (reaproveita scripts/seed-demo.sh) ────────
PAYLOAD_LOGIN=$(cat <<JSON
{ "dsEmail": "$EMAIL_ACESSO", "dsSenha": "$SENHA_CLINICA" }
JSON
)
chamar_ok "auth/login (clinica de demo)" POST "$API/api/v1/auth/login" "$PAYLOAD_LOGIN" ""
if [ "$ULTIMO_CODIGO" != "200" ]; then
  echo "ERRO: login na clinica de demo ($EMAIL_ACESSO) falhou ($ULTIMO_CODIGO)." >&2
  echo "Este script reaproveita a clinica criada por scripts/seed-demo.sh — rode-o primeiro:" >&2
  echo "  bash scripts/seed-demo.sh" >&2
  exit 1
fi
TOKEN=$(campo accessToken)
ID_VETERINARIO=$(campo usuario.id)
echo "ok     login (idVeterinario=$ID_VETERINARIO)"
echo

# ─── 2. Tutor — idempotente por CPF marcador ───────────────────────────────
chamar "tutores/busca (idempotencia)" 200 GET "$API/api/v1/tutores?busca=$CPF_TUTOR_LUNA" '' "$TOKEN"
ID_TUTOR_LUNA=$(achar_em_lista "nrCpf" "$CPF_TUTOR_LUNA" "id")

if [ -n "$ID_TUTOR_LUNA" ]; then
  echo "ok     tutor ja existe (id=$ID_TUTOR_LUNA) — pulando criacao/registro"

  # ─── LU-16 G4, achado A1 (BLOQUEANTE) ────────────────────────────────────
  # Este ramo de idempotencia NUNCA atualizava nrTelefone (-> DS_TELEFONE) — so
  # a criacao (linha ~262, TELEFONE_CONTATO) e so o bloco 3 abaixo (DS_WHATSAPP)
  # setavam telefone. DS_TELEFONE (busca EXATA de
  # GET /api/v1/tutores/telefone/{numero}, o que o InboundMessageService da Luna
  # chama) e DS_WHATSAPP (o que VW_VACINAS_VENCENDO le) sao colunas DIFERENTES.
  # Consequencia medida pelo G4: apos UMA execucao sem DEMO_WHATSAPP (que fixa
  # DS_TELEFONE no placeholder 11990000000), qualquer execucao seguinte COM
  # DEMO_WHATSAPP corrige so DS_WHATSAPP (bloco 3) — DS_TELEFONE fica preso pra
  # sempre, e o numero que o Twilio de fato entrega (E.164 sem '+') nunca bate
  # com DS_TELEFONE. Resultado: o Ato 1 do roteiro (mensagem real do
  # apresentador) cai no caminho de "tutor nao identificado".
  #
  # Fix: sempre que DEMO_WHATSAPP estiver definido, tambem alinhar DS_TELEFONE
  # com ele — via PUT /api/v1/tutores/{id} (endpoint real, TutorUpdateDto exige
  # os 4 campos, entao busca os outros 3 antes de reenviar). Idempotente por
  # construcao: se ja bate, pula o PUT.
  if [ "$TEM_WHATSAPP" = "S" ]; then
    NR_TELEFONE_ATUAL=$(achar_em_lista "nrCpf" "$CPF_TUTOR_LUNA" "nrTelefone")
    if [ "$NR_TELEFONE_ATUAL" = "$DEMO_WHATSAPP" ]; then
      echo "ok     DS_TELEFONE ja bate com DEMO_WHATSAPP (final $DEMO_WHATSAPP_MASCARADO) — nada a fazer"
    else
      NM_TUTOR_ATUAL=$(achar_em_lista "nrCpf" "$CPF_TUTOR_LUNA" "nmTutor")
      EMAIL_TUTOR_ATUAL=$(achar_em_lista "nrCpf" "$CPF_TUTOR_LUNA" "dsEmail")
      PAYLOAD_TUTOR_UPDATE=$(cat <<JSON
{
  "nmTutor": "$NM_TUTOR_ATUAL",
  "nrCpf": "$CPF_TUTOR_LUNA",
  "dsEmail": "$EMAIL_TUTOR_ATUAL",
  "nrTelefone": "$DEMO_WHATSAPP"
}
JSON
)
      chamar "tutores/{id} (corrige DS_TELEFONE p/ formato do webhook, A1)" 200 PUT "$API/api/v1/tutores/$ID_TUTOR_LUNA" "$PAYLOAD_TUTOR_UPDATE" "$TOKEN"
      echo "ok     DS_TELEFONE realinhado com DS_WHATSAPP (final $DEMO_WHATSAPP_MASCARADO) — Ato 1 volta a casar"
    fi
  else
    echo "aviso  DEMO_WHATSAPP nao definido — DS_TELEFONE do tutor existente NAO foi tocado"
    echo "       (pode estar divergente de DS_WHATSAPP; sem WhatsApp real nesta demo isso nao importa)"
  fi
else
  echo "ok     tutor ainda nao existe — criando"
  # NrTelefone (campo de contato do CRM, distinto de DS_WHATSAPP): usa o
  # proprio DEMO_WHATSAPP quando disponivel (o apresentador tambem e o
  # "telefone" cadastral do tutor nesta demo), senao um placeholder fixo.
  TELEFONE_CONTATO=${DEMO_WHATSAPP:-11990000000}
  PAYLOAD_TUTOR=$(cat <<JSON
{
  "nmTutor": "$NM_TUTOR_LUNA",
  "nrCpf": "$CPF_TUTOR_LUNA",
  "dsEmail": "tutor-demo-luna@kura.local",
  "nrTelefone": "$TELEFONE_CONTATO",
  "dsCanalConvite": "EMAIL"
}
JSON
)
  chamar "tutores (criar tutor Luna)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR" "$TOKEN"
  ID_TUTOR_LUNA=$(campo id)
  INVITE_TOKEN=$(campo invite.nrToken)

  # Completa o registro pelo caminho REAL do app do tutor — mesmo payload de
  # smoke-contratos.sh bloco 9 — com consentimento LEMBRETES aceito.
  PAYLOAD_REGISTER_INVITE=$(cat <<JSON
{
  "token": "$INVITE_TOKEN",
  "senha": "DemoLuna123",
  "aceites": [
    { "tipo": "LEMBRETES", "versaoTermo": "v1.0", "aceito": true }
  ]
}
JSON
)
  chamar "tutor/auth/register-invite (consentimento LEMBRETES)" 201 POST "$TUTOR_API/api/v1/auth/register-invite" "$PAYLOAD_REGISTER_INVITE"
  echo "ok     tutor criado e registrado (id=$ID_TUTOR_LUNA)"
fi
echo

# ─── 3. DS_WHATSAPP — UPDATE declarado (nenhum endpoint HTTP escreve isso) ─
if [ "$TEM_WHATSAPP" = "S" ]; then
  cat > "$PAYLOAD_FILE.py" <<PYEOF
import sys
from src.config.settings import Settings
from src.db.connection import OracleConnectionPool

settings = Settings()
pool = OracleConnectionPool(
    dsn=settings.ORACLE_DSN,
    user=settings.ORACLE_USER,
    password=settings.ORACLE_PASSWORD,
)
id_tutor = int(sys.argv[1])
whatsapp = sys.argv[2]
with pool.get_connection() as conn:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE TUTOR SET DS_WHATSAPP = :whatsapp WHERE ID_TUTOR = :id_tutor",
            {"whatsapp": whatsapp, "id_tutor": id_tutor},
        )
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT DS_WHATSAPP FROM TUTOR WHERE ID_TUTOR = :id_tutor", {"id_tutor": id_tutor})
        row = cur.fetchone()
        valor = row[0] if row else None
        # nunca imprimir o numero inteiro — so confirmar que bate com o final.
        print("OK" if valor is not None and str(valor).endswith(whatsapp[-4:]) else "DIVERGE")
PYEOF
  docker cp "$PAYLOAD_FILE.py" kura_luna_ai:/tmp/seed_luna_whatsapp.py >/dev/null
  RESULTADO_WHATSAPP=$(MSYS_NO_PATHCONV=1 docker exec -w /tmp -e PYTHONPATH=/app kura_luna_ai python /tmp/seed_luna_whatsapp.py "$ID_TUTOR_LUNA" "$DEMO_WHATSAPP")
  rm -f "$PAYLOAD_FILE.py"
  if [ "$RESULTADO_WHATSAPP" = "OK" ]; then
    echo "ok     TUTOR.DS_WHATSAPP atualizado (confirmado pelos 4 ultimos digitos, final $DEMO_WHATSAPP_MASCARADO)"
  else
    echo "ERRO: UPDATE de DS_WHATSAPP nao confirmou (resultado=$RESULTADO_WHATSAPP)" >&2
    exit 1
  fi
else
  echo "aviso  pulando UPDATE de DS_WHATSAPP (DEMO_WHATSAPP nao definido)"
fi
echo

# ─── 4. Pet Thor (Cao/Labrador) — idempotente por nome dentro do tutor ─────
chamar "pets (busca por tutor, idempotencia)" 200 GET "$API/api/v1/pets?tutorId=$ID_TUTOR_LUNA" '' "$TOKEN"
ID_PET_THOR=$(achar_em_lista "nmPet" "Thor" "id")

if [ -n "$ID_PET_THOR" ]; then
  echo "ok     pet Thor ja existe (id=$ID_PET_THOR) — pulando criacao"
else
  PAYLOAD_PET_THOR=$(cat <<JSON
{
  "idEspecie": 1,
  "idRaca": 1,
  "nmPet": "Thor",
  "dtNascimento": "2021-05-10T00:00:00Z",
  "sgSexo": "M",
  "sgPorte": "G",
  "idTutor": $ID_TUTOR_LUNA,
  "stPrincipal": true,
  "dsVinculo": "PROPRIETARIO"
}
JSON
)
  chamar "pets (criar Thor, Cao/Labrador)" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET_THOR" "$TOKEN"
  ESPECIE_OBTIDA=$(campo nmEspecie); RACA_OBTIDA=$(campo nmRaca)
  if [ "$ESPECIE_OBTIDA" != "Cao" ] || [ "$RACA_OBTIDA" != "Labrador" ]; then
    echo "ERRO: catalogo de referencia mudou — esperado Cao/Labrador, obtido $ESPECIE_OBTIDA/$RACA_OBTIDA." >&2
    exit 1
  fi
  ID_PET_THOR=$(campo id)
  echo "ok     pet Thor criado (id=$ID_PET_THOR)"
fi
echo

# ─── 5. Vacina aplicada, proxima dose em 3 dias — idempotente por janela ───
chamar "pets/{id}/proximas-vacinas (idempotencia)" 200 GET "$API/api/v1/pets/$ID_PET_THOR/proximas-vacinas" '' "$TOKEN"
QTD_VACINAS_PENDENTES=$(tamanho_lista)

if [ "$QTD_VACINAS_PENDENTES" -gt 0 ]; then
  echo "ok     Thor ja tem $QTD_VACINAS_PENDENTES vacina(s) com proxima dose futura — pulando criacao"
else
  PAYLOAD_VACINA=$(cat <<JSON
{
  "idPet": $ID_PET_THOR,
  "idVeterinario": $ID_VETERINARIO,
  "dtEvento": "$AGORA",
  "dsObservacao": "Dose de reforco aplicada - demo Luna (LU-15).",
  "nmVacina": "V10",
  "nrLote": "LOTE-DEMO-LUNA",
  "dsFabricante": "Fabricante Demo",
  "dtProximaDose": "$AGORA_MAIS_3"
}
JSON
)
  chamar "eventos-clinicos/vacinas (Thor, proxima dose em 3 dias)" 201 POST "$API/api/v1/eventos-clinicos/vacinas" "$PAYLOAD_VACINA" "$TOKEN"
  echo "ok     vacina aplicada em Thor, proxima dose em 3 dias"
fi
echo

# ─── 6. 3 triagens (ALTA/MEDIA/BAIXA) via caminho real dos endpoints Luna ──
# Mensagens + urgencia/score/sintomas vieram do motor real (ver cabecalho e
# lu-15-report.md). DS_REGRAS_VERSAO="1.3" (nao 1.1 — backlog §LU-16 envelheceu).
chamar "luna/triagens (contagem antes)" 200 GET "$API/api/v1/luna/triagens?pageSize=100" '' "$TOKEN"
QTD_TRIAGENS_ANTES=$(contar_triagens_do_tutor "$ID_TUTOR_LUNA")
echo "info   triagens do tutor $ID_TUTOR_LUNA antes desta rodada: $QTD_TRIAGENS_ANTES"

if [ "$QTD_TRIAGENS_ANTES" -ge 3 ]; then
  echo "ok     ja existem $QTD_TRIAGENS_ANTES triagens para este tutor — pulando criacao (idempotencia)"
else
  seed_triagem() {  # seed_triagem <urgencia> <score> <sintomas_json_array> <mensagem>
    local urgencia=$1 score=$2 sintomas=$3 mensagem=$4
    local dt_recebimento; dt_recebimento=$(agora_iso)
    local payload_interacao
    payload_interacao=$(cat <<JSON
{
  "id_tutor": $ID_TUTOR_LUNA,
  "ds_canal": "WHATSAPP",
  "ds_direcao": "INBOUND",
  "ds_conteudo": "$mensagem",
  "dt_recebimento": "$dt_recebimento",
  "ds_metadados": null
}
JSON
)
    chamar_apikey "luna/interactions ($urgencia)" 201 POST "$API/api/v1/luna/interactions" "$payload_interacao"
    local id_interacao; id_interacao=$(campo id_interacao)
    local payload_triagem
    payload_triagem=$(cat <<JSON
{
  "id_interacao": $id_interacao,
  "id_tutor": $ID_TUTOR_LUNA,
  "sintomas": $sintomas,
  "ds_urgencia": "$urgencia",
  "nr_score": $score,
  "ds_recomendacao": "Classificacao heuristica (DS_REGRAS_VERSAO=1.3) - nao substitui avaliacao veterinaria.",
  "regras_versao": "1.3"
}
JSON
)
    chamar_apikey "luna/triage ($urgencia)" 201 POST "$API/api/v1/luna/triage" "$payload_triagem"
  }

  seed_triagem "ALTA"  10 '["convulsionando"]' "socorro, meu cachorro esta convulsionando muito forte"
  seed_triagem "MEDIA" 3  '["vomitou"]'        "meu cachorro vomitou de manha, mas parece bem"
  seed_triagem "BAIXA" 1  '["queria saber"]'   "oi, queria saber se posso dar banho no meu cachorro hoje"
  echo "ok     3 triagens semeadas (ALTA/MEDIA/BAIXA) via caminho real"
fi
echo

# ─── 7. Prova final: fila nao vazia (corpo, nao so status) ─────────────────
chamar "luna/triagens (prova final, corpo)" 200 GET "$API/api/v1/luna/triagens?pageSize=100" '' "$TOKEN"
QTD_TRIAGENS_DEPOIS=$(contar_triagens_do_tutor "$ID_TUTOR_LUNA")
TOTAL_TRIAGENS_CLINICA=$(campo total)
echo "ok     GET /api/v1/luna/triagens: total da clinica=$TOTAL_TRIAGENS_CLINICA, do tutor demo=$QTD_TRIAGENS_DEPOIS"
if [ "$QTD_TRIAGENS_DEPOIS" -lt 3 ]; then
  echo "ERRO: esperado >=3 triagens do tutor demo, obtido $QTD_TRIAGENS_DEPOIS." >&2
  exit 1
fi

echo
echo "=== SEED LUNA PRONTO ==="
echo "Tutor demo Luna: id=$ID_TUTOR_LUNA (CPF marcador $CPF_TUTOR_LUNA)"
echo "Pet: Thor (id=$ID_PET_THOR)"
echo "Triagens do tutor na fila: $QTD_TRIAGENS_DEPOIS"
echo "DS_WHATSAPP setado: $TEM_WHATSAPP"
