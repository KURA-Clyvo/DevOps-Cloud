#!/usr/bin/env bash
# =============================================================================
# KURA · azure/deploy.sh — implantação em ACR + ACI (ambiente de produção)
#
# Substitui o antigo script-azure.sh, que provisionava uma VM Ubuntu e rodava o
# docker-compose.yml dentro dela. O compose CONTINUA sendo o caminho de
# desenvolvimento local; o que mudou é só o destino de produção: cada serviço
# passa a ser um Azure Container Instance próprio, com as imagens vindas de um
# Azure Container Registry e os segredos de um Azure Key Vault.
#
# ─── ORDEM DE EXECUÇÃO ───────────────────────────────────────────────────────
#   1. git submodule update --init --recursive   (o build precisa do conteúdo
#                                                  dos três submódulos)
#   2. az login
#   3. ./azure/deploy.sh                          (este script)
#   4. ./azure/verify.sh                          (valida por FQDN público)
#   5. ./azure/backup-db.sh                       (antes de qualquer mexida no
#                                                  container group do Oracle)
#
# ─── MODOS ───────────────────────────────────────────────────────────────────
#   ./azure/deploy.sh                     implantação completa. Se o container
#                                         group do Oracle JÁ EXISTE, ele é
#                                         PRESERVADO (o banco não é tocado).
#   ./azure/deploy.sh --apps-only         redeploy só das três aplicações; nem
#                                         olha para o Oracle. É o modo usado
#                                         pelo workflow do GitHub Actions.
#   ./azure/deploy.sh --service luna-ai   redeploy de um serviço só
#                                         (clinica-api | tutor-api | luna-ai)
#   ./azure/deploy.sh --db-only           só a infraestrutura e o Oracle; não
#                                         mexe em nenhuma aplicação. É o modo
#                                         usado no fluxo de restauração, para
#                                         que o banco volte ANTES de o Flyway
#                                         (que roda no boot do tutor-api) achar
#                                         um schema vazio e recriá-lo do zero.
#   ./azure/deploy.sh --recreate-db       APAGA e recria o Oracle. Destrói todos
#                                         os dados: o armazenamento do ACI é
#                                         efêmero e não há volume para os
#                                         datafiles (ver aci-oracle-db.yaml).
#                                         Pede confirmação digitada.
#   ./azure/deploy.sh --skip-build        não builda/pusha imagem; usa a tag que
#                                         já está no ACR.
#   ./azure/deploy.sh --yes               não pergunta nada (para automação).
#
# ─── IDEMPOTÊNCIA ────────────────────────────────────────────────────────────
# Resource group, Key Vault, ACR, storage account e file shares só são criados
# se ainda não existirem. Os container groups das APLICAÇÕES são recriados do
# zero a cada execução (delete + create), porque o ACI não suporta update
# in-place de imagem/env var — e para elas isso é inofensivo, já que não
# guardam estado. O container group do ORACLE é a exceção deliberada: nunca é
# recriado sem --recreate-db explícito.
# =============================================================================
set -eu

# ─── UTF-8 no Python DESTE script ────────────────────────────────────────────
# Vale para o $PYTHON_BIN usado em substituir_placeholders(), que lê e escreve
# os manifestos.
#
# ATENÇÃO — isto NÃO protege o `az`. O launcher do Azure CLI no Windows é
# `python.exe -IBm azure.cli`, e o -I (modo isolado, implica -E) faz o Python do
# az ignorar toda variável PYTHON*, estas duas inclusive. O manifesto acaba lido
# com a codificação ANSI da máquina (cp1252 em português), e um byte indefinido
# nessa tabela derruba `az container create --file` com "'charmap' codec can't
# decode byte 0x8d". Quem resolve isso é a dobra para ASCII em
# substituir_placeholders() — ver o docstring de para_ascii() lá embaixo.
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GERADOS_DIR="$SCRIPT_DIR/.generated"

# ─── Argumentos ──────────────────────────────────────────────────────────────
MODO_ESCOPO="tudo"      # tudo | apps | db | servico
SERVICO_ALVO=""
RECRIAR_DB=false
PULAR_BUILD=false
PERGUNTAR=true

# Imprime o cabecalho deste arquivo ate a linha que o fecha, para que a ajuda
# nunca fique defasada em relacao aos modos documentados la em cima.
mostrar_ajuda() {
    awk 'NR>2 && /^# ={10,}/{exit} NR>2{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apps-only)   MODO_ESCOPO="apps" ;;
        --db-only)     MODO_ESCOPO="db" ;;
        --service)
            shift
            [ $# -gt 0 ] || { echo "❌ --service exige um nome."; exit 1; }
            MODO_ESCOPO="servico"
            SERVICO_ALVO="$1"
            ;;
        --recreate-db) RECRIAR_DB=true ;;
        --skip-build)  PULAR_BUILD=true ;;
        --yes)         PERGUNTAR=false ;;
        -h|--help)     mostrar_ajuda ;;
        *)
            echo "❌ Argumento desconhecido: $1"
            echo "   Use --help para ver os modos disponíveis."
            exit 1
            ;;
    esac
    shift
done

case "$MODO_ESCOPO:$SERVICO_ALVO" in
    servico:clinica-api|servico:tutor-api|servico:luna-ai) ;;
    servico:*)
        echo "❌ Serviço inválido: '$SERVICO_ALVO'."
        echo "   Válidos: clinica-api | tutor-api | luna-ai"
        exit 1
        ;;
esac

# ─── .env: OPCIONAL para este script ─────────────────────────────────────────
# Atenção à diferença de papel entre os dois caminhos deste repositório:
#   - docker-compose.yml (desenvolvimento local): o .env é OBRIGATÓRIO. O
#     compose usa `${VAR:?mensagem}` nas chaves de auth de propósito, e o
#     workflow de CI tem um guard (TASK-39) que falha se `docker compose config`
#     passar a resolver sem .env. Isso não mudou.
#   - este script (produção em ACI): o .env é OPCIONAL. Os segredos vivem no
#     Azure Key Vault. Se houver um .env aqui, ele serve para config não-secreta
#     e para SEMEAR o cofre na primeira execução.
if [ -f "$ROOT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    . "$ROOT_DIR/.env"
    set +a
    echo "✅ .env local carregado (opcional aqui — semente do cofre + config não-secreta)."
else
    echo "ℹ️  Sem .env local — usando apenas o ambiente e o Azure Key Vault."
fi

# ─── Nomenclatura ────────────────────────────────────────────────────────────
# KURA_PREFIX é a ÚNICA fonte da verdade dos nomes. ACR, Key Vault e storage
# account exigem nome GLOBALMENTE único no Azure inteiro, e o dnsNameLabel dos
# ACIs precisa ser único dentro da região — se algum colidir, trocar esta
# variável (no .env ou no ambiente) reposiciona todos de uma vez.
KURA_PREFIX="${KURA_PREFIX:-kura-prod}"
# Variante sem hífen, para os recursos que só aceitam alfanumérico.
KURA_PREFIX_ALNUM="$(printf '%s' "$KURA_PREFIX" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"

AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${KURA_PREFIX}-rg}"
AZURE_LOCATION="${AZURE_LOCATION:-eastus2}"
KEYVAULT_NAME="${KEYVAULT_NAME:-${KURA_PREFIX}-kv}"
ACR_NAME="${ACR_NAME:-${KURA_PREFIX_ALNUM}acr}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-${KURA_PREFIX_ALNUM}storage}"
STORAGE_SHARE_BACKUP="${STORAGE_SHARE_BACKUP:-kura-oracle-backup}"
STORAGE_SHARE_DOCUMENTOS="${STORAGE_SHARE_DOCUMENTOS:-kura-documentos}"
STORAGE_SHARE_QUOTA_GB="${STORAGE_SHARE_QUOTA_GB:-10}"

