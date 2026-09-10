#!/usr/bin/env bash
# =============================================================================
# KURA · azure/restore-db.sh — restaura um dump do Data Pump no Oracle
#
# Contraparte de azure/backup-db.sh. Mesmo mecanismo: grava um script no file
# share (já montado em /mnt/backup dentro do container) e manda executar
# `/bin/sh /mnt/backup/<script>`, porque `az container exec` monta o argv
# quebrando a string em espaços, sem shell.
#
# ─── ORDEM IMPORTA ───────────────────────────────────────────────────────────
# O Flyway roda no boot do tutor-api e é a autoridade de DDL: se ele encontrar
# um schema vazio, cria tudo do zero — e aí o impdp bateria em tabelas já
# existentes. Por isso a sequência de restauração é:
#
#   ./azure/deploy.sh --db-only --recreate-db   banco novo, vazio, sem apps
#   ./azure/restore-db.sh <nome-do-dump>        este script
#   ./azure/deploy.sh --apps-only               sobe as três aplicações
#
# Funciona porque o dump inclui a tabela flyway_schema_history: quando o
# tutor-api sobe, o Flyway lê o histórico restaurado, conclui que as migrations
# já foram aplicadas e não repete nada.
#
# Uso:
#   ./azure/restore-db.sh kura-20260910T143000Z
#   ./azure/restore-db.sh --list      lista os dumps disponíveis no share
# =============================================================================
set -eu

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a
    . "$ROOT_DIR/.env"
    set +a
fi

KURA_PREFIX="${KURA_PREFIX:-kura-prod}"
KURA_PREFIX_ALNUM="$(printf '%s' "$KURA_PREFIX" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${KURA_PREFIX}-rg}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-${KURA_PREFIX_ALNUM}storage}"
STORAGE_SHARE_BACKUP="${STORAGE_SHARE_BACKUP:-kura-oracle-backup}"
ACI_ORACLE_NAME="${KURA_PREFIX}-oracle-db"
ORACLE_APP_USER="${ORACLE_APP_USER:-KURA}"
ORACLE_PDB_SERVICE="${ORACLE_PDB_SERVICE:-XEPDB1}"

STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" --query "[0].value" -o tsv)

if [ "${1:-}" = "--list" ] || [ $# -eq 0 ]; then
    echo "Dumps disponíveis em $STORAGE_SHARE_BACKUP:"
    az storage file list --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" \
        --share-name "$STORAGE_SHARE_BACKUP" --query "[?ends_with(name,'.dmp')].{nome:name,bytes:properties.contentLength}" \
        -o table
    [ $# -eq 0 ] && echo "" && echo "Uso: ./azure/restore-db.sh <nome-do-dump-sem-extensao>"
    exit 0
fi

NOME_DUMP="${1%.dmp}"

echo "========================================================"
echo " KURA · restore-db.sh"
echo "========================================================"
echo "  Dump            : $NOME_DUMP.dmp"
echo "  Container group : $ACI_ORACLE_NAME"
echo "  Schema destino  : $ORACLE_APP_USER"
echo ""
echo "  ⚠️  Isto SOBRESCREVE os objetos do schema $ORACLE_APP_USER com o"
echo "     conteúdo do dump (TABLE_EXISTS_ACTION=REPLACE)."
echo ""

if ! az container show --name "$ACI_ORACLE_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "❌ ERRO: container group $ACI_ORACLE_NAME não existe."
    echo "   Crie o banco antes: ./azure/deploy.sh --db-only"
    exit 1
fi

if [ "${KURA_RESTORE_YES:-false}" != "true" ]; then
    echo "  Digite o nome do dump para confirmar:"
    read -r CONFIRMACAO
    if [ "$CONFIRMACAO" != "$NOME_DUMP" ]; then
        echo "❌ Nome não confere. Abortando — nada foi alterado."
        exit 1
    fi
fi

TMP_LOCAL="$(mktemp)"
cat > "$TMP_LOCAL" <<INTERNO
#!/bin/sh
set -eu

DIR_LOCAL=/tmp/kura-restore
NOME="$NOME_DUMP"
SCHEMA="$ORACLE_APP_USER"
SERVICO="$ORACLE_PDB_SERVICE"

if ! command -v impdp >/dev/null 2>&1; then
    echo "ERRO: impdp nao encontrado no PATH desta imagem."
    echo "RESTORE_FALHOU"
    exit 1
fi

if [ ! -f "/mnt/backup/\${NOME}.dmp" ]; then
    echo "ERRO: /mnt/backup/\${NOME}.dmp nao existe no share."
    echo "RESTORE_FALHOU"
    exit 1
fi

echo "== copiando o dump do share para o disco local =="
# O impdp le pelo processo servidor (usuario oracle); o mount SMB pertence a
# root sem ajuste de uid/gid possivel no ACI. Copiar para /tmp primeiro e dar a
# posse ao oracle contorna isso — mesma razao, espelhada, do backup-db.sh.
mkdir -p "\$DIR_LOCAL"
cp "/mnt/backup/\${NOME}.dmp" "\$DIR_LOCAL/"
chown -R oracle:oinstall "\$DIR_LOCAL" 2>/dev/null || chown -R oracle "\$DIR_LOCAL" 2>/dev/null || true

echo "== registrando o DIRECTORY no banco =="
sqlplus -S -L "sys/\${ORACLE_PASSWORD}@localhost:1521/\${SERVICO}" as sysdba <<SQL
SET FEEDBACK OFF
CREATE OR REPLACE DIRECTORY KURA_RESTORE AS '\$DIR_LOCAL';
GRANT READ, WRITE ON DIRECTORY KURA_RESTORE TO \${SCHEMA};
EXIT
SQL

echo "== impdp para o schema \$SCHEMA =="
impdp "\${SCHEMA}/\${APP_USER_PASSWORD}@localhost:1521/\${SERVICO}" \\
    schemas="\$SCHEMA" \\
    directory=KURA_RESTORE \\
    dumpfile="\${NOME}.dmp" \\
    logfile="restore-\${NOME}.log" \\
    table_exists_action=replace

cp "\$DIR_LOCAL/restore-\${NOME}.log" /mnt/backup/ 2>/dev/null || true
rm -rf "\$DIR_LOCAL"
echo "RESTORE_OK"
INTERNO

NOME_INTERNO="kura-restore-interno.sh"
echo "  Enviando o script interno para o share..."
az storage file upload \
    --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" \
    --share-name "$STORAGE_SHARE_BACKUP" \
    --source "$TMP_LOCAL" --path "$NOME_INTERNO" \
    --output none
rm -f "$TMP_LOCAL"

echo "  Executando a importação dentro do container..."
SAIDA=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az container exec \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$ACI_ORACLE_NAME" \
    --exec-command "/bin/sh /mnt/backup/$NOME_INTERNO" \
    --output tsv 2>&1 || true)

echo "$SAIDA"
echo ""
if printf '%s' "$SAIDA" | grep -q "RESTORE_OK"; then
    echo "  ✅ Restauração concluída."
    echo ""
    echo "  Próximo passo: ./azure/deploy.sh --apps-only"
    echo "  (o Flyway vai encontrar o flyway_schema_history restaurado e não"
    echo "   vai reaplicar as migrations)"
else
    echo "  ❌ A restauração NÃO foi confirmada (sentinela RESTORE_OK ausente acima)."
    echo "     O banco pode ter ficado parcialmente importado — confira o log em"
    echo "     $STORAGE_SHARE_BACKUP/restore-$NOME_DUMP.log antes de subir as apps."
    exit 1
fi
echo "========================================================"
