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
# ACHADO original (LU-15): TUTOR.DS_WHATSAPP (V1__initial_schema.sql:92,
# coluna nullable, distinta de TUTOR.DS_TELEFONE) e a coluna que
# VW_VACINAS_VENCENDO (V21) le para decidir pra onde mandar o lembrete de
# vacina (vacina_repo.py -> notification_service.py: sem ela, "falhas += 1",
# nunca ORA-, mas o lembrete real NAO sai). Na epoca (LU-15), NENHUM endpoint
# HTTP escrevia essa coluna, e este script fazia um UPDATE declarado via
# `docker exec` no container kura_luna_ai.
#
# ATUALIZADO NA REC-05 (KURA_BACKLOG_RECEPCAO.md, A-8/A-9): isso deixou de
# ser verdade. TutorCreateDto E TutorUpdateDto (.NET, origin/main e33da98)
# ganharam `DsWhatsapp` (REC-01 na criacao, REC-02 fix wave na edicao) — os
# blocos 2/2b abaixo passam a setar DS_WHATSAPP por HTTP (POST/PUT reais),
# igual a qualquer outro campo. O UPDATE via `docker exec` foi REMOVIDO.
#
# ⚠️ Efeito colateral MEDIDO, nao evitavel por este script: TutorService.
# CreateAsync (.NET) aplica a convencao "mesmo numero" (A-9) quando
# DsWhatsapp esta ausente do payload — ou seja, TODO tutor criado por
# POST /api/v1/tutores agora GANHA um DS_WHATSAPP nao-nulo (igual ao
# NrTelefone informado), mesmo quando esse telefone e o placeholder fixo
# desta demo (11990000000, usado quando DEMO_WHATSAPP nao esta definido).
# Antes da REC-05, sem DEMO_WHATSAPP, DS_WHATSAPP ficava NULL de proposito
# (nenhum endpoint escrevia) e o lembrete de vacina contava "falha" sem
# tentar enviar. Agora, sem DEMO_WHATSAPP, DS_WHATSAPP sai preenchido com o
# placeholder normalizado (+5511990000000) — se um dia o Twilio deste
# ambiente estiver configurado com credenciais reais, o job de lembrete VAI
# TENTAR enviar para esse numero falso (Twilio devolve erro de numero
# invalido/nao-WhatsApp, nao um envio bem-sucedido — mas deixa de ser
# "silenciosamente nada"). Neste ambiente hoje o Twilio nao envia de verdade
# (ver KURA_LUNA_CICLO_FECHAMENTO.md, "Pre-voo"), entao o risco pratico e
# baixo — registrado para quem operar este script num ambiente com Twilio
# real: DEFINA SEMPRE DEMO_WHATSAPP ao rodar contra um ambiente com credencial
# Twilio de verdade.
# ═══════════════════════════════════════════════════════════════════════════
#
# Uso:
#   cd DevOps-Cloud
#   DEMO_WHATSAPP=<numero-do-time-com-DDI> bash scripts/seed-demo-luna.sh
#
# DEMO_WHATSAPP: numero do WHATSAPP REAL do time (DDI+DDD+numero, so digitos, ex.: 5511999998888;
# aceita "+", espacos, "-" e parenteses, que sao removidos) — NUNCA versionado, NUNCA impresso
# inteiro (so os 4 ultimos digitos).
#
# REC-18 — DECISAO: FALHAR, nao pular. Antes (LU-15) a variavel era opcional e, sem ela, o script
# semeava um placeholder. Isso era toleravel quando o numero so servia ao lembrete de vacina; agora
# ele e o ELO do percurso de estande: e o numero que a Twilio entrega (13 digitos 55...), o unico
# que a Luna casa com o tutor (G0 item 4), e o destino do lembrete D-1 e das respostas "1"/"3".
# Sem ele o tutor da demo fica com um numero falso e o D-1 mandaria WhatsApp para ninguem — uma
# demo "verde" que falha no palco. Por isso, sem DEMO_WHATSAPP (ou com formato invalido) o script
# aborta ANTES de qualquer chamada, com `exit 2`. Saida de emergencia explicita, para ambiente sem
# celular real (CI, ensaio de fila): SEED_SEM_WHATSAPP=1 — mantem o comportamento antigo
# (placeholder, sem o agendamento D-1).
#
# REC-18 — D-1 (bloco 6b): com DEMO_WHATSAPP, cria 1 agendamento de AMANHA 10:00 (POST /agendamentos,
# REC-10) para o Thor do tutor-demo — que tem consentimento LEMBRETES e DS_WHATSAPP = numero do time,
# ou seja, e ELEGIVEL ao lembrete de confirmacao D-1. Este e o unico lugar do seed onde o D-1 elegivel
# nasce (o tutor de scripts/seed-demo.sh nao tem LEMBRETES nem o WhatsApp do time). O job so envia se
# LEMBRETE_CONFIRMACAO_HABILITADO=true na Luna (default false; ver .env.example) e SO DENTRO DA JANELA
# DE 24h do sandbox, com o celular do time tendo refeito o `join` (sessao expira em 3 dias — G0 item 10):
# o seed NAO liga nada disso, so deixa o dado pronto.
#
# ⚠️ HORA DO TICK (G2 REC-18, m-2): o job D-1 roda UMA vez por dia, em LEMBRETE_CONFIRMACAO_HORA (default 9,
# hora de Sao Paulo) e mira o dia SEGUINTE (kura-luna-ai confirmacao_d1_service.py: hoje + 1 dia). NAO ha
# gatilho manual do D-1 (so existe /jobs/lembrete-vacina/executar). Logo: este seed deve rodar ANTES da
# hora do tick do dia anterior a demo. Rodado DEPOIS dessa hora, o agendamento de amanha ja perdeu o tick de
# hoje (que miraria amanha) e so seria visto pelo tick de amanha, que mira DEPOIS de amanha: o D-1 fica
# SEM lembrete. Para o percurso de estande: semeie antes das 9h, ou suba a Luna com LEMBRETE_CONFIRMACAO_HORA
# uns minutos a frente do horario atual (e confira o log do tick).
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
SEED_SEM_WHATSAPP=${SEED_SEM_WHATSAPP:-}
if [ -n "$DEMO_WHATSAPP" ]; then
  # Normaliza so a apresentacao (espacos, +, -, parenteses) e VALIDA o formato antes de
  # interpolar o valor em qualquer JSON — nunca ecoa o valor recebido em mensagem de erro.
  DEMO_WHATSAPP=$(printf '%s' "$DEMO_WHATSAPP" | tr -d ' +()-')
  if ! [[ "$DEMO_WHATSAPP" =~ ^55[0-9]{10,11}$ ]]; then
    echo "erro: DEMO_WHATSAPP em formato invalido — use DDI+DDD+numero, so digitos (12 ou 13 digitos" >&2
    echo "      comecando em 55; ex.: 5511999998888). O valor recebido nao e impresso." >&2
    exit 2
  fi
