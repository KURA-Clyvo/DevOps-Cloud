#!/usr/bin/env bash
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
#   all      infra, build, apps e web em sequência (deploy inicial completo)
#   destroy  apaga o grupo de recursos e purga o Key Vault (exige CONFIRMA=sim)
#
# Pré-requisitos: az logado (az login), python3, curl.
#   fase build: dotnet SDK 10, JDK 21 e zip      fase web: Node.js 22 LTS (npm/npx)
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

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
SUFFIX="${NAME_SUFFIX:-}"
if [ -z "$SUFFIX" ]; then
  SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
  [ -n "$SUB_ID" ] && SUFFIX="$(printf '%s' "$SUB_ID" | sha1sum | cut -c1-5)"
fi
KV_NAME="${KV_NAME:-kv-$PREFIX-${SUFFIX:-x0000}}"

# VM do banco (Oracle ≤ 2 GB de SGA+PGA; MongoDB limitado a 0,5 GB de cache; 8 GiB dá folga)
VM="vm-$PREFIX-db"
VM_SIZE="${VM_SIZE:-Standard_B2ms}"
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
RUNTIME_DOTNET="${RUNTIME_DOTNET:-DOTNETCORE:10.0}"
RUNTIME_JAVA="${RUNTIME_JAVA:-JAVA:21-java21}"
RUNTIME_PYTHON="${RUNTIME_PYTHON:-PYTHON:3.12}"

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
  local t
  for t in az python3 curl; do command -v "$t" >/dev/null 2>&1 || die "'$t' não encontrado no PATH"; done
  az account show >/dev/null 2>&1 || die "sem sessão Azure: rode 'az login' (ou use a service connection)"
}

gerar() { # gerar <alnum|hex|b64> <tamanho>
  python3 - "$1" "$2" <<'PY'
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
  az account get-access-token --query accessToken -o tsv | python3 -c '
import sys, json, base64
p = sys.stdin.read().strip().split(".")[1]
p += "=" * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))["oid"])'
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
  timeout 25 az webapp log tail -g "$RG" -n "$1" 2>&1 | tail -n 40 || true
}

# ═════════════════════════════════════════════════════════════════════════════
# FASE infra
# ═════════════════════════════════════════════════════════════════════════════
validar_runtimes() {
  local lista r; lista="$(az webapp list-runtimes --os-type linux -o tsv)"
  for r in "$RUNTIME_DOTNET" "$RUNTIME_JAVA" "$RUNTIME_PYTHON"; do
    grep -qix "$r" <<<"$lista" || die "runtime '$r' indisponível. Opções:
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
  segredo daily-api-key           DAILY_API_KEY           externo
  segredo twilio-sid              TWILIO_SID              externo
  segredo twilio-token            TWILIO_TOKEN            externo
  segredo openai-api-key          OPENAI_API_KEY          externo
}

montar_script_vm() { # imprime o script que roda DENTRO da VM (como root, via run-command)
  printf 'KV_NAME=%q\nORACLE_IMAGE=%q\nORACLE_SERVICE=%q\nORACLE_APP_USER=%q\n' \
    "$KV_NAME" "$ORACLE_IMAGE" "$ORACLE_SERVICE" "$ORACLE_APP_USER"
  printf 'MONGO_INIT_B64=%q\n' "$(base64 -w0 "$RAIZ/mongo/init/01-roles-usuarios.js")"
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
  if grep -Eq '^ +1$' <<<"$out"; then oracle_pronto=1; break; fi
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

criar_vm() {
  if ! az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
    # IP público só para SAÍDA (docker pull/apt): o NSG da sub-rede bloqueia toda entrada.
    az vm create -g "$RG" -n "$VM" -l "$LOCATION" --image "$VM_IMAGE" --size "$VM_SIZE" \
      --vnet-name "$VNET" --subnet "$SNET_DATA" --nsg "" --public-ip-sku Standard \
      --assign-identity '[system]' --os-disk-size-gb 64 --storage-sku StandardSSD_LRS \
      --admin-username azureuser --generate-ssh-keys -o none
  fi
  dar_papel "$(az vm show -g "$RG" -n "$VM" --query identity.principalId -o tsv)" ServicePrincipal \
    "Key Vault Secrets User" "$KV_ID"

  # Bootstrap por run-command. O código de saída do run-command não é confiável:
  # o sucesso é provado pela linha sentinela que o script imprime ao final.
  local tmp saida; tmp="$(mktemp)"
  montar_script_vm > "$tmp"
  saida="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
            --scripts "@$tmp" --query 'value[0].message' -o tsv || true)"
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
    --ftps-state Disabled --http20-enabled true \
    --generic-configurations "{\"healthCheckPath\": \"$saude\"}" -o none
  az webapp log config -g "$RG" -n "$app" --application-logging filesystem --level information \
    --docker-container-logging filesystem -o none
  # Sem credenciais básicas (FTP/SCM): o deploy usa a identidade do Entra ID
  local pol
  for pol in ftp scm; do
    az resource update -g "$RG" --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies \
      --parent "sites/$app" -n "$pol" --set properties.allow=false -o none
  done
}

