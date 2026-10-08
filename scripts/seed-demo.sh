#!/usr/bin/env bash
# Popula uma clinica de demonstracao via HTTP real, para o app da clinica nao nascer
# vazio numa demonstracao ao vivo (EXPO_PUBLIC_USE_MOCKS=false). NUNCA via migration —
# restricao dura do projeto: dado ficticio nao entra em Flyway que roda em prod (o
# compose roda prod). Todo dado abaixo nasce por chamada HTTP as mesmas rotas que os
# apps reais usam, igual ao smoke-contratos.sh (TASK-57).
#
# TASK-58 (KURA_BACKLOG_FIX_4). Reaproveita de scripts/smoke-contratos.sh (ler esse
# script primeiro): os helpers `chamar`/`campo`/`agora_iso` sao a mesma logica copiada
# (nao houve como importar funcoes entre dois scripts bash standalone sem exigir
# `source`, que mudaria o modo de invocar os dois) — mas a geracao de CPF/CNPJ NAO e
# reaproveitada em runtime: diferente do smoke, que precisa de CPF/CNPJ novos a cada
# execucao pra ficar idempotente em CI, este script quer o oposto — credenciais FIXAS e
# conhecidas, reutilizaveis entre demos (ver criterio de aceite da TASK-58). Os valores
# abaixo (CNPJ_CLINICA, CPF_TUTOR_1, CPF_TUTOR_2) sao constantes pre-computadas com o
# MESMO algoritmo modulo-11 de smoke-contratos.sh:gerar_cnpj/gerar_cpf (nao reimplementado
# aqui — so o resultado, fixo, esta hardcoded) — reproduzivel com:
#   python -c "from importlib import import_module; ..." (ver comentario acima de cada
#   constante para o script Python exato usado para gerar o valor).
#
# Uso:
#   cd DevOps-Cloud && bash scripts/seed-demo.sh
#
# Pre-requisitos: os mesmos do smoke-contratos.sh — compose de pe (5/5
# healthy/Exited(0)), curl e python (ou python3) no PATH.
#
# IDEMPOTENCIA (decisao documentada, criterio de aceite da TASK-58): este script NAO e
# idempotente por escolha — ele FALHA com mensagem clara se a clinica de demo ja existir
# (login com as credenciais fixas responde 200), em vez de tentar recriar/mesclar tutores
# e pets. Motivo: com CNPJ/CPF fixos, uma segunda execucao encontraria os registros ja
# criados e teria que decidir, endpoint a endpoint, se pula ou duplica — qualquer POST
# repetido (tutor com o mesmo CPF, pet, consulta, prescricao) arrisca duplicar dado ou
# quebrar em 422 no meio do fluxo, deixando a demo pela metade sem aviso claro. Falhar
# cedo com uma mensagem explicita, antes de qualquer POST, e mais seguro e mais simples
# de operar: para gerar uma demo nova, resete o ambiente primeiro (ver mensagem de erro).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./scripts/lib-env.sh   # ler_chave_env: leitura tolerante do .env (G4-I1)

