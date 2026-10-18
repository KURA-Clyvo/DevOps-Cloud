#!/usr/bin/env bash
# NX-03 (KURA_BACKLOG_NEXT_ESTANDE): envia a foto real dos 4 pets de demo (Rex, Mimi, Bolinha, Thor)
# pelo endpoint real do .NET (POST /api/v1/pets/{id}/foto, multipart thumb + media, ambos WebP).
# Standalone e IDEMPOTENTE: so envia para pet com dsFotoUrl nulo; pet que ja tem foto e' pulado.
# Falha de um pet nao derruba os outros; o script sai 1 se algum falhou (resumo no fim).
#
# Uso:  cd DevOps-Cloud && bash scripts/seed-demo-fotos.sh
# Pre-requisitos: clinica de demo ja semeada (seed-demo.sh / seed-demo-luna.sh), compose de pe, curl, python.
# Senha: DEMO_SENHA (env ou .env), default igual aos seeds. Nunca e' impressa.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./scripts/lib-env.sh

API=${API:-http://localhost:8080}
EMAIL_ACESSO="demo@kura.local"
SENHA=${DEMO_SENHA:-}
[ -z "$SENHA" ] && SENHA=$(ler_chave_env DEMO_SENHA)
SENHA=${SENHA:-SenhaDemo123!}
DIR_FOTOS="scripts/assets/pets"
PETS="Rex:rex Mimi:mimi Bolinha:bolinha Thor:thor"

PY=python
command -v python >/dev/null 2>&1 || PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "erro: python/python3 nao encontrado no PATH." >&2; exit 2; }

BODY_FILE=$(mktemp); PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE"' EXIT

# Git Bash do Windows: curl.exe nativo nao le o /tmp do MSYS — usar caminho nativo nos -F @arquivo
# (mesma armadilha de smoke-contratos.sh:caminho_nativo). NAO setar MSYS_NO_PATHCONV.
caminho_nativo() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# login: corpo por arquivo (nunca por argumento) e senha fora de qualquer echo
printf '{ "dsEmail": "%s", "dsSenha": "%s" }' "$EMAIL_ACESSO" "$SENHA" > "$PAYLOAD_FILE"
CODE=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "$API/api/v1/auth/login" \
  -H 'Content-Type: application/json' --data-binary "@$PAYLOAD_FILE")
if [ "$CODE" != "200" ]; then
  echo "ERRO: login em $EMAIL_ACESSO falhou (HTTP $CODE). Rode antes: bash scripts/seed-demo.sh" >&2
  exit 1
fi
TOKEN=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["accessToken"])' "$(caminho_nativo "$BODY_FILE")")

CODE=$(curl -s -o "$BODY_FILE" -w '%{http_code}' "$API/api/v1/pets" -H "Authorization: Bearer $TOKEN")
if [ "$CODE" != "200" ]; then echo "ERRO: GET /api/v1/pets devolveu HTTP $CODE." >&2; exit 1; fi
# lista tab-separada "nmPet<TAB>idPet<TAB>temFoto" (aceita lista no topo ou em items)
LISTA=$("$PY" -c '
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
if isinstance(d,dict): d=d.get("items") or d.get("content") or []
for p in d:
    print("%s\t%s\t%s" % (p.get("nmPet"), p.get("idPet", p.get("id")), "S" if p.get("dsFotoUrl") else "N"))
' "$(caminho_nativo "$BODY_FILE")")

ENVIADAS=0; PULADAS=0; FALHAS=0
for par in $PETS; do
  nome=${par%%:*}; arq=${par##*:}
  linha=$(printf '%s\n' "$LISTA" | awk -F'\t' -v n="$nome" '$1==n {print; exit}')
  if [ -z "$linha" ]; then echo "AVISO  $nome: pet nao encontrado nesta clinica (seed de pets nao rodou?) — pulado"; FALHAS=$((FALHAS+1)); continue; fi
  id=$(printf '%s' "$linha" | cut -f2 | tr -d '\r'); tem=$(printf '%s' "$linha" | cut -f3 | tr -d '\r')
  if [ "$tem" = "S" ]; then echo "pula   $nome (id $id): ja tem foto"; PULADAS=$((PULADAS+1)); continue; fi
  thumb="$DIR_FOTOS/${arq}_256.webp"; media="$DIR_FOTOS/${arq}.webp"
  if [ ! -f "$thumb" ] || [ ! -f "$media" ]; then echo "AVISO  $nome: arquivos $thumb / $media ausentes — pulado"; FALHAS=$((FALHAS+1)); continue; fi
  code=$(curl -s -o "$BODY_FILE" -w '%{http_code}' -X POST "$API/api/v1/pets/$id/foto" \
    -H "Authorization: Bearer $TOKEN" \
    -F "thumb=@$(caminho_nativo "$thumb");type=image/webp" \
    -F "media=@$(caminho_nativo "$media");type=image/webp")
  if [ "$code" = "200" ]; then echo "ok     $nome (id $id): foto enviada (200)"; ENVIADAS=$((ENVIADAS+1))
  else echo "AVISO  $nome (id $id): foto nao enviada (HTTP $code)"; head -c 200 "$BODY_FILE"; echo; FALHAS=$((FALHAS+1)); fi
done

echo "resumo: enviadas=$ENVIADAS puladas=$PULADAS falhas=$FALHAS"
[ "$FALHAS" -eq 0 ]
