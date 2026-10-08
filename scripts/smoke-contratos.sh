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
. ./scripts/lib-env.sh   # ler_chave_env: leitura tolerante do .env (G4-I1)
LUNA_API_KEY=${LUNA_API_KEY:-}
if [ -z "$LUNA_API_KEY" ] && [ -f .env ]; then
  LUNA_API_KEY=$(ler_chave_env LUNA_API_KEY .env)
fi
if [ -z "$LUNA_API_KEY" ]; then
  echo "erro: LUNA_API_KEY nao definido (nem env var, nem .env deste repo) — necessario para os checks server-a-servidor da Luna (ver chamar_apikey)." >&2
  exit 2
fi

# LU-13: base URL da Luna (porta propria, docker-compose.yml:206 "8000:8000") e a
# chave que a PROPRIA Luna valida em requisicoes inbound (validar_api_key em
# src/web/dependencies.py, settings.LUNA_INBOUND_API_KEY) — usada por
# POST /jobs/lembrete-vacina/executar (gatilho manual do LU-04). NAO confundir com
# LUNA_API_KEY acima: aquela e a chave que o .NET valida quando a LUNA o chama
# (Luna__ApiKey); esta e a chave que a LUNA valida quando ALGUEM (o .NET, ou este
# script) a chama diretamente (Luna__InboundApiKey/LUNA_INBOUND_API_KEY, mesmo par
# dos dois lados — docker-compose.yml:120/223).
LUNA_URL=${LUNA_URL:-http://localhost:8000}
LUNA_INBOUND_API_KEY=${LUNA_INBOUND_API_KEY:-}
if [ -z "$LUNA_INBOUND_API_KEY" ] && [ -f .env ]; then
  LUNA_INBOUND_API_KEY=$(ler_chave_env LUNA_INBOUND_API_KEY .env)
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

# ─── caminho nativo (armadilha de 3 leitores de /tmp diferentes no Git Bash) ─
# Achado no G4 da FT-10 (2026-09-26, g4-ft10.md F2.b): no Git Bash/Windows um
# mesmo caminho POSIX como "/tmp/tmp.XXXX" (saida de `mktemp`) e lido de forma
# DIFERENTE por 3 programas na mesma maquina:
#   - `cmp` (binario MSYS, `/usr/bin/cmp`) resolve "/tmp" para o /tmp real do
#     MSYS (ex.: C:\Users\<usuario>\AppData\Local\Temp);
#   - o `python` nativo do Windows (nao-MSYS, ex. C:\Python314) e o `curl.exe`
#     nativo (`/mingw64/bin/curl`, PE32+) NAO passam pela camada de traducao de
#     path do MSYS quando o argumento vem de dentro de uma string Python ou de
#     um `-F campo=@caminho` — os dois resolvem "/tmp/x" como a raiz do drive
#     do cwd (ex.: D:\tmp\x), que e uma pasta DIFERENTE da que o `cmp` le.
# Resultado medido: o servidor grava e serve os bytes certos, mas o `cmp` local
# compara contra o arquivo ERRADO (as vezes vazio) -> "FALHA bytes diferem"
# falso. Confirmado por 2 sondas (g4-ft10.md F2.a/F2.b): sem este helper, 2
# checks do bloco 23 davam FALHA por instrumento, nao por produto; com ele,
# verdes (bytes iguais).
# Em Linux (CI ubuntu-latest) nao ha `cygpath` e os 3 programas ja leem o mesmo
# /tmp — o helper devolve o caminho intacto, sem efeito.
caminho_nativo() {  # caminho_nativo <caminho_posix>
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

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

# REC-05 (KURA_BACKLOG_RECEPCAO.md, A-8). Variante de chamar() usada por TODO
# check cujo corpo de resposta possa carregar `invite.nrToken`/`dsLinkConvite`
# (TutorComInviteResponseDto/InviteTutorReemitidoResponseDto, e33da98) ou um
# JWT (TokenResponse, register-invite, d1522ee) — nao so os 2 blocos do bloco
# 24 que a REC-05 escreveu, mas TODO POST /tutores e o
# POST /auth/register-invite pre-existente: o corpo so' e' impresso no ramo de
# FALHA de chamar(), e e' exatamente QUANDO um desses checks falha (a
# regressao "o servidor aceitou o que deveria rejeitar") que o corpo carrega
# o token de verdade — G2 (`g2-rec05.md`, achado I-1) mediu isso 2x contra o
# compose (pin antigo) e 1x contra o .NET novo sob mutacao (M2): o check que
# existe pra pegar a regressao e' o que vaza a credencial quando a acha.
# PRECISA estar definida aqui (antes de campo()/gerar_cpf() e de QUALQUER
# chamada, inclusive "setup/tutores" no bloco 1) — bash nao suporta chamar
# uma funcao antes dela ser definida na ordem de execucao do script.
chamar_mascarando_token() {  # chamar_mascarando_token <nome> <esperado> <metodo> <url> <payload> <token_auth>
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5 token_auth=${6:-}
  printf '%s' "$payload" > "$PAYLOAD_FILE"
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json' --data-binary "@$PAYLOAD_FILE")
  [ -n "$token_auth" ] && args+=(-H "Authorization: Bearer $token_auth")
  local code; code=$(curl "${args[@]}")
  if [ "$code" != "$esperado" ]; then
    echo "FALHA  $nome: esperado $esperado, obtido $code"
    "$PY" -c '
import re, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    corpo = f.read()
# GUID: o token de convite (Guid.ToString() do .NET) — aparece na chave
# nrToken (invite.nrToken) e embutido na query string de dsLinkConvite
# (?token=<guid>&clinicaId=...). Regex sobre a string INTEIRA pega os dois
# lugares de uma vez, em vez de andar por chave conhecida (que erraria o caso
# dentro da URL).
corpo = re.sub(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    "***REDACTED-GUID***",
    corpo,
)
# JWT: accessToken/refreshToken de um TokenResponse (Java) — 3 segmentos
# base64url separados por ponto. Achado no 24d: contra um .NET sem a rota de
# reemissao (REC-02), o token "antigo" nunca e cancelado e o register-invite
# SUCEDE de verdade, devolvendo um par de JWT genuino.
corpo = re.sub(
    r"[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}",
    "***REDACTED-JWT***",
    corpo,
)
sys.stdout.write(corpo[:300])
' "$BODY_FILE"
    echo
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

# REC-05: variante de campo() que devolve "" (em vez de estourar KeyError, que
# mataria o script inteiro sob set -euo pipefail — mesma classe de armadilha do
# achado registrado acima na leitura de CONVITE_URL_BASE_APP_TUTOR) quando o
# CAMINHO não existe no corpo. Uso: campos que só existem no contrato NOVO
# (ex.: dsLinkConvite) e que este script roda deliberadamente contra o
# contrato ANTIGO também (REC-05, prova de contraste) — nesse caso "ausente"
# e "presente e null" têm de produzir o MESMO resultado observável (string
# vazia), porque para o efeito prático (link não disponível) são a mesma
# coisa. NÃO usada em nenhum outro lugar do script — os `campo()` puros que já
# existiam continuam estourando de propósito se o corpo não tiver o que o
# consumidor real do app espera (é o comportamento que os detecta).
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
    # corpo vazio (ex.: 404 sem payload de um .NET que nao tem a rota) tambem
    # cai aqui — achado ao rodar este script contra o .NET antigo (REC-02 nao
    # existe la, a rota de reemissao devolve 404 SEM corpo).
    sys.stdout.write("")
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
# REC-05 (KURA_BACKLOG_RECEPCAO.md, A-9): stAvisoPrivacidadeInformado passou a ser
# obrigatorio (TutorCreateValidator, origin/main e33da98) — sem ele, 400.
PAYLOAD_TUTOR=$(cat <<JSON
{
  "nmTutor": "Tutor Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR",
  "dsEmail": "tutor-smoke-$SUFIXO@kura-smoke.test",
  "nrTelefone": "11988880000",
  "stAvisoPrivacidadeInformado": true,
  "dsCanalConvite": "EMAIL"
}
JSON
)
# G2 REC-05 (I-1, varredura): resposta e' TutorComInviteResponseDto — carrega
# invite.nrToken e dsLinkConvite. So imprime corpo se vier != 201, mas se
# isso acontecer o corpo AINDA pode ter o token (mesma classe do achado
# principal) — chamar_mascarando_token por coerencia, nao so nos 2 checks
# que a regressao especifica ataca.
chamar_mascarando_token "setup/tutores" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR" "$TOKEN"
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
# G2 REC-05 (I-1, varredura): sucesso devolve TokenResponse (accessToken/
# refreshToken JWT reais) — chamar_mascarando_token por coerencia, mesma
# razao do "setup/tutores" acima (sem auth Bearer, ultimo argumento vazio).
chamar_mascarando_token "tutor/auth/register-invite" 201 POST "$TUTOR_API/api/v1/auth/register-invite" "$PAYLOAD_REGISTER_INVITE" ""

# ─── 10. TASK-60: pares DTO x coluna NOT NULL confirmados pela varredura ──
# Ver backend-clinica-dotnet/docs/NOT-NULL-audit.md e o relatorio da TASK-60
# (KURA_BACKLOG_FIX_4) para a varredura completa. Os 5 casos abaixo (4 colunas
# Oracle distintas) reproduziram 500/ORA-01400 real antes do fix (370ab7b em
# diante) e agora devem devolver 2xx com o sentinela persistido — regressao
# aqui significa que alguem removeu o coalesce do service correspondente.
# Nenhum dos 4 tem tela no app hoje (mesma situacao de vacina/exame no bloco
# 7/8 acima) — payloads construidos direto contra os DTOs/validators reais.
# ⚠️ EXCECAO: o 10b (tutor create sem nrTelefone) SAIU dessa familia na REC-05
# — deixou de ser um caso de coalesce (2xx) e virou um caso de validacao (400),
# porque nrTelefone passou a ser campo obrigatorio. Ver comentario no proprio
# 10b.

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

# 10b. Tutor (create) sem nrTelefone — SUPERSEDIDO pela REC-05
# (KURA_BACKLOG_RECEPCAO.md, A-12, G0 item 6 consumidor 5). Ate a REC-01,
# TutorCreateValidator nao tinha regra pra nrTelefone e o payload sem telefone
# caia no mesmo coalesce de NOT NULL dos outros casos deste bloco (201, com o
# sentinela "Nao informado"). Desde a REC-01 (origin/main e33da98),
# NormalizadorTelefone.TentarNormalizar roda ANTES do coalesce e nrTelefone
# passou a ser exigido pelo validator — o payload sem telefone agora e
# REJEITADO (400), nunca chega ao service. stAvisoPrivacidadeInformado:true
# aqui isola a causa do 400 (senao o teste tambem falharia por falta de
# aviso, e nao provaria o que se propoe a provar).
CPF_TUTOR_TASK60=$(gerar_cpf)
PAYLOAD_TUTOR_SEM_TEL=$(cat <<JSON
{
  "nmTutor": "Tutor SemTel Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR_TASK60",
  "dsEmail": "tutor-semtel-smoke-$SUFIXO@kura-smoke.test",
  "stAvisoPrivacidadeInformado": true,
  "dsCanalConvite": "EMAIL"
}
JSON
)
# I-1 (G2 REC-05): esta e' justamente a checagem cuja FALHA (backend aceitou
# em vez de rejeitar) e' a regressao que este check existe pra pegar — o
# corpo, nesse caso, carrega invite.nrToken/dsLinkConvite CRUS. Trocado de
# chamar() puro para chamar_mascarando_token — achado do G2, medido 2x
# vazando contra o compose (pin antigo) e 1x sob mutacao contra o .NET novo.
chamar_mascarando_token "tutores/POST (sem nrTelefone — REC-05: agora rejeitado)" 400 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_SEM_TEL" "$TOKEN"

# 10c. Tutor (update) sem nrTelefone — mesmo gap, TutorUpdateValidator tambem
# nunca teve regra pra esse campo. CONTINUA 200 (confirmado no G2 fix wave 2 da
# REC-01, rec-01-report.md: o PUT nao exige nrTelefone — decisao do maestro,
# "acompanha o telefone atual" quando ausente). Reusa o tutor do bloco "setup" (ID_TUTOR).
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
#
# REC-05 (KURA_BACKLOG_RECEPCAO.md, A-12, G0 item 6 consumidor 7) — REESCRITO.
# O valor antigo, "1199${SUFIXO}" (SUFIXO tem comprimento VARIAVEL, tipicamente
# 9-11 digitos -> total 13-15 digitos), nao passa em NENHUM ramo de
# NormalizadorTelefone.TentarNormalizar (Domain/Tutores/NormalizadorTelefone.cs,
# origin/main e33da98): nao comeca com '+' (ramo 1), nao tem 12/13 digitos
# COMECANDO EM "55" (ramo 2 — "1199..." comeca em "11", nao "55") e nao tem
# 10/11 digitos (ramo 3, e o total aqui e maior). POST/setup deste bloco daria
# 400 com o valor antigo — medido lendo o codigo-fonte, nao suposto.
#
# Novo valor: "55" + "11" (DDD) + 8 digitos derivados de timestamp+RANDOM,
# SEMPRE com largura fixa (printf %08d) — 12 digitos totais, cai no ramo 2
# ("55..." com 12/13 digitos), que ARMAZENA O VALOR SEM TRANSFORMAR (candidato
# = digitos, ver NormalizadorTelefone.cs). Por isso a BUSCA abaixo usa o MESMO
# $NR_TELEFONE_LUNA que foi enviado no cadastro — nao e "funcionar por
# coincidencia", e o comportamento medido do ramo 2 (stored == input quando
# input ja tem DDI embutido sem '+').
CPF_TUTOR_LUNA=$(gerar_cpf)
NR_TELEFONE_LUNA="5511$(printf '%08d' $(( ($(date +%s) * 7919 + RANDOM) % 100000000 )))"
PAYLOAD_TUTOR_LUNA=$(cat <<JSON
{
  "nmTutor": "Tutor Luna Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR_LUNA",
  "dsEmail": "tutor-luna-smoke-$SUFIXO@kura-smoke.test",
  "nrTelefone": "$NR_TELEFONE_LUNA",
  "stAvisoPrivacidadeInformado": true,
  "dsCanalConvite": "EMAIL"
}
JSON
)
# G2 REC-05 (I-1, varredura) — mesma razao do "setup/tutores" do bloco 1.
chamar_mascarando_token "setup/tutores (para checks Luna)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_LUNA" "$TOKEN"
ID_TUTOR_LUNA=$(campo id)

# 12a. GET /api/v1/tutores/telefone/{numero} — tutor conhecido (TutoresController.cs:81-91).
# Busca pelo MESMO valor gravado (ramo 2 nao transforma — ver comentario acima).
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
# REC-18: o bloco 25 reaproveita esta triagem como origem de um agendamento ("Agendar" pelo card).
ID_TRIAGEM_LUNA=$(campo_opcional id_triagem)

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
#
# ⚠️ CORRIGIDO no G4 do FIX_7 (2026-08-12). Este check nascia com
# `dataInicio=2020-01-01` — ~6 anos de intervalo — e devolvia **422**, nao 200:
# `LunaService.GerarRelatorioAsync` (LunaService.cs:61-62) rejeita intervalo maior
# que `MaxIntervaloDias = 90` (LunaService.cs:12). A API estava CERTA; o check e que
# violava a regra do cabecalho deste arquivo (payload copiado do app, com origem
# citada): a tela real (`mobile-clinica-rn/src/app/(app)/luna.tsx:190-194`) monta
# `dataInicio = subDays(new Date(), periodo)` com `periodo` default **7**, e
# `dataFim = hoje` — janela curta e movel, nunca uma data fixa de 2020.
# Nenhum valor do seletor de periodo daquela tela chega perto de 90 dias.
# Lição: este check foi escrito e revisado 3x SEM Docker no ar; so a execucao real
# pegou. Check nunca executado nao e cobertura, e intencao.
DATA_INICIO_RELATORIO=$("$PY" -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=7)).isoformat())')
DATA_FIM_RELATORIO=$("$PY" -c 'import datetime; print(datetime.date.today().isoformat())')
chamar "luna/triagens/relatorio (GET, JWT clinica)" 200 GET "$API/api/v1/luna/triagens/relatorio?dataInicio=$DATA_INICIO_RELATORIO&dataFim=$DATA_FIM_RELATORIO" '' "$TOKEN"

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

# ─── 21. .NET: luna/triagens (GET, JWT clinica) — PRIMEIRO CHECK DE CORPO ────
# Origem: mobile-clinica-rn/src/services/luna.service.ts::getTriagens (LU-09) e
# src/types/api.ts::TriagensListaApiResponse/TriagemListaItemApi (linhas 445-462),
# lidas diretamente do mapper (nao de memoria) — envelope {items,total,page,pageSize}
# e, por item, {idTriagem,dtTriagem,urgencia,sintomas,score,regrasVersao,
# encaminhadoVet,tutor,pets,trechoMensagem}. LunaController.ListarTriagens
# (LU-08) e [Authorize] no metodo, JWT de clinica igual ao bloco 19 (nao X-Api-Key).
#
# LU-13 (FIXES_PENDENTES tema ⑤): ate aqui NENHUM check deste script olhava o
# CORPO da resposta, so o status HTTP — um contrato que mudasse de shape sem mudar
# o status nunca seria pego. Este e o embriao do detector desse tema.
chamar "luna/triagens (GET, JWT clinica)" 200 GET "$API/api/v1/luna/triagens" '' "$TOKEN"

# Chaves esperadas derivadas do mapper (ver comentario acima) — LISTA-ALVO da
# mutacao obrigatoria do LU-13 (item 3 do brief): remover uma entrada aqui faz
# este check falhar nominalmente contra a resposta real, sem tocar no app.
LUNA_TRIAGENS_ENVELOPE="items total page pageSize"
LUNA_TRIAGENS_ITEM="idTriagem dtTriagem urgencia sintomas score regrasVersao encaminhadoVet tutor pets trechoMensagem"

CORPO_TRIAGENS_RESULTADO=$("$PY" -c '
import json, sys
envelope = sys.argv[1].split()
item_keys = sys.argv[2].split()
with open(sys.argv[3], "r", encoding="utf-8") as f:
    data = json.load(f)
faltando = [k for k in envelope if k not in data]
if not faltando and data.get("items"):
    faltando = ["items[0]." + k for k in item_keys if k not in data["items"][0]]
print(",".join(faltando) if faltando else "OK")
' "$LUNA_TRIAGENS_ENVELOPE" "$LUNA_TRIAGENS_ITEM" "$BODY_FILE")

if [ "$CORPO_TRIAGENS_RESULTADO" = "OK" ]; then
  echo "ok     luna/triagens (corpo: envelope + item batem com luna.service.ts)"
else
  echo "FALHA  luna/triagens (corpo): chave(s) ausente(s) vs luna.service.ts: $CORPO_TRIAGENS_RESULTADO"
  FALHAS=$((FALHAS+1))
fi

# ─── 22. Luna: POST /jobs/lembrete-vacina/executar (gatilho manual, LU-04) ───
# Origem: kura-luna-ai/luna/src/web/routers/jobs.py — auth por X-API-Key contra
# LUNA_INBOUND_API_KEY (validar_api_key), NAO Bearer.
#
# ⛔ REGRA DURA (brief LU-13, atualizacao sessao 7): este check NUNCA pode
# disparar envio real de WhatsApp. Dois sub-checks, os dois sem tocar o gateway
# Twilio de verdade:
# (a) sem X-API-Key -> auth barra em 401 antes de chegar em qualquer dependencia
#     de negocio — prova de 0 chamadas por falta de credencial.
# (b) COM X-API-Key correta -> get_lembrete_service (dependencies.py:108-131)
#     constroi o TwilioGateway ANTES de rodar o job; com TWILIO_SID/TWILIO_TOKEN
#     vazios (exigido pela sequencia do item 4 deste brief: exportados vazios no
#     shell do `docker compose up` desta prova) a construcao falha no SDK e a
#     dependencia converte isso em 503 (F4-1) — o job.executar() real NUNCA roda,
#     entao nenhum envio acontece mesmo com a chave certa. So roda se
#     LUNA_INBOUND_API_KEY estiver disponivel (env ou .env); sem ela, so (a).
chamar "jobs/lembrete-vacina/executar (POST, sem X-API-Key)" 401 POST "$LUNA_URL/jobs/lembrete-vacina/executar" '' ""
if [ -n "$LUNA_INBOUND_API_KEY" ]; then
  chamar_luna_inbound() {  # chamar_luna_inbound <nome> <esperado> <metodo> <url>
    local nome=$1 esperado=$2 metodo=$3 url=$4
    local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url" -H "X-API-Key: $LUNA_INBOUND_API_KEY")
    local code; code=$(curl "${args[@]}")
    if [ "$code" != "$esperado" ]; then
      echo "FALHA  $nome: esperado $esperado, obtido $code"
      head -c 300 "$BODY_FILE"; echo
      FALHAS=$((FALHAS+1))
    else
      echo "ok     $nome ($code)"
    fi
  }
  chamar_luna_inbound "jobs/lembrete-vacina/executar (POST, com X-API-Key, Twilio vazio)" 503 POST "$LUNA_URL/jobs/lembrete-vacina/executar"
else
  echo "aviso  jobs/lembrete-vacina/executar (com X-API-Key): LUNA_INBOUND_API_KEY indisponivel, sub-check (b) pulado — so (a) rodou"
fi

# ─── 23. FT-03/FT-04 (KURA_BACKLOG_FOTO_PET.md): upload de foto do pet + GET da foto ────
# assinada ────────────────────────────────────────────────────────────────────────────
# Origem dos endpoints: backend-clinica-dotnet PetsController.UploadFoto (FT-03, multipart
# com 2 partes nomeadas 'thumb'/'media' — PetFotoUploadValidator.cs) e
# FotosController.Obter (FT-04, GET /api/v1/fotos/{*chave}?exp=&sig=, anonimo).
#
# A tela do app que sobe foto e a FT-07 (mobile-clinica-rn, `pets.service.ts::uploadFoto`),
# que ja existe e ja e coberta no gate `smoke-coverage` — ver `registry.ts` daquele repo.
#
# Este bloco JA EXECUTOU contra o compose real: G4 da FT-10 (2026-09-26, g4-ft10.md F2.a/
# F2.b) — upload 200, GET thumb/media 200 com bytes iguais aos enviados, sig adulterada
# 403. A 1a execucao acusou 2 "bytes diferem" falsos por causa da armadilha de /tmp entre
# 3 leitores descrita no helper `caminho_nativo()` acima; corrigido usando o helper nas 2
# escritas do Python e nos 2 `-F …=@` abaixo.
FOTO_THUMB_FILE=$(mktemp)
FOTO_MEDIA_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE" "$FOTO_THUMB_FILE" "$FOTO_MEDIA_FILE"' EXIT
# JPEG minimo valido por MAGIC BYTES (FF D8 FF...) — o validator (ValidadorAssinaturaImagem.cs)
# so olha o cabecalho, nao o conteudo real da imagem. thumb e media com bytes DIFERENTES
# (0x01.. x 0x02..) para o check de bytes abaixo distinguir qual variante voltou.
"$PY" -c "open('$(caminho_nativo "$FOTO_THUMB_FILE")','wb').write(bytes([0xFF,0xD8,0xFF,0xE0]+[0x01]*16))"
"$PY" -c "open('$(caminho_nativo "$FOTO_MEDIA_FILE")','wb').write(bytes([0xFF,0xD8,0xFF,0xE0]+[0x02]*16))"

chamar_upload_foto() {  # chamar_upload_foto <nome> <esperado> <url> <thumb_path> <media_path> <token>
  local nome=$1 esperado=$2 url=$3 thumb=$4 media=$5 token=$6
  local code
  code=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "$url" \
    -H "Authorization: Bearer $token" \
    -F "thumb=@$(caminho_nativo "$thumb");type=application/octet-stream" \
    -F "media=@$(caminho_nativo "$media");type=application/octet-stream")
  if [ "$code" != "$esperado" ]; then
    echo "FALHA  $nome: esperado $esperado, obtido $code"
    head -c 300 "$BODY_FILE"; echo
    FALHAS=$((FALHAS+1))
  else
    echo "ok     $nome ($code)"
  fi
}

chamar_upload_foto "pets/{id}/foto (POST, upload thumb+media)" 200 \
  "$API/api/v1/pets/$ID_PET/foto" "$FOTO_THUMB_FILE" "$FOTO_MEDIA_FILE" "$TOKEN"

# GET /pets/{id} de novo, agora com foto — extrai as 2 URLs assinadas do DTO
# (PetResponseDto.DsFotoUrl/DsFotoThumbUrl, FT-04).
chamar "pets/{id} (GET, apos upload de foto)" 200 GET "$API/api/v1/pets/$ID_PET" '' "$TOKEN"
DS_FOTO_URL=$(campo dsFotoUrl)
DS_FOTO_THUMB_URL=$(campo dsFotoThumbUrl)

# GET pela URL devolvida pelo proprio DTO — prova que a assinatura que o .NET gerou e a
# que o .NET aceita de volta, e que os bytes servidos sao os ENVIADOS na parte certa
# (thumb -> variante 256, media -> variante 1080; conteudos diferentes pegam a troca).
baixar_foto_e_comparar() {  # baixar_foto_e_comparar <nome> <url> <arquivo_enviado>
  local nome=$1 url=$2 enviado=$3
  local code
  code=$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$url")
  if [ "$code" != "200" ]; then
    echo "FALHA  $nome: esperado 200, obtido $code"
    head -c 300 "$BODY_FILE"; echo
    FALHAS=$((FALHAS+1))
  elif ! cmp -s "$BODY_FILE" "$enviado"; then
    echo "FALHA  $nome: 200, mas os bytes servidos diferem dos enviados"
    FALHAS=$((FALHAS+1))
  else
    echo "ok     $nome (200, bytes iguais aos enviados)"
  fi
}

baixar_foto_e_comparar "fotos/{chave} (GET pela dsFotoThumbUrl do DTO)" "$DS_FOTO_THUMB_URL" "$FOTO_THUMB_FILE"
baixar_foto_e_comparar "fotos/{chave} (GET pela dsFotoUrl do DTO)" "$DS_FOTO_URL" "$FOTO_MEDIA_FILE"

# sig adulterada -> 403. Troca o PRIMEIRO caractere da sig, nao o ultimo: medido em
# PetFotoServirHttpTests.cs (backend-clinica-dotnet) que o ULTIMO caractere de uma sig
# HMAC-SHA256 base64url de 32 bytes carrega so 4 bits significativos (256/6 = 42,67 — os
# 2 bits baixos do ultimo grupo de 6 bits sao ignorados na decodificacao, mesmo achado
# F3-a do G2 da FT-01/FT-02) — trocar so o ultimo caractere pode produzir os MESMOS bytes
# e a "adulteracao" nao adulterar nada. O primeiro caractere cobre um grupo de 6 bits
# inteiramente significativo.
DS_FOTO_URL_SIG_ADULTERADA=$("$PY" -c "
import sys
import urllib.parse as up
partes = up.urlsplit(sys.argv[1])
query = up.parse_qs(partes.query)
sig = query['sig'][0]
sig_adulterada = ('B' if sig[0] == 'A' else 'A') + sig[1:]
query['sig'] = [sig_adulterada]
nova_query = up.urlencode(query, doseq=True)
print(up.urlunsplit((partes.scheme, partes.netloc, partes.path, nova_query, partes.fragment)))
" "$DS_FOTO_THUMB_URL")

CODE_FOTO_SIG_ADULTERADA=$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$DS_FOTO_URL_SIG_ADULTERADA")
if [ "$CODE_FOTO_SIG_ADULTERADA" != "403" ]; then
  echo "FALHA  fotos/{chave} (GET com sig adulterada): esperado 403, obtido $CODE_FOTO_SIG_ADULTERADA"
  head -c 300 "$BODY_FILE"; echo
  FALHAS=$((FALHAS+1))
else
  echo "ok     fotos/{chave} (GET com sig adulterada) (403)"
fi

# ─── 24. REC-05 (KURA_BACKLOG_RECEPCAO.md): cadastro pela recepcao — aviso de ──
# privacidade obrigatorio, link do convite e reemissao ──────────────────────
# Payloads contra TutorCreateDto.cs/GeradorLinkConvite.cs/TutoresController.cs
# (origin/main e33da98) e RegisterInviteRequest/OnboardingService.java
# (origin/main d1522ee). O TOKEN NUNCA vai para stdout/log — nem no sucesso
# (so os 4 ultimos digitos, mascarado, mesmo padrao de DEMO_WHATSAPP em
# seed-demo-luna.sh) nem na falha. `chamar_mascarando_token()` (definida no
# topo do script, junto de chamar()/chamar_apikey() — precisa vir ANTES de
# QUALQUER chamada, e o "setup/tutores" no bloco 1 ja usa) e' a variante que
# redige token/JWT do corpo antes de imprimir em caso de FALHA.

# Config do convite lida do mesmo .env do compose (ou env var, override) — usada
# so para decidir se a asserção "dsLinkConvite não-nulo" roda: sem a config
# setada, GerarLink() devolve sempre null por design (A-8), e afirmar
# não-nulo seria falso positivo do PRÓPRIO instrumento, não do produto.
#
# ⚠️ ACHADO (REC-05, medido ao rodar este script contra o .NET antigo, sem a
# var exportada e sem a linha em .env): `grep -m1 ... .env | cut -d= -f2-`
# SEM `|| true` mata o script inteiro em SILÊNCIO daqui pra frente, sob
# `set -euo pipefail` — quando o grep não acha a linha (exit 1) e é o único
# comando não-zero do pipe, `pipefail` propaga esse 1 pro `$(...)`, e a
# atribuição (comando simples dentro do corpo de um `if`, não isento de `-e`)
# derruba o script sem imprimir nada. Medido: comparar a contagem de checks
# reconhecidos entre um `bash -x` com a linha em `.env` (chega ao fim, 67
# checks) e sem ela (para exatamente aqui, 58 checks, sem nenhuma linha
# `FALHA`/erro — só some). O MESMO padrão (`LUNA_API_KEY`/`LUNA_INBOUND_API_KEY`,
# topo do script) tem a mesma fragilidade latente, mascarada porque essas 2
# chaves sempre existem no `.env` deste projeto — não corrigido aqui (fora do
# escopo da REC-05, que só toca os blocos que criou). O `|| true` abaixo evita
# que ESTE bloco novo repita a mesma armadilha.
CONVITE_URL_BASE_APP_TUTOR=${CONVITE_URL_BASE_APP_TUTOR:-}
if [ -z "$CONVITE_URL_BASE_APP_TUTOR" ] && [ -f .env ]; then
  CONVITE_URL_BASE_APP_TUTOR=$(grep -m1 '^CONVITE_URL_BASE_APP_TUTOR=' .env | cut -d= -f2- || true)
fi

# 24a. POST /api/v1/tutores com os campos novos — 201, dsLinkConvite
# não-nulo QUANDO a config estiver setada (senão, checa só o status e avisa).
CPF_TUTOR_REC05=$(gerar_cpf)
NR_TELEFONE_REC05="119$(printf '%08d' $(( ($(date +%s) * 15485863 + RANDOM) % 100000000 )))"
PAYLOAD_TUTOR_REC05=$(cat <<JSON
{
  "nmTutor": "Tutor REC-05 Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR_REC05",
  "dsEmail": "tutor-rec05-smoke-$SUFIXO@kura-smoke.test",
  "nrTelefone": "$NR_TELEFONE_REC05",
  "stAvisoPrivacidadeInformado": true,
  "dsCanalConvite": "WHATSAPP"
}
JSON
)
chamar_mascarando_token "rec-05/tutores (POST com aviso — criação + convite)" 201 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_REC05" "$TOKEN"
ID_TUTOR_REC05=$(campo id)
INVITE_TOKEN_REC05_V1=$(campo invite.nrToken)
DS_LINK_CONVITE_V1=$(campo_opcional dsLinkConvite)
if [ -n "$CONVITE_URL_BASE_APP_TUTOR" ]; then
  if [ "$DS_LINK_CONVITE_V1" != "None" ] && [ -n "$DS_LINK_CONVITE_V1" ]; then
    echo "ok     rec-05/tutores (dsLinkConvite não-nulo, config setada)"
  else
    echo "FALHA  rec-05/tutores (dsLinkConvite): esperado link não-nulo (CONVITE_URL_BASE_APP_TUTOR setada), obtido vazio/null"
    FALHAS=$((FALHAS+1))
  fi
else
  echo "aviso  CONVITE_URL_BASE_APP_TUTOR não setada nesta execução — pulando asserção de dsLinkConvite não-nulo (null é o esperado sem a config, A-8)"
fi

# 24b. POST /api/v1/tutores SEM aviso de privacidade — 400 e NENHUMA linha
# gravada (busca pelo CPF depois confirma lista vazia).
CPF_TUTOR_REC05_SEM_AVISO=$(gerar_cpf)
NR_TELEFONE_REC05_SEM_AVISO="119$(printf '%08d' $(( ($(date +%s) * 32452867 + RANDOM) % 100000000 )))"
PAYLOAD_TUTOR_REC05_SEM_AVISO=$(cat <<JSON
{
  "nmTutor": "Tutor REC-05 SemAviso Smoke $SUFIXO",
  "nrCpf": "$CPF_TUTOR_REC05_SEM_AVISO",
  "dsEmail": "tutor-rec05-semaviso-smoke-$SUFIXO@kura-smoke.test",
  "nrTelefone": "$NR_TELEFONE_REC05_SEM_AVISO",
  "dsCanalConvite": "WHATSAPP"
}
JSON
)
# I-1 (G2 REC-05): mesma classe do check "sem nrTelefone" acima — a FALHA
# (backend aceitou sem exigir o aviso) e' a propria regressao que este check
# detecta, e o corpo carregaria o token cru nesse caso.
chamar_mascarando_token "rec-05/tutores (POST sem stAvisoPrivacidadeInformado)" 400 POST "$API/api/v1/tutores" "$PAYLOAD_TUTOR_REC05_SEM_AVISO" "$TOKEN"
chamar "rec-05/tutores/busca (confirma nenhuma linha gravada apesar do 400)" 200 GET "$API/api/v1/tutores?busca=$CPF_TUTOR_REC05_SEM_AVISO" '' "$TOKEN"
QTD_TUTOR_SEM_AVISO=$("$PY" -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
sys.stdout.write(str(len(data)))
' "$BODY_FILE")
if [ "$QTD_TUTOR_SEM_AVISO" = "0" ]; then
  echo "ok     rec-05/tutores (sem aviso: confirmado 0 linhas gravadas)"
else
  echo "FALHA  rec-05/tutores (sem aviso): esperado 0 linhas, achou $QTD_TUTOR_SEM_AVISO"
  FALHAS=$((FALHAS+1))
fi

# 24c. POST /api/v1/tutores/{id}/convite — reemissão (REC-02): 201, token NOVO
# (nunca comparado/impresso em claro), cancela o invite V1 gerado no 24a.
chamar_mascarando_token "rec-05/tutores/{id}/convite (reemissão)" 201 POST "$API/api/v1/tutores/$ID_TUTOR_REC05/convite" '' "$TOKEN"
INVITE_TOKEN_REC05_V2=$(campo_opcional invite.nrToken)
DS_LINK_CONVITE_V2=$(campo_opcional dsLinkConvite)
# campo_opcional() (não campo()): a chamada acima pode ter falhado com 404 contra
# um .NET sem a rota de reemissão (REC-02) — corpo vazio/sem invite.nrToken. Sem a
# guarda abaixo, "" (ausente) != INVITE_TOKEN_REC05_V1 (o V1 real) daria um "ok"
# ENGANOSO ("token é novo") quando na verdade a reemissão nem aconteceu — o FALHA
# do esperado/obtido logo acima (chamar_mascarando_token) já registrou o problema
# real; não duplicar com uma comparação que passa pelo motivo errado.
if [ -z "$INVITE_TOKEN_REC05_V2" ]; then
  echo "aviso  rec-05/tutores/{id}/convite: sem invite.nrToken no corpo (reemissão não aconteceu — ver FALHA acima) — pulando comparação de token"
elif [ "$INVITE_TOKEN_REC05_V2" = "$INVITE_TOKEN_REC05_V1" ]; then
  echo "FALHA  rec-05/tutores/{id}/convite: token reemitido é IGUAL ao anterior (deveria ser novo)"
  FALHAS=$((FALHAS+1))
else
  echo "ok     rec-05/tutores/{id}/convite (token reemitido é novo, diferente do V1)"
fi
if [ -n "$CONVITE_URL_BASE_APP_TUTOR" ]; then
  if [ "$DS_LINK_CONVITE_V2" != "None" ] && [ -n "$DS_LINK_CONVITE_V2" ]; then
    echo "ok     rec-05/tutores/{id}/convite (dsLinkConvite não-nulo, config setada)"
  else
    echo "FALHA  rec-05/tutores/{id}/convite (dsLinkConvite): esperado link não-nulo, obtido vazio/null"
    FALHAS=$((FALHAS+1))
  fi
fi

# 24d. O token V1 (cancelado pela reemissão 24c) é recusado pelo Java em
# POST /auth/register-invite — 409 "Convite cancelado" (OnboardingService.java,
# passo 2, isAtivo()==false — NÃO "já utilizado", que seria o passo 3: o V1
# nunca foi usado, só cancelado).
#
# ⚠️ ACHADO (medido rodando este check contra o .NET ANTIGO, onde a reemissão
# não existe — REC-02 não fechou lá — e o token V1 continua ativo/não usado):
# a chamada abaixo então SUCEDE de verdade (201, "esperado 409, obtido 201"),
# e o corpo da resposta é um `TokenResponse` REAL do Java —
# `{"accessToken":"eyJ...","refreshToken":"eyJ..."}` — dois JWTs válidos. Um
# `chamar()` puro imprimiria esse corpo inteiro (via `head -c 300`) no
# caminho de falha — JWT vazando pro stdout do smoke, a MESMA classe de
# problema que este bloco existe para evitar no token de convite. Por isso
# usa `chamar_mascarando_token`, cujo regex de redação foi ampliado (abaixo)
# pra cobrir tanto GUID (token de convite) quanto JWT (accessToken/
# refreshToken) — não só "corpo não carrega token", carrega, e o helper
# genérico tinha que saber disso ANTES de rodar, não depois de vazar.
PAYLOAD_REGISTER_INVITE_TOKEN_ANTIGO=$(cat <<JSON
{
  "token": "$INVITE_TOKEN_REC05_V1",
  "senha": "SmokeTest123",
  "aceites": [
    { "tipo": "LEMBRETES", "versaoTermo": "v1.0", "aceito": true }
  ]
}
JSON
)
FALHAS_ANTES_24D=$FALHAS
chamar_mascarando_token "rec-05/tutor/auth/register-invite (token ANTIGO, cancelado pela reemissão)" 409 POST "$TUTOR_API/api/v1/auth/register-invite" "$PAYLOAD_REGISTER_INVITE_TOKEN_ANTIGO" ""
# m-24d (G2 REC-05): o status 409 sozinho não distingue "cancelado" (passo 2,
# isAtivo()==false) de "já utilizado" (passo 3) — os dois são 409. A mensagem
# do ApiError (campo "mensagem", GlobalExceptionHandler.java:134-138) é o que
# amarra a asserção ao motivo CERTO. Só roda se o status já bateu (senão o
# corpo pode não ser nem um ApiError — ex.: sucedeu de verdade e devolveu um
# TokenResponse, caso do achado I-1/F1b) — a mensagem "Convite cancelado."
# não é segredo (sem token/JWT dentro), pode aparecer no log sem risco.
if [ "$FALHAS" = "$FALHAS_ANTES_24D" ]; then
  MENSAGEM_TOKEN_ANTIGO=$(campo_opcional mensagem)
  if [ "$MENSAGEM_TOKEN_ANTIGO" = "Convite cancelado." ]; then
    echo "ok     rec-05/tutor/auth/register-invite (mensagem confere: \"Convite cancelado.\")"
  else
    echo "FALHA  rec-05/tutor/auth/register-invite (mensagem): esperado \"Convite cancelado.\", obtido \"$MENSAGEM_TOKEN_ANTIGO\""
    FALHAS=$((FALHAS+1))
  fi
else
  echo "aviso  rec-05/tutor/auth/register-invite (mensagem): status já não bateu o esperado (ver FALHA acima) — pulando checagem da mensagem"
fi

# ─── 25. REC-18 (KURA_BACKLOG_RECEPCAO.md): agendamento pela recepcao, check-in / ─
# inicio de atendimento e os 3 endpoints da confirmacao D-1 da Luna ──────────────
# Contrato lido na fonte (backend-clinica-dotnet origin/main 81d5a58, 2026-10-01):
#   - POST /api/v1/agendamentos                           AgendaController.cs:73 (REC-10)
#     corpo = AgendamentoCreateDto.cs:11-30 (camelCase: idTutor, idPet, idVeterinario,
#     dtAgendamento, duracao, dsTipo, dsObservacoes, idTriagemOrigem). dtAgendamento e
#     HORA LOCAL DA CLINICA, SEM "Z" (AgendamentoCreateValidator.cs:71-76 recusa Kind != Unspecified).
#   - POST /api/v1/agendamentos/{id}/checkin|inicio-atendimento  AgendaController.cs:97,120 (REC-11)
#     corpo = RegistrarEventoRecepcaoDto.cs:10 { "nrVersion": N }.
#   - GET  /api/v1/luna/agendamentos/confirmacao-pendente?data=   LunaController.cs:127 (REC-15)
#   - POST /api/v1/luna/agendamentos/{id}/lembrete-enviado        LunaController.cs:144 (sem corpo —
#     igual a KuraClient.marcar_lembrete_enviado, kura_client.py:231-243 @ kura-luna-ai e011335)
#   - POST /api/v1/luna/agendamentos/{id}/resposta-confirmacao    LunaController.cs:166
#     corpo = RespostaConfirmacaoRequestDto.cs:14-18 { "id_tutor", "resposta" } == dtos.py:100-105
#     (RespostaConfirmacaoRequestDTO) — snake_case, resposta in SIM|CANCELAR|REMARCAR.
# Regras que os payloads abaixo exercitam (AgendaService.cs @ 81d5a58):
#   check-in/inicio so a partir de AGENDADO/CONFIRMADO e SO NO DIA do agendamento (:439/:476),
#   idempotentes (:424/:472), lock por nrVersion (:444/:481), inicio NUNCA inventa dtCheckin
#   (:484); encaixe: no maximo 15 min no passado (CriarAsync).
#
# PRECONDICOES (quem roda precisa saber):
#   - LEMBRETE_CONFIRMACAO_HABILITADO deve estar false (default do compose). O bloco cria um
#     agendamento de AMANHA elegivel a D-1 (tutor com DS_WHATSAPP e consentimento LEMBRETES —
#     o do bloco 9) para provar a listagem; com o job da Luna LIGADO ele tentaria mandar
#     WhatsApp para o numero ficticio deste smoke.
#   - `confirmacao-pendente` e GLOBAL (todas as clinicas; API key, sem JWT — LunaService.cs:405):
#     o check afirma "contem o MEU id", nunca "a lista tem N itens".
#   - PII: o corpo de confirmacao-pendente carrega ds_whatsapp e nm_tutor. Os checks de corpo
#     abaixo (afirmar) NUNCA imprimem o corpo; so o nome do check e ok/FALHA. O unico `head -c`
#     de corpo e o do chamar_apikey em FALHA de status — que, num erro de status, e um
#     ProblemDetails (sem lista).
#   - Horarios: relogio da clinica = America/Sao_Paulo; o Brasil nao tem horario de verao desde
#     2019 (mesma premissa do fallback -03:00 de RelogioClinica.cs), entao o script calcula
#     "agora/amanha" com offset fixo -03:00, independente do fuso do host.
#   - Se o smoke rodar colado na virada do dia (23:59:59 -> 00:00) o "hoje" do script e o da
#     clinica podem divergir por 1 s; re-executar.

# afirmar: avalia uma expressao Python sobre `d` (o JSON do ULTIMO BODY_FILE) e imprime so
# ok/FALHA + o nome. Expressoes sao literais deste script (nunca vem de dado externo).
# TIMESTAMPS (G2 REC-18, I-1): a 1a resposta de check-in/lembrete e o valor EM MEMORIA do .NET
# (7 casas); a 2a em diante e RELIDA do Oracle (TIMESTAMP(6), V23:34,35,37). Por isso: (a) 1a x 2a
# compara com ts() e tolerancia de 1 ms (um overwrite real difere em dezenas de ms; arredondamento
# de 7->6 casas difere em <= 1 us); (b) 2a x 3a, as duas do banco, comparam a STRING exata.
afirmar() {  # afirmar <nome> <expressao sobre d>
  local r
  r=$("$PY" -c '
import json, sys
try:
    with open(sys.argv[2], "r", encoding="utf-8") as f:
        d = json.load(f)
    import datetime as _dt, re as _re
    def ts(x):
        # TIMESTAMP do Oracle tem 6 casas; o .NET em memoria tem 7 (tick de 100 ns). Corta a
        # fracao em 6 digitos antes de parsear — comparar a STRING crua entre uma resposta
        # em memoria (1a) e uma relida do banco (2a/3a) da falso FALHA (G2 REC-18, I-1).
        return _dt.datetime.fromisoformat(_re.sub(r"(\.\d{6})\d+", r"\1", x))
    sys.stdout.write("1" if eval(sys.argv[1]) else "0")
except Exception:
    sys.stdout.write("E")
' "$2" "$BODY_FILE") || r="E"
  if [ "$r" = "1" ]; then
    echo "ok     $1"
  else
    echo "FALHA  $1 (assercao sobre o corpo: $r — 0=falsa, E=erro ao avaliar; corpo NAO impresso)"
    FALHAS=$((FALHAS+1))
  fi
}

clinica_agora()    { "$PY" -c 'import datetime as d; print(d.datetime.now(d.timezone(d.timedelta(hours=-3))).strftime("%Y-%m-%dT%H:%M:%S"))'; }
clinica_min_atras() { "$PY" -c "import datetime as d; print((d.datetime.now(d.timezone(d.timedelta(hours=-3)))-d.timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%S'))"; }
clinica_amanha_data() { "$PY" -c 'import datetime as d; print((d.datetime.now(d.timezone(d.timedelta(hours=-3)))+d.timedelta(days=1)).strftime("%Y-%m-%d"))'; }

# payload_agendamento <idTutor> <idPet> <dtAgendamento> <dsTipo> [idTriagemOrigem|null]
payload_agendamento() {
  cat <<JSON
{
  "idTutor": $1,
  "idPet": $2,
  "idVeterinario": $ID_VETERINARIO,
  "dtAgendamento": "$3",
  "duracao": 30,
  "dsTipo": "$4",
  "dsObservacoes": "Agendamento smoke REC-18 $SUFIXO",
  "idTriagemOrigem": ${5:-null}
}
JSON
}
corpo_versao() { printf '{ "nrVersion": %s }' "$1"; }

DT_AGORA_CLINICA=$(clinica_agora)
DATA_AMANHA=$(clinica_amanha_data)
INEXISTENTE=999999999

# 25a. POST /agendamentos (RECEPCAO) — AGH1, hoje. Caso feliz + os 4xx esperados.
chamar "rec-18/agendamentos (POST, hoje, recepcao)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "$DT_AGORA_CLINICA" CONSULTA)" "$TOKEN"
ID_AGH1=$(campo_opcional idAgendamento)
afirmar "rec-18/agendamentos (POST) devolve AGENDADO, versao 0, origem RECEPCAO" \
  "d['dsStatus']=='AGENDADO' and d['nrVersion']==0 and d['dsOrigem']=='RECEPCAO' and d['dsEtapaRecepcao']=='AGENDADO' and d['dtCheckin'] is None"

chamar "rec-18/agendamentos (POST, dsTipo fora da lista)" 400 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "$DT_AGORA_CLINICA" URGENCIA)" "$TOKEN"
chamar "rec-18/agendamentos (POST, dtAgendamento com Z)" 400 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "${DT_AGORA_CLINICA}Z" CONSULTA)" "$TOKEN"
chamar "rec-18/agendamentos (POST, 30 min no passado)" 422 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "$(clinica_min_atras 30)" CONSULTA)" "$TOKEN"
chamar "rec-18/agendamentos (POST, pet de outro tutor)" 422 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_LUNA" "$ID_PET" "$DT_AGORA_CLINICA" CONSULTA)" "$TOKEN"
chamar "rec-18/agendamentos (POST, pet inexistente)" 404 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$INEXISTENTE" "$DT_AGORA_CLINICA" CONSULTA)" "$TOKEN"

# Guardas SEM aninhamento (coluna 0): `extrairNomesDeCheck` (mobile-clinica-rn,
# discover-network-consumers.ts:712) so reconhece `chamar*` no INICIO da linha (`^chamar`, /m) —
# um check dentro de if/else, indentado, fica INVISIVEL ao gate smoke-coverage (medido na REC-18:
# 3 de 4 entradas `coberto` falharam enquanto os checks estavam indentados). Por isso o bloco e
# plano: se um id nao veio, o FALHA abaixo e a causa, e os checks seguintes caem em cascata
# (URL com id vazio => 4xx/404 => mais FALHA), nunca em silencio.
[ -n "$ID_AGH1" ] || { echo "FALHA  rec-18: sem idAgendamento do POST feliz (hoje) — causa dos FALHA em cascata abaixo"; FALHAS=$((FALHAS+1)); }

# 25b. check-in: 1a chamada grava, 2a e idempotente (mesma dtCheckin, mesma versao, mesmo com
# nrVersion velho no corpo — a idempotencia vem ANTES do lock, AgendaService.cs:424-445).
chamar "rec-18/agendamentos/{id}/checkin (POST)" 200 POST "$API/api/v1/agendamentos/$ID_AGH1/checkin" "$(corpo_versao 0)" "$TOKEN"
DT_CHECKIN_1=$(campo_opcional dtCheckin)
afirmar "rec-18/checkin grava dtCheckin, etapa CHEGOU, versao 1, status segue AGENDADO (A-2)" \
  "d['dtCheckin'] is not None and d['dsEtapaRecepcao']=='CHEGOU' and d['nrVersion']==1 and d['dsStatus']=='AGENDADO'"
chamar "rec-18/agendamentos/{id}/checkin (POST, 2a chamada idempotente)" 200 POST "$API/api/v1/agendamentos/$ID_AGH1/checkin" "$(corpo_versao 0)" "$TOKEN"
DT_CHECKIN_2=$(campo_opcional dtCheckin)
afirmar "rec-18/2o checkin NAO sobrescreve dtCheckin (1a x 2a, tolerancia 1 ms) nem incrementa versao" \
  "abs((ts(d['dtCheckin'])-ts('$DT_CHECKIN_1')).total_seconds())<0.001 and d['nrVersion']==1"
chamar "rec-18/agendamentos/{id}/checkin (POST, 3a chamada idempotente)" 200 POST "$API/api/v1/agendamentos/$ID_AGH1/checkin" "$(corpo_versao 0)" "$TOKEN"
afirmar "rec-18/3o checkin devolve a MESMA dtCheckin da 2a (as duas relidas do banco, string exata)" \
  "d['dtCheckin']=='$DT_CHECKIN_2' and d['nrVersion']==1"

# 25c. inicio de atendimento depois do check-in: grava dtInicioAtendimento, nao mexe em dtCheckin.
chamar "rec-18/agendamentos/{id}/inicio-atendimento (POST)" 200 POST "$API/api/v1/agendamentos/$ID_AGH1/inicio-atendimento" "$(corpo_versao 1)" "$TOKEN"
afirmar "rec-18/inicio grava dtInicioAtendimento, etapa EM_ATENDIMENTO, dtCheckin intacta" \
  "d['dtInicioAtendimento'] is not None and d['dsEtapaRecepcao']=='EM_ATENDIMENTO' and d['dtCheckin']=='$DT_CHECKIN_2' and d['nrVersion']==2"

chamar "rec-18/agendamentos/{id}/checkin (POST, agendamento inexistente)" 404 POST "$API/api/v1/agendamentos/$INEXISTENTE/checkin" "$(corpo_versao 0)" "$TOKEN"

# 25d. AGH2: walk-in (entra direto, sem check-in) + versao velha => 409.
chamar "rec-18/agendamentos (POST, hoje, walk-in)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "$DT_AGORA_CLINICA" CONSULTA)" "$TOKEN"
ID_AGH2=$(campo_opcional idAgendamento)
chamar "rec-18/agendamentos/{id}/checkin (POST, versao velha)" 409 POST "$API/api/v1/agendamentos/$ID_AGH2/checkin" "$(corpo_versao 7)" "$TOKEN"
chamar "rec-18/agendamentos/{id}/inicio-atendimento (POST, walk-in sem check-in)" 200 POST "$API/api/v1/agendamentos/$ID_AGH2/inicio-atendimento" "$(corpo_versao 0)" "$TOKEN"
afirmar "rec-18/walk-in: inicio NAO inventa dtCheckin (A-6)" \
  "d['dtCheckin'] is None and d['dtInicioAtendimento'] is not None and d['dsEtapaRecepcao']=='EM_ATENDIMENTO'"

# 25e. AGH3: cancelado => check-in/inicio 422 (so AGENDADO/CONFIRMADO). PATCH /status ja existe
# (AgendaController.cs, FM-04) — usado aqui como setup, com seu proprio check.
chamar "rec-18/agendamentos (POST, hoje, para cancelar)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "$DT_AGORA_CLINICA" CONSULTA)" "$TOKEN"
ID_AGH3=$(campo_opcional idAgendamento)
chamar "rec-18/agendamentos/{id}/status (PATCH, cancelar)" 200 PATCH "$API/api/v1/agendamentos/$ID_AGH3/status" \
  '{ "dsStatus": "CANCELADO", "nrVersion": 0 }' "$TOKEN"
chamar "rec-18/agendamentos/{id}/checkin (POST, agendamento CANCELADO)" 422 POST "$API/api/v1/agendamentos/$ID_AGH3/checkin" "$(corpo_versao 1)" "$TOKEN"
chamar "rec-18/agendamentos/{id}/inicio-atendimento (POST, agendamento CANCELADO)" 422 POST "$API/api/v1/agendamentos/$ID_AGH3/inicio-atendimento" "$(corpo_versao 1)" "$TOKEN"

# 25f. AGD1: amanha 10:00, tutor do bloco 9 (consentimento LEMBRETES aceito + DS_WHATSAPP por
# convencao "mesmo numero" da REC-01) => elegivel a D-1. Check-in de amanha e recusado (m-2).
chamar "rec-18/agendamentos (POST, amanha, D-1)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "${DATA_AMANHA}T10:00:00" CONSULTA)" "$TOKEN"
ID_AGD1=$(campo_opcional idAgendamento)
[ -n "$ID_AGD1" ] || { echo "FALHA  rec-18: sem idAgendamento do agendamento de amanha — causa dos FALHA em cascata da D-1"; FALHAS=$((FALHAS+1)); }
chamar "rec-18/agendamentos/{id}/checkin (POST, agendamento de amanha)" 422 POST "$API/api/v1/agendamentos/$ID_AGD1/checkin" "$(corpo_versao 0)" "$TOKEN"

# 25g. Luna: confirmacao-pendente (API key). Sem a chave => 401.
chamar "rec-18/luna/confirmacao-pendente (GET, sem X-Api-Key)" 401 GET "$API/api/v1/luna/agendamentos/confirmacao-pendente?data=$DATA_AMANHA" ''
chamar_apikey "rec-18/luna/confirmacao-pendente (GET)" 200 GET "$API/api/v1/luna/agendamentos/confirmacao-pendente?data=$DATA_AMANHA" ''
afirmar "rec-18/confirmacao-pendente CONTEM o agendamento de amanha (corpo nao impresso)" \
  "any(i['id_agendamento']==$ID_AGD1 and i['id_tutor']==$ID_TUTOR and i['ds_whatsapp'] for i in d)"

# 25h. lembrete-enviado: 1a grava, 2a devolve a MESMA data (idempotente); inexistente => 404.
chamar_apikey "rec-18/luna/lembrete-enviado (POST)" 200 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/lembrete-enviado" ''
DT_LEMBRETE_1=$(campo_opcional dt_lembrete_confirmacao)
chamar_apikey "rec-18/luna/lembrete-enviado (POST, 2a chamada idempotente)" 200 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/lembrete-enviado" ''
DT_LEMBRETE_2=$(campo_opcional dt_lembrete_confirmacao)
afirmar "rec-18/2o lembrete-enviado devolve a mesma dt_lembrete_confirmacao (1a x 2a, tolerancia 1 ms)" \
  "d['id_agendamento']==$ID_AGD1 and '$DT_LEMBRETE_1'!='' and abs((ts(d['dt_lembrete_confirmacao'])-ts('$DT_LEMBRETE_1')).total_seconds())<0.001"
chamar_apikey "rec-18/luna/lembrete-enviado (POST, 3a chamada idempotente)" 200 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/lembrete-enviado" ''
afirmar "rec-18/3o lembrete-enviado devolve a MESMA dt da 2a (as duas relidas do banco, string exata)" \
  "d['dt_lembrete_confirmacao']=='$DT_LEMBRETE_2' and '$DT_LEMBRETE_2'!=''"
chamar_apikey "rec-18/luna/lembrete-enviado (POST, agendamento inexistente)" 404 POST "$API/api/v1/luna/agendamentos/$INEXISTENTE/lembrete-enviado" ''
chamar_apikey "rec-18/luna/confirmacao-pendente (GET, depois do lembrete)" 200 GET "$API/api/v1/luna/agendamentos/confirmacao-pendente?data=$DATA_AMANHA" ''
afirmar "rec-18/confirmacao-pendente NAO lista mais o agendamento ja lembrado" \
  "not any(i['id_agendamento']==$ID_AGD1 for i in d)"

# 25i. resposta-confirmacao: tutor errado 422, resposta fora do enum 400, inexistente 404,
# agendamento CANCELADO 422; SIM => CONFIRMADO; REMARCAR (a partir de CONFIRMADO) NAO muda status.
chamar_apikey "rec-18/luna/resposta-confirmacao (POST, tutor que nao e o do agendamento)" 422 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/resposta-confirmacao" \
  "{ \"id_tutor\": $ID_TUTOR_LUNA, \"resposta\": \"SIM\" }"
chamar_apikey "rec-18/luna/resposta-confirmacao (POST, resposta fora do enum)" 400 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/resposta-confirmacao" \
  "{ \"id_tutor\": $ID_TUTOR, \"resposta\": \"TALVEZ\" }"
chamar_apikey "rec-18/luna/resposta-confirmacao (POST, agendamento inexistente)" 404 POST "$API/api/v1/luna/agendamentos/$INEXISTENTE/resposta-confirmacao" \
  "{ \"id_tutor\": $ID_TUTOR, \"resposta\": \"SIM\" }"
chamar_apikey "rec-18/luna/resposta-confirmacao (POST, agendamento CANCELADO)" 422 POST "$API/api/v1/luna/agendamentos/$ID_AGH3/resposta-confirmacao" \
  "{ \"id_tutor\": $ID_TUTOR, \"resposta\": \"SIM\" }"
chamar_apikey "rec-18/luna/resposta-confirmacao (POST, SIM)" 200 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/resposta-confirmacao" \
  "{ \"id_tutor\": $ID_TUTOR, \"resposta\": \"SIM\" }"
afirmar "rec-18/resposta SIM => ds_status CONFIRMADO" \
  "d['ds_status']=='CONFIRMADO' and d['ds_resposta_confirmacao']=='SIM'"
chamar_apikey "rec-18/luna/resposta-confirmacao (POST, REMARCAR)" 200 POST "$API/api/v1/luna/agendamentos/$ID_AGD1/resposta-confirmacao" \
  "{ \"id_tutor\": $ID_TUTOR, \"resposta\": \"REMARCAR\" }"
afirmar "rec-18/resposta REMARCAR NAO muda o status (A-10/b)" \
  "d['ds_status']=='CONFIRMADO' and d['ds_resposta_confirmacao']=='REMARCAR'"

# 25j. O que a clinica enxerga na agenda de amanha (REC-09/REC-17): resposta do tutor + origem.
chamar "rec-18/agenda (GET, amanha, resposta da D-1 visivel)" 200 GET "$API/api/v1/agenda?dataInicio=$DATA_AMANHA&dataFim=$DATA_AMANHA" '' "$TOKEN"
afirmar "rec-18/agenda de amanha mostra dsRespostaConfirmacao=REMARCAR e origem RECEPCAO" \
  "any(a['idAgendamento']==$ID_AGD1 and a['dsRespostaConfirmacao']=='REMARCAR' and a['dsOrigem']=='RECEPCAO' and a['dsStatus']=='CONFIRMADO' for a in d['agendamentos'])"

# 25k. "Agendar" pelo card da triagem (REC-14): agendamento com idTriagemOrigem => origem
# TRIAGEM_LUNA + urgencia da triagem no item. Usa a triagem do bloco 12d (tutor Luna, MEDIA) e um pet
# proprio desse tutor (o bloco 12 so cria o tutor).
[ -n "${ID_TRIAGEM_LUNA:-}" ] || { echo "FALHA  rec-18: bloco 12d nao devolveu id_triagem — causa dos FALHA em cascata da origem TRIAGEM_LUNA"; FALHAS=$((FALHAS+1)); }
PAYLOAD_PET_TUTOR_LUNA=$(cat <<JSON
{
  "idEspecie": 1,
  "idRaca": 1,
  "nmPet": "Pet Luna Smoke $SUFIXO",
  "dtNascimento": "2022-01-01T00:00:00Z",
  "sgSexo": "F",
  "sgPorte": "M",
  "idTutor": $ID_TUTOR_LUNA,
  "stPrincipal": true,
  "dsVinculo": "PROPRIETARIO"
}
JSON
)
chamar "rec-18/setup/pets (pet do tutor da triagem)" 201 POST "$API/api/v1/pets" "$PAYLOAD_PET_TUTOR_LUNA" "$TOKEN"
ID_PET_TUTOR_LUNA=$(campo_opcional id)
chamar "rec-18/agendamentos (POST, a partir de triagem)" 201 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR_LUNA" "$ID_PET_TUTOR_LUNA" "${DATA_AMANHA}T11:00:00" CONSULTA "${ID_TRIAGEM_LUNA:-null}")" "$TOKEN"
afirmar "rec-18/agendamento da triagem: origem TRIAGEM_LUNA e urgencia MEDIA no item" \
  "d['dsOrigem']=='TRIAGEM_LUNA' and d['dsNivelUrgenciaOrigem']=='MEDIA'"
chamar "rec-18/agendamentos (POST, triagem de outro tutor)" 422 POST "$API/api/v1/agendamentos" \
  "$(payload_agendamento "$ID_TUTOR" "$ID_PET" "${DATA_AMANHA}T12:00:00" CONSULTA "${ID_TRIAGEM_LUNA:-null}")" "$TOKEN"

# ─── resultado ─────────────────────────────────────────────────────────────
echo
if [ "$FALHAS" -eq 0 ]; then
  echo "=== smoke-contratos.sh: TUDO OK (0 falhas) ==="
else
  echo "=== smoke-contratos.sh: $FALHAS falha(s) — ver acima ==="
fi
exit "$FALHAS"