fi
if [ -z "$DEMO_WHATSAPP" ]; then
  if [ "$SEED_SEM_WHATSAPP" != "1" ]; then
    echo "erro: DEMO_WHATSAPP nao definido. Este seed precisa do WhatsApp REAL do time (REC-18):" >&2
    echo "      e o numero que a Twilio entrega, o unico que a Luna casa com o tutor, e o destino do" >&2
    echo "      lembrete D-1. Rode:" >&2
    echo "        DEMO_WHATSAPP=<DDI+DDD+numero> bash scripts/seed-demo-luna.sh" >&2
    echo "      Sem celular real (CI, ensaio de fila), use SEED_SEM_WHATSAPP=1 — placeholder, sem D-1." >&2
    exit 2
  fi
  echo "aviso  SEED_SEM_WHATSAPP=1 — semeando tutor/pet/vacina/triagens SEM numero de"
  echo "       WhatsApp real. TUTOR.DS_WHATSAPP sai com o PLACEHOLDER normalizado"
  echo "       (+5511990000000, REC-05: TutorCreateDto ja nao deixa a coluna null — ver"
  echo "       achado no cabecalho deste script), NAO o numero real: o lembrete de vacina"
  echo "       desta demo tentaria mandar para um numero que nao existe, e a acao"
  echo "       'Responder no WhatsApp' nao tem para onde mandar de verdade. A fila da Luna e"
  echo "       as triagens funcionam normalmente (nao dependem de WhatsApp). O agendamento"
  echo "       D-1 (bloco 6b) NAO sera criado."
  TEM_WHATSAPP="N"
