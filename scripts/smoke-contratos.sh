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
FALHAS=0
BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

PY=python
command -v python >/dev/null 2>&1 || PY=python3
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "erro: nem 'python' nem 'python3' foram encontrados no PATH — necessario para parse de JSON (sem jq)." >&2
  exit 2
fi

# ─── helpers ────────────────────────────────────────────────────────────────

chamar() {  # chamar <nome> <esperado> <metodo> <url> <payload> [token]
  local nome=$1 esperado=$2 metodo=$3 url=$4 payload=$5 token=${6:-}
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$metodo" "$url"
              -H 'Content-Type: application/json' -d "$payload")
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
# (KURA_BACKLOG_FIX_4) para a varredura completa. Os 6 casos abaixo (4 colunas
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

# ─── resultado ─────────────────────────────────────────────────────────────
echo
if [ "$FALHAS" -eq 0 ]; then
  echo "=== smoke-contratos.sh: TUDO OK (0 falhas) ==="
else
  echo "=== smoke-contratos.sh: $FALHAS falha(s) — ver acima ==="
fi
exit "$FALHAS"
