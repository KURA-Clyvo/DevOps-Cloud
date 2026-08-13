#!/usr/bin/env bash
# Smoke de contrato app -> API. REGRA: todo payload aqui e copiado do onSubmit/service
# do app, com a origem citada. NUNCA acrescentar campo que o app nao envia — se faltar
# campo, isso e o bug que este script existe para achar.
#
# TASK-57 (KURA_BACKLOG_FIX_4). Motivacao: nenhuma suite automatizada deste projeto
# detecta a classe de bug '' -> NULL do Oracle nem divergencia de contrato app<->API —
# os 8 arquivos de teste .NET usam .UseInMemoryDatabase (sem NOT NULL, sem a semantica
# Oracle de string vazia virando NULL) e os testes mobile batem em mocks sinteticos que
# sempre respondem sucesso. Trocar de provider de teste nao resolve (SQLite grava ''
# como nao-nulo e passaria igual) — o unico detector possivel e rodar contra o compose
# real com o payload exato que o cliente envia. Ver relatorio da TASK-57 para a prova
# de que este script realmente pega a classe de bug que motivou o backlog (reversao da
# TASK-56 -> 500 nos 3 endpoints de evento clinico sem dsObservacao).
#
# Uso:
#   cd DevOps-Cloud && bash scripts/smoke-contratos.sh
#
# Pre-requisitos:
#   - docker compose de pe (ver `docker compose ps -a`: 5/5 healthy/Exited(0))
#   - curl no PATH
#   - python (ou python3) no PATH — usado so para parse de JSON (sem dependencia de jq,
#     que nao esta disponivel por padrao no Git Bash do Windows desta equipe)
#
# Fora de escopo (ver relatorio da TASK-57): rodar isto no CI. Exige Oracle no runner
# (~20min + imagem da Luna ~9-10GB) — mesma razao que excluiu o build completo do
# workflow do DevOps-Cloud na TASK-50. E um gate LOCAL, operado manualmente antes de
# qualquer demonstracao — nao roda automatico.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

