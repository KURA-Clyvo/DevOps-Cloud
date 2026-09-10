#!/usr/bin/env bash
# =============================================================================
# KURA · azure/teardown.sh — apaga o ambiente inteiro
#
# ⚠️ ESTE É UM AMBIENTE DE PRODUÇÃO. Diferente do script equivalente de um
# checkpoint, aqui rodar teardown NÃO é rotina — é uma operação excepcional
# (encerrar o ambiente, recomeçar do zero, cortar custo de vez). Não use isto
# para "reiniciar" nada: para redeploy existe `./azure/deploy.sh --apps-only`,
# que não toca no banco.
#
# O QUE SOME: o resource group inteiro — ACR (com todas as imagens), storage
# account (com os DUMPS DE BACKUP), Key Vault e os quatro container groups.
# Ou seja, isto apaga também a única cópia durável do banco. Se houver qualquer
# chance de precisar dos dados depois, baixe os dumps ANTES:
#
#   az storage file download-batch \
#     --account-name <storage> --source kura-oracle-backup --destination ./dumps
#
# O Key Vault cai junto com o resource group, mas fica em SOFT-DELETE por 90
# dias (comportamento obrigatório do serviço, não desligável). O deploy.sh sabe
# disso e faz `az keyvault recover` no próximo run — os segredos voltam
# intactos. Use --purge-keyvault só para apagá-los de vez.
#
# Uso:
#   ./azure/teardown.sh                  confirmação interativa (digitar o nome
#                                        do resource group)
#   ./azure/teardown.sh --yes            sem confirmação (automação)
#   ./azure/teardown.sh --purge-keyvault também PURGA o cofre (irreversível:
#                                        segredos apagados, nome liberado)
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    . "$ROOT_DIR/.env"
    set +a
fi

KURA_PREFIX="${KURA_PREFIX:-kura-prod}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${KURA_PREFIX}-rg}"
KEYVAULT_NAME="${KEYVAULT_NAME:-${KURA_PREFIX}-kv}"

PULAR_CONFIRMACAO=false
PURGAR_COFRE=false
for ARGUMENTO in "$@"; do
    case "$ARGUMENTO" in
        --yes) PULAR_CONFIRMACAO=true ;;
        --purge-keyvault) PURGAR_COFRE=true ;;
        *)
            echo "❌ Argumento desconhecido '$ARGUMENTO'."
            echo "   Use: ./azure/teardown.sh [--yes] [--purge-keyvault]"
            exit 1
            ;;
    esac
done

# `az keyvault purge` só age sobre um cofre JÁ apagado (soft-deleted) — num
# cofre vivo responde "not found". Por isso o fluxo é sempre delete → purge, e
# esta função cuida só da segunda metade.
purgar_cofre_soft_deleted() {
    local regiao_cofre
    # A região vem do registro do cofre apagado, não de $AZURE_LOCATION: se
    # alguém trocou a região depois do deploy, o purge ainda acerta o alvo certo
    # (`az keyvault purge` exige a location de onde o cofre foi criado).
    regiao_cofre="$(az keyvault list-deleted --query "[?name=='$KEYVAULT_NAME'].properties.location | [0]" -o tsv 2>/dev/null || true)"
    if [ -z "$regiao_cofre" ]; then
        echo "  ℹ️  Nenhum Key Vault '$KEYVAULT_NAME' em soft-delete — nada a purgar."
        return 0
    fi
    echo "  Purgando o Key Vault $KEYVAULT_NAME (região $regiao_cofre, irreversível)..."
    if az keyvault purge --name "$KEYVAULT_NAME" --location "$regiao_cofre" --output none 2>/dev/null; then
        echo "  ✅ Cofre purgado — segredos apagados de vez, nome liberado."
    else
        echo "  ⚠️  Não foi possível purgar (purge protection por policy, ou falta"
        echo "     de permissão). O cofre segue em soft-delete e o deploy.sh"
        echo "     consegue recuperá-lo normalmente."
    fi
}

echo "========================================================"
echo " KURA · teardown.sh — AMBIENTE DE PRODUÇÃO"
echo "========================================================"
echo ""
echo "  Isto apaga TODO o Resource Group: $AZURE_RESOURCE_GROUP"
echo "  (ACR e imagens, Storage Account e OS DUMPS DE BACKUP, Key Vault,"
echo "   e os quatro container groups)."
echo ""
echo "  ⚠️  Os dumps do banco moram na storage account que vai junto. Depois"
echo "     disto não há de onde restaurar."
echo ""
if [ "$PURGAR_COFRE" = "true" ]; then
    echo "  ⚠️  --purge-keyvault: o cofre $KEYVAULT_NAME será PURGADO."
    echo "     Irreversível — o próximo deploy.sh vai GERAR segredos novos."
    echo ""
else
    echo "  ℹ️  O cofre $KEYVAULT_NAME fica recuperável por 90 dias; o próximo"
    echo "     deploy.sh o recupera com os segredos intactos."
    echo ""
fi

if ! az group show --name "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "  ℹ️  Resource Group $AZURE_RESOURCE_GROUP não existe (já apagado?)."
    if [ "$PURGAR_COFRE" = "true" ]; then
        purgar_cofre_soft_deleted
    else
        echo "  Nada a fazer."
    fi
    exit 0
fi

if [ "$PULAR_CONFIRMACAO" = "false" ]; then
    echo "  Digite o nome do resource group para confirmar (ou Ctrl+C para cancelar):"
    read -r CONFIRMACAO
    if [ "$CONFIRMACAO" != "$AZURE_RESOURCE_GROUP" ]; then
        echo "❌ Nome não confere. Abortando — nada foi apagado."
        exit 1
    fi
fi

if [ "$PURGAR_COFRE" = "true" ]; then
    # Antes do `az group delete`, de propósito: a exclusão do RG roda com
    # --no-wait, então o cofre só entraria em soft-delete minutos depois e o
    # purge falharia por "cofre ainda existe". Apagando explicitamente primeiro,
    # o soft-delete é imediato e o purge logo em seguida é garantido.
    echo ""
    echo "  Apagando o Key Vault antes do resource group..."
    az keyvault delete --name "$KEYVAULT_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --output none 2>/dev/null \
        || echo "  ℹ️  Cofre já não estava ativo neste resource group."
    purgar_cofre_soft_deleted
fi

echo ""
echo "  Apagando $AZURE_RESOURCE_GROUP (--no-wait — a exclusão segue em"
echo "  background no Azure)..."
az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait

echo ""
echo "  ✅ Exclusão disparada. Para confirmar quando terminar:"
echo "     az group exists --name $AZURE_RESOURCE_GROUP   (deve devolver 'false')"
echo "========================================================"