else
  DEMO_WHATSAPP_MASCARADO="****${DEMO_WHATSAPP: -4}"
  echo "ok     DEMO_WHATSAPP definido (final $DEMO_WHATSAPP_MASCARADO) — TUTOR.DS_WHATSAPP sera setado"
  TEM_WHATSAPP="S"
fi
echo

# ─── credenciais fixas da clinica de demo (scripts/seed-demo.sh) ───────────
EMAIL_ACESSO="demo@kura.local"
SENHA_CLINICA="${DEMO_SENHA:-}"
if [ -z "$SENHA_CLINICA" ] && [ -f "$(dirname "$0")/../.env" ]; then
  # le SO esta chave do .env (sem `source`: nao exporta segredo nenhum)
  SENHA_CLINICA=$(grep -E '^DEMO_SENHA=' "$(dirname "$0")/../.env" | tail -1 | cut -d= -f2- | tr -d '\r"')
fi
# REC-05b (I-1 do G2): este default esta num repo PUBLICO. Com o tunel ligado ele vira login
# remoto na clinica demo — para a demo ao vivo defina DEMO_SENHA (env ou .env) ANTES de semear.
# O default segue so para nao quebrar quem ja usa; scripts/tunnel-up.sh recusa subir se o
# login com ele ainda funcionar.
SENHA_CLINICA="${SENHA_CLINICA:-SenhaDemo123!}"

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

  # ─── LU-16 G4, achado A1 (BLOQUEANTE) — atualizado na REC-05 ─────────────
  # Historico: este ramo de idempotencia so alinhava nrTelefone (-> DS_TELEFONE)
  # quando DEMO_WHATSAPP nao batia com o valor atual; DS_WHATSAPP era corrigido
  # a parte, pelo antigo bloco 3 (UPDATE SQL via docker exec, REMOVIDO nesta
  # task). DS_TELEFONE (busca EXATA de GET /api/v1/tutores/telefone/{numero},
  # o que o InboundMessageService da Luna chama) e DS_WHATSAPP (o que
  # VW_VACINAS_VENCENDO le) sao colunas DIFERENTES, e o A1 original era
  # DS_TELEFONE ficar preso no placeholder para sempre.
  #
  # REC-05 (A-9): TutorUpdateDto ganhou DsWhatsapp opcional (origin/main
  # e33da98) — o mesmo PUT que corrige nrTelefone agora tambem manda
  # dsWhatsapp, endpoint real, nao mais SQL a mao. Sempre que DEMO_WHATSAPP
  # estiver definido este PUT roda (sem o atalho "ja bate" antigo: o PUT e
  # idempotente por construcao — mesmo valor de entrada, mesmo valor gravado
  # — entao rodar de novo nao tem custo alem de uma chamada HTTP a mais, e
  # cobre o caso em que nrTelefone ja batia mas dsWhatsapp nunca tinha sido
  # setado por HTTP).
  if [ "$TEM_WHATSAPP" = "S" ]; then
    NM_TUTOR_ATUAL=$(achar_em_lista "nrCpf" "$CPF_TUTOR_LUNA" "nmTutor")
    EMAIL_TUTOR_ATUAL=$(achar_em_lista "nrCpf" "$CPF_TUTOR_LUNA" "dsEmail")
    PAYLOAD_TUTOR_UPDATE=$(cat <<JSON
{
  "nmTutor": "$NM_TUTOR_ATUAL",
  "nrCpf": "$CPF_TUTOR_LUNA",
  "dsEmail": "$EMAIL_TUTOR_ATUAL",
  "nrTelefone": "$DEMO_WHATSAPP",
  "dsWhatsapp": "$DEMO_WHATSAPP"
}
JSON
)
    chamar "tutores/{id} (corrige DS_TELEFONE e DS_WHATSAPP, A1+REC-05)" 200 PUT "$API/api/v1/tutores/$ID_TUTOR_LUNA" "$PAYLOAD_TUTOR_UPDATE" "$TOKEN"
    echo "ok     DS_TELEFONE e DS_WHATSAPP realinhados (final $DEMO_WHATSAPP_MASCARADO) — Ato 1 volta a casar"
  else
    echo "aviso  DEMO_WHATSAPP nao definido — DS_TELEFONE/DS_WHATSAPP do tutor existente NAO"
    echo "       foram tocados (podem estar divergentes; sem WhatsApp real nesta demo isso"
    echo "       nao importa)"
  fi