API=${API:-http://localhost:8080}
TUTOR_API=${TUTOR_API:-http://localhost:8081}

# TASK-69: LUNA_API_KEY autentica os 3 endpoints server-a-servidor consumidos pela IA
# Luna (chamar_apikey, abaixo). Mesma variavel que o compose injeta como Luna__ApiKey
# no kura-api e KURA_API_KEY no luna-ai (docker-compose.yml:109/210) — nao duplicada.
# Aceita override por env var (padrao API/TUTOR_API acima); sem override, le do .env
# deste repo, que e o mesmo arquivo que o compose usa.
LUNA_API_KEY=${LUNA_API_KEY:-}
if [ -z "$LUNA_API_KEY" ] && [ -f .env ]; then
  LUNA_API_KEY=$(grep -m1 '^LUNA_API_KEY=' .env | cut -d= -f2-)
fi
if [ -z "$LUNA_API_KEY" ]; then
  echo "erro: LUNA_API_KEY nao definido (nem env var, nem .env deste repo) — necessario para os checks server-a-servidor da Luna (ver chamar_apikey)." >&2
  exit 2
fi

FALHAS=0
BODY_FILE=$(mktemp)
# Corpo da requisicao vai para disco e e enviado com --data-binary @arquivo, nunca
# como argumento de linha de comando — ver o bloco de comentario acima de chamar().
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

PY=python
command -v python >/dev/null 2>&1 || PY=python3
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "erro: nem 'python' nem 'python3' foram encontrados no PATH — necessario para parse de JSON (sem jq)." >&2
  exit 2
fi

# ─── helpers ────────────────────────────────────────────────────────────────

# ─── envio de corpo: SEMPRE por arquivo, nunca por argumento ────────────────
# Descoberto no G4 do FIX_7 (2026-08-12), com a stack real de pe: passar o corpo
# como ARGUMENTO (`-d "$payload"`) corrompe qualquer byte nao-ASCII no Git Bash do
# Windows. `curl.exe` e binario nativo Win32, e a camada de conversao de argumento
# do MSYS transcodifica o argumento de UTF-8 para o codepage ANSI (cp1252) antes de
# entregar ao processo. Sintoma medido: um em-dash (UTF-8 `e2 80 94`) chegou ao Java
# como o byte solto `0x97` (em-dash do cp1252), e o Jackson devolveu
# "Invalid UTF-8 start byte 0x97" -> **HTTP 500**, num endpoint que estava correto.
#
# Custou um falso REPROVA do G4: o bloco 14 (POST /tutor/agendamentos) acusou 500 e
# a suspeita inicial recaiu sobre a TASK-74a. Provado isolado que era o harness, nao
# o produto: payload so-ASCII via `-d` -> 201; o MESMO em-dash via arquivo -> 201,
# com o servidor devolvendo o caractere intacto no corpo da resposta.
#
# `--data-binary @arquivo` faz curl ler os bytes do disco, sem passar pela conversao
# de argumento. Isso importa alem do cosmetico: este e um produto em PORTUGUES — os
# payloads reais dos apps carregam acento o tempo todo, e um gate que nao consegue
# exercitar UTF-8 e cego justamente onde o produto vive.
chamar() {  # chamar <nome> <esperado> <metodo> <url> <payload> [token]
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5 token=${6:-}
  printf '%s' "$payload" > "$PAYLOAD_FILE"
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json' --data-binary "@$PAYLOAD_FILE")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  local code; code=$(curl "${args[@]}")
  if [ "$code" != "$esperado" ]; then
    echo "FALHA  $nome: esperado $esperado, obtido $code"
    head -c 300 "$BODY_FILE"; echo
    FALHAS=$((FALHAS+1))
  else
    echo "ok     $nome ($code)"
  fi
}

# TASK-69 (KURA_BACKLOG_FIX_6, extensao do G4). Variante de chamar() para os 3
# endpoints server-a-servidor consumidos pela IA Luna (GET /tutores/telefone/{numero},
# POST /luna/interactions, POST /luna/triage) — autenticados por header X-Api-Key
# (LunaApiKeyAuthFilter.cs), nao por "Authorization: Bearer" como o resto da API. Nao
# generaliza chamar() (os chamadores existentes dependem do parametro posicional
# "token" -> Bearer) — helper irmao, minimo, so pra este par de headers.
chamar_apikey() {  # chamar_apikey <nome> <esperado> <metodo> <url> <payload>
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json' -H "X-Api-Key: $LUNA_API_KEY")
  # corpo por arquivo, nunca por argumento — ver bloco de comentario em chamar()
  if [ -n "$payload" ]; then
    printf '%s' "$payload" > "$PAYLOAD_FILE"
    args+=(--data-binary "@$PAYLOAD_FILE")
  fi
  local code; code=$(curl "${args[@]}")
  if [ "$code" != "$esperado" ]; then
    echo "FALHA  $nome: esperado $esperado, obtido $code"
    head -c 300 "$BODY_FILE"; echo
    FALHAS=$((FALHAS+1))
  else
    echo "ok     $nome ($code)"
  fi
}

# TASK-81 (KURA_BACKLOG_FIX_7). Variante de chamar() para POST /api/v1/tutor/
# consentimentos (ConsentimentoBffController.java:57-79) — exige Authorization: Bearer
# (JWT do tutor) E Idempotency-Key na MESMA chamada (o app manda os dois — o header
# nao substitui o JWT, ver consentimentos.service.ts::assinar/revogar no
# mobile-tutor-rn: apiClient injeta o Bearer via interceptor, o service so acrescenta
# o Idempotency-Key). Nao generaliza chamar()/chamar_apikey() — helper irmao minimo,
# so pra este par (Bearer + Idempotency-Key), seguindo a mesma regra do cabecalho.
chamar_idempotency() {  # chamar_idempotency <nome> <esperado> <metodo> <url> <payload> <token> <idem_key>
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5 token=$6 idem=$7
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json' -H "Authorization: Bearer $token"
              -H "Idempotency-Key: $idem")
  # corpo por arquivo, nunca por argumento — ver bloco de comentario em chamar()
  printf '%s' "$payload" > "$PAYLOAD_FILE"
  args+=(--data-binary "@$PAYLOAD_FILE")
  local code; code=$(curl "${args[@]}")
  if [ "$code" != "$esperado" ]; then
    echo "FALHA  $nome: esperado $esperado, obtido $code"
    head -c 300 "$BODY_FILE"; echo
    FALHAS=$((FALHAS+1))
  else
    echo "ok     $nome ($code)"
  fi
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

# CPF valido (11 digitos, sem formatacao) com digito verificador real — algoritmo
# oficial (modulo 11). Gerado por chamada (random.SystemRandom, nao hardcoded) para o
# script ser idempotente entre execucoes.
gerar_cpf() {
  "$PY" -c '
import random
rnd = random.SystemRandom()
def dv(nums):
    s = sum(n * w for n, w in zip(nums, range(len(nums) + 1, 1, -1)))
    r = s % 11
    return 0 if r < 2 else 11 - r
base = [rnd.randint(0, 9) for _ in range(9)]
d1 = dv(base)
d2 = dv(base + [d1])
print("".join(map(str, base + [d1, d2])))
'
}

# CNPJ valido, FORMATADO (00.000.000/0000-00) — os validators .NET exigem esse formato
# exato (RegisterClinicaValidator.NrCnpj: regex \d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}).
# Filial fixa em "0001", 8 digitos de raiz aleatorios, 2 digitos verificadores reais.
gerar_cnpj() {
  "$PY" -c '
import random
rnd = random.SystemRandom()
def dv(nums, weights):
    s = sum(n * w for n, w in zip(nums, weights))
    r = s % 11
    return 0 if r < 2 else 11 - r
base = [rnd.randint(0, 9) for _ in range(8)] + [0, 0, 0, 1]
w1 = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
w2 = [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
d1 = dv(base, w1)
d2 = dv(base + [d1], w2)
s = "".join(map(str, base + [d1, d2]))
print(f"{s[0:2]}.{s[2:5]}.{s[5:8]}/{s[8:12]}-{s[12:14]}")
'
}

agora_iso() { "$PY" -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))'; }

# TASK-81 (KURA_BACKLOG_FIX_7). UUID v4 — para o header Idempotency-Key exigido por
# POST /api/v1/tutor/consentimentos (ConsentimentoBffController.java, ver bloco 15).
gerar_uuid() { "$PY" -c 'import uuid; print(uuid.uuid4())'; }

# TASK-81. `dtAgendamento` de AgendamentoRequest.java (backend-tutor-java) e um
# LocalDateTime SEM fuso, com @Future — o Jackson do lado Java desserializa relogio
# de parede puro. Formata 10 dias no futuro, hora fixa 10:30 — folga bem maior que
# qualquer diferenca de fuso entre o host que roda este script e a JVM do container
# (que roda em UTC, TASK-87 ainda nao corrigida), entao nao ha risco de a data cair
# no passado por causa de conversao de fuso.
data_futura_java() { "$PY" -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(days=10)).strftime("%Y-%m-%dT10:30:00"))'; }

# ─── dados unicos desta execucao (idempotencia — nunca hardcoded) ──────────
# Curto de proposito: NrCRMV tem MaximumLength(20) e usa "CRMV-$SUFIXO" — precisa
# caber com folga (epoch mod 1e6 + $RANDOM fica sempre <= 11 digitos).
SUFIXO="$(( $(date +%s) % 1000000 ))${RANDOM}"
CPF_TUTOR=$(gerar_cpf)
CNPJ_CLINICA=$(gerar_cnpj)
AGORA=$(agora_iso)

echo "=== smoke-contratos.sh — sufixo desta execucao: $SUFIXO ==="
echo

# ─── 1. Cadastro da clinica ───────────────────────────────────────────────
# Origem: mobile-clinica-rn/src/services/auth.service.ts:21 (chamada) — o shape do
# payload (campos e obrigatoriedade) vem de mobile-clinica-rn/src/app/register.tsx:
# schema em 27-39, onSubmit em 119-122 (envia todo o form exceto confirmSenha; NAO
# envia nmRazaoSocial — campo opcional que o form nem tem).
PAYLOAD_REGISTER_CLINICA=$(cat <<JSON
{
  "nmClinica": "Clinica Smoke $SUFIXO",
  "nrCnpj": "$CNPJ_CLINICA",
  "dsEndereco": "Rua Smoke Test, 100",
  "nmCidade": "Sao Paulo",
  "sgUf": "SP",
  "nrCep": "01000-000",
  "nrTelefone": "11999990000",
  "dsEmail": "clinica-smoke-$SUFIXO@kura-smoke.test",
  "dsEmailAcesso": "vet-smoke-$SUFIXO@kura-smoke.test",
  "dsSenha": "SmokeTest123",
  "nmVeterinarioAdmin": "Vet Smoke $SUFIXO",
  "nrCRMV": "CRMV-$SUFIXO"
}
JSON
)
chamar "auth/register-clinica" 201 POST "$API/api/v1/auth/register-clinica" "$PAYLOAD_REGISTER_CLINICA"
TOKEN=$(campo accessToken)
ID_VETERINARIO=$(campo usuario.id)

# ─── 2. GET /pets (contexto de clinica) ──────────────────────────────────
# Origem: mobile-clinica-rn/src/services/pets.service.ts:5
chamar "pets/listar" 200 GET "$API/api/v1/pets" '' "$TOKEN"

# ─── setup (nao coberto por tela do app — necessario para os testes seguintes) ──
# POST /api/v1/tutores nao esta na tabela de cobertura da TASK-57 (nenhuma tela do app
# chama diretamente hoje neste form — o app usa hooks que nao apareceram na varredura
# do brief); construido direto contra Kura.Application/DTOs/Tutor/TutorCreateDto.cs e
# TutorCreateValidator.cs so para obter um invite valido, insumo do teste 11.
PAYLOAD_TUTOR=$(cat <<JSON
{
  "nmTutor": "Tutor Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR",
  "dsEmail": "tutor-smoke-$SUFIXO@kura-smoke.test",
  "nrTelefone": "11988880000",
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "setup/tutores" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR" "$TOKEN"
INVITE_TOKEN=$(campo invite.nrToken)

# POST /api/v1/pets tambem nao tem tela no app hoje (mobile-clinica-rn nao tem cadastro
# de pet — so consome GET). idEspecie=1/idRaca=1 vem do catalogo fixo semeado por
# V14__seed_referencia.sql (Cao/Labrador) — os unicos valores manuais permitidos pela
# regra do brief ("completar campos obrigatorios do catalogo").
ID_TUTOR=$(campo id)
PAYLOAD_PET=$(cat <<JSON
{
  "idEspecie": 1,
  "idRaca": 1,
  "nmPet": "Pet Smoke $SUFIXO",
  "dtNascimento": "2022-01-01T00:00:00Z",
  "sgSexo": "M",
  "sgPorte": "M",
  "idTutor": $ID_TUTOR,
  "stPrincipal": true,
  "dsVinculo": "PROPRIETARIO"
}
JSON
)
chamar "setup/pets" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET" "$TOKEN"
ID_PET=$(campo id)

# ─── 3. Consulta — dsObservacao vazio (o caso que estourava ORA-01400) ────
# Origem: mobile-clinica-rn/src/app/(app)/consulta/[idPet].tsx:186 (defaultValues:
# dsObservacao: '') e 192-204 (onSubmit — envia dsObservacao: data.dsObservacao, que o
# vet pode legitimamente deixar vazio: o form SOAP so exige um dos quatro campos S/O/A/P).
PAYLOAD_CONSULTA=$(cat <<JSON
{
  "idPet": $ID_PET,
  "idVeterinario": $ID_VETERINARIO,
  "dtConsulta": "$AGORA",
  "dsMotivo": "Consulta de rotina",
  "dsAnamnese": "Sem queixas relevantes",
  "dsExameFisico": "Normal",
  "dsDiagnostico": "Saudavel",
  "dsObservacao": ""
}
JSON
)
chamar "eventos-clinicos/consultas (dsObservacao vazio)" 201 POST "$API/api/v1/eventos-clinicos/consultas" "$PAYLOAD_CONSULTA" "$TOKEN"
# TASK-81: capturado aqui (nao so no bloco 18) porque tambem alimenta o check de
# timeline do tutor (bloco 17) — ConsultaResponseDto.IdEventoClinico (camelCase
# padrao do System.Text.Json: idEventoClinico).
ID_EVENTO_CONSULTA=$(campo idEventoClinico)

# ─── 4. GET /medicamentos ─────────────────────────────────────────────────
# Origem: mobile-clinica-rn/src/services/eventos-clinicos.service.ts:36
chamar "medicamentos/listar" 200 GET "$API/api/v1/medicamentos" '' "$TOKEN"
ID_MEDICAMENTO=$(campo items.0.id 2>/dev/null || echo 1)

# ─── 5. Prescricao — dsObservacao vazio (app envia "", nao omite mais) ───
# Origem: mobile-clinica-rn/src/app/(app)/receituario/[idPet].tsx:191-197 (defaultValues,
# dsObservacao: '') e 219-230 (onSubmit — envia dsObservacao: data.dsObservacao junto com
# idPet, idVeterinario, dtEvento, idMedicamento, dsPosologia, nrDuracaoDias). Ate a
# TASK-62 (e434f62, com fix wave adicional em a15fca3) o form nao tinha esse campo e o
# app de fato nunca enviava a chave — hoje ele envia sempre, vazio por padrao se o vet
# nao preencher. Este e um dos 3 endpoints de evento clinico que a prova de que morde da
# TASK-57 usa; o coalesce do backend trata ausente e "" da mesma forma, entao o 201
# esperado nao muda.
PAYLOAD_PRESCRICAO=$(cat <<JSON
{
  "idPet": $ID_PET,
  "idVeterinario": $ID_VETERINARIO,
  "dtEvento": "$AGORA",
  "idMedicamento": $ID_MEDICAMENTO,
  "dsPosologia": "1 comprimido a cada 12h por 7 dias",
  "nrDuracaoDias": 7,
  "dsObservacao": ""
}
JSON
)
chamar "eventos-clinicos/prescricoes (dsObservacao vazio)" 201 POST "$API/api/v1/eventos-clinicos/prescricoes" "$PAYLOAD_PRESCRICAO" "$TOKEN"
# TASK-81: PrescricaoResponseDto.IdEventoClinico — insumo do bloco 18 (receituario
# exige uma Prescricao pre-existente para o evento clinico, ver GerarReceituarioAsync).
ID_EVENTO_PRESCRICAO=$(campo idEventoClinico)

# ─── 6. GET /dashboard/hoje ───────────────────────────────────────────────
# Origem: mobile-clinica-rn/src/services/dashboard.service.ts:131
chamar "dashboard/hoje" 200 GET "$API/api/v1/dashboard/hoje" '' "$TOKEN"

# ─── 7/8. Vacina e exame — sem consumidor no app hoje ─────────────────────
# sem consumidor no app — cobre a API diretamente. Nenhuma tela cria vacina/exame hoje
# (achado da TASK-56/56-brief: foi exatamente essa ausencia de consumidor que escondeu
# o 500 original que motivou este backlog). Payloads construidos direto contra
# Kura.Application/DTOs/Vacina/VacinaCreateDto.cs e DTOs/Exame/ExameCreateDto.cs +
# validators — sem dsObservacao, reproduzindo o payload que um cliente hipotetico sem
# esse campo enviaria (igual prescricao/exame reais).
PAYLOAD_VACINA=$(cat <<JSON
{
  "idPet": $ID_PET,
  "idVeterinario": $ID_VETERINARIO,
  "dtEvento": "$AGORA",
  "nmVacina": "V10",
  "nrLote": "LOTE-$SUFIXO",
  "dsFabricante": "Fabricante Smoke"
}
JSON
)
chamar "eventos-clinicos/vacinas (sem dsObservacao)" 201 POST "$API/api/v1/eventos-clinicos/vacinas" "$PAYLOAD_VACINA" "$TOKEN"

PAYLOAD_EXAME=$(cat <<JSON
{
  "idPet": $ID_PET,
  "idVeterinario": $ID_VETERINARIO,
  "dtEvento": "$AGORA",
  "nmExame": "Hemograma completo",
  "dsResultado": "Dentro dos parametros normais",
  "dtRealizacao": "$AGORA"
}
JSON
)
chamar "eventos-clinicos/exames (sem dsObservacao)" 201 POST "$API/api/v1/eventos-clinicos/exames" "$PAYLOAD_EXAME" "$TOKEN"

# ─── 9. Cadastro do tutor por convite (mobile-tutor-rn) ───────────────────
# Origem: mobile-tutor-rn/src/services/auth.service.ts — register() (linhas 58-63):
# POST /api/v1/auth/register-invite com { token, senha, aceites }. `aceites` (pos-
# TASK-61, linhas 24-56): array de AceiteInviteApi montado por montarAceites() a partir
# do que o tutor marcou no form — aqui simulamos os dois aceites marcados (LEMBRETES e
# TELEORIENTACAO), com versaoTermo 'v1.0' (VERSAO_TERMO_ATUAL, linha 39), igual ao app
# manda quando o usuario aceita os dois. Senha respeita RegisterInviteRequest.java
# (min 8, 1 maiuscula, 1 minuscula, 1 numero).
PAYLOAD_REGISTER_INVITE=$(cat <<JSON
{
  "token": "$INVITE_TOKEN",
  "senha": "SmokeTest123",
  "aceites": [
    { "tipo": "LEMBRETES", "versaoTermo": "v1.0", "aceito": true },
    { "tipo": "TELEORIENTACAO", "versaoTermo": "v1.0", "aceito": true }
  ]
}
JSON
)
chamar "tutor/auth/register-invite" 201 POST "$TUTOR_API/api/v1/auth/register-invite" "$PAYLOAD_REGISTER_INVITE"

# ─── 10. TASK-60: pares DTO x coluna NOT NULL confirmados pela varredura ──
# Ver backend-clinica-dotnet/docs/NOT-NULL-audit.md e o relatorio da TASK-60
# (KURA_BACKLOG_FIX_4) para a varredura completa. Os 5 casos abaixo (4 colunas
# Oracle distintas) reproduziram 500/ORA-01400 real antes do fix (370ab7b em
# diante) e agora devem devolver 2xx com o sentinela persistido — regressao
# aqui significa que alguem removeu o coalesce do service correspondente.
# Nenhum dos 4 tem tela no app hoje (mesma situacao de vacina/exame no bloco
# 7/8 acima) — payloads construidos direto contra os DTOs/validators reais.

# 10a. Medicamento sem dsApresentacao (MEDICAMENTO.DS_APRESENTACAO NOT NULL,
# MedicamentoCreateValidator nunca teve NotEmpty() pra esse campo).
PAYLOAD_MEDICAMENTO_SEM_APRES=$(cat <<JSON
{
  "nmMedicamento": "Medicamento Smoke $SUFIXO",
  "dsPrincipioAtivo": "Principio Ativo Smoke"
}
JSON
)
chamar "medicamentos/POST (sem dsApresentacao)" 201 POST "$API/api/v1/medicamentos" "$PAYLOAD_MEDICAMENTO_SEM_APRES" "$TOKEN"

# 10b. Tutor (create) sem nrTelefone (TUTOR.DS_TELEFONE NOT NULL,
# TutorCreateValidator nunca teve regra pra esse campo).
CPF_TUTOR_TASK60=$(gerar_cpf)
PAYLOAD_TUTOR_SEM_TEL=$(cat <<JSON
{
  "nmTutor": "Tutor SemTel Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR_TASK60",
  "dsEmail": "tutor-semtel-smoke-$SUFIXO@kura-smoke.test",
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "tutores/POST (sem nrTelefone)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_SEM_TEL" "$TOKEN"

# 10c. Tutor (update) sem nrTelefone — mesmo gap, TutorUpdateValidator tambem
# nunca teve regra pra esse campo. Reusa o tutor do bloco "setup" (ID_TUTOR).
PAYLOAD_TUTOR_UPD_SEM_TEL=$(cat <<JSON
{
  "nmTutor": "Tutor Update SemTel Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR",
  "dsEmail": "tutor-smoke-$SUFIXO@kura-smoke.test"
}
JSON
)
chamar "tutores/PUT (sem nrTelefone)" 200 PUT "$API/api/v1/tutores/$ID_TUTOR" "$PAYLOAD_TUTOR_UPD_SEM_TEL" "$TOKEN"

# 10d. Vacina sem dsFabricante (VACINA.DS_FABRICANTE NOT NULL,
# VacinaCreateValidator nunca teve regra pra esse campo).
PAYLOAD_VACINA_SEM_FAB=$(cat <<JSON
{
  "idPet": $ID_PET,
  "idVeterinario": $ID_VETERINARIO,
  "dtEvento": "$AGORA",
  "nmVacina": "V10 Smoke",
  "nrLote": "LOTE60-$SUFIXO"
}
JSON
)
chamar "eventos-clinicos/vacinas (sem dsFabricante)" 201 POST "$API/api/v1/eventos-clinicos/vacinas" "$PAYLOAD_VACINA_SEM_FAB" "$TOKEN"

# 10e. Pet com dsVinculo vazio explicito (TUTOR_PET.DS_VINCULO NOT NULL).
# Diferente dos outros 3: PetCreateDto.DsVinculo ja tem default nomeado
# "PROPRIETARIO" (nao string.Empty) — so quebra se o cliente mandar "" de
# proposito. Simulado aqui porque nenhum form do app envia esse campo hoje
# (GET-only em mobile-clinica-rn), entao um futuro form que inicialize o
# state com "" reproduziria isso sem aviso.
PAYLOAD_PET_DSVINCULO_VAZIO=$(cat <<JSON
{
  "idEspecie": 1,
  "idRaca": 1,
  "nmPet": "Pet DsVinculo Smoke $SUFIXO",
  "dtNascimento": "2022-01-01T00:00:00Z",
  "sgSexo": "M",
  "sgPorte": "M",
  "idTutor": $ID_TUTOR,
  "stPrincipal": true,
  "dsVinculo": ""
}
JSON
)
chamar "pets/POST (dsVinculo vazio explicito)" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET_DSVINCULO_VAZIO" "$TOKEN"

# ─── 11. TASK-63: GET /pets/{id}/timeline nao devolve mais 500 ───────────
# Origem do bug: TimelineRepository.GetByPetIdAsync (backend-clinica-dotnet) consultava
# VW_TIMELINE_PET via FromSqlRaw — view Flyway (backend-tutor-java) derivada de
# AGENDAMENTO, sem DS_OBSERVACAO/NM_VETERINARIO, causando ORA-00904 contra Oracle real.
# Fix: consulta EventoClinico direto via LINQ. ID_PET ja tem 2 eventos clinicos criados
# nos blocos 3 (consulta) e 5 (prescricao) acima — suficiente pra provar 200 com lista
# nao-vazia e sem estourar 500. Nao valida ordenacao/conteudo aqui (isso e coberto pelos
# testes automatizados .NET, TimelineRepositoryTests.cs) — este script so precisa provar
# que o endpoint nao quebra mais contra o Oracle real, que era exatamente o sintoma que
# nenhuma suite com .UseInMemoryDatabase conseguia pegar (FromSqlRaw nem roda no
# InMemory, entao o bug real ficava invisivel pros testes ate bater no compose).
chamar "pets/timeline (GET, nao mais 500)" 200 GET "$API/api/v1/pets/$ID_PET/timeline" '' "$TOKEN"

# ─── 12. TASK-69: os 3 endpoints server-a-servidor da IA Luna ────────────
# Regra de ouro v6 do KURA_BACKLOG_FIX_6: nenhum gate deste projeto tinha verificado que
# a contraparte .NET destes 3 endpoints existisse de verdade — a Luna chamava rotas que
# nunca foram implementadas (TASK-66/67 fecharam o gap: schema V15 + os 3 endpoints).
# Autenticacao: X-Api-Key (chamar_apikey), NAO "Authorization: Bearer" — ver
# LunaApiKeyAuthFilter.cs. Payloads copiados campo a campo, literalmente, de
# kura-luna-ai/luna/src/integration/dtos.py — chaves snake_case (id_tutor, ds_canal...),
# sem traducao pra camelCase: InteractionRequestDto/TriageRequestDto do .NET usam
# [JsonPropertyName] pra espelhar 1:1 o Pydantic (ver Kura.Application/DTOs/Luna/*.cs).
# kura_client.py serializa com dto.model_dump(mode="json") (linhas 83-97 e 103-116).

# Tutor dedicado a este bloco (telefone com sufixo desta execucao — GET
# /tutores/telefone/{numero} nao tem escopo de clinica sem JWT, entao um telefone fixo
# reusado entre execucoes acumularia tutores ambiguos; sufixado, cada execucao fica
# inequivoca). Mesmo payload/origem do bloco "setup" acima (TutorCreateDto).
CPF_TUTOR_LUNA=$(gerar_cpf)
NR_TELEFONE_LUNA="1199${SUFIXO}"
PAYLOAD_TUTOR_LUNA=$(cat <<JSON
{
  "nmTutor": "Tutor Luna Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR_LUNA",
  "dsEmail": "tutor-luna-smoke-$SUFIXO@kura-smoke.test",
  "nrTelefone": "$NR_TELEFONE_LUNA",
  "dsCanalConvite": "EMAIL"
}
JSON
)
chamar "setup/tutores (para checks Luna)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_LUNA" "$TOKEN"
ID_TUTOR_LUNA=$(campo id)

# 12a. GET /api/v1/tutores/telefone/{numero} — tutor conhecido (TutoresController.cs:81-91).
chamar_apikey "luna/tutores-telefone (tutor conhecido)" 200 GET "$API/api/v1/tutores/telefone/$NR_TELEFONE_LUNA" ''

# 12b. POST /api/v1/luna/interactions — id_tutor conhecido (2xx esperado).
# Origem: InteractionRequestDTO, dtos.py:29-37 (id_tutor, ds_canal, ds_direcao,
# ds_conteudo, dt_recebimento, ds_metadados). ds_metadados vai null porque
# inbound_message_service.py nunca popula esse campo (nao e omitido do payload —
# model_dump(mode="json") sem exclude_none inclui a chave com valor null).
PAYLOAD_LUNA_INTERACTION=$(cat <<JSON
{
  "id_tutor": $ID_TUTOR_LUNA,
  "ds_canal": "WHATSAPP",
  "ds_direcao": "INBOUND",
  "ds_conteudo": "Mensagem de smoke test do script automatizado.",
  "dt_recebimento": "$AGORA",
  "ds_metadados": null
}
JSON
)
chamar_apikey "luna/interactions (id_tutor conhecido)" 201 POST "$API/api/v1/luna/interactions" "$PAYLOAD_LUNA_INTERACTION"
ID_INTERACAO_LUNA=$(campo id_interacao)

# 12c. POST /api/v1/luna/interactions — id_tutor null (tutor desconhecido pela Luna,
# inbound_message_service.py:85).
#
# TASK-81 (achado ao vivo, nao so leitura de doc): este check estava DESATUALIZADO
# contra o codigo real no momento em que esta task rodou — CLAUDE.md ainda descrevia
# "422 por design" (o comportamento fechado pela TASK-67/FIX_6) como se fosse o
# estado atual, mas backend-clinica-dotnet@7642f4e ("fix(luna): allow interaction to
# be recorded when tutor is unknown (TASK-77)"), commit presente no working tree no
# momento desta task, MUDOU o contrato: LunaService.RegistrarInteracaoAsync (linhas
# 82-120) para de lancar RegraDeNegocioException quando dto.IdTutor e null — passa a
# GRAVAR a interacao com IdClinica/IdTutor nulos (viavel desde que
# INTERACAO_CANAL.ID_CLINICA virou nullable, V16, TASK-76). Decisao de produto do
# Felipe (ver CLAUDE.md, cadeia V16 TASK-76->78): o ganho e auditoria, nao
# visibilidade — uma linha com ID_CLINICA nulo fica invisivel a qualquer leitura
# escopada por clinica.
#
# Exatamente o tipo de drift que a regra de ouro v7 deste backlog existe para achar:
# um check hardcoded que ficou correto no dia em que foi escrito e ficou errado
# silenciosamente quando o contrato mudou embaixo dele, sem nenhum teste acusar.
# Atualizado aqui para o contrato REAL (201), nao o que a documentacao desatualizada
# alegava — ver a regra do cabecalho deste script ("valor esperado tem que ser o
# contrato real conferido na fonte").
PAYLOAD_LUNA_INTERACTION_SEM_TUTOR=$(cat <<JSON
{
  "id_tutor": null,
  "ds_canal": "WHATSAPP",
  "ds_direcao": "INBOUND",
  "ds_conteudo": "Mensagem de tutor desconhecido (id_tutor null).",
  "dt_recebimento": "$AGORA",
  "ds_metadados": null
}
JSON
)
chamar_apikey "luna/interactions (id_tutor null — TASK-77: grava com id_clinica nulo, nao mais 422)" 201 POST "$API/api/v1/luna/interactions" "$PAYLOAD_LUNA_INTERACTION_SEM_TUTOR"

# 12d. POST /api/v1/luna/triage — liga-se a interacao criada em 12b.
# Origem: TriageRequestDTO, dtos.py:46-54 (id_interacao, id_tutor, sintomas,
# ds_urgencia, nr_score, ds_recomendacao).
PAYLOAD_LUNA_TRIAGE=$(cat <<JSON
{
  "id_interacao": $ID_INTERACAO_LUNA,
  "id_tutor": $ID_TUTOR_LUNA,
  "sintomas": ["vomito", "letargia"],
  "ds_urgencia": "MEDIA",
  "nr_score": 55,
  "ds_recomendacao": "Observar por 24h e retornar se os sintomas persistirem."
}
JSON
)
chamar_apikey "luna/triage" 201 POST "$API/api/v1/luna/triage" "$PAYLOAD_LUNA_TRIAGE"

# ═══════════════════════════════════════════════════════════════════════════
# TASK-81 (KURA_BACKLOG_FIX_7). Blocos 13-20: extensao de 22 para ~49 checks.
#
# Motivacao (regra de ouro v7): a auditoria que abriu este ciclo mediu que este
# script cobria MENOS DE UM QUINTO da superficie de consumo real dos 2 apps mobile
# — e foi exatamente na parte descoberta que estavam os achados Critical do FIX_7
# (consentimento LGPD do tutor morto em modo real, "Solicitar agendamento" 400
# garantido). Os blocos abaixo fecham a maior parte da lacuna: toda funcao
# exportada de src/services/*.service.ts nos 2 apps que faz chamada HTTP real e
# nao tinha check antes desta task, cobrindo o que era seguro cobrir sem rodar
# fluxo de audio/Whisper nem disparar mensagem real via Twilio (ver
# scripts/../mobile-clinica-rn/tests/smoke-coverage.test.ts e
# mobile-tutor-rn/src/__tests__/smoke-coverage.test.ts para o detector que
# verifica, a partir do CODIGO (nao de lista escrita a mao), que toda funcao de
# service nova entra ou neste script ou numa entrada `naoCoberto` com razao
# explicita — nunca cai fora dos dois em silencio).
#
# 3 funcoes ficaram de fora de proposito, marcadas `naoCoberto` no registry dos
# apps (nao neste script): enviarTranscricao (multipart de audio real + round-trip
# Whisper via Luna — pesado/nao-deterministico demais pra smoke test),
# enviarWhatsApp (dispara SMS/WhatsApp real via Twilio — side-effecting, alem de
# imprevisivel com as credenciais Twilio dummy deste ambiente) e getLunaHealth
# (bate direto no servico Python da Luna, nao no .NET/Java — terceiro upstream sem
# LUNA_BASE_URL modelado neste script; candidato a follow-up, nao resolvido aqui).
# ═══════════════════════════════════════════════════════════════════════════

# ─── 13. Login isolado (nao testado antes — so via register/register-invite) ──
# Origem: mobile-clinica-rn/src/services/auth.service.ts::login (linha 9-12) e
# mobile-tutor-rn/src/services/auth.service.ts::login (linha 4-7). Reusa as
# credenciais criadas nos blocos 1 (vet-smoke) e 9 (tutor-smoke).

# 13a. POST /api/v1/auth/login (clinica) — LoginDto.DsEmail/DsSenha (sem
# validator, ver AuthController.cs:26-33 — credencial ruim daria 422, nao testado
# aqui porque a regra do script e so payload real do app com credencial valida).
PAYLOAD_LOGIN_CLINICA=$(cat <<JSON
{
  "dsEmail": "vet-smoke-$SUFIXO@kura-smoke.test",
  "dsSenha": "SmokeTest123"
}
JSON
)
chamar "auth/login (clinica)" 200 POST "$API/api/v1/auth/login" "$PAYLOAD_LOGIN_CLINICA"

# 13b. POST /api/v1/auth/login (tutor) — LoginRequest.java usa email/senha, NAO
# dsEmail/dsSenha (divergencia da convencao .NET, confirmada na fonte:
# auth/api/dto/LoginRequest.java:8-17). Credenciais do tutor criado no bloco
# "setup" + registrado por convite no bloco 9.
PAYLOAD_LOGIN_TUTOR=$(cat <<JSON
{
  "email": "tutor-smoke-$SUFIXO@kura-smoke.test",
  "senha": "SmokeTest123"
}
JSON
)
chamar "tutor/auth/login" 200 POST "$TUTOR_API/api/v1/auth/login" "$PAYLOAD_LOGIN_TUTOR"
TUTOR_TOKEN=$(campo accessToken)

# ─── 14. tutor/agendamentos (mobile-tutor-rn::agendamentos.service.ts) ────────
# Origem: listAgendamentos (linha 4-5), solicitarAgendamento (linha 67-73) —
# corpo ja mapeado pra AgendamentoRequestJava real (TASK-74b, FIX_7):
# idPet/dtAgendamento/tipo/observacoes, SEM idClinica (decisao do Felipe — Java
# deriva a clinica do pet) e SEM idVeterinario/duracaoMinutos (a tela nao coleta).
# cancelarAgendamento (linha 75-76).

chamar "tutor/agendamentos (GET lista)" 200 GET "$TUTOR_API/api/v1/tutor/agendamentos" '' "$TUTOR_TOKEN"

# AG1: para o bloco 20 (teleconsulta) — tipo TELEORIENTACAO so por realismo
# semantico; TeleconsultaService.GarantirConsentimentoAsync (backend-clinica-
# dotnet) so exige consentimento TELEORIENTACAO aceito do TUTOR do agendamento,
# nao verifica o campo `tipo` do agendamento em si (conferido na fonte,
# TeleconsultaService.cs:71-81) — o tutor-smoke ja tem esse consentimento aceito
# desde o aceites[] do register-invite (bloco 9).
PAYLOAD_AGENDAMENTO_AG1=$(cat <<JSON
{
  "idPet": $ID_PET,
  "dtAgendamento": "$(data_futura_java)",
  "tipo": "TELEORIENTACAO",
  "observacoes": "Agendamento smoke test — reservado para teleconsulta (bloco 20)."
}
JSON
)
chamar "tutor/agendamentos (POST — AG1, para teleconsulta)" 201 POST "$TUTOR_API/api/v1/tutor/agendamentos" "$PAYLOAD_AGENDAMENTO_AG1" "$TUTOR_TOKEN"
ID_AGENDAMENTO_TELE=$(campo idAgendamento)

# AG2: descartavel, so para o check de cancelamento (DELETE).
PAYLOAD_AGENDAMENTO_AG2=$(cat <<JSON
{
  "idPet": $ID_PET,
  "dtAgendamento": "$(data_futura_java)",
  "tipo": "CONSULTA",
  "observacoes": "Agendamento smoke test — sera cancelado (bloco 14d)."
}
JSON
)
chamar "tutor/agendamentos (POST — AG2, para cancelar)" 201 POST "$TUTOR_API/api/v1/tutor/agendamentos" "$PAYLOAD_AGENDAMENTO_AG2" "$TUTOR_TOKEN"
ID_AGENDAMENTO_CANCELAR=$(campo idAgendamento)

# Confirmado na fonte (AgendamentoBffController.java:84-99): 204 sem corpo.
chamar "tutor/agendamentos (DELETE — cancelar AG2)" 204 DELETE "$TUTOR_API/api/v1/tutor/agendamentos/$ID_AGENDAMENTO_CANCELAR" '' "$TUTOR_TOKEN"

# ─── 15. tutor/consentimentos (mobile-tutor-rn::consentimentos.service.ts) ───
# Origem: listConsentimentos (linha 18-19), assinar (linha 21-25), revogar
# (linha 31-35) — todos exigem Authorization: Bearer (interceptor do apiClient)
# E Idempotency-Key (ConsentimentoBffController.java:57-79, @RequestHeader
# obrigatorio) na MESMA chamada — chamar_idempotency() injeta os dois.
# tipo=MARKETING de proposito: os 2 tipos que o register-invite (bloco 9) ja
# assinou (LEMBRETES/TELEORIENTACAO) tornariam o 200/201 esperado ambiguo
# (replay de idempotencia vs insercao nova) — MARKETING nunca foi tocado antes
# deste bloco, entao o POST e garantidamente uma insercao nova (201).
#
# TASK-81, rodada de fix 1 (G2 achou Critical #2 — task-81-review.md secao 3): o
# check de "revogar" abaixo esperava 200. ERRADO — confirmado ate um teste
# automatizado ja existente no proprio repo Java. ConsentimentoBffController.
# registrar (linha 77): `status = result.criado() ? CREATED : OK`.
# ConsentimentoService.registrarComIdempotencia (linhas 79-98, comentario
# linhas 25-27: "REGRA ABSOLUTA: nunca UPDATE — sempre INSERT"): `criado()` so
# e false quando a Idempotency-Key JA EXISTE (replay). Como cada chamada deste
# bloco usa `$(gerar_uuid)` — uma key NOVA a cada invocacao — as duas chamadas
# (assinar E revogar) sao insercoes genuinamente novas do ponto de vista do
# servidor, nunca um replay. `aceito` ("S" ou "N") NAO entra na decisao de
# status em nenhum ramo do codigo — "revogar" nao e tratado como update em
# lugar nenhum. ConsentimentoServiceTest.duasChamadasComKeysDiferentesCriamDoisRegistros
# (linhas 109-141) confirma: 2 chamadas com keys diferentes -> `criado()==true`
# nas DUAS, sempre 201. Corrigido de 200 para 201 abaixo — um check errado no
# instrumento de medida e pior que um bug no codigo medido (teria gerado FALHA
# falsa contra um servidor correto no primeiro G4 pos-resync).

chamar "tutor/consentimentos (GET lista)" 200 GET "$TUTOR_API/api/v1/tutor/consentimentos" '' "$TUTOR_TOKEN"

PAYLOAD_CONSENTIMENTO_ASSINAR=$(cat <<JSON
{
  "tipo": "MARKETING",
  "versaoTermo": "v1.0",
  "aceito": "S"
}
JSON
)
chamar_idempotency "tutor/consentimentos (POST — assinar MARKETING)" 201 POST "$TUTOR_API/api/v1/tutor/consentimentos" "$PAYLOAD_CONSENTIMENTO_ASSINAR" "$TUTOR_TOKEN" "$(gerar_uuid)"

PAYLOAD_CONSENTIMENTO_REVOGAR=$(cat <<JSON
{
  "tipo": "MARKETING",
  "versaoTermo": "v1.0",
  "aceito": "N"
}
JSON
)
chamar_idempotency "tutor/consentimentos (POST — revogar MARKETING)" 201 POST "$TUTOR_API/api/v1/tutor/consentimentos" "$PAYLOAD_CONSENTIMENTO_REVOGAR" "$TUTOR_TOKEN" "$(gerar_uuid)"

# ─── 16. tutor/notificacoes e tutor/me/push-token ─────────────────────────────
# Origem: mobile-tutor-rn/src/services/notifications.service.ts::getNotificacoes
# (linha 13-15) e registerDeviceToken (linha 61-75, TASK-70 — dsPlatforma em
# PT-BR, nao dsPlatform).

chamar "tutor/notificacoes (GET)" 200 GET "$TUTOR_API/api/v1/tutor/notificacoes" '' "$TUTOR_TOKEN"

PAYLOAD_PUSH_TOKEN=$(cat <<JSON
{
  "dsPushToken": "ExponentPushToken[smoke-$SUFIXO]",
  "dsPlatforma": "android"
}
JSON
)
chamar "tutor/me/push-token (PATCH)" 204 PATCH "$TUTOR_API/api/v1/tutor/me/push-token" "$PAYLOAD_PUSH_TOKEN" "$TUTOR_TOKEN"

# ─── 17. tutor/pets, timeline e vacinas ───────────────────────────────────────
# Origem: mobile-tutor-rn/src/services/pets.service.ts, timeline.service.ts,
# vacinas.service.ts. ID_PET pertence ao tutor-smoke desde o bloco "setup"
# (PAYLOAD_PET.idTutor=$ID_TUTOR, o mesmo tutor que assinou o convite no bloco 9).

chamar "tutor/pets (GET lista)" 200 GET "$TUTOR_API/api/v1/tutor/pets" '' "$TUTOR_TOKEN"
chamar "tutor/pets/{id} (GET detalhe)" 200 GET "$TUTOR_API/api/v1/tutor/pets/$ID_PET" '' "$TUTOR_TOKEN"

# GET timeline: TutorBffController.timelinePet le VW_TIMELINE_PET
# (TimelinePet.java:7-11), uma view baseada em AGENDAMENTO (nao em
# EVENTO_CLINICO — achado ja documentado em CLAUDE.md pela TASK-63: foi
# exatamente a base AGENDAMENTO dessa view que fez o .NET abandona-la pro
# proprio uso). Isso significa que a consulta/prescricao dos blocos 3/5 (tabela
# EVENTO_CLINICO, .NET-owned) NAO aparecem aqui — quem aparece sao os
# agendamentos AG1/AG2 do bloco 14, criados no mesmo pet. idEvento e o campo
# real (TimelineEventoResponse.java:10), nao idEventoClinico.
chamar "tutor/pets/{id}/timeline (GET)" 200 GET "$TUTOR_API/api/v1/tutor/pets/$ID_PET/timeline" '' "$TUTOR_TOKEN"
ID_EVENTO_TIMELINE_TUTOR=$(campo content.0.idEvento)

chamar "tutor/pets/{id}/timeline/{idEvento} (GET detalhe)" 200 GET "$TUTOR_API/api/v1/tutor/pets/$ID_PET/timeline/$ID_EVENTO_TIMELINE_TUTOR" '' "$TUTOR_TOKEN"

# Pode devolver lista vazia (VW_VACINAS_VENCENDO so lista pendencia futura, e
# nenhum bloco deste script cria Vacina para este pet) — 200 e o contrato
# esperado em ambos os casos, vazio ou nao.
chamar "tutor/pets/{id}/vacinas (GET)" 200 GET "$TUTOR_API/api/v1/tutor/pets/$ID_PET/vacinas" '' "$TUTOR_TOKEN"
chamar "tutor/pets/{id}/vacinas/status (GET)" 200 GET "$TUTOR_API/api/v1/tutor/pets/$ID_PET/vacinas/status" '' "$TUTOR_TOKEN"

# ─── 18. .NET: dashboard, pets/{id}, agenda, soap, receituario ───────────────
# Origem: mobile-clinica-rn/src/services/dashboard.service.ts (getAlertas,
# getRecentes), pets.service.ts (getPetById), agenda.service.ts (getAgenda),
# eventos-clinicos.service.ts (confirmarSoap, gerarReceituario,
# baixarEAbrirReceituario).

chamar "dashboard/alertas (GET)" 200 GET "$API/api/v1/dashboard/alertas" '' "$TOKEN"
chamar "dashboard/recentes (GET)" 200 GET "$API/api/v1/dashboard/recentes" '' "$TOKEN"
chamar "pets/{id} (GET detalhe, contexto clinica)" 200 GET "$API/api/v1/pets/$ID_PET" '' "$TOKEN"

# Janela de 7 dias a partir de hoje — bem dentro do limite de 31 dias que
# AgendaService.GetAgendaAsync exige (dataFim - dataInicio <= 31), evitando 422.
DATA_INICIO_AGENDA=$("$PY" -c 'import datetime; print(datetime.date.today().isoformat())')
DATA_FIM_AGENDA=$("$PY" -c 'import datetime; print((datetime.date.today()+datetime.timedelta(days=7)).isoformat())')
chamar "agenda (GET)" 200 GET "$API/api/v1/agenda?dataInicio=$DATA_INICIO_AGENDA&dataFim=$DATA_FIM_AGENDA" '' "$TOKEN"

# PUT soap — SoapConfirmarDto (S/O/A/P todos string? nullable, sem validator,
# ver EventosClinicosController.cs:188-195) — usa o evento da consulta (bloco 3).
PAYLOAD_SOAP=$(cat <<JSON
{
  "s": "Tutor relata melhora do quadro.",
  "o": "Temperatura e FC dentro do normal ao exame.",
  "a": "Quadro em resolucao.",
  "p": "Manter observacao, retorno se piora."
}
JSON
)
chamar "eventos-clinicos/{id}/soap (PUT confirmar)" 200 PUT "$API/api/v1/eventos-clinicos/$ID_EVENTO_CONSULTA/soap" "$PAYLOAD_SOAP" "$TOKEN"

# POST receituario — sem corpo (GerarReceituario(long id), sem [FromBody]).
# Precisa de Prescricao pre-existente pro MESMO evento clinico — usa
# ID_EVENTO_PRESCRICAO (bloco 5), nao ID_EVENTO_CONSULTA (senao 404,
# EntidadeNaoEncontradaException("Prescricao", id), ver ReceituarioPdfService.cs:49-51).
chamar "eventos-clinicos/{id}/receituario (POST gerar)" 200 POST "$API/api/v1/eventos-clinicos/$ID_EVENTO_PRESCRICAO/receituario" '' "$TOKEN"
ID_DOCUMENTO_RECEITUARIO=$(campo id)

# GET download — binario (application/pdf), sem corpo JSON. chamar() so verifica
# o status code aqui; BODY_FILE fica com os bytes do PDF, nao importa pro check.
chamar "eventos-clinicos/{id}/receituario/{idDocumento}/download (GET)" 200 GET "$API/api/v1/eventos-clinicos/$ID_EVENTO_PRESCRICAO/receituario/$ID_DOCUMENTO_RECEITUARIO/download" '' "$TOKEN"

# ─── 19. .NET: luna/triagens/relatorio (JWT de clinica, distinto dos 3 x-api-key) ──
# Origem: mobile-clinica-rn/src/services/luna.service.ts::getRelatorioTriagens
# (linha 46-54). LunaController.GerarRelatorio (linha 28-38) e [Authorize] no
# METODO, nao na classe — distinto dos irmaos POST /interactions e /triage
# ([AllowAnonymous] + X-Api-Key) do MESMO controller. Usa Bearer, nao X-Api-Key.
chamar "luna/triagens/relatorio (GET, JWT clinica)" 200 GET "$API/api/v1/luna/triagens/relatorio?dataInicio=2020-01-01&dataFim=$DATA_FIM_AGENDA" '' "$TOKEN"

# ─── 20. .NET: teleconsulta (POST idempotente + GET) ─────────────────────────
# Origem: mobile-clinica-rn/src/services/teleconsulta.service.ts::criarOuObterSala
# (linha 12-17) e obterSala (linha 19-24). Usa AG1 (bloco 14) — tutor com
# consentimento TELEORIENTACAO aceito (bloco 9), TeleconsultaService.
# GarantirConsentimentoAsync (cs:71-81) exige exatamente isso. DailyService usa
# API key placeholder deste ambiente (CLAUDE.md: "Daily nao e credencial real") —
# CriarSalaAsync tanto pode ter sucesso quanto falhar; os dois caminhos de
# TeleconsultaService.CriarOuObterSalaAsync (cs:34-57) devolvem 200, nunca lancam
# por causa disso (StFallbackManual=true no caminho de falha) — 200 e
# determinístico independente do resultado do provedor externo.
chamar "teleconsulta/{id}/sala (POST criar)" 200 POST "$API/api/v1/teleconsulta/$ID_AGENDAMENTO_TELE/sala" '' "$TOKEN"
chamar "teleconsulta/{id}/sala (GET obter)" 200 GET "$API/api/v1/teleconsulta/$ID_AGENDAMENTO_TELE/sala" '' "$TOKEN"

# ─── resultado ─────────────────────────────────────────────────────────────
echo
if [ "$FALHAS" -eq 0 ]; then
  echo "=== smoke-contratos.sh: TUDO OK (0 falhas) ==="
else
  echo "=== smoke-contratos.sh: $FALHAS falha(s) — ver acima ==="
fi
exit "$FALHAS"