ACI_ORACLE_NAME="${KURA_PREFIX}-oracle-db"
ACI_DOTNET_NAME="${KURA_PREFIX}-clinica-api"
ACI_JAVA_NAME="${KURA_PREFIX}-tutor-api"
ACI_LUNA_NAME="${KURA_PREFIX}-luna-ai"

# ─── Config não-secreta das aplicações ───────────────────────────────────────
# ORACLE_APP_USER é o DONO DO SCHEMA: o Flyway cria todos os objetos dentro
# dele. O compose ainda traz RM562999 como default (herança da nomenclatura de
# checkpoint); aqui o default é KURA, alinhado ao resto dos nomes. A troca é
# segura porque o banco nasce vazio e o Flyway não qualifica objeto por schema —
# mas se alguma migration passar a fazer `CREATE ... KURA.TABELA` ou similar, a
# falha aparece já na primeira subida do Java, alto e claro, não silenciosa.
ORACLE_APP_USER="${ORACLE_APP_USER:-KURA}"
ORACLE_PDB_SERVICE="${ORACLE_PDB_SERVICE:-XEPDB1}"
ASPNETCORE_ENVIRONMENT="${ASPNETCORE_ENVIRONMENT:-Production}"
STORAGE_BASE_PATH="${STORAGE_BASE_PATH:-/data/kura/receituarios}"
JWT_ACCESS_EXPIRATION_MINUTES="${JWT_ACCESS_EXPIRATION_MINUTES:-15}"
CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost:8081,http://localhost:19006}"
TWILIO_FROM_NUMBER="${TWILIO_FROM_NUMBER:-+14155238886}"
WEBHOOK_PUBLIC_URL="${WEBHOOK_PUBLIC_URL:-https://kura-webhook-nao-configurado.invalid/webhook/twilio/whatsapp}"

# ─── Tabela de segredos gerenciados no Key Vault ─────────────────────────────
#   VARIAVEL_DE_AMBIENTE|nome-no-cofre|modo
# O nome no cofre é kebab-case porque o Key Vault não aceita '_'.
#
# Modos:
#   alnum   28 caracteres alfanuméricos. Usado nas senhas do Oracle DE PROPÓSITO:
#           elas entram numa connection string ADO.NET
#           ("User Id=...;Password=...;Data Source=...") e num JDBC URL, onde
#           ';' '/' '+' '=' de um base64 quebrariam o parsing.
#   b64:N   N bytes aleatórios em base64 — chave de assinatura JWT e API key
#           interna, que trafegam como valor opaco.
#   externo NUNCA é gerado. São credenciais emitidas por terceiros (Daily.co,
#           Twilio, OpenAI, Docker Hub): inventar um valor aleatório produziria
#           uma credencial inválida em vez de um erro claro. Se não vier do
#           ambiente nem do cofre, segue vazio — todas são opcionais e quem as
#           consome degrada de forma tratada quando faltam (as três de aplicação
#           conforme o docker-compose.yml; a do Docker Hub conforme o passo
#           [3/10], que cai para import anônimo).
#
# DOCKERHUB_USERNAME não é segredo — é público no perfil do Docker Hub. Está
# aqui mesmo assim porque o Docker Hub autentica com o PAR username+PAT, e o PAT
# só vale para o seu dono: separar os dois faria o cofre guardar meia credencial
# e produziria um 401 sem explicação quando o segundo deploy herdasse só o token.
SEGREDOS_GERENCIADOS="ORACLE_SYS_PASSWORD|oracle-sys-password|alnum
ORACLE_APP_PASSWORD|oracle-app-password|alnum
DOTNET_JWT_KEY|dotnet-jwt-key|b64:48
IOT_API_KEY|iot-api-key|b64:32
LUNA_API_KEY|luna-api-key|b64:32
LUNA_INBOUND_API_KEY|luna-inbound-api-key|b64:32
JAVA_JWT_SECRET|java-jwt-secret|b64:64
DAILY_API_KEY|daily-api-key|externo
TWILIO_SID|twilio-sid|externo
TWILIO_TOKEN|twilio-token|externo
OPENAI_API_KEY|openai-api-key|externo
DOCKERHUB_USERNAME|dockerhub-username|externo
DOCKERHUB_TOKEN|dockerhub-token|externo"

# ─── FQDNs pré-calculados ────────────────────────────────────────────────────
# O FQDN de um ACI é determinístico: <dnsNameLabel>.<região>.azurecontainer.io,
# e o dnsNameLabel é o nome do container group, definido logo acima. Calcular os
# quatro ANTES de criar qualquer um resolve a dependência circular entre o .NET
# e a Luna (cada um precisa do endereço do outro) sem exigir dois passos de
# criação nem um update posterior — que o ACI não suporta de qualquer forma.
fqdn_aci() { printf '%s.%s.azurecontainer.io' "$1" "$AZURE_LOCATION"; }
ORACLE_FQDN="$(fqdn_aci "$ACI_ORACLE_NAME")"
DOTNET_FQDN="$(fqdn_aci "$ACI_DOTNET_NAME")"
JAVA_FQDN="$(fqdn_aci "$ACI_JAVA_NAME")"
LUNA_FQDN="$(fqdn_aci "$ACI_LUNA_NAME")"

mkdir -p "$GERADOS_DIR"

# ─── Interpretador Python funcional ──────────────────────────────────────────
# Em Windows, `python3` às vezes existe no PATH apenas como o stub de App
# Execution Alias da Microsoft Store, que falha ao executar mesmo com
# `command -v` retornando sucesso. Por isso testa a EXECUÇÃO, não a presença.
resolver_python() {
    local candidato
    for candidato in python3 python; do
        if command -v "$candidato" >/dev/null 2>&1 && "$candidato" -c "print(1)" >/dev/null 2>&1; then
            echo "$candidato"
            return 0
        fi
    done
    echo "❌ ERRO: nenhum Python funcional encontrado (tentado: python3, python)." >&2
    exit 1
}
PYTHON_BIN="$(resolver_python)"