API=${API:-http://localhost:8080}
TUTOR_API=${TUTOR_API:-http://localhost:8081}
BODY_FILE=$(mktemp)
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE"' EXIT

# REC-18: a triagem sem agendamento do "dia de clinica" (bloco 6b) e escrita pelos mesmos endpoints
# que a Luna usa (X-Api-Key, nao Bearer). Mesma leitura de smoke-contratos.sh / seed-demo-luna.sh:
# env var, senao o .env deste repo (o mesmo arquivo que o compose usa). Checado ANTES de qualquer POST
# — faltar a chave no meio do fluxo deixaria a demo pela metade.
LUNA_API_KEY=${LUNA_API_KEY:-}
if [ -z "$LUNA_API_KEY" ] && [ -f .env ]; then
  LUNA_API_KEY=$(grep -m1 '^LUNA_API_KEY=' .env | cut -d= -f2- || true)
fi
if [ -z "$LUNA_API_KEY" ]; then
  echo "erro: LUNA_API_KEY nao definido (nem env var, nem .env deste repo) — necessario para semear a triagem do dia de clinica (bloco 6b)." >&2
  exit 2
fi

PY=python
command -v python >/dev/null 2>&1 || PY=python3
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "erro: nem 'python' nem 'python3' foram encontrados no PATH — necessario para parse de JSON (sem jq)." >&2
  exit 2
fi

# ─── helpers ────────────────────────────────────────────────────────────────
# (mesma logica de scripts/smoke-contratos.sh — ver comentario do cabecalho sobre por
# que nao foi extraida para um arquivo compartilhado). Diferenca proposital: aqui
# `chamar` e FATAL (sai no primeiro status inesperado) em vez de contar falhas e seguir
# — os 7 passos deste script sao uma cadeia de dependencias (pet precisa do tutor criado
# no passo anterior, receituario precisa da prescricao), entao nao ha valor em continuar
# depois do primeiro passo que quebrar; so confundiria o operador da demo.
chamar() {  # chamar <nome> <esperado> <metodo> <url> <payload> [token]
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5 token=${6:-}
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json')
  # REC-18: corpo por ARQUIVO, nunca por argumento (-d "$payload" corrompe byte nao-ASCII no Git Bash
  # do Windows — mesmo achado do G4 do FIX_7, ver smoke-contratos.sh). Sem corpo (GET), nada e enviado.
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

# REC-18: variante de chamar() para os endpoints server-a-servidor da Luna (X-Api-Key, nao Bearer —
# LunaApiKeyAuthFilter.cs). FATAL como chamar().
chamar_apikey() {  # chamar_apikey <nome> <esperado> <metodo> <url> <payload>
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json' -H "X-Api-Key: $LUNA_API_KEY")
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

# Extrai um campo de um JSON lido do ultimo BODY_FILE gravado por chamar().
# Caminho em pontos; segmentos so-digitos indexam listas (ex.: "items.0.id").
campo() {  # campo <caminho.pontilhado>
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

# REC-05 (fix wave G2, m-seed): variante de campo() que nao estoura sob
# set -euo pipefail quando o caminho nao existe — usada so' pra dsLinkConvite,
# que sai null quando CONVITE_URL_BASE_APP_TUTOR nao esta configurada (A-8) e
# este script roda sem essa garantia (compose local tipico nao seta a var).
campo_opcional() {  # campo_opcional <caminho.pontilhado>
  "$PY" -c '
import json, sys
try:
    with open(sys.argv[2], "r", encoding="utf-8") as f:
        data = json.load(f)
    cur = data
    for p in sys.argv[1].split("."):
        cur = cur[int(p)] if p.isdigit() else cur[p]
    sys.stdout.write(str(cur))
except (KeyError, IndexError, TypeError, json.JSONDecodeError):
    sys.stdout.write("")
' "$1" "$BODY_FILE"
}

# Conta itens de uma lista JSON no topo do ultimo BODY_FILE (usado na verificacao final
# de GET /api/v1/pets — precisa confirmar "nao vazio", nao so status 200).
tamanho_lista() {
  "$PY" -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
sys.stdout.write(str(len(data)))
' "$BODY_FILE"
}

agora_iso() { "$PY" -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))'; }
AGORA=$(agora_iso)

# ─── Guarda de horario (G2 REC-18, m-1) — ANTES de criar qualquer coisa ──────────────────────
# O bloco 6b ("dia de clinica") agenda Rex em "agora - 10 min" e Mimi em "agora - 5 min" e depois faz
# check-in neles; o check-in so e aceito NO DIA do agendamento (AgendaService.cs:439). Entre 00:00 e
# ~00:10 (America/Sao_Paulo) esses dois horarios caem em ONTEM: o POST passa (encaixe <= 15 min) mas o
# check-in da 422 FATAL — depois de a clinica ja existir, e a guarda da TASK-58 (abaixo) impede
# reexecutar: o unico caminho seria `down -v`. Medido por sonda (G2): 00:00:30, 00:04:30 e 00:09:30
# quebram; 00:11:30 em diante nao. Por isso o script RECUSA rodar de 00:00 a 00:10 (11 min de folga),
# com mensagem clara, antes de qualquer chamada. Offset fixo -03:00 (Brasil sem horario de verao desde
# 2019 — mesma premissa do fallback de RelogioClinica.cs). SEED_AGORA_CLINICA_TESTE=HH:MM existe so para
# testar a guarda sem esperar a meia-noite; nao use em demo real.
MIN_DESDE_MEIA_NOITE=$("$PY" -c '
import datetime as d, os, sys
t = os.environ.get("SEED_AGORA_CLINICA_TESTE")
if t:
    h, m = t.split(":")
    print(int(h) * 60 + int(m))
else:
    n = d.datetime.now(d.timezone(d.timedelta(hours=-3)))
    print(n.hour * 60 + n.minute)
')
if [ "$MIN_DESDE_MEIA_NOITE" -lt 11 ]; then
  echo "erro: sao 00:00-00:10 no horario da clinica (America/Sao_Paulo). O bloco 'dia de clinica' agenda" >&2
  echo "      'agora - 10 min' (ONTEM nesta janela) e o check-in so vale no dia do agendamento — o seed" >&2
  echo "      abortaria no meio, com a clinica ja criada, e so um 'down -v' desfaria. Rode depois das 00:11." >&2
  exit 2
fi

# ─── credenciais e dados fixos da demo ─────────────────────────────────────
EMAIL_ACESSO="demo@kura.local"
SENHA_CLINICA="${DEMO_SENHA:-}"
if [ -z "$SENHA_CLINICA" ]; then
  # le SO esta chave do .env (sem `source`: nao exporta segredo nenhum). Tolerante: sem a chave
  # (caso padrao — o .env.example a traz comentada) devolve vazio e cai no default abaixo (G4-I1).
  SENHA_CLINICA=$(ler_chave_env DEMO_SENHA)
fi
# REC-05b (I-1 do G2): este default esta num repo PUBLICO. Com o tunel ligado ele vira login
# remoto na clinica demo — para a demo ao vivo defina DEMO_SENHA (env ou .env) ANTES de semear.
# O default segue so para nao quebrar quem ja usa; scripts/tunnel-up.sh recusa subir se o
# login com ele ainda funcionar.
SENHA_CLINICA="${SENHA_CLINICA:-SenhaDemo123!}"

# CNPJ valido (formato 00.000.000/0000-00, exigido por RegisterClinicaValidator.NrCnpj),
# pre-computado uma unica vez com o mesmo algoritmo (modulo 11, filial 0001) de
# smoke-contratos.sh:gerar_cnpj, a partir da raiz fixa [5,8,0,0,1,2,0,0]. Fixo de
# proposito — ver nota de idempotencia no cabecalho.
CNPJ_CLINICA="58.001.200/0001-49"

# CPFs validos (modulo 11), pre-computados com o mesmo algoritmo de
# smoke-contratos.sh:gerar_cpf a partir das raizes fixas [1,1,1,2,2,2,3,3,3] e
# [4,4,4,5,5,5,6,6,6].
CPF_TUTOR_1="11122233396"
CPF_TUTOR_2="44455566619"

echo "=== seed-demo.sh — preparando clinica de demonstracao ==="
echo

# ─── 0. Checagem de idempotencia: a clinica de demo ja existe? ────────────
# Login com as credenciais fixas. 200 = ja existe (ver nota de idempotencia no
# cabecalho) -> falha cedo, antes de qualquer POST. 422 (credenciais invalidas, mesmo
# comportamento do AuthController para "nao encontrado") = ainda nao existe -> segue.
PAYLOAD_LOGIN_CHECK=$(cat <<JSON
{ "dsEmail": "$EMAIL_ACESSO", "dsSenha": "$SENHA_CLINICA" }
JSON
)
CODE_LOGIN_CHECK=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "$API/api/v1/auth/login" \
  -H 'Content-Type: application/json' -d "$PAYLOAD_LOGIN_CHECK")
if [ "$CODE_LOGIN_CHECK" = "200" ]; then
  echo "ERRO: a clinica de demo ($EMAIL_ACESSO) ja existe neste ambiente." >&2
  echo "Este script nao recria dados por cima de uma demo existente (ver nota de" >&2
  echo "idempotencia no cabecalho do script) — CNPJ/CPF fixos duplicariam ou quebrariam" >&2
  echo "no meio do fluxo. Para gerar uma demo nova do zero:" >&2
  echo "  docker compose down -v && docker compose up -d && bash scripts/seed-demo.sh" >&2
  exit 1
fi
echo "ok     checagem de idempotencia (clinica de demo ainda nao existe)"
echo

# ─── 1. Cadastro da clinica ────────────────────────────────────────────────
# Mesma rota/payload de smoke-contratos.sh passo 1 (origem: mobile-clinica-rn
# register.tsx) — aqui com valores fixos de demo em vez de gerados por sufixo aleatorio.
PAYLOAD_REGISTER_CLINICA=$(cat <<JSON
{
  "nmClinica": "Clinica Demo KURA",
  "nrCnpj": "$CNPJ_CLINICA",
  "dsEndereco": "Av. Demonstracao, 1000",
  "nmCidade": "Sao Paulo",
  "sgUf": "SP",
  "nrCep": "01000-000",
  "nrTelefone": "11999990001",
  "dsEmail": "contato@demo.kura.local",
  "dsEmailAcesso": "$EMAIL_ACESSO",
  "dsSenha": "$SENHA_CLINICA",
  "nmVeterinarioAdmin": "Dra. Demo KURA",
  "nrCRMV": "CRMV-DEMO-0001"
}
JSON
)
chamar "auth/register-clinica" 201 POST "$API/api/v1/auth/register-clinica" "$PAYLOAD_REGISTER_CLINICA"
TOKEN=$(campo accessToken)
ID_VETERINARIO=$(campo usuario.id)

# ─── 2. Dois tutores, cada um com convite gerado ──────────────────────────
# Origem do payload: TutorCreateDto (mesma logica de smoke-contratos.sh, bloco "setup").
PAYLOAD_TUTOR_1=$(cat <<JSON
{
  "nmTutor": "Tutor Demo Um",
  "nrCpf": "$CPF_TUTOR_1",
  "dsEmail": "tutor1-demo@kura.local",
  "nrTelefone": "11988880001",
  "stAvisoPrivacidadeInformado": true,
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "tutores (tutor 1)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_1" "$TOKEN"
ID_TUTOR_1=$(campo id)
INVITE_TUTOR_1=$(campo invite.nrToken)
DS_LINK_CONVITE_1=$(campo_opcional dsLinkConvite)

PAYLOAD_TUTOR_2=$(cat <<JSON
{
  "nmTutor": "Tutor Demo Dois",
  "nrCpf": "$CPF_TUTOR_2",
  "dsEmail": "tutor2-demo@kura.local",
  "nrTelefone": "11988880002",
  "stAvisoPrivacidadeInformado": true,
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "tutores (tutor 2)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_2" "$TOKEN"
ID_TUTOR_2=$(campo id)
INVITE_TUTOR_2=$(campo invite.nrToken)
DS_LINK_CONVITE_2=$(campo_opcional dsLinkConvite)

# ─── 3. Tres pets, usando idEspecie/idRaca do catalogo V14 ────────────────
# IDs conferidos contra java-backend/src/main/resources/db/migration/V14__seed_referencia.sql
# (a migration que roda de fato em prod, nao presumidos por auditoria antiga):
# ID_ESPECIE 1=Cao, 2=Gato; ID_RACA 1=Labrador(Cao), 2=Poodle(Cao), 3=Siames(Gato).
# Alem da leitura estatica do SQL, cada criacao abaixo valida em runtime que a resposta
# (NmEspecie/NmRaca) bate com o esperado — se um reseed futuro do catalogo mudar esses
# IDs sem atualizar este script, falha aqui com mensagem clara em vez de criar pets com
# especie/raca erradas silenciosamente.
verificar_especie_raca() {  # verificar_especie_raca <especie_esperada> <raca_esperada>
  local especie_esperada=$1 raca_esperada=$2
  local especie_obtida raca_obtida
  especie_obtida=$(campo nmEspecie)
  raca_obtida=$(campo nmRaca)
  if [ "$especie_obtida" != "$especie_esperada" ] || [ "$raca_obtida" != "$raca_esperada" ]; then
    echo "ERRO: catalogo de referencia mudou — esperado especie='$especie_esperada'/raca='$raca_esperada', obtido especie='$especie_obtida'/raca='$raca_obtida'." >&2
    echo "Os IDs de idEspecie/idRaca hardcoded neste script nao batem mais com V14__seed_referencia.sql — atualizar antes de reusar." >&2
    exit 1
  fi
}

PAYLOAD_PET_1=$(cat <<JSON
{
  "idEspecie": 1,
  "idRaca": 1,
  "nmPet": "Rex",
  "dtNascimento": "2022-01-01T00:00:00Z",
  "sgSexo": "M",
  "sgPorte": "M",
  "idTutor": $ID_TUTOR_1,
  "stPrincipal": true,
  "dsVinculo": "PROPRIETARIO"
}
JSON
)
chamar "pets (Rex, Cao/Labrador, tutor 1)" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET_1" "$TOKEN"
verificar_especie_raca "Cao" "Labrador"
ID_PET_1=$(campo id)

PAYLOAD_PET_2=$(cat <<JSON
{
  "idEspecie": 2,
  "idRaca": 3,
  "nmPet": "Mimi",
  "dtNascimento": "2021-06-15T00:00:00Z",
  "sgSexo": "F",
  "sgPorte": "P",
  "idTutor": $ID_TUTOR_1,
  "stPrincipal": true,
  "dsVinculo": "PROPRIETARIO"
}
JSON
)
chamar "pets (Mimi, Gato/Siames, tutor 1)" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET_2" "$TOKEN"
verificar_especie_raca "Gato" "Siames"
ID_PET_2=$(campo id)

PAYLOAD_PET_3=$(cat <<JSON
{
  "idEspecie": 1,
  "idRaca": 2,
  "nmPet": "Bolinha",
  "dtNascimento": "2023-03-10T00:00:00Z",
  "sgSexo": "M",
  "sgPorte": "P",
  "idTutor": $ID_TUTOR_2,
  "stPrincipal": true,
  "dsVinculo": "PROPRIETARIO"
}
JSON
)
chamar "pets (Bolinha, Cao/Poodle, tutor 2)" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET_3" "$TOKEN"
verificar_especie_raca "Cao" "Poodle"
ID_PET_3=$(campo id)

# ─── 4. Uma consulta (pet Rex) ─────────────────────────────────────────────
# Origem do payload: ConsultaCreateDto (mesma logica de smoke-contratos.sh passo 3),
# com dsObservacao preenchida (texto de demo, nao vazio) em vez do caso de teste vazio.
PAYLOAD_CONSULTA=$(cat <<JSON
{
  "idPet": $ID_PET_1,
  "idVeterinario": $ID_VETERINARIO,
  "dtConsulta": "$AGORA",
  "dsMotivo": "Checape anual de rotina",
  "dsAnamnese": "Tutor relata apetite e disposicao normais",
  "dsExameFisico": "Sem alteracoes ao exame fisico",
  "dsDiagnostico": "Animal saudavel",
  "dsObservacao": "Retorno recomendado em 6 meses para nova avaliacao."
}
JSON
)
chamar "eventos-clinicos/consultas (Rex)" 201 POST "$API/api/v1/eventos-clinicos/consultas" "$PAYLOAD_CONSULTA" "$TOKEN"
ID_EVENTO_CONSULTA=$(campo idEventoClinico)

# ─── 5. Uma prescricao (pet Rex) — dsObservacao preenchida (TASK-62) ──────
# Origem do payload: PrescricaoCreateDto (mesma logica de smoke-contratos.sh passo 5),
# idMedicamento=1 (Amoxicilina) conferido contra V14__seed_referencia.sql. dsObservacao
# com texto de exemplo, propositalmente NAO vazio — a task pede que a demo mostre o
# campo populado, nao o sentinela "Sem observacoes" que o app usa quando o vet deixa em
# branco.
PAYLOAD_PRESCRICAO=$(cat <<JSON
{
  "idPet": $ID_PET_1,
  "idVeterinario": $ID_VETERINARIO,
  "dtEvento": "$AGORA",
  "dsObservacao": "Administrar preferencialmente apos as refeicoes, com bastante agua.",
  "idMedicamento": 1,
  "dsPosologia": "1 comprimido a cada 12h por 7 dias",
  "nrDuracaoDias": 7
}
JSON
)
chamar "eventos-clinicos/prescricoes (Rex)" 201 POST "$API/api/v1/eventos-clinicos/prescricoes" "$PAYLOAD_PRESCRICAO" "$TOKEN"
ID_EVENTO_PRESCRICAO=$(campo idEventoClinico)

# ─── 6. Receituario gerado a partir da prescricao ─────────────────────────
# Endpoint da TASK-51 (ciclo anterior) — ja existe, sem payload.
chamar "eventos-clinicos/{id}/receituario" 200 POST "$API/api/v1/eventos-clinicos/$ID_EVENTO_PRESCRICAO/receituario" '{}' "$TOKEN"
ID_DOCUMENTO_RECEITUARIO=$(campo id)

# ─── 6b. REC-18: "dia de clinica" — a tela "Hoje" da recepcao nao nasce vazia ─────────
# Tudo pelos endpoints REAIS da recepcao (nunca SQL, nunca migration — a regra do cabecalho vale
# aqui tambem): POST /api/v1/agendamentos (REC-10) e POST .../checkin | .../inicio-atendimento
# (REC-11), contrato lido em backend-clinica-dotnet origin/main 81d5a58 (AgendamentoCreateDto.cs:11-30,
# RegistrarEventoRecepcaoDto.cs:10; AgendaService.cs: check-in/inicio so NO DIA do agendamento, :439/:476;
# encaixe: no maximo 15 min no passado). A PK vem da SEQ_AGENDAMENTO pelo mapeamento do EF (REC-10/V23)
# — este script nao escolhe id nenhum.
#
# O que a tela "Hoje" mostra depois deste bloco (etapas = DsEtapaRecepcao):
#   Rex     (hoje, "agora - 10 min")  EM_ATENDIMENTO  (check-in + inicio)
#   Mimi    (hoje, "agora - 5 min")   CHEGOU          ("esperando ha N min" cresce durante a demo)
#   Bolinha (hoje, "agora")           AGENDADO
#   Rex     (hoje, "agora + 2 h")     AGENDADO        (retorno; limitado a 23:59 de hoje)
#   Bolinha (AMANHA 09:30)            AGENDADO        (aparece na visao Semana; NAO e D-1: o tutor 2
#                                                      nao tem consentimento LEMBRETES nem WhatsApp do
#                                                      time. O D-1 elegivel nasce em seed-demo-luna.sh,
#                                                      que e quem cria o tutor com LEMBRETES + DEMO_WHATSAPP)
#   + 1 triagem da Luna SEM agendamento (tutor 1) — a origem do botao "Agendar" do card.
# Horarios: hora LOCAL da clinica (America/Sao_Paulo), sem "Z" (AgendamentoCreateValidator.cs:71-76).
# JANELA PROIBIDA: de 00:00 a ~00:10 (SP) "agora - 10 min" cai em ontem e o check-in recusaria (422, so no
# dia). A guarda de horario no inicio do script (antes de criar a clinica) recusa rodar nessa janela.
# O Brasil nao tem horario de verao desde 2019 (mesma premissa do fallback -03:00 do RelogioClinica.cs),
# entao o script usa offset fixo -03:00, independente do fuso da maquina.
# "Check-in agora" e do relogio da clinica no servidor (nao se pode retrodatar): por isso o "esperando ha N
# min" de Mimi comeca em ~0 no instante do seed e cresce ate a demo.
clinica_delta_min() { "$PY" -c "import datetime as d; print((d.datetime.now(d.timezone(d.timedelta(hours=-3)))+d.timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%S'))"; }
clinica_hoje_mais_tarde() {  # agora + 2 h, mas nunca depois das 23:59 de HOJE
  "$PY" -c '
import datetime as d
n = d.datetime.now(d.timezone(d.timedelta(hours=-3)))
t = n + d.timedelta(hours=2)
if t.date() != n.date():
    t = n.replace(hour=23, minute=59, second=0, microsecond=0)
print(t.strftime("%Y-%m-%dT%H:%M:%S"))'
}
clinica_amanha_hora() { "$PY" -c "import datetime as d; print((d.datetime.now(d.timezone(d.timedelta(hours=-3)))+d.timedelta(days=1)).strftime('%Y-%m-%dT$1'))"; }

payload_agendamento() {  # payload_agendamento <idTutor> <idPet> <dtAgendamento> <dsTipo> <observacao>
  cat <<JSON
{
  "idTutor": $1,
  "idPet": $2,
  "idVeterinario": $ID_VETERINARIO,
  "dtAgendamento": "$3",
  "duracao": 30,
  "dsTipo": "$4",
  "dsObservacoes": "$5"
}
JSON
}

# Rex: em atendimento (check-in, depois inicio — versao 0 -> 1 -> 2)
chamar "agendamentos (hoje, Rex, em atendimento)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_1" "$ID_PET_1" "$(clinica_delta_min -10)" CONSULTA "Consulta de rotina (demo)")" "$TOKEN"
ID_AG_REX=$(campo idAgendamento)
chamar "agendamentos/{id}/checkin (Rex)" 200 POST "$API/api/v1/agendamentos/$ID_AG_REX/checkin" '{ "nrVersion": 0 }' "$TOKEN"
chamar "agendamentos/{id}/inicio-atendimento (Rex)" 200 POST "$API/api/v1/agendamentos/$ID_AG_REX/inicio-atendimento" '{ "nrVersion": 1 }' "$TOKEN"

# Mimi: chegou (so check-in)
chamar "agendamentos (hoje, Mimi, chegou)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_1" "$ID_PET_2" "$(clinica_delta_min -5)" CONSULTA "Pele irritada (demo)")" "$TOKEN"
ID_AG_MIMI=$(campo idAgendamento)
chamar "agendamentos/{id}/checkin (Mimi)" 200 POST "$API/api/v1/agendamentos/$ID_AG_MIMI/checkin" '{ "nrVersion": 0 }' "$TOKEN"

# Bolinha: agendado agora; Rex: retorno mais tarde hoje; Bolinha: amanha (visao Semana, NAO e D-1)
chamar "agendamentos (hoje, Bolinha, agendado)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_2" "$ID_PET_3" "$(clinica_delta_min 0)" CONSULTA "Primeira consulta (demo)")" "$TOKEN"
chamar "agendamentos (hoje, Rex, retorno mais tarde)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_1" "$ID_PET_1" "$(clinica_hoje_mais_tarde)" RETORNO "Retorno (demo)")" "$TOKEN"
chamar "agendamentos (amanha 09:30, Bolinha)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_2" "$ID_PET_3" "$(clinica_amanha_hora 09:30:00)" VACINA "Vacina (demo)")" "$TOKEN"

# Triagem da Luna SEM agendamento (tutor 1) — mesmo par de endpoints que o InboundMessageService chama
# (X-Api-Key). Mensagem/urgencia/score/sintomas/versao: a triagem MEDIA do seed-demo-luna.sh (que
# documenta te-los obtido do motor real, TriageEngine.classificar, regras 1.3) — nao inventei valor novo.
PAYLOAD_INTERACAO_TRIAGEM=$(cat <<JSON
{
  "id_tutor": $ID_TUTOR_1,
  "ds_canal": "WHATSAPP",
  "ds_direcao": "INBOUND",
  "ds_conteudo": "meu cachorro vomitou de manha, mas parece bem",
  "dt_recebimento": "$AGORA",
  "ds_metadados": null
}
JSON
)
chamar_apikey "luna/interactions (triagem sem agendamento, tutor 1)" 201 POST "$API/api/v1/luna/interactions" "$PAYLOAD_INTERACAO_TRIAGEM"
ID_INTERACAO_TRIAGEM=$(campo id_interacao)
PAYLOAD_TRIAGEM=$(cat <<JSON
{
  "id_interacao": $ID_INTERACAO_TRIAGEM,
  "id_tutor": $ID_TUTOR_1,
  "sintomas": ["vomitou"],
  "ds_urgencia": "MEDIA",
  "nr_score": 3,
  "ds_recomendacao": "Classificacao heuristica (DS_REGRAS_VERSAO=1.3) - nao substitui avaliacao veterinaria.",
  "regras_versao": "1.3"
}
JSON
)
chamar_apikey "luna/triage (MEDIA, sem agendamento, tutor 1)" 201 POST "$API/api/v1/luna/triage" "$PAYLOAD_TRIAGEM"
ID_TRIAGEM_SEM_AGENDAMENTO=$(campo id_triagem)

# Prova pelo CORPO (nao so status): a agenda de hoje tem as 3 etapas esperadas.
DATA_HOJE_CLINICA=$("$PY" -c 'import datetime as d; print(d.datetime.now(d.timezone(d.timedelta(hours=-3))).strftime("%Y-%m-%d"))')
chamar "agenda (verificacao do dia de clinica)" 200 GET "$API/api/v1/agenda?dataInicio=$DATA_HOJE_CLINICA&dataFim=$DATA_HOJE_CLINICA" '' "$TOKEN"
ETAPAS_HOJE=$("$PY" -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
e = sorted(a["dsEtapaRecepcao"] for a in d["agendamentos"])
sys.stdout.write(",".join(e))
' "$BODY_FILE")
if [ "$ETAPAS_HOJE" != "AGENDADO,AGENDADO,CHEGOU,EM_ATENDIMENTO" ]; then
  echo "ERRO: etapas da agenda de hoje = '$ETAPAS_HOJE', esperado 'AGENDADO,AGENDADO,CHEGOU,EM_ATENDIMENTO' (2 agendados, 1 chegou, 1 em atendimento)." >&2
  exit 1
fi
echo "ok     agenda de hoje tem as etapas esperadas: $ETAPAS_HOJE"
echo

# ─── 7. Verificacao final: login "normal" (nao o token de registro) + pets nao vazio ──
# Simula o que um operador faria numa proxima sessao de demo: logar, nao reusar o token
# do registro. Confirma via GET /api/v1/pets (nao so presume pela resposta dos POSTs
# acima) que a lista de pacientes esta populada — o proprio critério de aceite da TASK-58.
PAYLOAD_LOGIN=$(cat <<JSON
{ "dsEmail": "$EMAIL_ACESSO", "dsSenha": "$SENHA_CLINICA" }
JSON
)
chamar "auth/login (verificacao final)" 200 POST "$API/api/v1/auth/login" "$PAYLOAD_LOGIN"
TOKEN_LOGIN=$(campo accessToken)

chamar "pets/listar (verificacao final)" 200 GET "$API/api/v1/pets" '' "$TOKEN_LOGIN"
QTD_PETS=$(tamanho_lista)
if [ "$QTD_PETS" -lt 3 ]; then
  echo "ERRO: GET /api/v1/pets devolveu $QTD_PETS pet(s), esperado >= 3." >&2
  exit 1
fi
echo "ok     GET /api/v1/pets confirma $QTD_PETS pet(s) para a clinica de demo"
echo

# REC-05 (fix wave G2, achado m-seed): ate aqui os 2 tokens de convite sao
# INSUMO DO OPERADOR (por design — sem eles nao ha como completar o registro
# do tutor no app), mas imprimir o valor CRU no stdout colide com A-8 ("grep
# 0 no G4") se algum gate capturar a saida deste seed. Solucao: o valor
# completo (token + link, quando a config existir) vai para um arquivo LOCAL
# gitignored — nunca pro stdout — e o stdout mostra so' os 8 primeiros
# caracteres + "…", com um ponteiro pra alternativa que nao depende de
# nenhum dos dois: o botao "Gerar novo convite" no app da clinica
# (mobile-clinica-rn, tela tutores/novo.tsx — REC-03, ainda numa branch nao
# mesclada em main no momento desta fix wave; se essa branch nao estiver
# disponivel no seu checkout, use o arquivo local abaixo).
#
# Achado ao varrer os .md que citam esse output (grep, sem escopo nenhuma
# ocorrencia real fora de `.A Call/secao_E.md`, roteiro academico antigo):
# aquele roteiro manda "anotar INVITE_TUTOR_1" e completar o registro do
# tutor com o valor cru — dependencia real, registrada aqui em vez de
# quebrada em silencio. O arquivo local preserva essa dependencia (o operador
# ainda consegue o valor completo, so' não sai mais pelo terminal/log).
CONVITES_LOCAL_FILE="seed-demo-convites.local.txt"
{
  echo "# Gerado por scripts/seed-demo.sh em $(agora_iso) — NUNCA versionar, NUNCA colar em relatorio/log."
  echo "# Convite de tutor #1 (Tutor Demo Um):"
  echo "token: $INVITE_TUTOR_1"
  [ -n "$DS_LINK_CONVITE_1" ] && [ "$DS_LINK_CONVITE_1" != "None" ] && echo "link:  $DS_LINK_CONVITE_1"
  echo "# Convite de tutor #2 (Tutor Demo Dois):"
  echo "token: $INVITE_TUTOR_2"
  [ -n "$DS_LINK_CONVITE_2" ] && [ "$DS_LINK_CONVITE_2" != "None" ] && echo "link:  $DS_LINK_CONVITE_2"
} > "$CONVITES_LOCAL_FILE"

# ─── resultado ──────────────────────────────────────────────────────────────
echo "=== DEMO PRONTA ==="
echo "Clinica:  $EMAIL_ACESSO / $SENHA_CLINICA"
echo "App clinica: EXPO_PUBLIC_USE_MOCKS=false"
echo "Convite de tutor #1 (Tutor Demo Um), token mascarado: ${INVITE_TUTOR_1:0:8}…"
echo "Convite de tutor #2 (Tutor Demo Dois), token mascarado: ${INVITE_TUTOR_2:0:8}…"
echo "Para completar o registro do tutor: abra o app da clinica, tela do tutor, botao"
echo "\"Gerar novo convite\" (QR/link prontos pro app do tutor) — OU use o valor completo"
echo "salvo em ./$CONVITES_LOCAL_FILE (arquivo local, gitignored, nunca impresso aqui)."
echo "Pets: Rex (id $ID_PET_1), Mimi (id $ID_PET_2), Bolinha (id $ID_PET_3)"
echo "Consulta: idEventoClinico $ID_EVENTO_CONSULTA"
echo "Dia de clinica (REC-18): hoje 4 agendamentos ($ETAPAS_HOJE) + 1 amanha (Bolinha 09:30, sem D-1) + triagem $ID_TRIAGEM_SEM_AGENDAMENTO sem agendamento (tutor 1)"
echo "D-1 elegivel (tutor com LEMBRETES + WhatsApp do time): rode DEMO_WHATSAPP=<numero> bash scripts/seed-demo-luna.sh em seguida"
echo "Prescricao + receituario: idEventoClinico $ID_EVENTO_PRESCRICAO, idDocumento $ID_DOCUMENTO_RECEITUARIO"