fase_infra() {
  exigir_ferramentas
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

fase_build() {
  exigir_comandos build dotnet java zip
  local jdk out
  dotnet --list-sdks | grep -q '^10\.' || die "dotnet SDK 10 não encontrado ('dotnet --list-sdks')"
  jdk="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
  [ "${jdk:-0}" -ge 21 ] || die "JDK 21 ou superior necessário (encontrado: ${jdk:-desconhecido})"
  exigir_submodulos dotnet-backend/src/Kura.Api/Kura.Api.csproj java-backend/mvnw luna-ia/luna/requirements.txt

  mkdir -p "$ARTIFACTS_DIR"; out="$(cd "$ARTIFACTS_DIR" && pwd)"
  rm -f "$out/clinica.zip" "$out/tutor.jar" "$out/luna.zip"

  log "Build: clinica-api (.NET 10)"
  rm -rf "$out/.clinica"
  dotnet publish "$RAIZ/dotnet-backend/src/Kura.Api/Kura.Api.csproj" -c Release -o "$out/.clinica" --nologo -v q
  ( cd "$out/.clinica" && zip -qr "$out/clinica.zip" . )
  rm -rf "$out/.clinica"

  # Os testes rodam no CI do repositório da API; aqui só empacota.
  log "Build: tutor-api (Java 21)"
  ( cd "$RAIZ/java-backend" && bash ./mvnw -B -ntp -DskipTests package )
  cp "$RAIZ"/java-backend/target/kura-backend-tutor-*.jar "$out/tutor.jar"

  # O Oryx do App Service instala o requirements.txt durante o deploy (SCM_DO_BUILD_DURING_DEPLOYMENT).
  log "Build: luna-ai (Python 3.12)"
  ( cd "$RAIZ/luna-ia/luna" && zip -qr "$out/luna.zip" src requirements.txt pyproject.toml \
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
    "Convite__UrlBaseAppTutor=$web_tutor"

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
  az webapp deploy -g "$RG" -n "$1" --src-path "$3" --type "$2" --restart true --timeout 900000 -o none
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
    node -e "
      const fs=require('fs'); const j=JSON.parse(fs.readFileSync('app.json'));
      if (j.expo.web && j.expo.web.output !== 'single') {
        console.log('app.json: web.output ' + j.expo.web.output + ' -> single');
        j.expo.web.output='single'; fs.writeFileSync('app.json', JSON.stringify(j,null,2));
      }"
    npm ci --no-audit --no-fund
    # As URLs são embutidas no JavaScript (EXPO_PUBLIC_*): mudou a URL, refaça o build.
    EXPO_PUBLIC_API_BASE_URL="$api" EXPO_PUBLIC_LUNA_BASE_URL="$luna" \
    EXPO_PUBLIC_USE_MOCKS=false CI=1 EXPO_NO_TELEMETRY=1 \
      npx expo export -p web --clear --output-dir "$WEB_DIR/$saida"
  )
  rm -rf "$src"
}

preparar_dist() {
  local d=$1
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
    npx --yes "@azure/static-web-apps-cli@$SWA_CLI_VERSION" deploy "$2" --env production
}

fase_web() {
  exigir_ferramentas
  exigir_comandos web node npm npx
  [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ] || die "Node.js 20 ou superior necessário (recomendado: 22 LTS)"
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

fase_destroy() {
  exigir_ferramentas
  [ "${CONFIRMA:-}" = sim ] || die "isto apaga TUDO em '$RG' (inclusive os dados do banco). Repita com CONFIRMA=sim"
  az group delete -n "$RG" --yes -o none
  az keyvault purge --name "$KV_NAME" --location "$LOCATION" -o none || true
  info "grupo $RG removido e cofre $KV_NAME purgado"
}

case "${1:-}" in
  infra)   fase_infra ;;
  build)   fase_build ;;
  apps)    fase_apps ;;
  web)     fase_web ;;
  urls)    exigir_ferramentas; fase_urls ;;
  all)     fase_infra; fase_build; fase_apps; fase_web ;;
  destroy) fase_destroy ;;
  *)       awk 'NR > 1 && /^set -/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2 ;;
esac