# ─── Substituição de placeholders __CHAVE__ ──────────────────────────────────
# Usa Python, não sed: os valores incluem connection string com ';' e '=' e
# senhas com '/', que quebram delimitador de sed com facilidade.
#
# Cada valor é passado em base64 e decodificado dentro do Python porque o Git
# Bash reescreve silenciosamente qualquer argumento que PAREÇA caminho POSIX
# (o default de STORAGE_BASE_PATH, "/data/kura/receituarios", viraria
# "C:/Program Files/Git/data/kura/receituarios"). `export MSYS_NO_PATHCONV=1`
# não serve aqui porque os caminhos do próprio template/saída estão no mesmo
# comando e PRECISAM ser convertidos para o Python nativo do Windows.
substituir_placeholders() {
    local template="$1" saida="$2"
    shift 2
    local args=() par chave valor valor_b64
    for par in "$@"; do
        chave="${par%%=*}"
        valor="${par#*=}"
        valor_b64=$(printf '%s' "$valor" | base64 -w 0)
        args+=("${chave}=${valor_b64}")
    done
    "$PYTHON_BIN" - "$template" "$saida" "${args[@]}" <<'PYEOF'
import base64
import re
import sys
import unicodedata
template_path, saida_path = sys.argv[1], sys.argv[2]
with open(template_path, "r", encoding="utf-8") as f:
    conteudo = f.read()


def para_ascii(texto):
    """Dobra o texto para ASCII puro.

    `az container create --file` é executado por `python.exe -IBm azure.cli`, e
    o -I (modo isolado, implica -E) faz o Python do az IGNORAR todas as
    variáveis PYTHON* — inclusive o PYTHONUTF8=1 exportado no topo deste
    script. O YAML acaba lido com a codificação ANSI da máquina, cp1252 em
    português. O cp1252 mapeia quase todo byte de UTF-8 para mojibake sem
    reclamar, e comentário com mojibake o YAML ignora — por isso os manifestos
    do Oracle e do Java sempre passaram. Mas cinco bytes são INDEFINIDOS no
    cp1252 (0x81 0x8D 0x8F 0x90 0x9D), e aí o az morre com
    "'charmap' codec can't decode byte 0x8d ... character maps to <undefined>".
    Bastou um "Í" (0xC3 0x8D) num comentário do template do .NET para derrubar
    o passo [8/10]; o template da Luna tinha dois 0x81 esperando no [9/10].

    Dobrar resolve na origem: sem byte >127, nenhuma codificação de leitura
    pode falhar. O NFKD separa o acento da letra e o encode descarta o que não
    tem equivalente ASCII (acentos soltos, ─, →, ✅), então "DETERMINÍSTICO"
    vira "DETERMINISTICO" e o comentário segue legível.
    """
    return unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode("ascii")


# Dobra o TEMPLATE, antes de injetar qualquer valor: assim comentário acentuado
# vira ASCII, mas senha, connection string e JWT entram depois e passam intactos
# — dobrar um segredo o corromperia em silêncio.
conteudo = para_ascii(conteudo)
for par in sys.argv[3:]:
    chave, _, valor_b64 = par.partition("=")
    conteudo = conteudo.replace("__" + chave + "__", base64.b64decode(valor_b64).decode("utf-8"))
# ─── secureValue vazio vira value: "" ────────────────────────────────────────
# As credenciais EXTERNAS (Twilio, OpenAI, Daily) são opcionais e ficam vazias
# no cofre quando ninguém as fornece. Substituir __TWILIO_SID__ por nada deixa
# a linha como `secureValue:` pelada, que o YAML lê como null — e o ACI recusa
# o container group inteiro com:
#   (InvalidEnvironmentVariable) ... One and only one property of 'value' and
#   'secureValue' can be specified in an environment variable.
# porque null não conta como "especificado".
#
# Omitir a variável NÃO serve: em luna-ia/src/config/settings.py, TWILIO_SID e
# TWILIO_TOKEN são declarados `str` SEM default, então o Pydantic Settings
# aborta o boot com ValidationError se a env var não existir. A Luna precisa da
# variável presente e vazia.
#
# Daí `value: ""`: string vazia é um valor especificado, satisfaz o ACI e o
# Pydantic, e mantém a degradação documentada (TwilioGateway é dependência de
# requisição, não de startup — sobe e só falha se alguém tentar enviar). Trocar
# secureValue por value aqui não vaza nada: o que se esconderia é vazio.
PADRAO_SECRETO_VAZIO = re.compile(r'^(\s*)secureValue:[ \t]*$', re.MULTILINE)
conteudo = PADRAO_SECRETO_VAZIO.sub(r'\1value: ""', conteudo)

# Placeholder real é __TUDO_MAIUSCULO__. Não confundir com a convenção .NET de
# env var com "__" no meio em case misto ("ConnectionStrings__DefaultConnection",
# "Jwt__Key"), que são valores legítimos do YAML final.
PADRAO = re.compile(r"__[A-Z][A-Z0-9_]*__")
# Linhas de comentário são ignoradas: o cabeçalho dos templates cita "__ALGO__"
# como exemplo genérico, o que bateria com o próprio padrão de detecção.
restantes = [l for l in conteudo.splitlines()
             if not l.strip().startswith("#") and PADRAO.search(l)]
with open(saida_path, "w", encoding="utf-8") as f:
    f.write(conteudo)
if restantes:
    print("⚠️  Placeholders não substituídos em " + saida_path + ":", file=sys.stderr)
    for l in restantes:
        print("    " + l, file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ─── Esperas ─────────────────────────────────────────────────────────────────
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

# ─── O escopo escolhido inclui este serviço? ─────────────────────────────────
# Usada tanto pelo build quanto pela criação dos container groups, para que
# `--service luna-ai` não builde as outras duas imagens (e, principalmente, para
# que `--service clinica-api` não builde a da Luna, de ~9,8 GB).
quer_servico() {
    case "$MODO_ESCOPO" in
        tudo|apps) return 0 ;;
        db)        return 1 ;;
        servico)   [ "$SERVICO_ALVO" = "$1" ] && return 0 || return 1 ;;
    esac
}

# ─── Recria um container group (delete-se-existir + create) ──────────────────
recriar_container_group() {
    local nome="$1" arquivo="$2"
    if az container show --name "$nome" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
        echo "  Container group existe — apagando para recriar (ACI não faz update in-place)."
        az container delete --name "$nome" --resource-group "$AZURE_RESOURCE_GROUP" --yes --output none
    fi
    az container create --resource-group "$AZURE_RESOURCE_GROUP" --file "$arquivo" --output none
}

# ─── Tag de imagem = SHA do commit fixado do submódulo ───────────────────────
# Lido do gitlink na árvore DESTE repositório (`git ls-tree`), não do HEAD de
# dentro do submódulo: funciona mesmo com o submódulo não inicializado, que é o
# caso quando se roda só `--skip-build` para reimplantar uma tag já no ACR.
tag_submodulo() {
    local caminho="$1" sha
    sha="$(git -C "$ROOT_DIR" ls-tree HEAD -- "$caminho" 2>/dev/null | awk '{print $3}')"
    if [ -z "$sha" ]; then
        echo "❌ ERRO: não foi possível ler o commit fixado do submódulo '$caminho'." >&2
        echo "   Este script precisa rodar dentro do clone git do DevOps-Cloud." >&2
        exit 1
    fi
    printf '%s' "${sha:0:12}"
}

DOTNET_IMAGE_TAG="$(tag_submodulo dotnet-backend)"
JAVA_IMAGE_TAG="$(tag_submodulo java-backend)"
LUNA_IMAGE_TAG="$(tag_submodulo luna-ia)"
# Tag da imagem do Oracle ESPELHADA do Docker Hub, sem modificação.
ORACLE_BASE_TAG="${ORACLE_BASE_TAG:-21-slim}"
# Minutos do SQLNET.EXPIRE_TIME (dead connection detection) da imagem derivada.
# Tem de ficar ABAIXO da janela de NAT (4 min no default da plataforma) para que
# a sonda do servidor também mantenha a tradução viva — ver comentário do
# azure/oracle-xe-dcd/Dockerfile.
ORACLE_DCD_MINUTOS="${ORACLE_DCD_MINUTOS:-2}"
# Tag que o container group REALMENTE roda: a base + DCD. O valor entra na tag
# porque mudá-lo tem de produzir imagem nova — tag igual faria o ACI reaproveitar
# a que ele já conhece e a mudança não chegaria ao ar.
ORACLE_IMAGE_TAG="${ORACLE_IMAGE_TAG:-${ORACLE_BASE_TAG}-dcd${ORACLE_DCD_MINUTOS}}"

# A derivada não pode ocupar a tag da base: sobrescreveria no ACR a única cópia
# espelhada do Docker Hub, e o próximo build passaria a empilhar DCD sobre uma
# imagem que já tem DCD, sem nunca mais tocar a imagem original.
if [ "$ORACLE_IMAGE_TAG" = "$ORACLE_BASE_TAG" ]; then
    echo "❌ ERRO: ORACLE_IMAGE_TAG ('$ORACLE_IMAGE_TAG') é igual a ORACLE_BASE_TAG."
    echo "   A imagem derivada (com SQLNET.EXPIRE_TIME) precisa de tag própria."
    echo "   Deixe ORACLE_IMAGE_TAG sem definir para usar o default"
    echo "   '${ORACLE_BASE_TAG}-dcd${ORACLE_DCD_MINUTOS}', ou escolha outra tag."
    exit 1
fi

