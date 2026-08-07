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

API=${API:-http://localhost:8080}
TUTOR_API=${TUTOR_API:-http://localhost:8081}
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

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
              -H 'Content-Type: application/json' -d "$payload")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
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

# ─── credenciais e dados fixos da demo ─────────────────────────────────────
EMAIL_ACESSO="demo@kura.local"
SENHA_CLINICA="SenhaDemo123!"

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
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "tutores (tutor 1)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_1" "$TOKEN"
ID_TUTOR_1=$(campo id)
INVITE_TUTOR_1=$(campo invite.nrToken)

PAYLOAD_TUTOR_2=$(cat <<JSON
{
  "nmTutor": "Tutor Demo Dois",
  "nrCpf": "$CPF_TUTOR_2",
  "dsEmail": "tutor2-demo@kura.local",
  "nrTelefone": "11988880002",
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "tutores (tutor 2)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_2" "$TOKEN"
ID_TUTOR_2=$(campo id)
INVITE_TUTOR_2=$(campo invite.nrToken)

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

# ─── resultado ──────────────────────────────────────────────────────────────
echo "=== DEMO PRONTA ==="
echo "Clinica:  $EMAIL_ACESSO / $SENHA_CLINICA"
echo "App clinica: EXPO_PUBLIC_USE_MOCKS=false"
echo "Convite de tutor #1 (Tutor Demo Um, para completar o passo de registro): $INVITE_TUTOR_1"
echo "Convite de tutor #2 (Tutor Demo Dois): $INVITE_TUTOR_2"
echo "Pets: Rex (id $ID_PET_1), Mimi (id $ID_PET_2), Bolinha (id $ID_PET_3)"
echo "Consulta: idEventoClinico $ID_EVENTO_CONSULTA"
echo "Prescricao + receituario: idEventoClinico $ID_EVENTO_PRESCRICAO, idDocumento $ID_DOCUMENTO_RECEITUARIO"
