#!/usr/bin/env bash
# =============================================================================
# KURA · azure/backup-db.sh — dump lógico do Oracle para o Azure Files
#
# ─── POR QUE ISTO EXISTE ─────────────────────────────────────────────────────
# O ACI só oferece volume do tipo `azureFile`, que é SMB, e o Oracle não abre a
# instância com os datafiles em SMB. Consequência: NÃO HÁ VOLUME PERSISTENTE
# PARA O BANCO — o armazenamento do container group é efêmero, e recriar o
# container group apaga tudo.
#
# A durabilidade, portanto, não vem de volume: vem daqui. Este script é o
# mecanismo de persistência real do banco, e o share de backup é a fonte da
# verdade dos dados.
#
# ─── POR QUE DATA PUMP, E NÃO CÓPIA DOS DATAFILES ────────────────────────────
# Copiar /opt/oracle/oradata com o banco aberto produz datafiles *fuzzy*: cada
# bloco é capturado num SCN diferente, e tornar o conjunto consistente exigiria
# o redo do intervalo — que não é copiado junto e que, em NOARCHIVELOG (o
# padrão do XE), nem existe. Uma cópia dessas não restaura. O Data Pump é
# consistente por construção (FLASHBACK_TIME), e o dump resultante é
# reimportável em qualquer instância Oracle.
#
# ─── COMO O SCRIPT ROTEIA O TRABALHO ─────────────────────────────────────────
# `az container exec` monta o argv quebrando a string em espaços, sem shell e
# sem respeitar aspas — então não dá para mandar um comando composto por ali.
# A saída: este script grava um script interno no próprio file share (que já
# está montado em /mnt/backup dentro do container) e manda executar
#   /bin/sh /mnt/backup/<script>
# que são três tokens sem espaço interno. Lá dentro há um shell de verdade.
#
# O script interno não recebe segredo nenhum por parâmetro: as senhas já estão
# no ambiente do container, injetadas como `secureValue` pelo manifesto.
#
# Uso:
#   ./azure/backup-db.sh              dump com nome baseado na data/hora UTC
#   ./azure/backup-db.sh meu-rotulo   dump com nome próprio
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

ROTULO="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
NOME_DUMP="kura-${ROTULO}"

echo "========================================================"
echo " KURA · backup-db.sh"
echo "========================================================"
echo "  Container group : $ACI_ORACLE_NAME"
echo "  Schema          : $ORACLE_APP_USER"
echo "  Destino         : $STORAGE_SHARE_BACKUP/$NOME_DUMP.dmp"
echo ""

if ! az container show --name "$ACI_ORACLE_NAME" --resource-group "$AZURE_RESOURCE_GROUP" -o none 2>/dev/null; then
    echo "❌ ERRO: container group $ACI_ORACLE_NAME não existe. Nada a exportar."
    exit 1
fi

STORAGE_KEY=$(az storage account keys list --account-name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" --query "[0].value" -o tsv)

# ─── Script que roda DENTRO do container ─────────────────────────────────────
# Escreve o dump primeiro em /tmp e só depois copia para /mnt/backup, de
# propósito: o Data Pump grava pelo processo servidor (usuário `oracle`), e o
# mount SMB do ACI pertence a root sem opção de ajustar uid/gid. Já a cópia
# final roda como root (é assim que `az container exec` entra), então consegue
# gravar no share. De quebra, copiar um dump JÁ FECHADO é uma transferência
# sequencial de arquivo pronto — não há a inconsistência que existiria ao
# copiar datafiles de um banco em uso.
TMP_LOCAL="$(mktemp)"
cat > "$TMP_LOCAL" <<INTERNO
#!/bin/sh
set -eu

DIR_LOCAL=/tmp/kura-backup
NOME="$NOME_DUMP"
SCHEMA="$ORACLE_APP_USER"
SERVICO="$ORACLE_PDB_SERVICE"

echo "== preparando diretorio local =="
mkdir -p "\$DIR_LOCAL"
chown oracle:oinstall "\$DIR_LOCAL" 2>/dev/null || chown oracle "\$DIR_LOCAL" 2>/dev/null || true

if ! command -v expdp >/dev/null 2>&1; then
    echo "ERRO: expdp nao encontrado no PATH desta imagem."
    echo "BACKUP_FALHOU"
    exit 1
fi

echo "== registrando o DIRECTORY no banco =="
sqlplus -S -L "sys/\${ORACLE_PASSWORD}@localhost:1521/\${SERVICO}" as sysdba <<SQL
SET FEEDBACK OFF
CREATE OR REPLACE DIRECTORY KURA_BACKUP AS '\$DIR_LOCAL';
GRANT READ, WRITE ON DIRECTORY KURA_BACKUP TO \${SCHEMA};
EXIT
SQL

echo "== expdp do schema \$SCHEMA =="
# FLASHBACK_TIME=SYSTIMESTAMP e o que torna o dump consistente: todas as
# tabelas sao lidas no mesmo ponto no tempo, mesmo com escrita concorrente.
expdp "\${SCHEMA}/\${APP_USER_PASSWORD}@localhost:1521/\${SERVICO}" \\
    schemas="\$SCHEMA" \\
    directory=KURA_BACKUP \\
    dumpfile="\${NOME}.dmp" \\
    logfile="\${NOME}.log" \\
    flashback_time=systimestamp \\
    reuse_dumpfiles=yes

echo "== copiando para o share =="
cp "\$DIR_LOCAL/\${NOME}.dmp" /mnt/backup/
cp "\$DIR_LOCAL/\${NOME}.log" /mnt/backup/ 2>/dev/null || true
rm -f "\$DIR_LOCAL/\${NOME}.dmp"

ls -l "/mnt/backup/\${NOME}.dmp"
echo "BACKUP_OK"
INTERNO

NOME_INTERNO="kura-backup-interno.sh"
echo "  Enviando o script interno para o share..."
az storage file upload \
    --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" \
    --share-name "$STORAGE_SHARE_BACKUP" \
    --source "$TMP_LOCAL" --path "$NOME_INTERNO" \
    --output none
rm -f "$TMP_LOCAL"

echo "  Executando o dump dentro do container (pode levar alguns minutos)..."
# MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL ficam POR COMANDO: no Git Bash o MSYS
# reescreve argumento que pareça caminho POSIX ("/bin/sh" viraria
# "C:/Program Files/Git/bin/sh") e o exec falha com
# `exec: "C:/Program": stat C:/Program: no such file or directory`.
SAIDA=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az container exec \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$ACI_ORACLE_NAME" \
    --exec-command "/bin/sh /mnt/backup/$NOME_INTERNO" \
    --output tsv 2>&1 || true)

echo "$SAIDA"
echo ""
if printf '%s' "$SAIDA" | grep -q "BACKUP_OK"; then
    echo "  ✅ Dump concluído: $STORAGE_SHARE_BACKUP/$NOME_DUMP.dmp"
    echo ""
    echo "  Listar os dumps existentes:"
    echo "    az storage file list --account-name $STORAGE_ACCOUNT_NAME \\"
    echo "      --share-name $STORAGE_SHARE_BACKUP -o table"
    echo ""
    echo "  Restaurar este dump: ./azure/restore-db.sh $NOME_DUMP"
else
    echo "  ❌ O dump NÃO foi confirmado (sentinela BACKUP_OK ausente na saída acima)."
    echo "     Não trate este backup como válido."
    exit 1
fi
echo "========================================================"