echo ""
echo "========================================================"
echo " KURA · Deploy em ACR/ACI"
echo "========================================================"
echo " Resource Group : $AZURE_RESOURCE_GROUP"
echo " Região         : $AZURE_LOCATION"
echo " Key Vault      : $KEYVAULT_NAME"
echo " ACR            : $ACR_NAME"
echo " Storage        : $STORAGE_ACCOUNT_NAME"
echo " Escopo         : $MODO_ESCOPO${SERVICO_ALVO:+ ($SERVICO_ALVO)}"
echo ""
echo " Tags de imagem (SHA do commit fixado de cada submódulo):"
echo "   clinica-api : $DOTNET_IMAGE_TAG"
echo "   tutor-api   : $JAVA_IMAGE_TAG"
echo "   luna-ai     : $LUNA_IMAGE_TAG"
echo "   oracle-xe   : $ORACLE_IMAGE_TAG"
echo "                 (base $ORACLE_BASE_TAG espelhada do Docker Hub +"
echo "                  SQLNET.EXPIRE_TIME=$ORACLE_DCD_MINUTOS, derivada no ACR)"
echo "========================================================"

# ─── [0/10] Azure CLI autenticada ────────────────────────────────────────────
echo ""
echo "[0/10] Verificando login da Azure CLI..."
if ! az account show -o none 2>/dev/null; then
    echo "❌ ERRO: não autenticado. Rode 'az login' antes."
    exit 1
fi
echo "  ✅ Autenticado."

# ─── [1/10] Resource Group + providers ───────────────────────────────────────
echo ""
echo "[1/10] Criando/confirmando Resource Group: $AZURE_RESOURCE_GROUP..."
az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" --output none
echo "  ✅ Resource Group pronto."

for PROVIDER in Microsoft.ContainerInstance Microsoft.ContainerRegistry Microsoft.Storage Microsoft.KeyVault; do
    ESTADO=$(az provider show --namespace "$PROVIDER" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
    if [ "$ESTADO" != "Registered" ]; then
        echo "  Registrando provider $PROVIDER (estado atual: $ESTADO)..."
        az provider register --namespace "$PROVIDER" -o none
    fi
done

# ─── [2/10] Azure Key Vault ──────────────────────────────────────────────────
echo ""
echo "[2/10] Criando/confirmando Azure Key Vault: $KEYVAULT_NAME..."

# Soft-delete em Key Vault é obrigatório e não desligável: apagar o resource
# group NÃO libera o nome — o cofre fica recuperável por 90 dias e um
# `az keyvault create` com o mesmo nome falha com (VaultAlreadyExists). Por isso
# a ordem é: existe? → existe apagado? → cria.
if az keyvault show --name "$KEYVAULT_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  Key Vault já existe, reaproveitando."
elif [ -n "$(az keyvault list-deleted --query "[?name=='$KEYVAULT_NAME'].name" -o tsv 2>/dev/null || true)" ]; then
    echo "  Key Vault em estado SOFT-DELETED — recuperando (os segredos voltam junto)..."
    az keyvault recover --name "$KEYVAULT_NAME" --location "$AZURE_LOCATION" --output none
    echo "  ✅ Key Vault recuperado."
else
    # --enable-rbac-authorization false mantém o modelo de access policy, no qual
    # o próprio `az keyvault create` já concede ao criador acesso total a
    # segredos. Evita depender de criar role assignment, que exige Owner ou User
    # Access Administrator e nem sempre está disponível.
    az keyvault create \
        --name "$KEYVAULT_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION" \
        --sku standard \
        --enable-rbac-authorization false \
        --tags projeto=kura ambiente=producao \
        --output none
    echo "  ✅ Key Vault criado."
fi

# Cofre pré-existente (ou criado por policy) em modo RBAC não tem access policy
# automática — a permissão precisa vir de uma role. Best-effort: se falhar,
# avisa, porque o erro real aparece logo abaixo com mensagem melhor.
KV_RBAC=$(az keyvault show --name "$KEYVAULT_NAME" --query "properties.enableRbacAuthorization" -o tsv 2>/dev/null || echo "false")
if [ "$KV_RBAC" = "true" ]; then
    echo "  Cofre em modo RBAC — garantindo 'Key Vault Secrets Officer' para o usuário logado..."
    KV_ID=$(az keyvault show --name "$KEYVAULT_NAME" --query id -o tsv)
    KV_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
    if [ -n "$KV_OBJECT_ID" ]; then
        az role assignment create --role "Key Vault Secrets Officer" \
            --assignee-object-id "$KV_OBJECT_ID" --assignee-principal-type User \
            --scope "$KV_ID" --output none 2>/dev/null \
            || echo "  ℹ️  Role já existente ou sem permissão para criá-la — seguindo."
    fi
fi

echo "  Aguardando o cofre aceitar operações de segredo..."
KV_PRONTO=false
for TENTATIVA in $(seq 1 12); do
    if az keyvault secret list --vault-name "$KEYVAULT_NAME" --maxresults 1 -o none 2>/dev/null; then
        KV_PRONTO=true
        break
    fi
    echo "  ... tentativa $TENTATIVA/12 (aguardando 5s)"
    sleep 5
done
if [ "$KV_PRONTO" != "true" ]; then
    echo "❌ ERRO: o cofre $KEYVAULT_NAME não aceitou 'az keyvault secret list'."
    echo "   Causa mais comum: o usuário logado não tem permissão de DADOS sobre o cofre."
    echo "   Confira: az keyvault show --name $KEYVAULT_NAME --query properties.accessPolicies"
    exit 1
fi

# Geração em Python (stdlib `secrets`, criptograficamente seguro) em vez de
# `openssl rand`: o script já depende de Python, então não se acrescenta uma
# dependência só para isso.
gerar_segredo() {
    "$PYTHON_BIN" - "$1" <<'PYSEGREDO'
import base64
import os
import secrets
import string
import sys
modo = sys.argv[1]
if modo == "alnum":
    print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(28)))
else:
    print(base64.b64encode(os.urandom(int(modo.split(":", 1)[1]))).decode("ascii"))
PYSEGREDO
}

# Devolve string vazia (sem falhar) quando o segredo ainda não existe.
ler_segredo_kv() {
    az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$1" --query value -o tsv 2>/dev/null || true
}

garantir_segredo_kv() {
    local var="$1" nome_kv="$2" modo="$3"
    local valor_local="${!var:-}" valor_kv
    valor_kv="$(ler_segredo_kv "$nome_kv")"
    if [ -n "$valor_local" ] && [ "$valor_local" != "$valor_kv" ]; then
        az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$nome_kv" --value "$valor_local" --output none
        echo "  ↑ $nome_kv — semeado/atualizado a partir de \$$var."
    elif [ -n "$valor_local" ]; then
        echo "  = $nome_kv — já no cofre com o mesmo valor (sem versão nova)."
    elif [ -n "$valor_kv" ]; then
        echo "  ✓ $nome_kv — já no cofre, reaproveitado."
    elif [ "$modo" = "externo" ]; then
        echo "  ~ $nome_kv — credencial externa ausente; segue vazia (serviço degrada de forma tratada)."
    else
        valor_local="$(gerar_segredo "$modo")"
        az keyvault secret set --vault-name "$KEYVAULT_NAME" --name "$nome_kv" --value "$valor_local" --output none
        echo "  + $nome_kv — não existia; gerado agora e guardado no cofre."
    fi
}

echo ""
echo "  Sincronizando segredos (ambiente/.env → Key Vault):"
while IFS='|' read -r SEG_VAR SEG_NOME SEG_MODO; do
    [ -n "${SEG_VAR:-}" ] || continue
    garantir_segredo_kv "$SEG_VAR" "$SEG_NOME" "$SEG_MODO"
done <<EOF
$SEGREDOS_GERENCIADOS
EOF

# Releitura: mesmo o segredo que veio do .env é relido do cofre, de propósito —
# assim o valor que entra no manifesto é comprovadamente o que está guardado, e
# não uma cópia local que poderia estar defasada.
echo ""
echo "  Lendo os segredos de volta do cofre (az keyvault secret show):"
while IFS='|' read -r SEG_VAR SEG_NOME SEG_MODO; do
    [ -n "${SEG_VAR:-}" ] || continue
    SEG_VALOR="$(ler_segredo_kv "$SEG_NOME")"
    if [ -z "$SEG_VALOR" ] && [ "$SEG_MODO" != "externo" ]; then
        echo "❌ ERRO: segredo obrigatório '$SEG_NOME' não pôde ser lido do cofre."
        exit 1
    fi
    # printf -v em vez de eval: atribuição indireta sem reinterpretar o valor
    # (uma senha com aspas ou '$' seria reavaliada por eval).
    printf -v "$SEG_VAR" '%s' "$SEG_VALOR"
    echo "  ← \$$SEG_VAR ← $KEYVAULT_NAME/$SEG_NOME"
