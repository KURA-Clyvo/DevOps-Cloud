#!/usr/bin/env bash
if [ -z "${KURA_LF_OK:-}" ] && grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then _lf="$(mktemp)"; tr -d '\r' < "${BASH_SOURCE[0]}" > "$_lf"; KURA_LF_OK=1 KURA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" exec bash "$_lf" "$@"; fi # CRLF -> LF
# =============================================================================
# azure/deploy.sh — provisiona e implanta o Kura no Azure (deploy inicial)
#
#   App Service (Linux) ... clinica-api (.NET 10) · tutor-api (Java 21) · luna-ai (Python 3.12)
#   VM Ubuntu ............. Oracle + MongoDB em containers (volumes nomeados no disco da VM)
#   Key Vault (RBAC) ...... segredos, lidos pelos Web Apps via Key Vault references
#   Static Web Apps ....... build web dos apps React Native (clínica e tutor)
#
# Uso:  azure/deploy.sh <fase>
#
#   infra    RG, rede (VNet/NSG), Key Vault, VM do banco, plano e Web Apps, Static Web Apps
#   build    compila as 3 APIs a partir dos submódulos em $ARTIFACTS_DIR
#            (clinica.zip · tutor.jar · luna.zip)
#   apps     app settings + deploy das 3 APIs, a partir de $ARTIFACTS_DIR
#   web      compila os 2 apps web com as URLs reais das APIs ($WEB_DIR) e publica nos Static Web Apps
#   urls     imprime CHAVE=VALOR com as URLs públicas
#   check    confere pré-requisitos (ferramentas, login, submódulos, runtimes) sem criar nada
#   all      check, infra, build, apps e web em sequência (deploy inicial completo)
#   seed     (opcional, depois do deploy) popula dados de demonstração com scripts/seed-demo*.sh
#   destroy  apaga o grupo de recursos e purga o Key Vault (exige CONFIRMA=sim)
#   db-packages          (opcional, depois do infra) instala os packages PL/SQL no schema do Oracle da VM (Sprint 4, frente Database)
#   db-packages-remover  remove a trigger e os packages (saída de emergência; a API financeira da .NET passa a devolver 503; exige CONFIRMA=sim)
#
# Pré-requisitos: az logado (az login), Python 3, curl.
#   fase build: dotnet SDK 10 e JDK 21 (o zip é opcional: sem ele o script usa o Python)
#   fase web:   Node.js 22 LTS (npm/npx)
#
# Linux, macOS, WSL2 ou Windows (Git Bash). No Windows, instale: Git for Windows, Azure CLI,
# Python 3 (winget install Python.Python.3.12), .NET SDK 10, JDK 21 e Node.js 22; rode no Git Bash
# (ou pelo azure/deploy.ps1, que chama o Git Bash). Finais de linha CRLF são corrigidos sozinhos.
#
# Várias subscriptions: AZURE_SUBSCRIPTION=<id ou nome> escolhe a que será usada.
# Seed: DEMO_SENHA (obrigatória, senha própria: as APIs são públicas) e DEMO_WHATSAPP=<DDI+DDD+número>
# (ou SEED_SEM_WHATSAPP=1).
#
# Máquina do banco: VM_SIZE fixa o tamanho; sem ele, o script testa (az vm create --validate) os
# tamanhos de VM_SIZE_CANDIDATOS e as zonas (VM_ZONE=1|2|3 fixa; VM_ZONE= vazio força "sem zona").
# Os submódulos precisam estar baixados (git submodule update --init --recursive).
# A identidade precisa criar role assignments (Owner, ou Contributor + User Access
# Administrator) — o script concede papéis no Key Vault às identidades dos Web Apps e da VM.
#
# Tudo é sobrescrevível por variável de ambiente (ver "Configuração").
# Segredos: gerados no Key Vault na primeira execução. Para fornecer um valor
# (ex.: TWILIO_SID, TWILIO_TOKEN, OPENAI_API_KEY, DAILY_API_KEY) exporte a variável
# de mesmo nome antes de rodar; ela é gravada no cofre. Nada é impresso.
# =============================================================================
set -Eeuo pipefail
trap 'echo "ERRO na linha $LINENO: $BASH_COMMAND" >&2' ERR

_dir="${KURA_SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
RAIZ="$(cd "$_dir/.." && pwd)"

