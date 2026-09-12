#!/usr/bin/env bash
# =============================================================================
# KURA · azure/verify.sh — validação externa do ambiente em ACI
#
# Roda depois de deploy.sh. Testa tudo de FORA, pelo FQDN público de cada
# container group — nunca por localhost: é isso que prova que o ambiente
# responde para quem está do lado de fora, e não só "de dentro do container".
#
# Também confere se o Key Vault tem os segredos que os manifestos consomem.
# Confere PRESENÇA, nunca valor: nenhum segredo é impresso aqui.
#
# Uso: ./azure/verify.sh
# Saída: exit 0 se cofre + Oracle + as três APIs estão saudáveis; 1 caso
# contrário. Diferente do ambiente anterior em VM, aqui não há serviço
# "opcional": os quatro compõem o ecossistema em produção.
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env é opcional aqui: este script não lê segredo nenhum, só precisa dos nomes
# de recurso — que vêm do ambiente ou dos mesmos defaults do deploy.sh.
if [ -f "$ROOT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    . "$ROOT_DIR/.env"
    set +a
fi

KURA_PREFIX="${KURA_PREFIX:-kura-prod}"
KURA_PREFIX_ALNUM="$(printf '%s' "$KURA_PREFIX" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${KURA_PREFIX}-rg}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus2}"
KEYVAULT_NAME="${KEYVAULT_NAME:-${KURA_PREFIX}-kv}"
ACR_NAME="${ACR_NAME:-${KURA_PREFIX_ALNUM}acr}"

ACI_ORACLE_NAME="${KURA_PREFIX}-oracle-db"
ACI_DOTNET_NAME="${KURA_PREFIX}-clinica-api"
ACI_JAVA_NAME="${KURA_PREFIX}-tutor-api"
ACI_LUNA_NAME="${KURA_PREFIX}-luna-ai"

fqdn_aci() { printf '%s.%s.azurecontainer.io' "$1" "$AZURE_LOCATION"; }

aguardar_porta_tcp() {
    local host="$1" porta="$2" max="$3" espera="$4" i
    for i in $(seq 1 "$max"); do
        if (exec 3<>"/dev/tcp/${host}/${porta}") 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            exec 3<&- 2>/dev/null || true
            return 0
        fi
        echo "  ... tentativa $i/$max — $host:$porta ainda não responde (aguardando ${espera}s)"
        sleep "$espera"
    done
    return 1
}

aguardar_http_ok() {
    local url="$1" max="$2" espera="$3" i codigo
    for i in $(seq 1 "$max"); do
        codigo=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
        echo "  ... tentativa $i/$max — GET $url → HTTP $codigo"
        [ "$codigo" = "200" ] && return 0
        sleep "$espera"
    done
    return 1
}

FALHOU=false

# Cada API é verificada do mesmo jeito: existe o container group? o health
# responde 200 de fora?
checar_api() {
    local rotulo="$1" nome="$2" porta="$3" caminho="$4"
    local fqdn url
    if ! az container show --name "$nome" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
        echo "  ❌ Container group $nome não existe no RG $AZURE_RESOURCE_GROUP."
        FALHOU=true
        return
    fi
    fqdn="$(fqdn_aci "$nome")"
    url="http://${fqdn}:${porta}${caminho}"
    echo "  URL: $url"
    if aguardar_http_ok "$url" 10 15; then
        echo "  ✅ $rotulo saudável (validado de fora, não localhost)."
    else
        echo "  ❌ $rotulo não respondeu 200."
        echo "     Ver logs: az container logs --name $nome --resource-group $AZURE_RESOURCE_GROUP"
        FALHOU=true
    fi
}

echo "========================================================"
echo " KURA · verify.sh — validação externa do ambiente em ACI"
echo "========================================================"

# ─── [1/6] Key Vault ─────────────────────────────────────────────────────────
echo ""
echo "[1/6] Azure Key Vault ($KEYVAULT_NAME)..."
if ! az keyvault show --name "$KEYVAULT_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  ❌ Key Vault não encontrado. Rode ./azure/deploy.sh (passo [2/10])."
    FALHOU=true
else
    # Só os obrigatórios. Daily/Twilio/OpenAI são credenciais externas e
    # opcionais — a ausência delas degrada função, não derruba o ambiente, então
    # não entram como falha aqui.
    #
    # dockerhub-username/dockerhub-token ficam de fora das DUAS listas de
    # propósito: são credenciais de FERRAMENTA DE DEPLOY (`az acr import`), não
    # de runtime. Nenhum container as recebe, e a ausência delas não diz nada
    # sobre a saúde do ambiente — o que importa aqui é a imagem estar no ACR, o
    # que o passo [2/6] já verifica.
    for SEGREDO in oracle-sys-password oracle-app-password dotnet-jwt-key \
                   iot-api-key luna-api-key luna-inbound-api-key java-jwt-secret; do
        if az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$SEGREDO" -o none 2>/dev/null; then
            echo "  ✅ $SEGREDO presente."
        else
            echo "  ❌ $SEGREDO AUSENTE (ou sem permissão de leitura)."
            FALHOU=true
        fi
    done
    for SEGREDO in daily-api-key twilio-sid twilio-token openai-api-key; do
        if az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$SEGREDO" -o none 2>/dev/null; then
            echo "  ✅ $SEGREDO presente (externa)."
        else
            echo "  ~  $SEGREDO ausente — externa e opcional, função correspondente inativa."
        fi
    done
fi

# ─── [2/6] ACR — as imagens que os ACIs consomem existem mesmo? ──────────────
echo ""
echo "[2/6] Azure Container Registry ($ACR_NAME)..."
if ! az acr show --name "$ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  ❌ ACR não encontrado."
    FALHOU=true
else
    for REPO in kura/oracle-xe kura/clinica-api kura/tutor-api kura/luna-ai; do
        if az acr repository show --name "$ACR_NAME" --repository "$REPO" -o none 2>/dev/null; then
            TAGS=$(az acr repository show-tags --name "$ACR_NAME" --repository "$REPO" -o tsv 2>/dev/null | tr '\n' ' ')
            echo "  ✅ $REPO — tags: $TAGS"
        else
            echo "  ❌ repositório $REPO ausente no ACR."
            FALHOU=true
        fi
    done
fi

# ─── [3/6] Oracle — TCP na 1521 (não fala HTTP) ──────────────────────────────
echo ""
echo "[3/6] Oracle ($ACI_ORACLE_NAME)..."
if ! az container show --name "$ACI_ORACLE_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  ❌ Container group $ACI_ORACLE_NAME não existe."
    FALHOU=true
else
    ORACLE_FQDN="$(fqdn_aci "$ACI_ORACLE_NAME")"
    echo "  FQDN: $ORACLE_FQDN"
    if aguardar_porta_tcp "$ORACLE_FQDN" 1521 10 15; then
        echo "  ✅ Oracle aceitando conexões em $ORACLE_FQDN:1521."
    else
        echo "  ❌ Oracle não respondeu na porta 1521."
        FALHOU=true
    fi
fi

# ─── [4/6] .NET ──────────────────────────────────────────────────────────────
echo ""
echo "[4/6] clinica-api ($ACI_DOTNET_NAME)..."
checar_api "clinica-api" "$ACI_DOTNET_NAME" 8080 "/health"

# ─── [5/6] Java ──────────────────────────────────────────────────────────────
echo ""
echo "[5/6] tutor-api ($ACI_JAVA_NAME)..."
checar_api "tutor-api" "$ACI_JAVA_NAME" 8081 "/api/actuator/health"

# ─── [6/6] Luna ──────────────────────────────────────────────────────────────
echo ""
echo "[6/6] luna-ai ($ACI_LUNA_NAME)..."
checar_api "luna-ai" "$ACI_LUNA_NAME" 8000 "/health"

echo ""
echo "========================================================"
if [ "$FALHOU" = "true" ]; then
    echo " ❌ VERIFICAÇÃO FALHOU — ver os itens marcados acima."
    echo "========================================================"
    exit 1
fi
echo " ✅ VERIFICAÇÃO OK — segredos no Key Vault, imagens no ACR e os quatro"
echo "    serviços respondendo por IP/FQDN público, sem depender de localhost."
echo "========================================================"