done <<EOF
$SEGREDOS_GERENCIADOS
EOF
unset SEG_VALOR
echo "  ✅ Segredos em memória, vindos do Key Vault."

# ─── [3/10] ACR ──────────────────────────────────────────────────────────────
echo ""
echo "[3/10] Criando/confirmando Azure Container Registry: $ACR_NAME..."
if az acr show --name "$ACR_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  ACR já existe, reaproveitando."
else
    # SKU Standard, não Basic: a imagem da Luna tem ~9,8 GB e o Basic inclui só
    # 10 GB de armazenamento no total — não caberia junto com as outras três.
    az acr create --resource-group "$AZURE_RESOURCE_GROUP" --name "$ACR_NAME" \
        --sku Standard --output none
    echo "  ✅ ACR criado (SKU Standard)."
fi
az acr update --name "$ACR_NAME" --admin-enabled true --output none
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)
echo "  ✅ ACR pronto: $ACR_LOGIN_SERVER"

# ─── Espelhamento da imagem do Oracle XE ─────────────────────────────────────
# `az acr import` copia SERVER-SIDE (registry → registry), sem baixar os ~2,6 GB
# para a máquina que roda o deploy. Espelhar em vez de deixar o ACI puxar do
# Docker Hub evita o rate limit de pull anônimo, que é aplicado por IP de origem
# — e os IPs de saída do ACI são compartilhados entre assinaturas, então o limite
# pode ser atingido por tráfego de terceiros. Num container group com
# `restartPolicy: Always` e sem volume para os datafiles, isso transformaria um
# limite de terceiro em banco que não volta do restart.
#
# AUTENTICAÇÃO NA ORIGEM: o mesmo compartilhamento de IPs vale para o serviço de
# import do ACR, que sai por IPs do Azure usados por muita gente — na prática o
# import anônimo falha com 401/TOOMANYREQUESTS mesmo quando o `docker pull` da
# mesma imagem funciona da estação de trabalho. Com DOCKERHUB_USERNAME+
# DOCKERHUB_TOKEN o import passa a contar contra a quota da conta (100 pulls/h)
# em vez da quota anônima compartilhada. PAT com escopo "Public Repo Read-only"
# basta: a origem é uma imagem pública.
#
# Só roda quando o Oracle está no escopo — `--apps-only` e `--service X` não têm
# o que fazer com esta imagem, e é por isso que o workflow de rollout (que só
# usa esses dois escopos) nunca precisa de credencial do Docker Hub.
if [ "$MODO_ESCOPO" != "tudo" ] && [ "$MODO_ESCOPO" != "db" ]; then
    echo "  Escopo '$MODO_ESCOPO' — imagem do Oracle não é espelhada."
elif az acr repository show --name "$ACR_NAME" --image "kura/oracle-xe:$ORACLE_BASE_TAG" -o none 2>/dev/null; then
    echo "  Imagem base do Oracle já está no ACR, pulando o import."