# ─── Compatibilidade Windows (Git Bash/MSYS) ─────────────────────────────────
case "$(uname -s 2>/dev/null || true)" in MINGW* | MSYS* | CYGWIN*) WINDOWS=1 ;; *) WINDOWS=0 ;; esac
AZBIN=az
PYBIN=""
export PYTHONUTF8=1
if [ "$WINDOWS" = 1 ]; then
  # Sem isto o Git Bash reescreve argumentos que começam com "/" (--scope /subscriptions/...,
  # STORAGE_BASE_PATH=/home/..., @//ip no JDBC) para caminhos do Windows. Os caminhos de ARQUIVO
  # passados a programas nativos (az, dotnet, node, python) são convertidos por caminho_nativo().
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  if ! command -v az >/dev/null 2>&1; then
    if command -v az.cmd >/dev/null 2>&1; then AZBIN=az.cmd; fi
  fi
  # O az do Windows devolve CRLF: sem remover o \r, toda variável capturada por $(az ...) ficaria suja.
  az() { command "$AZBIN" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
fi

CURL_EXTRA=()
if [ "$WINDOWS" = 1 ]; then CURL_EXTRA=(--ssl-no-revoke); fi

caminho_nativo() { # caminho que programas nativos do Windows entendem (C:/...); igual no Linux/macOS
  if [ "$WINDOWS" = 1 ] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

achar_python() { # um Python 3 de verdade (o atalho python3 da Microsoft Store não conta)
  local c v
  for c in python3 python py; do
    command -v "$c" >/dev/null 2>&1 || continue
    if [ "$c" = py ]; then v="$(py -3 -c 'import sys;print(sys.version_info[0])' 2>/dev/null | tr -d '\r' || true)"
    else v="$("$c" -c 'import sys;print(sys.version_info[0])' 2>/dev/null | tr -d '\r' || true)"; fi
    if [ "$v" = 3 ]; then
      if [ "$c" = py ]; then PYBIN="py -3"; else PYBIN="$c"; fi
      return 0
    fi
  done
  return 1
}
# O Python do Windows imprime CRLF: pyx remove o \r (senão senhas e ids ficariam com \r no fim).
pyx() {
  if [ -z "$PYBIN" ]; then achar_python || die "Python 3 não encontrado (Windows: 'winget install Python.Python.3.12'; o atalho python3 da Microsoft Store não serve)"; fi
  $PYBIN "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"
}

# ─── Configuração ────────────────────────────────────────────────────────────
LOCATION="${LOCATION:-eastus2}"
SWA_LOCATION="${SWA_LOCATION:-$LOCATION}"   # Static Web Apps só existe em algumas regiões
PREFIX="${PREFIX:-kura}"
RG="${RG:-rg-$PREFIX}"

# Rede
VNET="vnet-$PREFIX"; VNET_CIDR="10.20.0.0/16"
SNET_APP="snet-app";   SNET_APP_CIDR="10.20.1.0/24"     # integração dos Web Apps (delegada)
SNET_DATA="snet-data"; SNET_DATA_CIDR="10.20.2.0/24"    # VM do banco
NSG="nsg-$PREFIX-data"

# Key Vault (nome global: sufixo estável derivado da subscription)
if [ -n "${AZURE_SUBSCRIPTION:-}" ]; then az account set --subscription "$AZURE_SUBSCRIPTION" >/dev/null 2>&1 || true; fi
SUFFIX="${NAME_SUFFIX:-}"
if [ -z "$SUFFIX" ]; then
  SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
  [ -n "$SUB_ID" ] && SUFFIX="$(printf '%s' "$SUB_ID" | sha1sum | cut -c1-5)"
fi
KV_NAME="${KV_NAME:-kv-$PREFIX-${SUFFIX:-x0000}}"

# VM do banco (Oracle ≤ 2 GB de SGA+PGA; MongoDB limitado a 0,5 GB de cache; 8 GiB dá folga)
VM="vm-$PREFIX-db"
VM_SIZE="${VM_SIZE:-}"   # vazio: o script escolhe entre os candidatos (2 vCPU / 8 GiB)
VM_SIZE_CANDIDATOS="${VM_SIZE_CANDIDATOS:-Standard_B2ms Standard_D2s_v3 Standard_B2s_v2 Standard_B2as_v2 Standard_D2as_v4}"
VM_IMAGE="${VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"

# Banco: Oracle XE 21c (service XEPDB1), a imagem validada no projeto, e MongoDB 7 (Loja do tutor).
# Alternativa ainda não validada com o Flyway do tutor: ORACLE_IMAGE=gvenzl/oracle-free:slim ORACLE_SERVICE=FREEPDB1
ORACLE_IMAGE="${ORACLE_IMAGE:-gvenzl/oracle-xe:21-slim}"
ORACLE_SERVICE="${ORACLE_SERVICE:-XEPDB1}"
ORACLE_APP_USER="${ORACLE_APP_USER:-KURA}"      # dono do schema: o Flyway (tutor) cria tudo nele

# App Service
PLAN="plan-$PREFIX"; PLAN_SKU="${PLAN_SKU:-B2}"
APP_CLINICA="$PREFIX-clinica-api"; APP_TUTOR="$PREFIX-tutor-api"; APP_LUNA="$PREFIX-luna-ai"
SWA_CLINICA="$PREFIX-clinica-web"; SWA_TUTOR="$PREFIX-tutor-web"
# Strings de runtime: confira com `az webapp list-runtimes --os-type linux` (o script valida)
RUNTIME_DOTNET="${RUNTIME_DOTNET:-DOTNETCORE|10.0}"; RUNTIME_DOTNET="${RUNTIME_DOTNET//:/|}"
RUNTIME_JAVA="${RUNTIME_JAVA:-JAVA|21-java21}";     RUNTIME_JAVA="${RUNTIME_JAVA//:/|}"
RUNTIME_PYTHON="${RUNTIME_PYTHON:-PYTHON|3.12}";    RUNTIME_PYTHON="${RUNTIME_PYTHON//:/|}"

# Valores de aplicação
ASPNETCORE_ENVIRONMENT="${ASPNETCORE_ENVIRONMENT:-Production}"
STORAGE_BASE_PATH="${STORAGE_BASE_PATH:-/home/kura/receituarios}"   # /home persiste no App Service
JWT_ACCESS_EXPIRATION_MINUTES="${JWT_ACCESS_EXPIRATION_MINUTES:-15}"
TWILIO_FROM_NUMBER="${TWILIO_FROM_NUMBER:-+14155238886}"
LEMBRETE_CONFIRMACAO_HABILITADO="${LEMBRETE_CONFIRMACAO_HABILITADO:-false}"
LEMBRETE_CONFIRMACAO_HORA="${LEMBRETE_CONFIRMACAO_HORA:-9}"
LUNA_SCHEDULER_ENABLED="${LUNA_SCHEDULER_ENABLED:-false}"
LUNA_SCHEDULER_HORA="${LUNA_SCHEDULER_HORA:-8}"
LOJA_SEED_EXEMPLO="${LOJA_SEED_EXEMPLO:-true}"      # catálogo de exemplo da Loja (D-LOJA-10)
EXTRA_CORS_ORIGINS="${EXTRA_CORS_ORIGINS:-}"        # ex.: http://localhost:19006 (desenvolvimento)

ARTIFACTS_DIR="${ARTIFACTS_DIR:-$RAIZ/artifacts}"
WEB_DIR="${WEB_DIR:-$RAIZ/web-dist}"
SWA_CLI_VERSION="${SWA_CLI_VERSION:-2.0.10}"        # fixada (publicada há mais de 14 dias)

# ─── Utilitários ─────────────────────────────────────────────────────────────
log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

tentar() { # tentar <tentativas> <espera-s> <comando...>
  local n=$1 s=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    [ "$i" -lt "$n" ] && sleep "$s"
  done
  return 1
}

exigir_ferramentas() {
  (unset -f az 2>/dev/null; command -v "$AZBIN" >/dev/null 2>&1) || die "'az' (Azure CLI) não encontrado no PATH"
  command -v curl >/dev/null 2>&1 || die "'curl' não encontrado no PATH"
  achar_python || die "Python 3 não encontrado (Windows: 'winget install Python.Python.3.12'; o atalho python3 da Microsoft Store não serve)"
  az account show >/dev/null 2>&1 || die "sem sessão Azure: rode 'az login' (ou use a service connection)"
  if [ -n "${AZURE_SUBSCRIPTION:-}" ]; then
    az account set --subscription "$AZURE_SUBSCRIPTION" || die "subscription '$AZURE_SUBSCRIPTION' não encontrada (veja: az account list -o table)"
  fi
}

gerar() { # gerar <alnum|hex|b64> <tamanho>
  pyx - "$1" "$2" <<'PY'
import secrets, string, sys
tipo, n = sys.argv[1], int(sys.argv[2])
if tipo == "alnum":   # começa com letra: senhas Oracle e connection strings
    todos = string.ascii_letters + string.digits
    print(secrets.choice(string.ascii_letters) + "".join(secrets.choice(todos) for _ in range(n - 1)))
elif tipo == "hex":   # sem caracteres que exijam URL-encode em URIs
    print(secrets.token_hex(n // 2))
else:                 # base64 url-safe
    print(secrets.token_urlsafe(n)[:n])
PY
}

oid_chamador() { # object id de quem executa (usuário ou service principal), lido do token — sem Graph
  local tok; tok="$(az account get-access-token --query accessToken -o tsv)"
  KURA_TOK="$tok" pyx - <<'PY'
import os, json, base64
p = os.environ["KURA_TOK"].strip().split(".")[1]
p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["oid"])
PY
}
tipo_chamador() {
  if [ "$(az account show --query user.type -o tsv)" = "servicePrincipal" ]; then echo ServicePrincipal; else echo User; fi
}

dar_papel() { # dar_papel <object-id> <User|ServicePrincipal> <papel> <escopo> — idempotente, com retry
  local i out
  for ((i = 1; i <= 12; i++)); do
    if out="$(az role assignment create --assignee-object-id "$1" --assignee-principal-type "$2" \
                --role "$3" --scope "$4" -o none 2>&1)"; then return 0; fi
    grep -qi 'already exists' <<<"$out" && return 0
    sleep 10   # identidade recém-criada ainda replicando no Entra ID
  done
  printf '%s\n' "$out" >&2; return 1
}

# ─── Key Vault: segredos ─────────────────────────────────────────────────────
kv_ler() { az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv 2>/dev/null || true; }

kv_gravar() { # só cria nova versão quando o valor muda
  [ "$(kv_ler "$1")" = "$2" ] && return 0
  tentar 20 15 az keyvault secret set --vault-name "$KV_NAME" --name "$1" --value "$2" -o none   # RBAC propaga em minutos
}

segredo() { # segredo <nome-no-cofre> <VARIÁVEL> <alnum|hex|b64|externo> [tamanho]
  local nome=$1 tipo=$3 tam=${4:-32} valor="${!2:-}"
  if [ -n "$valor" ]; then kv_gravar "$nome" "$valor"; return 0; fi   # valor fornecido pelo ambiente
  [ -n "$(kv_ler "$nome")" ] && return 0                              # já existe: preserva
  [ "$tipo" = externo ] && return 0                                    # opcional: segue ausente
  kv_gravar "$nome" "$(gerar "$tipo" "$tam")"
}

kvref()         { printf '@Microsoft.KeyVault(VaultName=%s;SecretName=%s)' "$KV_NAME" "$1"; }
kvref_opcional() { if [ -n "$(kv_ler "$1")" ]; then kvref "$1"; fi; }   # vazio se o segredo não existe

# ─── Consultas ───────────────────────────────────────────────────────────────
host_app() { az webapp show -g "$RG" -n "$1" --query defaultHostName -o tsv; }
host_swa() { az staticwebapp show -g "$RG" -n "$1" --query defaultHostname -o tsv; }
ip_vm()    { az vm show -d -g "$RG" -n "$VM" --query privateIps -o tsv; }

aguardar_saude() { # aguardar_saude <url> [tentativas] [espera-s]
  local url=$1 n=${2:-40} s=${3:-15} i code
  for ((i = 1; i <= n; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
    if [ "$code" = 200 ]; then info "saudável: $url"; return 0; fi
    sleep "$s"
  done
  return 1
}

diagnostico() { # últimas linhas do log do Web App quando algo falha
  info "log de $1 (últimos segundos):"
  timeout 25 "$AZBIN" webapp log tail -g "$RG" -n "$1" 2>&1 | tail -n 40 || true
}

# ═════════════════════════════════════════════════════════════════════════════
# FASE infra
# ═════════════════════════════════════════════════════════════════════════════
validar_runtimes() {
  # O az novo devolve várias colunas por linha (nome, fim de suporte, SO...): compara só o nome,
  # e aceita os dois separadores (":" e "|").
  local lista r n; lista="$(az webapp list-runtimes --os-type linux -o tsv | cut -f1 | tr ':' '|')"
  for r in "$RUNTIME_DOTNET" "$RUNTIME_JAVA" "$RUNTIME_PYTHON"; do
    n="${r//:/|}"
    grep -Fqix -- "$n" <<<"$lista" || die "runtime '$r' indisponível. Opções:
$lista"
  done
}

criar_rede() {
  az group create -n "$RG" -l "$LOCATION" --tags projeto=kura -o none

  # NSG da sub-rede do banco: só os Web Apps (snet-app) chegam em Oracle e MongoDB.
  # Nada mais entra (sem SSH: a administração é por `az vm run-command`).
  az network nsg create -g "$RG" -n "$NSG" -l "$LOCATION" -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-db-from-app \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$SNET_APP_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 1521 27017 -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n deny-all-inbound \
    --priority 4000 --direction Inbound --access Deny --protocol '*' \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges '*' -o none

  az network vnet create -g "$RG" -n "$VNET" -l "$LOCATION" --address-prefixes "$VNET_CIDR" -o none
  az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SNET_APP" \
    --address-prefixes "$SNET_APP_CIDR" --delegations Microsoft.Web/serverFarms -o none
  az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SNET_DATA" \
    --address-prefixes "$SNET_DATA_CIDR" --network-security-group "$NSG" -o none
}

criar_cofre() {
  # Um cofre apagado (soft-delete) segura o nome: ao recriar do zero, purga.
  if [ -n "$(az keyvault list-deleted --query "[?name=='$KV_NAME'].name | [0]" -o tsv)" ]; then
    info "purgando cofre removido anteriormente: $KV_NAME"
    az keyvault purge --name "$KV_NAME" --location "$LOCATION" -o none
  fi
  if ! az keyvault show -n "$KV_NAME" >/dev/null 2>&1; then
    az keyvault create -n "$KV_NAME" -g "$RG" -l "$LOCATION" \
      --enable-rbac-authorization true --retention-days 7 -o none
  fi
  KV_ID="$(az keyvault show -n "$KV_NAME" --query id -o tsv)"
  dar_papel "$(oid_chamador)" "$(tipo_chamador)" "Key Vault Secrets Officer" "$KV_ID"

  segredo oracle-sys-password     ORACLE_SYS_PASSWORD     alnum 24
  segredo oracle-app-password     ORACLE_APP_PASSWORD     alnum 24
  segredo dotnet-jwt-key          DOTNET_JWT_KEY          b64   48
  segredo iot-api-key             IOT_API_KEY             b64   32
  segredo luna-api-key            LUNA_API_KEY            b64   32
  segredo luna-inbound-api-key    LUNA_INBOUND_API_KEY    b64   32
  segredo java-jwt-secret         JAVA_JWT_SECRET         b64   64
  segredo foto-url-secret         FOTO_URL_SECRET         b64   48
  segredo mongo-root-password     MONGO_ROOT_PASSWORD     hex   48
  segredo mongo-java-password     MONGO_JAVA_PASSWORD     hex   48
  segredo mongo-dotnet-password   MONGO_DOTNET_PASSWORD   hex   48
  segredo daily-api-key           DAILY_API_KEY           externo
  segredo twilio-sid              TWILIO_SID              externo
  segredo twilio-token            TWILIO_TOKEN            externo
  segredo openai-api-key          OPENAI_API_KEY          externo
}

montar_script_vm() { # imprime o script que roda DENTRO da VM (como root, via run-command)
  # O run-command executa com /bin/sh (dash no Ubuntu), que não tem 'set -o pipefail': reexecuta no bash.
  printf '%s\n' '[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"'
  printf 'KV_NAME=%q\nORACLE_IMAGE=%q\nORACLE_SERVICE=%q\nORACLE_APP_USER=%q\n' \
    "$KV_NAME" "$ORACLE_IMAGE" "$ORACLE_SERVICE" "$ORACLE_APP_USER"
  printf 'MONGO_INIT_B64=%q\n' "$(tr -d '\r' < "$RAIZ/mongo/init/01-roles-usuarios.js" | base64 -w0)"
  cat <<'VM_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 1) Docker (pacotes do Ubuntu: docker.io + plugin compose v2)
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 python3 curl ca-certificates >/dev/null
fi
systemctl enable --now docker

# 2) Segredos: Key Vault, com a identidade gerenciada da VM (o papel pode levar minutos para propagar)
segredo() {
  local t v
  for _ in $(seq 1 30); do
    if t="$(curl -sf -H 'Metadata:true' 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')" \
       && v="$(curl -sf -H "Authorization: Bearer $t" "https://${KV_NAME}.vault.azure.net/secrets/$1?api-version=7.4" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')" \
       && [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    sleep 10
  done
  echo "ERRO: segredo $1 inacessível no Key Vault" >&2; return 1
}
ORACLE_SYS_PASSWORD="$(segredo oracle-sys-password)"
ORACLE_APP_PASSWORD="$(segredo oracle-app-password)"
MONGO_ROOT_PASSWORD="$(segredo mongo-root-password)"
MONGO_JAVA_PASSWORD="$(segredo mongo-java-password)"
MONGO_DOTNET_PASSWORD="$(segredo mongo-dotnet-password)"

# 3) Arquivos do stack (permissão 600: só root lê)
install -d -m 700 /opt/kura /opt/kura/mongo-init
umask 077
cat > /opt/kura/.env <<ENV
ORACLE_IMAGE=${ORACLE_IMAGE}
ORACLE_SYS_PASSWORD=${ORACLE_SYS_PASSWORD}
ORACLE_APP_USER=${ORACLE_APP_USER}
ORACLE_APP_PASSWORD=${ORACLE_APP_PASSWORD}
KURA_MONGO_ROOT_USER=kura_root
KURA_MONGO_ROOT_PASSWORD=${MONGO_ROOT_PASSWORD}
KURA_MONGO_JAVA_PASSWORD=${MONGO_JAVA_PASSWORD}
KURA_MONGO_DOTNET_PASSWORD=${MONGO_DOTNET_PASSWORD}
ENV
printf '%s' "$MONGO_INIT_B64" | base64 -d > /opt/kura/mongo-init/01-roles-usuarios.js

cat > /opt/kura/docker-compose.yml <<'YML'
name: kura
services:
  oracle-db:
    image: ${ORACLE_IMAGE}
    container_name: kura_oracle_db
    restart: unless-stopped
    shm_size: 1g
    ports: ["1521:1521"]
    environment:
      ORACLE_PASSWORD: ${ORACLE_SYS_PASSWORD}
      APP_USER: ${ORACLE_APP_USER}
      APP_USER_PASSWORD: ${ORACLE_APP_PASSWORD}
    volumes:
      - kura-oracle-data:/opt/oracle/oradata

  kura-mongo:
    image: mongo:7.0.45-jammy
    container_name: kura_mongo
    restart: unless-stopped
    command: ["--wiredTigerCacheSizeGB", "0.5"]
    ports: ["27017:27017"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${KURA_MONGO_ROOT_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${KURA_MONGO_ROOT_PASSWORD}
    volumes:
      - kura-mongo-data:/data/db
    healthcheck:
      # --host "$(hostname)" e de proposito, nao localhost: no 1o boot a imagem sobe um mongod
      # temporario so em 127.0.0.1; o IP do container so responde com o mongod definitivo.
      test: ["CMD-SHELL", "mongosh --quiet --host \"$$(hostname)\" --eval \"db.adminCommand('ping').ok\" | grep -qx 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  mongo-init:
    image: mongo:7.0.45-jammy
    container_name: kura_mongo_init
    restart: "no"
    depends_on:
      kura-mongo:
        condition: service_healthy
    environment:
      KURA_MONGO_ROOT_USER: ${KURA_MONGO_ROOT_USER}
      KURA_MONGO_ROOT_PASSWORD: ${KURA_MONGO_ROOT_PASSWORD}
      KURA_MONGO_JAVA_PASSWORD: ${KURA_MONGO_JAVA_PASSWORD}
      KURA_MONGO_DOTNET_PASSWORD: ${KURA_MONGO_DOTNET_PASSWORD}
    volumes:
      - /opt/kura/mongo-init:/scripts:ro
    entrypoint: ["sh", "-c"]
    command:
      - "exec mongosh --host kura-mongo --quiet -u \"$$KURA_MONGO_ROOT_USER\" -p \"$$KURA_MONGO_ROOT_PASSWORD\" --authenticationDatabase admin --file /scripts/01-roles-usuarios.js"

volumes:
  kura-oracle-data:
  kura-mongo-data:
YML

# 4) Sobe o stack (idempotente) e espera ficar pronto
docker compose -f /opt/kura/docker-compose.yml --env-file /opt/kura/.env up -d

oracle_pronto=0
for _ in $(seq 1 180); do   # 1ª subida do Oracle leva alguns minutos (cria o banco)
  out="$(printf 'connect %s/%s@//localhost:1521/%s\nselect 1 from dual;\n' "$ORACLE_APP_USER" "$ORACLE_APP_PASSWORD" "$ORACLE_SERVICE" \
         | docker exec -i kura_oracle_db sqlplus -s /nolog 2>&1 || true)"
  if grep -Eq '^[[:space:]]*1[[:space:]]*$' <<<"$out"; then oracle_pronto=1; break; fi
  sleep 10
done
if [ "$oracle_pronto" != 1 ]; then
  docker logs --tail 40 kura_oracle_db 2>&1 || true
  echo "ERRO: Oracle não aceitou conexão de ${ORACLE_APP_USER} no service ${ORACLE_SERVICE}" >&2; exit 1
fi

for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' kura_mongo 2>/dev/null || true)" = healthy ] && break
  sleep 5
done
rc="$(docker wait kura_mongo_init)"
if [ "$rc" != 0 ]; then
  docker logs --tail 40 kura_mongo_init 2>&1 || true
  echo "ERRO: mongo-init terminou com código $rc" >&2; exit 1
fi

echo KURA_BOOTSTRAP_OK
VM_SCRIPT
}

provisionar_vm() { # cria a VM só se não existir; testa tamanhos/zonas com --validate (capacidade varia por conta)
  az vm show -g "$RG" -n "$VM" >/dev/null 2>&1 && return 0
  local args tamanhos zonas s z zarg rotulo ok=0
  # IP público só para SAÍDA (docker pull/apt): o NSG da sub-rede bloqueia toda entrada.
  args=(-g "$RG" -n "$VM" -l "$LOCATION" --image "$VM_IMAGE"
        --vnet-name "$VNET" --subnet "$SNET_DATA" --nsg "" --public-ip-sku Standard
        --assign-identity '[system]' --os-disk-size-gb 64 --storage-sku StandardSSD_LRS
        --admin-username azureuser --generate-ssh-keys)
  tamanhos="${VM_SIZE:-$VM_SIZE_CANDIDATOS}"
  if [ "${VM_ZONE+set}" = set ]; then zonas="${VM_ZONE:-none}"; else zonas="none 1 3 2"; fi
  for s in $tamanhos; do
    for z in $zonas; do
      zarg=(); rotulo="sem zona"
      if [ "$z" != none ]; then zarg=(--zone "$z"); rotulo="zona $z"; fi
      info "verificando $s ($rotulo)"
      if az vm create "${args[@]}" --size "$s" ${zarg[@]+"${zarg[@]}"} --validate -o none >/dev/null 2>&1; then
        ok=1; break 2
      fi
    done
  done
  [ "$ok" = 1 ] || die "nenhum tamanho de VM disponível em $LOCATION para esta subscription (testados: $tamanhos).
Veja os tamanhos liberados:  az vm list-skus -l $LOCATION --resource-type virtualMachines -o table
e exporte VM_SIZE=<tamanho> (2 vCPU e 8 GiB ou mais), ou outra LOCATION."
  info "criando a VM: $s ($rotulo)"
  az vm create "${args[@]}" --size "$s" ${zarg[@]+"${zarg[@]}"} -o none
}

criar_vm() {
  provisionar_vm
  dar_papel "$(az vm show -g "$RG" -n "$VM" --query identity.principalId -o tsv)" ServicePrincipal \
    "Key Vault Secrets User" "$KV_ID"

  # Bootstrap por run-command. O código de saída do run-command não é confiável:
  # o sucesso é provado pela linha sentinela que o script imprime ao final.
  # O script vai por ARQUIVO (--scripts @arquivo): argumento multilinha quebra no az do Windows.
  local tmp saida; tmp="$(mktemp)"
  montar_script_vm | tr -d '\r' > "$tmp"
  saida="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
            --scripts "@$(caminho_nativo "$tmp")" --query 'value[0].message' -o tsv || true)"
  rm -f "$tmp"
  if ! grep -q KURA_BOOTSTRAP_OK <<<"$saida"; then
    printf '%s\n' "$saida" | tail -n 40 >&2
    die "bootstrap da VM não concluiu (sentinela ausente)"
  fi
  info "banco pronto em $(ip_vm) (Oracle ${ORACLE_SERVICE} + MongoDB)"
}

criar_webapp() { # criar_webapp <nome> <runtime> <path-de-saude>
  local app=$1 runtime=$2 saude=$3 pid
  if ! az webapp show -g "$RG" -n "$app" >/dev/null 2>&1; then
    # hostname único e estável dentro do tenant (--domain-name-scope TenantReuse)
    az webapp create -g "$RG" -n "$app" -p "$PLAN" --runtime "$runtime" \
      --domain-name-scope TenantReuse -o none
  fi
  az webapp identity assign -g "$RG" -n "$app" -o none
  pid="$(az webapp identity show -g "$RG" -n "$app" --query principalId -o tsv)"
  dar_papel "$pid" ServicePrincipal "Key Vault Secrets User" "$KV_ID"

  # Saída para o banco pela VNet (o banco só aceita a sub-rede dos Web Apps)
  if [ -z "$(az webapp vnet-integration list -g "$RG" -n "$app" --query '[0].name' -o tsv)" ]; then
    az webapp vnet-integration add -g "$RG" -n "$app" --vnet "$VNET" --subnet "$SNET_APP" -o none
  fi

  # Baseline de segurança e operação
  az webapp update -g "$RG" -n "$app" --https-only true -o none
  az webapp config set -g "$RG" -n "$app" --always-on true --min-tls-version 1.2 \
    --ftps-state Disabled --http20-enabled true -o none
  if ! az webapp config set -g "$RG" -n "$app" --generic-configurations "{\"healthCheckPath\": \"$saude\"}" -o none 2>/dev/null \
     && ! az webapp config set -g "$RG" -n "$app" --generic-configurations "healthCheckPath=$saude" -o none 2>/dev/null; then
    info "aviso: healthCheckPath de $app não foi definido ($saude): ajuste no portal (Monitoring > Health check)"
  fi
  az webapp log config -g "$RG" -n "$app" --application-logging filesystem --level information \
    --docker-container-logging filesystem -o none
  # Sem credenciais básicas (FTP/SCM): o deploy usa a identidade do Entra ID
  local pol
  for pol in ftp scm; do
    az resource update -g "$RG" --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies \
      --parent "sites/$app" -n "$pol" --set properties.allow=false -o none
  done
}

registrar_providers() { # subscription nova pode não ter os providers registrados (MissingSubscriptionRegistration)
  local ns st i pend=()
  for ns in Microsoft.Compute Microsoft.Network Microsoft.KeyVault Microsoft.Web; do
    st="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || true)"
    [ "$st" = Registered ] && continue
    info "registrando o provider $ns (estado: ${st:-desconhecido})"
    az provider register -n "$ns" -o none 2>/dev/null || info "aviso: não consegui registrar $ns (precisa de Owner ou Contributor)"
    pend+=("$ns")
  done
  for ns in ${pend[@]+"${pend[@]}"}; do
    st=""
    for ((i = 1; i <= 60; i++)); do
      st="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || true)"
      [ "$st" = Registered ] && break
      sleep 5
    done
    [ "$st" = Registered ] || info "aviso: $ns ainda está '${st:-desconhecido}'; se o deploy falhar com MissingSubscriptionRegistration, espere e repita"
  done
}

fase_infra() {
  exigir_ferramentas
  log "Providers da subscription"; registrar_providers
  log "1/6  Runtimes disponíveis"; validar_runtimes
  log "2/6  Rede: NSG, VNet e sub-redes"; criar_rede
  log "3/6  Key Vault e segredos"; criar_cofre
  log "4/6  VM do banco (Oracle + MongoDB)"; criar_vm
  log "5/6  App Service: plano e Web Apps"
  if ! az appservice plan show -g "$RG" -n "$PLAN" >/dev/null 2>&1; then
    az appservice plan create -g "$RG" -n "$PLAN" -l "$LOCATION" --is-linux --sku "$PLAN_SKU" -o none
  fi
  criar_webapp "$APP_CLINICA" "$RUNTIME_DOTNET" /health
  criar_webapp "$APP_TUTOR"   "$RUNTIME_JAVA"   /api/actuator/health
  criar_webapp "$APP_LUNA"    "$RUNTIME_PYTHON" /health
  log "6/6  Static Web Apps (web dos apps)"
  local swa
  for swa in "$SWA_CLINICA" "$SWA_TUTOR"; do
    if ! az staticwebapp show -g "$RG" -n "$swa" >/dev/null 2>&1; then
      az staticwebapp create -g "$RG" -n "$swa" -l "$SWA_LOCATION" --sku Free -o none
    fi
  done
  fase_urls
}

# ═════════════════════════════════════════════════════════════════════════════
# FASE build
# ═════════════════════════════════════════════════════════════════════════════
exigir_comandos() { # exigir_comandos <fase> <comando...>
  local fase=$1 t; shift
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "'$t' não encontrado no PATH (necessário na fase $fase)"; done
}

exigir_submodulos() { # exigir_submodulos <arquivo-relativo...>
  local f
  for f in "$@"; do
    [ -f "$RAIZ/$f" ] || die "'$f' não encontrado: baixe os submódulos com 'git submodule update --init --recursive'"
  done
}

zipar() { # zipar <zip-destino> <itens...> [-x padrões...] — a partir do diretório atual; usa zip ou, sem ele, Python
  local dest=$1; shift
  if command -v zip >/dev/null 2>&1; then zip -qr "$dest" "$@"; return; fi
  pyx - "$(caminho_nativo "$dest")" "$@" <<'PY'
import sys, os, zipfile, fnmatch
dest, args = sys.argv[1], sys.argv[2:]
itens, excl = args, []
if "-x" in args:
    i = args.index("-x"); itens, excl = args[:i], args[i + 1:]
def ignorado(nome): return any(fnmatch.fnmatch(nome, p) for p in excl)
if os.path.exists(dest): os.remove(dest)
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
    for item in itens:
        if os.path.isdir(item):
            for raiz, _, arqs in os.walk(item):
                for a in arqs:
                    cam = os.path.join(raiz, a)
                    nome = os.path.relpath(cam, ".").replace(os.sep, "/")
                    if not ignorado(nome): z.write(cam, nome)
        else:
            nome = os.path.relpath(item, ".").replace(os.sep, "/")
            if not ignorado(nome): z.write(item, nome)
PY
}

MVN=()
maven_pronto() { # define MVN para o java-backend: mvnw; senão mvn do PATH; senão baixa o Maven (versão do mvnw)
  local dir="$RAIZ/java-backend" props url name home zip
  # o mvnw e suas propriedades precisam de LF (checkout no Windows pode trazer CRLF)
  sed -i 's/\r$//' "$dir/mvnw" "$dir/.mvn/wrapper/maven-wrapper.properties" 2>/dev/null || true
  if ( cd "$dir" && bash ./mvnw -B --version >/dev/null 2>&1 ); then MVN=(bash ./mvnw); return 0; fi
  # O mvnw baixa o Maven com curl e extrai com unzip: o Git Bash não traz unzip e o curl pode falhar na rede.
  info "o mvnw não conseguiu preparar o Maven (diagnóstico: cd java-backend && MVNW_VERBOSE=true bash ./mvnw --version)"
  if command -v mvn >/dev/null 2>&1; then info "usando o mvn do PATH"; MVN=(mvn); return 0; fi
  props="$dir/.mvn/wrapper/maven-wrapper.properties"
  url="$(sed -n 's/^distributionUrl=//p' "$props" 2>/dev/null | head -n1 | tr -d '\r\\')"
  [ -n "$url" ] || url="https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.11/apache-maven-3.9.11-bin.zip"
  name="$(basename "$url" -bin.zip)"
  home="${KURA_TOOLS:-$HOME/.kura-tools}"
  if [ ! -f "$home/$name/bin/mvn" ]; then
    mkdir -p "$home"; zip="$home/$name-bin.zip"
    info "baixando o Maven: $url"
    curl -fsSL --retry 3 --retry-delay 3 --max-time 600 ${CURL_EXTRA[@]+"${CURL_EXTRA[@]}"} -o "$zip" "$url" \
      || die "não consegui baixar o Maven. Instale-o (Windows: 'winget install Apache.Maven') ou libere o acesso a repo.maven.apache.org (proxy/antivírus) e rode de novo"
    pyx - "$(caminho_nativo "$zip")" "$(caminho_nativo "$home")" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
    rm -f "$zip"
  fi
  MVN=(bash "$home/$name/bin/mvn")
}

fase_build() {
  exigir_comandos build dotnet java
  local jdk out
  dotnet --list-sdks | grep -q '^10\.' || die "dotnet SDK 10 não encontrado ('dotnet --list-sdks')"
  jdk="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
  [ "${jdk:-0}" -ge 21 ] || die "JDK 21 ou superior necessário (encontrado: ${jdk:-desconhecido})"
  exigir_submodulos dotnet-backend/src/Kura.Api/Kura.Api.csproj java-backend/mvnw luna-ia/luna/requirements.txt

  mkdir -p "$ARTIFACTS_DIR"; out="$(cd "$ARTIFACTS_DIR" && pwd)"
  rm -f "$out/clinica.zip" "$out/tutor.jar" "$out/luna.zip"

  log "Build: clinica-api (.NET 10)"
  rm -rf "$out/.clinica"
  dotnet publish "$(caminho_nativo "$RAIZ/dotnet-backend/src/Kura.Api/Kura.Api.csproj")" -c Release \
    -o "$(caminho_nativo "$out/.clinica")" --nologo -v q
  ( cd "$out/.clinica" && zipar "$out/clinica.zip" . )
  rm -rf "$out/.clinica"

  # Os testes rodam no CI do repositório da API; aqui só empacota.
  log "Build: tutor-api (Java 21)"
  maven_pronto
  ( cd "$RAIZ/java-backend" && "${MVN[@]}" -B -ntp -DskipTests package )
  cp "$RAIZ"/java-backend/target/kura-backend-tutor-*.jar "$out/tutor.jar"

  # O Oryx do App Service instala o requirements.txt durante o deploy (SCM_DO_BUILD_DURING_DEPLOYMENT).
  log "Build: luna-ai (Python 3.12)"
  ( cd "$RAIZ/luna-ia/luna" && zipar "$out/luna.zip" src requirements.txt pyproject.toml \
      -x '*/__pycache__/*' '*.pyc' )

  info "artefatos em $out:"; ls -l "$out" | sed 's/^/    /'
}

# ═════════════════════════════════════════════════════════════════════════════
# FASE apps
# ═════════════════════════════════════════════════════════════════════════════
configurar_apps() {
  local ip clinica_url luna_url web_tutor cors
  ip="$(ip_vm)"
  clinica_url="https://$(host_app "$APP_CLINICA")"
  luna_url="https://$(host_app "$APP_LUNA")"
  web_tutor="https://$(host_swa "$SWA_TUTOR")"
  cors="$web_tutor,https://$(host_swa "$SWA_CLINICA")${EXTRA_CORS_ORIGINS:+,$EXTRA_CORS_ORIGINS}"

  # Segredos compostos (referência de Key Vault precisa ser o valor inteiro)
  kv_gravar dotnet-oracle-connection-string \
    "User Id=${ORACLE_APP_USER};Password=$(kv_ler oracle-app-password);Data Source=${ip}:1521/${ORACLE_SERVICE};Validate Connection=true;Connection Lifetime=180;Min Pool Size=0"
  kv_gravar tutor-mongodb-uri \
    "mongodb://kura_java:$(kv_ler mongo-java-password)@${ip}:27017/kura_docs?authSource=kura_docs&serverSelectionTimeoutMS=2000"
  # S4-NET-05: usuario kura_dotnet (role kura_dotnet_runtime: escreve laudos, le documentos_tutor).
  kv_gravar dotnet-mongodb-uri \
    "mongodb://kura_dotnet:$(kv_ler mongo-dotnet-password)@${ip}:27017/kura_docs?authSource=kura_docs&serverSelectionTimeoutMS=3000"

  # .NET — clinica-api
  az webapp config appsettings set -g "$RG" -n "$APP_CLINICA" -o none --settings \
    "WEBSITES_PORT=8080" "ASPNETCORE_URLS=http://+:8080" \
    "ASPNETCORE_ENVIRONMENT=$ASPNETCORE_ENVIRONMENT" \
    "ConnectionStrings__DefaultConnection=$(kvref dotnet-oracle-connection-string)" \
    "Jwt__Key=$(kvref dotnet-jwt-key)" "Jwt__Issuer=kura-api" "Jwt__Audience=kura-client" \
    "IoT__ApiKey=$(kvref iot-api-key)" \
    "Luna__ApiKey=$(kvref luna-api-key)" "Luna__InboundApiKey=$(kvref luna-inbound-api-key)" \
    "Luna__BaseUrl=$luna_url" \
    "Daily__ApiKey=$(kvref_opcional daily-api-key)" \
    "CORS_ALLOWED_ORIGINS=$cors" "Storage__BasePath=$STORAGE_BASE_PATH" \
    "Foto__UrlSecret=$(kvref foto-url-secret)" "Foto__UrlBase=$clinica_url" \
    "Convite__UrlBaseAppTutor=$web_tutor" \
    "Mongo__ConnectionString=$(kvref dotnet-mongodb-uri)" "Mongo__InitEnabled=true"

  # Java — tutor-api (o Flyway cria o schema Oracle ao subir)
  az webapp config appsettings set -g "$RG" -n "$APP_TUTOR" -o none --settings \
    "WEBSITES_PORT=8081" "SERVER_PORT=8081" "SPRING_PROFILES_ACTIVE=prod" "TZ=America/Sao_Paulo" \
    "DB_URL=jdbc:oracle:thin:@//${ip}:1521/${ORACLE_SERVICE}" "DB_USERNAME=$ORACLE_APP_USER" \
    "DB_PASSWORD=$(kvref oracle-app-password)" \
    "SPRING_DATASOURCE_HIKARI_KEEPALIVE_TIME=120000" "SPRING_DATASOURCE_HIKARI_MAX_LIFETIME=180000" \
    "JWT_SECRET=$(kvref java-jwt-secret)" "JWT_ACCESS_EXPIRATION_MINUTES=$JWT_ACCESS_EXPIRATION_MINUTES" \
    "CORS_ALLOWED_ORIGINS=$cors" \
    "FOTO_URL_SECRET=$(kvref foto-url-secret)" "FOTO_URL_BASE=$clinica_url" \
    "SPRING_DATA_MONGODB_URI=$(kvref tutor-mongodb-uri)" \
    "KURA_LOJA_MONGO_INIT_ENABLED=true" "KURA_LOJA_SEED_EXEMPLO_ENABLED=$LOJA_SEED_EXEMPLO"

  # Python — luna-ai (instância única: o APScheduler roda dentro do processo)
  az webapp config appsettings set -g "$RG" -n "$APP_LUNA" -o none --settings \
    "WEBSITES_PORT=8000" "LUNA_HTTP_PORT=8000" "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
    "ORACLE_DSN=${ip}:1521/${ORACLE_SERVICE}" "ORACLE_USER=$ORACLE_APP_USER" \
    "ORACLE_PASSWORD=$(kvref oracle-app-password)" \
    "KURA_API_BASE_URL=$clinica_url" "KURA_API_KEY=$(kvref luna-api-key)" "KURA_API_TIMEOUT=10" \
    "LUNA_INBOUND_API_KEY=$(kvref luna-inbound-api-key)" "CORS_ALLOWED_ORIGINS=$cors" \
    "TWILIO_SID=$(kvref_opcional twilio-sid)" "TWILIO_TOKEN=$(kvref_opcional twilio-token)" \
    "TWILIO_FROM_NUMBER=$TWILIO_FROM_NUMBER" "WEBHOOK_PUBLIC_URL=$luna_url/webhook/twilio/whatsapp" \
    "OPENAI_API_KEY=$(kvref_opcional openai-api-key)" \
    "YOLO_WEIGHTS_PATH=src/ai/models/yolov8n.pt" "BREED_CLASSIFIER_WEIGHTS_PATH=src/ai/models/breed_classifier.pth" \
    "LEMBRETE_CONFIRMACAO_HABILITADO=$LEMBRETE_CONFIRMACAO_HABILITADO" \
    "LEMBRETE_CONFIRMACAO_HORA=$LEMBRETE_CONFIRMACAO_HORA" \
    "LUNA_SCHEDULER_ENABLED=$LUNA_SCHEDULER_ENABLED" "LUNA_SCHEDULER_HORA=$LUNA_SCHEDULER_HORA" \
    "LOG_LEVEL=INFO"
  az webapp config set -g "$RG" -n "$APP_LUNA" -o none \
    --startup-file "python -m uvicorn src.web.app:app --host 0.0.0.0 --port 8000"
}

implantar() { # implantar <app> <zip|jar> <arquivo>
  [ -f "$3" ] || die "artefato não encontrado: $3 (gere-o antes: azure/deploy.sh build)"
  local app=$1 antes atual st i
  antes="$(az webapp log deployment list -g "$RG" -n "$app" --query '[0].id' -o tsv 2>/dev/null || true)"
  if az webapp deploy -g "$RG" -n "$app" --src-path "$(caminho_nativo "$3")" --type "$2" --restart true \
       --timeout 900000 -o none; then
    return 0
  fi
  # O gateway devolve 504 quando o Oryx demora (pip install na Luna), mas o deploy segue no servidor.
  info "az webapp deploy retornou erro (504 é comum enquanto o Oryx instala dependências); conferindo no servidor..."
  for ((i = 1; i <= 60; i++)); do
    atual="$(az webapp log deployment list -g "$RG" -n "$app" --query '[0].id' -o tsv 2>/dev/null || true)"
    st="$(az webapp log deployment list -g "$RG" -n "$app" --query '[0].status' -o tsv 2>/dev/null || true)"
    if [ -n "$atual" ] && [ "$atual" != "$antes" ]; then
      case "$st" in
        4) info "deploy de $app concluído no servidor"; return 0 ;;
        3) die "deploy de $app falhou no servidor (az webapp log deployment show -g $RG -n $app)" ;;
      esac
    elif [ "$i" -gt 8 ]; then
      die "o deploy de $app não foi registrado no servidor"
    fi
    sleep 15
  done
  die "o deploy de $app não concluiu a tempo"
}

fase_apps() {
  exigir_ferramentas
  log "Configurando app settings (Key Vault references)"; configurar_apps

  # O tutor vai primeiro: o Flyway cria o schema que o .NET e a Luna consomem.
  log "Deploy: tutor-api (Java) — Flyway aplica as migrations"
  implantar "$APP_TUTOR" jar "$ARTIFACTS_DIR/tutor.jar"
  aguardar_saude "https://$(host_app "$APP_TUTOR")/api/actuator/health" 60 15 \
    || { diagnostico "$APP_TUTOR"; die "tutor-api não ficou saudável"; }

  log "Deploy: clinica-api (.NET) e luna-ai (Python)"
  implantar "$APP_CLINICA" zip "$ARTIFACTS_DIR/clinica.zip"
  implantar "$APP_LUNA"    zip "$ARTIFACTS_DIR/luna.zip"
  aguardar_saude "https://$(host_app "$APP_CLINICA")/health" 40 15 \
    || { diagnostico "$APP_CLINICA"; die "clinica-api não ficou saudável"; }
  aguardar_saude "https://$(host_app "$APP_LUNA")/health" 40 15 \
    || { diagnostico "$APP_LUNA"; die "luna-ai não ficou saudável"; }
  fase_urls
}

# ═════════════════════════════════════════════════════════════════════════════
# FASE web
# ═════════════════════════════════════════════════════════════════════════════
construir_web() { # construir_web <submódulo> <pasta-de-saída> <url-da-api> <url-da-luna>
  local repo=$1 saida=$2 api=$3 luna=$4 src
  exigir_submodulos "$repo/package.json" "$repo/package-lock.json"
  # Cópia de trabalho fora do submódulo: o app.json é ajustado e o node_modules criado só nela.
  src="$(mktemp -d)"
  tar -C "$RAIZ" --exclude=.git --exclude=node_modules -cf - "$repo" | tar -C "$src" -xf -
  rm -rf "${WEB_DIR:?}/$saida"
  (
    cd "$src/$repo"
    # O app roda como SPA: um único index.html + fallback no Static Web Apps.
    node - <<'JS'
const fs = require('fs'); const j = JSON.parse(fs.readFileSync('app.json'));
if (j.expo.web && j.expo.web.output !== 'single') {
  console.log('app.json: web.output ' + j.expo.web.output + ' -> single');
  j.expo.web.output = 'single'; fs.writeFileSync('app.json', JSON.stringify(j, null, 2));
}
JS
    npm ci --no-audit --no-fund
    # As URLs são embutidas no JavaScript (EXPO_PUBLIC_*): mudou a URL, refaça o build.
    EXPO_PUBLIC_API_BASE_URL="$api" EXPO_PUBLIC_LUNA_BASE_URL="$luna" \
    EXPO_PUBLIC_USE_MOCKS=false CI=1 EXPO_NO_TELEMETRY=1 \
      npx expo export -p web --clear --output-dir "$(caminho_nativo "$WEB_DIR")/$saida"
  )
  rm -rf "$src"
}

garantir_swa_config() { # o arquivo deve ficar versionado em azure/; se faltar, gera o padrão
  local f="$RAIZ/azure/staticwebapp.config.json"
  [ -f "$f" ] && return 0
  info "azure/staticwebapp.config.json ausente: gerando o padrão (versione o arquivo no repositório)"
  cat > "$f" <<'JSON'
{
  "navigationFallback": {
    "rewrite": "/index.html",
    "exclude": ["/_expo/*", "/assets/*", "/*.ico", "/*.png", "/*.jpg", "/*.svg", "/*.json", "/*.ttf", "/*.js", "/*.css"]
  },
  "routes": [
    { "route": "/_expo/static/*", "headers": { "cache-control": "public, max-age=31536000, immutable" } },
    { "route": "/assets/*", "headers": { "cache-control": "public, max-age=31536000, immutable" } },
    { "route": "/index.html", "headers": { "cache-control": "no-cache" } }
  ],
  "globalHeaders": {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "SAMEORIGIN",
    "Referrer-Policy": "strict-origin-when-cross-origin"
  }
}
JSON
}

preparar_dist() {
  local d=$1
  garantir_swa_config
  [ -f "$d/index.html" ] || die "build web não encontrado em $d"
  # O export do Expo põe assets de pacotes em assets/node_modules; pastas com esse nome são
  # descartadas por várias hospedagens estáticas. Renomear + reescrever as referências é neutro
  # para qualquer host.
  if [ -d "$d/assets/node_modules" ]; then
    mv "$d/assets/node_modules" "$d/assets/nm"
    grep -rlI --include='*.js' --include='*.html' --include='*.json' '/assets/node_modules/' "$d" \
      | xargs -r sed -i 's#/assets/node_modules/#/assets/nm/#g'
  fi
  cp "$RAIZ/azure/staticwebapp.config.json" "$d/staticwebapp.config.json"
}

publicar_swa() { # publicar_swa <static-web-app> <pasta-do-build>
  local token
  preparar_dist "$2"
  # O token de deploy é lido na hora e passado por variável de ambiente (não fica em disco nem no ps).
  token="$(az staticwebapp secrets list -g "$RG" -n "$1" --query properties.apiKey -o tsv)"
  SWA_CLI_DEPLOYMENT_TOKEN="$token" \
    npx --yes "@azure/static-web-apps-cli@$SWA_CLI_VERSION" deploy "$(caminho_nativo "$2")" --env production
}

fase_web() {
  exigir_ferramentas
  exigir_comandos web node npm npx
  [ "$(node -p 'process.versions.node.split(".")[0]' | tr -d '\r')" -ge 20 ] || die "Node.js 20 ou superior necessário (recomendado: 22 LTS)"
  local clinica tutor luna
  clinica="https://$(host_app "$APP_CLINICA")"
  tutor="https://$(host_app "$APP_TUTOR")"
  luna="https://$(host_app "$APP_LUNA")"
  mkdir -p "$WEB_DIR"; WEB_DIR="$(cd "$WEB_DIR" && pwd)"

  log "Build web da clínica";  construir_web mobile-clinica-rn clinica "$clinica" "$luna"
  log "Build web do tutor";    construir_web mobile-tutor-rn   tutor   "$tutor"   "$luna"
  log "Publicando web da clínica"; publicar_swa "$SWA_CLINICA" "$WEB_DIR/clinica"
  log "Publicando web do tutor";   publicar_swa "$SWA_TUTOR"   "$WEB_DIR/tutor"
  fase_urls
}

# ═════════════════════════════════════════════════════════════════════════════
# FASE urls / destroy
# ═════════════════════════════════════════════════════════════════════════════
fase_urls() {
  echo "CLINICA_API_URL=https://$(host_app "$APP_CLINICA")"
  echo "TUTOR_API_URL=https://$(host_app "$APP_TUTOR")"
  echo "LUNA_URL=https://$(host_app "$APP_LUNA")"
  echo "CLINICA_WEB_URL=https://$(host_swa "$SWA_CLINICA")"
  echo "TUTOR_WEB_URL=https://$(host_swa "$SWA_TUTOR")"
}

fase_check() { # só leitura: aponta tudo o que faltaria antes de gastar 30 minutos no infra
  local nf=0
  chk() { # chk <descrição> <função/comando...>
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  PASSOU  %s\n' "$d"; else printf '  FALHOU  %s\n' "$d"; nf=$((nf + 1)); fi
  }
  tem_az() { (unset -f az 2>/dev/null; command -v "$AZBIN" >/dev/null 2>&1); }
  tem_git() { command -v git; }
  tem_curl() { command -v curl; }
  tem_dotnet10() { dotnet --list-sdks | grep -q '^10\.'; }
  tem_java21() { local v; v="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"; [ "${v:-0}" -ge 21 ]; }
  tem_node20() { [ "$(node -p 'process.versions.node.split(".")[0]' | tr -d '\r')" -ge 20 ]; }
  tem_npm() { command -v npm && command -v npx; }
  tem_login() { az account show; }
  tem_runtimes() { ( validar_runtimes ); }
  tem_arq() { local f; for f in "$@"; do [ -f "$RAIZ/$f" ] || return 1; done; }

  log "Verificando pré-requisitos"
  chk "git" tem_git
  chk "Azure CLI (az)" tem_az
  chk "curl" tem_curl
  chk "Python 3 (não o atalho da Microsoft Store)" achar_python
  chk "dotnet SDK 10" tem_dotnet10
  chk "JDK 21 ou superior" tem_java21
  chk "Node.js 20 ou superior" tem_node20
  chk "npm e npx" tem_npm
  chk "submódulos das 3 APIs baixados" tem_arq dotnet-backend/src/Kura.Api/Kura.Api.csproj java-backend/mvnw luna-ia/luna/requirements.txt
  chk "submódulos dos 2 apps baixados" tem_arq mobile-clinica-rn/package.json mobile-clinica-rn/package-lock.json mobile-tutor-rn/package.json mobile-tutor-rn/package-lock.json
  chk "sessão Azure ativa (az login)" tem_login
  if tem_login >/dev/null 2>&1; then
    info "subscription: $(az account show --query '[name, state]' -o tsv | tr '\t' ' ' | tr -d '\r')  |  região: $LOCATION  |  grupo: $RG"
    chk "runtimes $RUNTIME_DOTNET, $RUNTIME_JAVA e $RUNTIME_PYTHON disponíveis em $LOCATION" tem_runtimes
  fi
  curl -sI --max-time 15 https://repo.maven.apache.org/maven2/ >/dev/null 2>&1 \
    || info "aviso: sem acesso a repo.maven.apache.org (o build do tutor baixa o Maven e as dependências de lá)"
  [ -f "$RAIZ/azure/staticwebapp.config.json" ] || info "aviso: azure/staticwebapp.config.json ausente (o deploy gera o padrão; versione o arquivo)"
  if [ "$nf" -gt 0 ]; then
    printf '\n  %s pendência(s). Corrija e rode de novo: azure/deploy.sh check\n' "$nf" >&2
    return 1
  fi
  info "tudo pronto para o deploy"
}

fase_seed() { # dados de demonstração por HTTP real (scripts/seed-demo*.sh), com a stack já no ar
  exigir_ferramentas
  [ -d "$RAIZ/scripts" ] || die "pasta scripts/ não encontrada em $RAIZ"
  [ -n "${DEMO_SENHA:-}" ] || die "defina DEMO_SENHA (senha própria da clínica demo: as APIs do Azure são públicas). Ex.: DEMO_SENHA='...' azure/deploy.sh seed"
  [ "$DEMO_SENHA" != 'SenhaDemo123!' ] || die "DEMO_SENHA não pode ser a senha pública do repositório"
  [ -n "${DEMO_WHATSAPP:-}" ] || [ "${SEED_SEM_WHATSAPP:-}" = 1 ] || \
    die "defina DEMO_WHATSAPP=<DDI+DDD+número> (ou SEED_SEM_WHATSAPP=1 para dispensar o lembrete por WhatsApp)"

  local k
  # scripts em CRLF (cópia do Windows) quebram no bash
  find "$RAIZ/scripts" -name '*.sh' -exec sed -i 's/\r$//' {} +

  eval "$(fase_urls)"
  for k in "$CLINICA_API_URL/health" "$TUTOR_API_URL/api/actuator/health" "$LUNA_URL/health"; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$k" || true)" = 200 ] \
      || die "a API não respondeu 200 em $k: rode 'azure/deploy.sh apps' antes do seed"
  done
  LUNA_API_KEY="$(kv_ler luna-api-key)"
  [ -n "$LUNA_API_KEY" ] || die "segredo luna-api-key não encontrado no Key Vault $KV_NAME"

  for k in seed-demo.sh seed-demo-luna.sh seed-demo-fotos.sh seed-demo-contas.sh; do
    log "Seed: $k"
    # Os scripts de seed tratam caminhos do Windows sozinhos: rodam sem as variáveis MSYS deste script.
    # (segredos só pelo ambiente, nunca como argumento de comando)
    ( cd "$RAIZ" && export API="$CLINICA_API_URL" TUTOR_API="$TUTOR_API_URL" LUNA_URL LUNA_API_KEY \
        && env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL bash "scripts/$k" ) \
      || die "$k falhou. O seed-demo.sh não é idempotente: se a clínica demo já existe, ele falha de propósito"
  done
  info "seed concluído. Confira o login nos apps: $CLINICA_WEB_URL  $TUTOR_WEB_URL"
}

fase_destroy() {
  exigir_ferramentas
  [ "${CONFIRMA:-}" = sim ] || die "isto apaga TUDO em '$RG' (inclusive os dados do banco). Repita com CONFIRMA=sim"
  az group delete -n "$RG" --yes -o none
  az keyvault purge --name "$KV_NAME" --location "$LOCATION" -o none || true
  info "grupo $RG removido e cofre $KV_NAME purgado"
}

# ═════════════════════════════════════════════════════════════════════════════
# FASES db-packages / db-packages-remover (Sprint 4, frente Database — S4-DB-07)
#
# Instala (ou remove) os packages PL/SQL do schema KURA na VM do banco, por um único
# `az vm run-command`. O .sql vem do repo Mastering-Relational-Database (não é submódulo daqui).
# A decisão de sucesso NÃO usa o código de saída do run-command (não é confiável, ver criar_vm) e
# NÃO lê o log: o run-command devolve só os últimos 4.096 bytes (G0 B.8, achado B8-1), então um
# ORA- no começo de um log longo nunca chegaria até aqui. Quem lê o log inteiro é o script que
# roda DENTRO da VM; ele só imprime a sentinela, na última linha, se todas as condições passaram.
# ═════════════════════════════════════════════════════════════════════════════
DB_PACKAGES_SQL_DIR="${DB_PACKAGES_SQL_DIR:-$RAIZ/../Mastering-Relational-Database/src}"
DB_PACKAGES_ARQ_INSTALAR="2TDSPF_2026_Packages_Integrantes.sql"
DB_PACKAGES_ARQ_REMOVER="2TDSPF_2026_Packages_Remover.sql"
DB_PACKAGES_SENT_INSTALAR="KURA_DB_PACKAGES_OK"
DB_PACKAGES_SENT_REMOVER="KURA_DB_PACKAGES_REMOVIDO_OK"

validar_sql_packages() { # validar_sql_packages <arquivo> <instalar|remover> — recusa o .sql errado ANTES de qualquer chamada à Azure
  local f=$1 modo=$2
  [ -s "$f" ] || die "arquivo vazio ou ilegível: $f"
  # Contagem com grep -c (lê o arquivo inteiro): grep -q sai no 1º acerto e, num pipe com pipefail, o tr morre por
  # SIGPIPE e o `if` dá falso — flake medido com o arquivo real da S3 (acerto na linha 132 de milhares).
  local n_drop n_marca
  n_drop="$(tr -d '\r' < "$f" | grep -ciE 'drop[[:space:]]+(table|user)|truncate[[:space:]]+table' || true)"
  if [ "${n_drop:-0}" -gt 0 ]; then
    die "recusado: $f contém DROP TABLE/DROP USER/TRUNCATE. Parece o arquivo da Sprint 3 (CodigoSql), cujo BLOCO 1 derruba as 30 tabelas do schema KURA. Nada foi enviado à VM"
  fi
  if [ "$modo" = instalar ]; then
    n_marca="$(tr -d '\r' < "$f" | grep -ciE 'create or replace package body[[:space:]]+pkg_cobranca' || true)"
    [ "${n_marca:-0}" -gt 0 ] || die "recusado: $f não parece o instalador de packages (sem o body de PKG_COBRANCA). Nada foi enviado à VM"
  else
    n_marca="$(tr -d '\r' < "$f" | grep -c 'TRG_AUDITORIA_COBRANCA' || true)"
    [ "${n_marca:-0}" -gt 0 ] || die "recusado: $f não parece o removedor de packages (sem TRG_AUDITORIA_COBRANCA). Nada foi enviado à VM"
  fi
}

montar_script_db_vm() { # montar_script_db_vm <instalar|remover> <nome-do-arquivo> <sha256> <sql-gzip-base64> — script que roda DENTRO da VM
  # O run-command executa com /bin/sh (dash): reexecuta no bash, igual ao bootstrap.
  # shellcheck disable=SC2016  # literal de propósito: é o texto da 1ª linha do script da VM
  printf '%s\n' '[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"'
  printf 'PKG_MODO=%q\nKV_NAME=%q\nORACLE_SERVICE=%q\nORACLE_APP_USER=%q\nPKG_SQL_NAME=%q\nPKG_SQL_SHA256=%q\nPKG_SQL_B64=%q\n' \
    "$1" "$KV_NAME" "$ORACLE_SERVICE" "$ORACLE_APP_USER" "$2" "$3" "$4"
  cat <<'VM_SCRIPT'
set -euo pipefail
umask 077
# KURA_BASE é redirecionável só para os testes (azure/tests/db-packages.test.sh); na VM é sempre /opt/kura.
KURA_BASE="${KURA_BASE:-/opt/kura}"
CONT=kura_oracle_db

falhar() { echo "ERRO: $*" >&2; exit 1; }
case "$PKG_MODO" in
  instalar) SENT=KURA_DB_PACKAGES_OK; PREF=db-packages ;;
  remover)  SENT=KURA_DB_PACKAGES_REMOVIDO_OK; PREF=db-packages-remover ;;
  *) falhar "modo desconhecido: $PKG_MODO" ;;
esac
for c in base64 gzip sha256sum awk grep sed curl python3 docker; do
  command -v "$c" >/dev/null 2>&1 || falhar "ferramenta ausente na VM: $c"
done
[ "$(docker inspect -f '{{.State.Running}}' "$CONT" 2>/dev/null || true)" = true ] || falhar "o container $CONT não está rodando"

SQL_DIR="$KURA_BASE/sql"; LOG_DIR="$KURA_BASE/logs"
mkdir -p "$SQL_DIR" "$LOG_DIR"; chmod 700 "$SQL_DIR" "$LOG_DIR"
SQL_LOCAL="$SQL_DIR/$PKG_SQL_NAME"
LOG="$LOG_DIR/$PREF-$(date +%Y%m%d-%H%M%S).log"
limpar() { rm -f "$SQL_LOCAL"; docker exec "$CONT" rm -f "/tmp/$PKG_SQL_NAME" >/dev/null 2>&1 || true; }
trap limpar EXIT

# 1) SQL: decodifica, confere a integridade (sha256) e copia para o container
printf '%s' "$PKG_SQL_B64" | base64 -d | gzip -dc > "$SQL_LOCAL"
chmod 600 "$SQL_LOCAL"
sha_obtido="$(sha256sum "$SQL_LOCAL" | cut -d' ' -f1)"
[ "$sha_obtido" = "$PKG_SQL_SHA256" ] || falhar "sha256 do SQL decodificado diverge (esperado $PKG_SQL_SHA256, obtido $sha_obtido)"
docker cp "$SQL_LOCAL" "$CONT:/tmp/$PKG_SQL_NAME" >/dev/null

# 2) Senha do schema: Key Vault, com a identidade gerenciada da VM.
# Âncora (regra 11): mesmo padrão de montar_script_vm/segredo() em azure/deploy.sh:339-350 e de
# scripts/db-select.sh:88-92, conferido em 2026-10-29 no DevOps-Cloud@9f986f8
# (reproduz com: git show 9f986f8:azure/deploy.sh | sed -n '339,350p'; git show 9f986f8:scripts/db-select.sh | sed -n '88,92p').
segredo() {
  local t v
  for _ in $(seq 1 10); do
    if t="$(curl -sf -H 'Metadata:true' 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')" \
       && v="$(curl -sf -H "Authorization: Bearer $t" "https://${KV_NAME}.vault.azure.net/secrets/$1?api-version=7.4" \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')" \
       && [ -n "$v" ]; then
      printf '%s' "$v"; return 0
    fi
    sleep 3
  done
  return 1
}
senha="$(segredo oracle-app-password)" || falhar "senha do banco indisponível no Key Vault"
[ -n "$senha" ] || falhar "senha do banco vazia"

# 3) sqlplus nº 1: o arquivo inteiro. A senha vai SÓ por stdin (printf é builtin: não aparece em argv).
ec_sql=0
printf 'whenever sqlerror exit 1\nwhenever oserror exit 2\nconnect %s/%s@//localhost:1521/%s\n@/tmp/%s\nexit\n' \
  "$ORACLE_APP_USER" "$senha" "$ORACLE_SERVICE" "$PKG_SQL_NAME" \
  | docker exec -i "$CONT" sqlplus -s /nolog > "$LOG" 2>&1 || ec_sql=$?
chmod 600 "$LOG"

# 4) Validação DENTRO da VM, sobre o log inteiro (B8-1)
lf() { tr -d '\r' < "$LOG"; }
conta() { grep -c "$@" || true; }
ORA_FORA_DEMO="$(lf | awk '
  /^#+[ \t]+DEMO S4-DB-[0-9]+: INICIO[ \t]+#+[ \t]*$/ { d = 1; next }
  /^#+[ \t]+DEMO S4-DB-[0-9]+: FIM[ \t]+#+[ \t]*$/    { d = 0; next }
  d == 0 && /(ORA|SP2)-[0-9]+/ { n++ }
  END { print n + 0 }')"
DEMOS_ABERTAS="$(lf | conta -E '^#+[[:space:]]+DEMO S4-DB-[0-9]+: INICIO[[:space:]]+#+[[:space:]]*$')"
DEMOS_FECHADAS="$(lf | conta -E '^#+[[:space:]]+DEMO S4-DB-[0-9]+: FIM[[:space:]]+#+[[:space:]]*$')"
RESUMOS_OK="$(lf | conta -E '^RESUMO: [1-9][0-9]* OK, 0 FALHOU[[:space:]]*$')"
RESUMOS_TOTAL="$(lf | conta -E '^RESUMO: ')"
RESUMOS_FALHOU=$((RESUMOS_TOTAL - RESUMOS_OK))
SENHA_NO_LOG="$(conta -F -- "$senha" "$LOG")"

# 5) sqlplus nº 2: estado dos objetos (user_objects). Fecha em falha: sem a linha-resposta, a contagem é inválida.
if [ "$PKG_MODO" = instalar ]; then
  CONSULTA="select 'INVALIDO:' || object_type || ' ' || object_name || ' ' || status from user_objects where status <> 'VALID' order by object_type, object_name;
select 'PKGVALIDOS:' || count(*) from user_objects where status = 'VALID' and ((object_type in ('PACKAGE', 'PACKAGE BODY') and object_name in ('PKG_KURA_LOG', 'PKG_TRIAGEM', 'PKG_COBRANCA', 'PKG_AUDITORIA')) or (object_type = 'TRIGGER' and object_name = 'TRG_AUDITORIA_COBRANCA'));"
else
  CONSULTA="select 'RESTANTES:' || count(*) from user_objects where object_type in ('PACKAGE', 'PACKAGE BODY', 'TRIGGER') and object_name in ('PKG_KURA_LOG', 'PKG_TRIAGEM', 'PKG_COBRANCA', 'PKG_AUDITORIA', 'TRG_AUDITORIA_COBRANCA');"
fi
ec_q=0
SAIDA_Q="$(printf 'whenever sqlerror exit 1\nwhenever oserror exit 2\nconnect %s/%s@//localhost:1521/%s\nset heading off feedback off pagesize 0 linesize 300 trimspool on\n%s\nexit\n' \
  "$ORACLE_APP_USER" "$senha" "$ORACLE_SERVICE" "$CONSULTA" \
  | docker exec -i "$CONT" sqlplus -s /nolog 2>&1)" || ec_q=$?
SAIDA_Q="$(printf '%s\n' "$SAIDA_Q" | tr -d '\r')"
ORA_Q="$(printf '%s\n' "$SAIDA_Q" | conta -E '(ORA|SP2)-[0-9]+')"
SENHA_NA_CONSULTA="$(printf '%s\n' "$SAIDA_Q" | conta -F -- "$senha")"
INVALIDOS=-1; PACKAGES_VALIDOS=-1; RESTANTES=-1
if [ "$ec_q" = 0 ] && [ "$ORA_Q" = 0 ]; then
  if [ "$PKG_MODO" = instalar ]; then
    pv="$(printf '%s\n' "$SAIDA_Q" | sed -n 's/^PKGVALIDOS:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -n 1)"
    if [ -n "$pv" ]; then PACKAGES_VALIDOS="$pv"; INVALIDOS="$(printf '%s\n' "$SAIDA_Q" | conta -E '^INVALIDO:')"; fi
  else
    rs="$(printf '%s\n' "$SAIDA_Q" | sed -n 's/^RESTANTES:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -n 1)"
    if [ -n "$rs" ]; then RESTANTES="$rs"; fi
  fi
fi

# 6) Veredito: cada condição é uma linha; qualquer uma que falhe acrescenta o nome em MOTIVOS.
MOTIVOS=""
[ "$ec_sql" = 0 ]        || MOTIVOS="$MOTIVOS EXIT_SQLPLUS"
[ "$SENHA_NO_LOG" = 0 ]  || MOTIVOS="$MOTIVOS SENHA_NO_LOG"
[ "$SENHA_NA_CONSULTA" = 0 ] || MOTIVOS="$MOTIVOS SENHA_NA_CONSULTA"
if [ "$PKG_MODO" = instalar ]; then
  [ "$ORA_FORA_DEMO" = 0 ]      || MOTIVOS="$MOTIVOS ORA_FORA_DEMO"
  [ "$DEMOS_ABERTAS" = 2 ]      || MOTIVOS="$MOTIVOS DEMOS_ABERTAS"
  [ "$DEMOS_FECHADAS" = 2 ]     || MOTIVOS="$MOTIVOS DEMOS_FECHADAS"
  [ "$RESUMOS_OK" = 2 ]         || MOTIVOS="$MOTIVOS RESUMOS_OK"
  [ "$RESUMOS_FALHOU" = 0 ]     || MOTIVOS="$MOTIVOS RESUMOS_FALHOU"
  [ "$INVALIDOS" = 0 ]          || MOTIVOS="$MOTIVOS INVALIDOS"
  [ "$PACKAGES_VALIDOS" = 9 ]   || MOTIVOS="$MOTIVOS PACKAGES_VALIDOS"
else
  [ "$ORA_FORA_DEMO" = 0 ]      || MOTIVOS="$MOTIVOS ORA_NO_LOG"
  [ "$RESTANTES" = 0 ]          || MOTIVOS="$MOTIVOS RESTANTES"
fi

# 7) Resumo curto (o run-command devolve só os últimos 4.096 bytes). A senha nunca fica no log:
# se vazou, o log é apagado e nada dele é impresso.
echo "db-packages modo=$PKG_MODO"
echo "EXIT_SQLPLUS=$ec_sql"
echo "ORA_FORA_DEMO=$ORA_FORA_DEMO"
if [ "$PKG_MODO" = instalar ]; then
  echo "DEMOS_ABERTAS=$DEMOS_ABERTAS DEMOS_FECHADAS=$DEMOS_FECHADAS"
  echo "RESUMOS_OK=$RESUMOS_OK RESUMOS_FALHOU=$RESUMOS_FALHOU"
  echo "INVALIDOS=$INVALIDOS PACKAGES_VALIDOS=$PACKAGES_VALIDOS"
else
  echo "RESTANTES=$RESTANTES"
fi
echo "SENHA_NO_LOG=$SENHA_NO_LOG"
if [ "$SENHA_NO_LOG" != 0 ]; then
  rm -f "$LOG"
  echo "log apagado (continha a senha do schema)"
else
  echo "LOG=$LOG"
fi
if [ -n "$MOTIVOS" ]; then
  echo "FALHOU:$MOTIVOS"
  if [ "$SENHA_NO_LOG" = 0 ]; then
    {
      lf | grep -E '(ORA|SP2)-[0-9]+|FALHOU|^RESUMO' | grep -v 'KURA_DB_PACKAGES' | tail -n 15 | cut -c1-200 || true
      printf '%s\n' "$SAIDA_Q" | grep -E '^INVALIDO:|(ORA|SP2)-[0-9]+' | head -n 10 | cut -c1-200 || true
    } | head -c 2500
  fi
  exit 1
fi
echo "$SENT"
VM_SCRIPT
}

executar_db_packages() { # executar_db_packages <instalar|remover>
  local modo=$1 nome sent f sha b64 tmp saida c
  exigir_ferramentas
  for c in gzip base64 sha256sum; do command -v "$c" >/dev/null 2>&1 || die "'$c' é necessário (Git Bash e Linux já trazem)"; done
  if [ "$modo" = instalar ]; then nome="$DB_PACKAGES_ARQ_INSTALAR"; sent="$DB_PACKAGES_SENT_INSTALAR"
  else nome="$DB_PACKAGES_ARQ_REMOVER"; sent="$DB_PACKAGES_SENT_REMOVER"; fi
  f="$DB_PACKAGES_SQL_DIR/$nome"
  [ -f "$f" ] || die "não achei $f. O Mastering-Relational-Database não é submódulo daqui: clone-o ao lado deste repo
(git clone https://github.com/KURA-Clyvo/Mastering-Relational-Database ../Mastering-Relational-Database) ou aponte DB_PACKAGES_SQL_DIR=<pasta src>"
  validar_sql_packages "$f" "$modo"

  sha="$(tr -d '\r' < "$f" | sha256sum | cut -d' ' -f1)"
  info "SQL: $f"
  info "sha256 (sem CR): $sha"
  info "commit do arquivo: $(git -C "$(dirname "$f")" log -1 --format=%h -- "$nome" 2>/dev/null || true)"
  b64="$(tr -d '\r' < "$f" | gzip -9 | base64 -w0)"

  tmp="$(mktemp)"
  montar_script_db_vm "$modo" "$nome" "$sha" "$b64" | tr -d '\r' > "$tmp"
  if [ -n "${DB_PACKAGES_SALVAR_SCRIPT:-}" ]; then cp "$tmp" "$DB_PACKAGES_SALVAR_SCRIPT"; fi
  info "script enviado à VM: $(wc -c < "$tmp" | tr -d ' ') bytes (o limite de entrada do run-command é NÃO VERIFICADO)"

  # 1 chamada à Azure. O código de saída do run-command não é confiável: o sucesso é a sentinela, linha exata.
  saida="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
            --scripts "@$(caminho_nativo "$tmp")" --query 'value[0].message' -o tsv || true)"
  rm -f "$tmp"
  saida="$(printf '%s\n' "$saida" | tr -d '\r')"
  if grep -qx "$sent" <<<"$saida"; then
    printf '%s\n' "$saida" | grep -vx "$sent" | sed -e '/^Enable succeeded:/d' -e '/^\[stdout\]$/d' -e '/^\[stderr\]$/d' | sed 's/^/    /' || true
    info "$sent ($modo concluído; o log completo está na VM em /opt/kura/logs/)"
    return 0
  fi
  printf '%s\n' "$saida" | tail -n 40 >&2
  die "db-packages ($modo) não concluiu: sentinela $sent ausente na saída da VM"
}

fase_db_packages() {
  log "Instalando os packages PL/SQL (db-packages)"
  executar_db_packages instalar
}

fase_db_packages_remover() {
  [ "${CONFIRMA:-}" = sim ] || die "isto REMOVE a trigger e os 4 packages do schema $ORACLE_APP_USER: sem eles a API financeira da .NET (exportação JSON e relatório Oracle) devolve 503. Repita com CONFIRMA=sim"
  log "Removendo os packages PL/SQL (db-packages-remover)"
  executar_db_packages remover
}

case "${1:-}" in
  infra)   fase_infra ;;
  build)   fase_build ;;
  apps)    fase_apps ;;
  web)     fase_web ;;
  urls)    exigir_ferramentas; fase_urls ;;
  check)   fase_check || exit 1 ;;
  seed)    fase_seed ;;
  all)     fase_check || die "pré-requisitos pendentes (veja acima)"; fase_infra; fase_build; fase_apps; fase_web ;;
  destroy) fase_destroy ;;
  db-packages) fase_db_packages ;;
  db-packages-remover) fase_db_packages_remover ;;
  *)       awk 'NR > 1 && /^set -/ { exit } NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2 ;;
esac