else
  echo "ok     tutor ainda nao existe — criando"
  # NrTelefone (campo de contato do CRM) e DsWhatsapp: usa o proprio
  # DEMO_WHATSAPP quando disponivel (o apresentador tambem e o "telefone"
  # cadastral do tutor nesta demo), senao um placeholder fixo — REC-05:
  # dsWhatsapp e enviado EXPLICITO (mesmo valor de nrTelefone) em vez de
  # confiar no default "mesmo numero" do TutorService (A-9): o efeito e
  # identico, mas explicito deixa a intencao visivel neste script (ver
  # achado no cabecalho sobre o placeholder tambem virar DS_WHATSAPP agora).
  TELEFONE_CONTATO=${DEMO_WHATSAPP:-11990000000}
  PAYLOAD_TUTOR=$(cat <<JSON
{
  "nmTutor": "$NM_TUTOR_LUNA",
  "nrCpf": "$CPF_TUTOR_LUNA",
  "dsEmail": "tutor-demo-luna@kura.local",
  "nrTelefone": "$TELEFONE_CONTATO",
  "dsWhatsapp": "$TELEFONE_CONTATO",
  "stAvisoPrivacidadeInformado": true,
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

# ─── 3. DS_WHATSAPP ────────────────────────────────────────────────────────
# REC-05: bloco REMOVIDO. Ate a REC-05, nenhum endpoint HTTP escrevia
# DS_WHATSAPP, entao este bloco fazia um UPDATE SQL a mao via `docker exec`
# no container kura_luna_ai (ver historico no cabecalho deste script). Isso
# deixou de ser necessario: o bloco 2/2b acima (POST na criacao, PUT na
# idempotencia) ja manda `dsWhatsapp` no mesmo payload que seta nrTelefone —
# TutorCreateDto/TutorUpdateDto (.NET, origin/main e33da98) aceitam o campo
# desde REC-01/REC-02. DS_WHATSAPP sai setado (com ou sem DEMO_WHATSAPP —
# ver o aviso do bloco 0 acima) sem nenhum acesso direto ao Oracle.
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

# ─── 6b. REC-18: agendamento de AMANHA elegivel ao lembrete D-1 (so com DEMO_WHATSAPP) ───────
# Contrato: POST /api/v1/agendamentos (backend-clinica-dotnet origin/main 81d5a58,
# AgendamentoCreateDto.cs:11-30; dtAgendamento = hora LOCAL da clinica, sem "Z",
# AgendamentoCreateValidator.cs:71-76). Elegibilidade (LunaService.cs:405+): status AGENDADO, dia =
# amanha, tutor com DS_WHATSAPP e consentimento LEMBRETES aceito e nao revogado, DT_LEMBRETE nulo —
# o tutor-demo atende as tres coisas (bloco 2). Offset fixo -03:00 (Brasil sem horario de verao desde
# 2019; mesma premissa do fallback de RelogioClinica.cs).
#
# Idempotencia: se ja existe amanha um agendamento do Thor ainda "virgem" (AGENDADO e sem resposta do
# tutor), nao cria outro. LIMITE CONHECIDO: o DTO da agenda nao expoe DT_LEMBRETE_CONFIRMACAO, entao um
# agendamento que ja recebeu o lembrete mas nao foi respondido ainda conta como "virgem" e o seed nao o
# recria — depois de um ENSAIO que consumiu o lembrete, crie outro agendamento de amanha pelo app (ou
# um `down -v` + os dois seeds). Um agendamento CONFIRMADO/respondido NAO bloqueia: o seed cria um novo.
if [ "$TEM_WHATSAPP" = "S" ]; then
  DATA_AMANHA=$("$PY" -c 'import datetime as d; print((d.datetime.now(d.timezone(d.timedelta(hours=-3)))+d.timedelta(days=1)).strftime("%Y-%m-%d"))')
  chamar "agenda (amanha, idempotencia do D-1)" 200 GET "$API/api/v1/agenda?dataInicio=$DATA_AMANHA&dataFim=$DATA_AMANHA" '' "$TOKEN"
  ID_AG_D1=$("$PY" -c '
import json, sys
with open(sys.argv[2], "r", encoding="utf-8") as f:
    d = json.load(f)
for a in d["agendamentos"]:
    if str(a.get("idPet")) == sys.argv[1] and a.get("dsStatus") == "AGENDADO" and not a.get("dsRespostaConfirmacao"):
        sys.stdout.write(str(a["idAgendamento"]))
        break
' "$ID_PET_THOR" "$BODY_FILE")
  if [ -n "$ID_AG_D1" ]; then
    echo "ok     agendamento D-1 de amanha ja existe (id=$ID_AG_D1) — pulando criacao"
  else
    PAYLOAD_AGENDAMENTO_D1=$(cat <<JSON
{
  "idTutor": $ID_TUTOR_LUNA,
  "idPet": $ID_PET_THOR,
  "idVeterinario": $ID_VETERINARIO,
  "dtAgendamento": "${DATA_AMANHA}T10:00:00",
  "duracao": 30,
  "dsTipo": "CONSULTA",
  "dsObservacoes": "Consulta de amanha (demo D-1)"
}
JSON
)
    chamar "agendamentos (amanha 10:00, Thor — elegivel ao D-1)" 201 POST "$API/api/v1/agendamentos" "$PAYLOAD_AGENDAMENTO_D1" "$TOKEN"
    ID_AG_D1=$(campo idAgendamento)
    echo "ok     agendamento D-1 criado (id=$ID_AG_D1, amanha $DATA_AMANHA 10:00, tutor $ID_TUTOR_LUNA, WhatsApp final $DEMO_WHATSAPP_MASCARADO)"
  fi
else
  ID_AG_D1=""
  echo "aviso  SEED_SEM_WHATSAPP=1 — agendamento D-1 NAO criado (sem numero real nao ha D-1 elegivel de verdade)"
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
echo "DS_WHATSAPP e o numero REAL do apresentador (nao o placeholder): $TEM_WHATSAPP"
echo "Agendamento D-1 de amanha (elegivel ao lembrete; so enviado com LEMBRETE_CONFIRMACAO_HABILITADO=true): ${ID_AG_D1:-nao criado}"
echo "As 3 triagens acima ficam SEM agendamento de proposito: sao a origem do botao Agendar do card."