else
    # Par indivisível: o PAT só autentica com o username do seu dono. Meio par é
    # sempre erro de configuração, e falhar aqui é muito mais barato que deixar
    # o `az acr import` responder 401 sem dizer o porquê.
    if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -z "${DOCKERHUB_TOKEN:-}" ]; then
        echo "❌ ERRO: DOCKERHUB_USERNAME definido sem DOCKERHUB_TOKEN."
        echo "   O Docker Hub autentica com o par username+PAT — o token pertence ao usuário."
        exit 1
    fi
    if [ -z "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
        echo "❌ ERRO: DOCKERHUB_TOKEN definido sem DOCKERHUB_USERNAME."
        echo "   Informe o usuário DONO do token (o username não é segredo)."
        exit 1
    fi

    IMPORT_AUTH=()
    if [ -n "${DOCKERHUB_USERNAME:-}" ]; then
        IMPORT_AUTH=(--username "$DOCKERHUB_USERNAME" --password "$DOCKERHUB_TOKEN")
        echo "  Espelhando gvenzl/oracle-xe:$ORACLE_BASE_TAG no ACR — autenticado como '$DOCKERHUB_USERNAME'..."
    else
        echo "  Espelhando gvenzl/oracle-xe:$ORACLE_BASE_TAG no ACR — ANÔNIMO (sem credencial do Docker Hub)..."
    fi

    # `if !` e não chamada direta: com `set -e` uma falha aqui abortaria o script
    # com o stderr cru do az, e a causa (quota anônima) não está nessa mensagem.
    if ! az acr import --name "$ACR_NAME" \
        --source "docker.io/gvenzl/oracle-xe:$ORACLE_BASE_TAG" \
        --image "kura/oracle-xe:$ORACLE_BASE_TAG" \
        "${IMPORT_AUTH[@]}" \
        --output none
    then
        echo ""
        echo "❌ ERRO: não foi possível espelhar gvenzl/oracle-xe:$ORACLE_BASE_TAG."
        if [ -z "${DOCKERHUB_USERNAME:-}" ]; then
            echo "   O import foi anônimo. A causa mais provável é a quota de pull anônimo"
            echo "   do Docker Hub, consumida pelos IPs compartilhados do serviço de import"
            echo "   do ACR — não por você. Duas saídas:"
            echo ""
            echo "   1) Autenticar a ORIGEM (recomendado). Crie um PAT em"
            echo "      hub.docker.com → Account Settings → Personal access tokens,"
            echo "      escopo 'Public Repo Read-only', e preencha no .env:"
            echo "        DOCKERHUB_USERNAME=<o dono do token>"
            echo "        DOCKERHUB_TOKEN=<o PAT>"
            echo "      É necessário UMA vez por ACR: o import acima é pulado depois."
            echo ""
            echo "   2) Sem conta no Docker Hub — espelhe pela sua máquina:"
            echo "        docker pull gvenzl/oracle-xe:$ORACLE_BASE_TAG"
            echo "        az acr login --name $ACR_NAME"
            echo "        docker tag gvenzl/oracle-xe:$ORACLE_BASE_TAG \\"
            echo "          $ACR_LOGIN_SERVER/kura/oracle-xe:$ORACLE_BASE_TAG"
            echo "        docker push $ACR_LOGIN_SERVER/kura/oracle-xe:$ORACLE_BASE_TAG"
            echo "      ~2,6 GB de download + upload, uma vez. Depois rode o deploy de novo."
        else
            echo "   O import foi autenticado como '$DOCKERHUB_USERNAME'. Verifique se o PAT"
            echo "   pertence a esse usuário, não está expirado/revogado, e tem ao menos o"
            echo "   escopo 'Public Repo Read-only'."
        fi
        exit 1
    fi
    echo "  ✅ Imagem base do Oracle espelhada."
fi


# ─── Imagem derivada do Oracle: dead connection detection ────────────────────
# A base espelhada acima não tem `SQLNET.EXPIRE_TIME`, e sem ele o servidor nunca
# descobre que um cliente desapareceu: como o tráfego de banco passa por NAT (não
# há VNet comum entre container groups), toda conexão que morre por ociosidade
# deixa uma SESSÃO ÓRFÃ no XE, que nada recolhe antes de um restart. A camada
# derivada acrescenta essa única linha. O porquê completo — e o motivo de ser
# imagem derivada, e não volume nem override de `command` — está no cabeçalho de
# azure/oracle-xe-dcd/Dockerfile.
#
# `az acr build` roda DENTRO do ACR: o contexto enviado é só o Dockerfile, a base
# é puxada registry-local e o resultado nasce lá — nada dos ~2,6 GB passa pela
# máquina de quem faz o deploy, nem exige Docker instalado. Depende de ACR com
# suporte a Tasks; o criado aqui é Standard.
#
# Mesmo escopo do import: `--apps-only` e `--service X` não têm o que fazer com a
# imagem do banco. E `--skip-build` NÃO cobre este build — aquela flag existe para
# pular o build/push das imagens de aplicação, que é o passo caro (a luna-ai tem
# ~9,8 GB); este é uma camada de poucos KB construída server-side, e pulá-lo
# deixaria o passo [6/10] apontando para uma tag que não existe no registry.
if [ "$MODO_ESCOPO" != "tudo" ] && [ "$MODO_ESCOPO" != "db" ]; then
    echo "  Escopo '$MODO_ESCOPO' — imagem derivada do Oracle não é construída."
elif az acr repository show --name "$ACR_NAME" --image "kura/oracle-xe:$ORACLE_IMAGE_TAG" -o none 2>/dev/null; then
    echo "  Imagem derivada kura/oracle-xe:$ORACLE_IMAGE_TAG já está no ACR, pulando o build."
else
    echo "  Derivando kura/oracle-xe:$ORACLE_IMAGE_TAG (SQLNET.EXPIRE_TIME=$ORACLE_DCD_MINUTOS) no ACR..."
    if ! az acr build --registry "$ACR_NAME" \
        --image "kura/oracle-xe:$ORACLE_IMAGE_TAG" \
        --file "$SCRIPT_DIR/oracle-xe-dcd/Dockerfile" \
        --build-arg "IMAGEM_BASE=$ACR_LOGIN_SERVER/kura/oracle-xe:$ORACLE_BASE_TAG" \
        --build-arg "DCD_MINUTOS=$ORACLE_DCD_MINUTOS" \
        "$SCRIPT_DIR/oracle-xe-dcd" \
        --output none
    then
        echo ""
        echo "❌ ERRO: o build da imagem derivada do Oracle falhou."
        echo "   O log da task do ACR saiu acima — quando o build chega ao fim, ele"
        echo "   imprime o sqlnet.ora resultante."
        echo ""
        echo "   Causas prováveis, em ordem:"
        echo "   1) ACR sem suporte a Tasks (SKU). Confira:"
        echo "        az acr show --name $ACR_NAME --query sku.name -o tsv"
        echo "   2) A imagem base mudou e o diretório de rede do ORACLE_HOME deixou"
        echo "      de ser gravável pelo usuário da imagem — o RUN falha explícito."
        echo "   3) Base ausente no ACR: kura/oracle-xe:$ORACLE_BASE_TAG."
        echo ""
        echo "   Saída de emergência, para subir o banco SEM DCD (as sessões órfãs"
        echo "   voltam a acumular, mas o ambiente sobe):"
        echo "     ORACLE_IMAGE_TAG=$ORACLE_BASE_TAG ./azure/deploy.sh --db-only"
        exit 1
    fi
    echo "  ✅ Imagem derivada pronta: kura/oracle-xe:$ORACLE_IMAGE_TAG"
fi

# ─── [4/10] Build + push das três imagens de aplicação ───────────────────────
echo ""
if [ "$PULAR_BUILD" = "true" ]; then
    echo "[4/10] --skip-build — usando as tags já presentes no ACR."
else
    echo "[4/10] Build e push das imagens de aplicação..."

    # Tabela: serviço|contexto de build|repositório no ACR|tag
    # O contexto sai do submódulo, que está fixado num commit conhecido — é isso
    # que dá sentido à tag por SHA. O antigo script-azure.sh buildava dentro da
    # VM a partir de um `git clone` feito lá; aqui a árvore tem procedência
    # verificável.
    IMAGENS="clinica-api|dotnet-backend|kura/clinica-api|$DOTNET_IMAGE_TAG
tutor-api|java-backend|kura/tutor-api|$JAVA_IMAGE_TAG
luna-ai|luna-ia/luna|kura/luna-ai|$LUNA_IMAGE_TAG"

    # Só builda o que o escopo pede. Sem isto, `--service clinica-api` arrastaria
    # o build da Luna (~9,8 GB) junto — o que, além de lento, não cabe num runner
    # hospedado do GitHub Actions.
    ALGUM_BUILD=false
    while IFS='|' read -r SVC CTX _REPO _TAG; do
        [ -n "${SVC:-}" ] || continue
        quer_servico "$SVC" || continue
        ALGUM_BUILD=true
        if [ ! -f "$ROOT_DIR/$CTX/Dockerfile" ]; then
            echo "❌ ERRO: $CTX/Dockerfile não encontrado."
            echo "   Os submódulos não estão inicializados. Rode:"
            echo "     git submodule update --init --recursive"
            echo "   (ou use --skip-build para reimplantar uma tag já no ACR)."
            exit 1
        fi
    done <<EOF
$IMAGENS
EOF

    if [ "$ALGUM_BUILD" = "false" ]; then
        echo "  Nenhuma imagem no escopo '$MODO_ESCOPO' — nada a buildar."
    else
        # Login aqui só para falhar cedo se a credencial estiver quebrada — o
        # push usa um token NOVO, pedido logo antes de cada envio. Ver abaixo.
        az acr login --name "$ACR_NAME" --output none
        echo "  ✅ Login no ACR OK."
        while IFS='|' read -r SVC CTX REPO TAG; do
            [ -n "${SVC:-}" ] || continue
            quer_servico "$SVC" || continue
            if [ "$SVC" = "luna-ai" ]; then
                echo "  → build $SVC ($TAG) — imagem grande (~9,8 GB), pode demorar"
            else
                echo "  → build $SVC ($TAG)"
            fi
            docker build -t "${ACR_LOGIN_SERVER}/${REPO}:${TAG}" "$ROOT_DIR/$CTX"

            # ─── Push com token renovado e retentativa ───────────────────────
            # O refresh token de `az acr login` vale 3 HORAS. Com um único login
            # no topo do laço, o build da luna-ai (~9,8 GB, medido em 4h numa
            # conexão de ~4 Mbit/s) consome a validade inteira antes de o push
            # começar, e o envio morre em "error from registry: authentication
            # required" com TODAS as camadas em Waiting — nada enviado, depois
            # de horas de build. Por isso o token é pedido por push, não por
            # execução.
            #
            # A retentativa existe porque o próprio push pode estourar as 3h em
            # link lento. Ela não é cara: `docker push` pula camada que já está
            # no registry, então cada tentativa retoma de onde a anterior parou
            # em vez de recomeçar.
            echo "  → push $SVC"
            PUSH_OK=false
            for TENTATIVA in 1 2 3; do
                az acr login --name "$ACR_NAME" --output none
                if docker push "${ACR_LOGIN_SERVER}/${REPO}:${TAG}"; then
                    PUSH_OK=true
                    break
                fi
                if [ "$TENTATIVA" -lt 3 ]; then
                    echo "  ⚠️  push de $SVC falhou (tentativa $TENTATIVA/3) — renovando token do ACR."
                    echo "     As camadas já enviadas são preservadas; a retentativa continua de onde parou."
                fi
            done
            if [ "$PUSH_OK" != "true" ]; then
                echo ""
                echo "❌ ERRO: push de $SVC falhou nas 3 tentativas."
                echo "   A imagem local ${ACR_LOGIN_SERVER}/${REPO}:${TAG} está intacta —"
                echo "   NÃO é preciso rebuildar. Verifique a conexão e rode de novo:"
                echo "     ./azure/deploy.sh --service $SVC"
                echo "   O build baterá no cache e o push retoma das camadas que faltam."
                exit 1
            fi
        done <<EOF
$IMAGENS
EOF
        echo "  ✅ Imagens do escopo enviadas ao ACR."
    fi
fi

# ─── [5/10] Storage account + file shares ────────────────────────────────────
echo ""
echo "[5/10] Criando/confirmando Storage Account: $STORAGE_ACCOUNT_NAME..."
if az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  Storage Account já existe, reaproveitando."
else
    az storage account create --name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" \
        --sku Standard_LRS --kind StorageV2 --output none
    echo "  ✅ Storage Account criada."
fi
STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" --query "[0].value" -o tsv)

# Dois shares com propósitos distintos:
#   backup     → destino dos dumps do Data Pump (azure/backup-db.sh). É a
#                durabilidade real do banco, já que o ACI não permite volume
#                para os datafiles.
#   documentos → PDFs de receituário, equivalente ao named volume
#                kura_storage_documentos do compose.
for SHARE in "$STORAGE_SHARE_BACKUP" "$STORAGE_SHARE_DOCUMENTOS"; do
    az storage share create --name "$SHARE" --account-name "$STORAGE_ACCOUNT_NAME" \
        --account-key "$STORAGE_KEY" --quota "$STORAGE_SHARE_QUOTA_GB" --output none
    echo "  ✅ File share pronto: $SHARE"
done

# ─── [6/10] ACI do Oracle ────────────────────────────────────────────────────
echo ""
if [ "$MODO_ESCOPO" != "tudo" ] && [ "$MODO_ESCOPO" != "db" ]; then
    echo "[6/10] Escopo '$MODO_ESCOPO' — container group do Oracle não é tocado."
else
    echo "[6/10] Oracle: $ACI_ORACLE_NAME..."
    ORACLE_EXISTE=false
    az container show --name "$ACI_ORACLE_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null && ORACLE_EXISTE=true

    if [ "$ORACLE_EXISTE" = "true" ] && [ "$RECRIAR_DB" = "false" ]; then
        echo "  Container group já existe — PRESERVADO. O banco não foi tocado."
        echo "  (para refazer do zero, e APAGAR os dados: --recreate-db)"
    else
        if [ "$ORACLE_EXISTE" = "true" ]; then
            echo ""
            echo "  ⚠️  --recreate-db: isto APAGA TODOS OS DADOS do banco."
            echo "     O armazenamento do ACI é efêmero e não há volume para os"
            echo "     datafiles — recriar o container group é começar do zero."
            echo "     Rode ./azure/backup-db.sh antes, se ainda não rodou."
            if [ "$PERGUNTAR" = "true" ]; then
                echo ""
                echo "     Digite o nome do container group para confirmar:"
                read -r CONFIRMACAO
                if [ "$CONFIRMACAO" != "$ACI_ORACLE_NAME" ]; then
                    echo "❌ Nome não confere. Abortando — nada foi apagado."
                    exit 1
                fi
            fi
        fi
        substituir_placeholders \
            "$SCRIPT_DIR/aci-oracle-db.yaml" \
            "$GERADOS_DIR/aci-oracle-db.yaml" \
            "LOCATION=$AZURE_LOCATION" \
            "ORACLE_ACI_NAME=$ACI_ORACLE_NAME" \
            "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER" \
            "ACR_USERNAME=$ACR_USERNAME" \
            "ACR_PASSWORD=$ACR_PASSWORD" \
            "ORACLE_IMAGE_TAG=$ORACLE_IMAGE_TAG" \
            "ORACLE_SYS_PASSWORD=$ORACLE_SYS_PASSWORD" \
            "ORACLE_APP_USER=$ORACLE_APP_USER" \
            "ORACLE_APP_PASSWORD=$ORACLE_APP_PASSWORD" \
            "STORAGE_SHARE_BACKUP=$STORAGE_SHARE_BACKUP" \
            "STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME" \
            "STORAGE_ACCOUNT_KEY=$STORAGE_KEY"
        recriar_container_group "$ACI_ORACLE_NAME" "$GERADOS_DIR/aci-oracle-db.yaml"
        echo "  ✅ Container group do Oracle criado."
    fi

    echo "  Aguardando o listener responder em $ORACLE_FQDN:1521"
    echo "  (Oracle XE cria o PDB na primeira subida — pode levar vários minutos)..."
    if ! aguardar_porta_tcp "$ORACLE_FQDN" 1521 30 30; then
        echo "❌ Oracle não respondeu em 15 min. Ver logs:"
        echo "   az container logs --name $ACI_ORACLE_NAME --resource-group $AZURE_RESOURCE_GROUP"
        exit 1
    fi
    echo "  ✅ Oracle aceitando conexões."
fi

# Endereços derivados, usados pelos três manifestos de aplicação
#
# ─── POR QUE OS POOLS PRECISAM DE AJUSTE AQUI ────────────────────────────────
# Os três clientes alcançam o Oracle pelo FQDN PÚBLICO (não há VNet comum entre
# container groups — ver cabeçalho de aci-dotnet-api.yaml). Esse caminho sai do
# container group, passa pelo balanceador/NAT do Azure e volta, e tem uma
# propriedade que muda a configuração de pool: o fluxo TCP que fica OCIOSO é
# descartado no meio do caminho — o NAT de saída do container group expira a
# tradução (o default documentado da plataforma é 4 minutos) e não envia RST nem
# FIN para nenhuma das duas pontas. Quem deixou a conexão parada no pool não é
# avisado: descobre ao usar, e o erro chega como
#   ORA-12537 TNS:connection closed   (ODP.NET / .NET)
#   ORA-17008 Closed connection       (JDBC / Java)
#
# Como isto foi localizado, para quem for reinvestigar: o alert log do Oracle não
# registra erro nem restart na janela da falha (o banco não caiu), e o log do
# tutor-api mostra o Hikari reprovando UMA A UMA as conexões que abriu ~50 min
# antes ("Failed to validate connection ... ORA-17008"), com a requisição
# seguinte funcionando — ou seja, o que morre é o socket parado, não o banco.
# Atenção a um falso negativo ao reproduzir: um socket ocioso aberto DE FORA para
# o IP público do Oracle sobrevive a 300s (testado) — o caminho que expira é o de
# SAÍDA dos container groups das aplicações, que é onde os pools vivem.
#
# Daí a regra que vale para os três: NENHUMA conexão pode ficar ociosa no pool
# perto dos 4 minutos sem ser validada ou renovada. Isto não é ajuste de
# performance — sem isto, a primeira chamada depois de alguns minutos de
# ociosidade devolve 500.
#
# .NET (ODP.NET):
#   Validate Connection=true  valida a conexão ao tirá-la do pool; se o socket
#                             morreu, descarta e pega outra em vez de estourar
#                             ORA-12537 na cara do endpoint.
#   Connection Lifetime=180   aposenta a conexão 3 min após abri-la, antes de a
#                             janela de risco existir. Como o fechamento
#                             acontece com o socket ainda vivo, o logoff chega
#                             ao servidor e não deixa sessão órfã no XE.
#   Min Pool Size=0           o default (1) mantém uma conexão parada para
#                             sempre — exatamente a que morre e reaparece como
#                             erro intermitente.
ORACLE_CONNECTION_STRING="User Id=${ORACLE_APP_USER};Password=${ORACLE_APP_PASSWORD};Data Source=${ORACLE_FQDN}:1521/${ORACLE_PDB_SERVICE};Validate Connection=true;Connection Lifetime=180;Min Pool Size=0"
DB_URL_JAVA="jdbc:oracle:thin:@//${ORACLE_FQDN}:1521/${ORACLE_PDB_SERVICE}"
ORACLE_DSN_LUNA="${ORACLE_FQDN}:1521/${ORACLE_PDB_SERVICE}"
KURA_API_BASE_URL="http://${DOTNET_FQDN}:8080"
LUNA_BASE_URL="http://${LUNA_FQDN}:8000"

# ─── [7/10] ACI do Java (autoridade de DDL — Flyway) ─────────────────────────
echo ""
if quer_servico tutor-api; then
    # Sobe ANTES do .NET de propósito: o Flyway deste serviço cria o schema, e
    # com esta ordem o .NET já encontra as tabelas na primeira subida.
    echo "[7/10] tutor-api (Flyway cria o schema): $ACI_JAVA_NAME..."
    substituir_placeholders \
        "$SCRIPT_DIR/aci-java-api.yaml" \
        "$GERADOS_DIR/aci-java-api.yaml" \
        "LOCATION=$AZURE_LOCATION" \
        "JAVA_ACI_NAME=$ACI_JAVA_NAME" \
        "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER" \
        "ACR_USERNAME=$ACR_USERNAME" \
        "ACR_PASSWORD=$ACR_PASSWORD" \
        "JAVA_IMAGE_TAG=$JAVA_IMAGE_TAG" \
        "DB_URL=$DB_URL_JAVA" \
        "ORACLE_APP_USER=$ORACLE_APP_USER" \
        "ORACLE_APP_PASSWORD=$ORACLE_APP_PASSWORD" \
        "JAVA_JWT_SECRET=$JAVA_JWT_SECRET" \
        "JWT_ACCESS_EXPIRATION_MINUTES=$JWT_ACCESS_EXPIRATION_MINUTES" \
        "CORS_ALLOWED_ORIGINS=$CORS_ALLOWED_ORIGINS"
    recriar_container_group "$ACI_JAVA_NAME" "$GERADOS_DIR/aci-java-api.yaml"
    echo "  Aguardando health (o Flyway aplica as migrations na primeira subida)..."
    if ! aguardar_http_ok "http://$JAVA_FQDN:8081/api/actuator/health" 30 20; then
        echo "❌ tutor-api não respondeu 200 em 10 min. Ver logs:"
        echo "   az container logs --name $ACI_JAVA_NAME --resource-group $AZURE_RESOURCE_GROUP"
        echo "   (o schema não existir bloqueia as outras duas APIs — não siga sem resolver)"
        exit 1
    fi
    echo "  ✅ tutor-api saudável, schema criado."
else
    echo "[7/10] Fora do escopo — tutor-api não alterado."
fi

# ─── [8/10] ACI do .NET ──────────────────────────────────────────────────────
echo ""
if quer_servico clinica-api; then
    echo "[8/10] clinica-api: $ACI_DOTNET_NAME..."
    substituir_placeholders \
        "$SCRIPT_DIR/aci-dotnet-api.yaml" \
        "$GERADOS_DIR/aci-dotnet-api.yaml" \
        "LOCATION=$AZURE_LOCATION" \
        "DOTNET_ACI_NAME=$ACI_DOTNET_NAME" \
        "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER" \
        "ACR_USERNAME=$ACR_USERNAME" \
        "ACR_PASSWORD=$ACR_PASSWORD" \
        "DOTNET_IMAGE_TAG=$DOTNET_IMAGE_TAG" \
        "ASPNETCORE_ENVIRONMENT=$ASPNETCORE_ENVIRONMENT" \
        "ORACLE_CONNECTION_STRING=$ORACLE_CONNECTION_STRING" \
        "DOTNET_JWT_KEY=$DOTNET_JWT_KEY" \
        "IOT_API_KEY=$IOT_API_KEY" \
        "LUNA_API_KEY=$LUNA_API_KEY" \
        "DAILY_API_KEY=$DAILY_API_KEY" \
        "LUNA_BASE_URL=$LUNA_BASE_URL" \
        "LUNA_INBOUND_API_KEY=$LUNA_INBOUND_API_KEY" \
        "STORAGE_BASE_PATH=$STORAGE_BASE_PATH" \
        "STORAGE_SHARE_DOCUMENTOS=$STORAGE_SHARE_DOCUMENTOS" \
        "STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT_NAME" \
        "STORAGE_ACCOUNT_KEY=$STORAGE_KEY"
    recriar_container_group "$ACI_DOTNET_NAME" "$GERADOS_DIR/aci-dotnet-api.yaml"
    echo "  Aguardando health..."
    if ! aguardar_http_ok "http://$DOTNET_FQDN:8080/health" 20 20; then
        echo "⚠️  clinica-api não respondeu 200 em ~7 min. Ver logs:"
        echo "   az container logs --name $ACI_DOTNET_NAME --resource-group $AZURE_RESOURCE_GROUP"
    else
        echo "  ✅ clinica-api saudável."
    fi
else
    echo "[8/10] Fora do escopo — clinica-api não alterado."
fi

# ─── [9/10] ACI da Luna ──────────────────────────────────────────────────────
echo ""
if quer_servico luna-ai; then
    echo "[9/10] luna-ai: $ACI_LUNA_NAME..."
    echo "  (imagem de ~9,8 GB — o primeiro pull do container group é demorado)"
    substituir_placeholders \
        "$SCRIPT_DIR/aci-luna-ai.yaml" \
        "$GERADOS_DIR/aci-luna-ai.yaml" \
        "LOCATION=$AZURE_LOCATION" \
        "LUNA_ACI_NAME=$ACI_LUNA_NAME" \
        "ACR_LOGIN_SERVER=$ACR_LOGIN_SERVER" \
        "ACR_USERNAME=$ACR_USERNAME" \
        "ACR_PASSWORD=$ACR_PASSWORD" \
        "LUNA_IMAGE_TAG=$LUNA_IMAGE_TAG" \
        "ORACLE_DSN=$ORACLE_DSN_LUNA" \
        "ORACLE_APP_USER=$ORACLE_APP_USER" \
        "ORACLE_APP_PASSWORD=$ORACLE_APP_PASSWORD" \
        "KURA_API_BASE_URL=$KURA_API_BASE_URL" \
        "LUNA_API_KEY=$LUNA_API_KEY" \
        "LUNA_INBOUND_API_KEY=$LUNA_INBOUND_API_KEY" \
        "TWILIO_SID=$TWILIO_SID" \
        "TWILIO_TOKEN=$TWILIO_TOKEN" \
        "TWILIO_FROM_NUMBER=$TWILIO_FROM_NUMBER" \
        "OPENAI_API_KEY=$OPENAI_API_KEY" \
        "WEBHOOK_PUBLIC_URL=$WEBHOOK_PUBLIC_URL"
    recriar_container_group "$ACI_LUNA_NAME" "$GERADOS_DIR/aci-luna-ai.yaml"
    echo "  Aguardando health..."
    if ! aguardar_http_ok "http://$LUNA_FQDN:8000/health" 30 20; then
        echo "⚠️  luna-ai não respondeu 200 em 10 min. Ver logs:"
        echo "   az container logs --name $ACI_LUNA_NAME --resource-group $AZURE_RESOURCE_GROUP"
    else
        echo "  ✅ luna-ai saudável."
    fi
else
    echo "[9/10] Fora do escopo — luna-ai não alterado."
fi

# ─── [10/10] Resumo ──────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " DEPLOY CONCLUÍDO"
echo "========================================================"
echo ""
echo "  Oracle   : $ORACLE_FQDN:1521/$ORACLE_PDB_SERVICE  (schema $ORACLE_APP_USER)"
echo "  .NET API : http://$DOTNET_FQDN:8080/swagger   · health /health"
echo "  Java API : http://$JAVA_FQDN:8081/api/swagger-ui/index.html · health /api/actuator/health"
echo "  Luna IA  : http://$LUNA_FQDN:8000/docs        · health /health"
echo ""
echo "  Segredos (Key Vault $KEYVAULT_NAME):"
echo "    az keyvault secret list --vault-name $KEYVAULT_NAME -o table"
echo ""
echo "  Próximos passos:"
echo "    ./azure/verify.sh          valida tudo por FQDN público"
echo "    ./azure/backup-db.sh       dump do banco para o share $STORAGE_SHARE_BACKUP"
echo ""
echo "  Redeploy de aplicação sem tocar no banco:"
echo "    ./azure/deploy.sh --apps-only"
echo "    ./azure/deploy.sh --service luna-ai --skip-build"
echo ""
echo "  Restaurar um dump (nesta ordem, para o Flyway não recriar o schema vazio):"
echo "    ./azure/deploy.sh --db-only --recreate-db"
echo "    ./azure/restore-db.sh <nome-do-dump>"
echo "    ./azure/deploy.sh --apps-only"
echo "========================================================"
