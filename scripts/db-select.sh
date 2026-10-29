#!/usr/bin/env bash
if [ -z "${KURA_LF_OK:-}" ] && grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then _lf="$(mktemp)"; tr -d '\r' < "${BASH_SOURCE[0]}" > "$_lf"; KURA_LF_OK=1 exec bash "$_lf" "$@"; fi # CRLF -> LF
# =============================================================================
# scripts/db-select.sh — executa um SELECT no Oracle da VM, sem SSH e sem expor a senha
#
# Uso:
#   bash scripts/db-select.sh "select * from tutor"
#   bash scripts/db-select.sh -f consulta.sql       SELECT guardado em arquivo
#   bash scripts/db-select.sh --tabelas             lista as tabelas do schema
#   bash scripts/db-select.sh --colunas PET         lista as colunas de uma tabela
#
# Como funciona: `az vm run-command` roda um script na VM do banco; ele lê a senha do
# Key Vault com a identidade gerenciada da VM e abre o sqlplus no container kura_oracle_db.
# A senha nunca passa pela sua tela (serve para gravar o vídeo). A transação é READ ONLY:
# INSERT, UPDATE e DELETE são recusados pelo próprio banco (ORA-01456). A evidência de
# persistência é feita por SELECT; as operações do CRUD são feitas pela aplicação.
#
# Pré-requisitos: az logado (az login) e o ambiente criado pelo azure/deploy.sh.
# Variáveis (mesmos padrões do deploy.sh): PREFIX=kura, RG=rg-$PREFIX, VM_NAME=vm-$PREFIX-db,
# ORACLE_SERVICE=XEPDB1, ORACLE_APP_USER=KURA, KV_NAME (vazio: descobre pelo grupo).
# Cada consulta leva alguns segundos (a VM é acionada pelo Azure).
# =============================================================================
set -Eeuo pipefail
trap 'echo "ERRO na linha $LINENO: $BASH_COMMAND" >&2' ERR

PREFIX="${PREFIX:-kura}"
RG="${RG:-rg-$PREFIX}"
VM_NAME="${VM_NAME:-vm-$PREFIX-db}"
ORACLE_SERVICE="${ORACLE_SERVICE:-XEPDB1}"
ORACLE_APP_USER="${ORACLE_APP_USER:-KURA}"
KV_NAME="${KV_NAME:-}"

# Windows (Git Bash): sem conversão de caminhos e com o az.cmd; o az do Windows devolve CRLF
AZBIN=az
WINDOWS=0
case "$(uname -s 2>/dev/null || true)" in
  MINGW* | MSYS* | CYGWIN*)
    WINDOWS=1
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    if ! command -v az >/dev/null 2>&1 && command -v az.cmd >/dev/null 2>&1; then AZBIN=az.cmd; fi
    ;;
esac
az() { command "$AZBIN" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }

die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
uso() { awk 'NR > 2 && /^set -/ { exit } NR > 2 && /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

SQL=""
case "${1:-}" in
  "" | -h | --help) uso; exit 2 ;;
  --tabelas) SQL="select table_name from user_tables order by table_name" ;;
  --colunas)
    [ -n "${2:-}" ] || die "informe a tabela. Ex.: --colunas PET"
    tabela="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    [[ "$tabela" =~ ^[A-Z0-9_]+$ ]] || die "nome de tabela inválido: $2"
    SQL="select column_name, data_type, nullable from user_tab_columns where table_name = '$tabela' order by column_id"
    ;;
  -f)
    [ -f "${2:-}" ] || die "arquivo não encontrado: ${2:-}"
    SQL="$(tr -d '\r' < "$2")"
    ;;
  *) SQL="$*" ;;
esac

validar_sql() { # só SELECT, um comando por vez
  local s="$SQL" limpo
  limpo="${s#"${s%%[![:space:]]*}"}"
  limpo="${limpo%"${limpo##*[![:space:]]}"}"
  limpo="${limpo%;}"
  [ -n "$limpo" ] || die "SQL vazio"
  case "$(printf '%s' "$limpo" | tr '[:upper:]' '[:lower:]')" in
    select[[:space:]]* | with[[:space:]]*) ;;
    *) die "só SELECT é permitido aqui. A evidência de persistência é por SELECT; INSERT, UPDATE e DELETE são feitos pela aplicação" ;;
  esac
  case "$limpo" in
    *\;*) die "envie um comando por vez (sem ';' no meio do SQL)" ;;
  esac
  SQL="$limpo"
}

montar_script_vm() { # imprime o script que roda DENTRO da VM (como root, via run-command)
  # O run-command executa com /bin/sh: reexecuta no bash.
  printf '%s\n' '[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"'
  printf 'KV_NAME=%q\nORACLE_SERVICE=%q\nORACLE_APP_USER=%q\nSQL_B64=%q\n' \
    "$KV_NAME" "$ORACLE_SERVICE" "$ORACLE_APP_USER" "$(printf '%s' "$SQL" | base64 | tr -d '\n')"
  cat <<'VM_SCRIPT'
set -euo pipefail
tok="$(curl -sf -H 'Metadata:true' 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"
senha="$(curl -sf -H "Authorization: Bearer $tok" "https://${KV_NAME}.vault.azure.net/secrets/oracle-app-password?api-version=7.4" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')"
[ -n "$senha" ] || { echo "ERRO: senha do banco indisponível no Key Vault" >&2; exit 1; }
sql="$(printf '%s' "$SQL_B64" | base64 -d)"
# A senha segue só por stdin (printf é builtin: não aparece na lista de processos)
printf 'set pagesize 200 linesize 220 trimspool on feedback on\nconnect %s/%s@//localhost:1521/%s\nset transaction read only;\n%s;\nexit\n' \
  "$ORACLE_APP_USER" "$senha" "$ORACLE_SERVICE" "$sql" \
  | docker exec -i kura_oracle_db sqlplus -s /nolog
VM_SCRIPT
}

validar_sql
command -v az >/dev/null 2>&1 || command -v az.cmd >/dev/null 2>&1 || die "'az' (Azure CLI) não encontrado no PATH"
az account show >/dev/null 2>&1 || die "sem sessão Azure: rode 'az login'"
[ -n "$KV_NAME" ] || KV_NAME="$(az keyvault list -g "$RG" --query '[0].name' -o tsv)"
[ -n "$KV_NAME" ] || die "Key Vault não encontrado em $RG (confira PREFIX/RG e rode 'bash azure/deploy.sh check')"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
montar_script_vm | tr -d '\r' > "$tmp"
arq="$tmp"
if [ "$WINDOWS" = 1 ] && command -v cygpath >/dev/null 2>&1; then arq="$(cygpath -m "$tmp")"; fi

saida="$(az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "@$arq" --query 'value[0].message' -o tsv || true)"
[ -n "$saida" ] || die "o run-command não devolveu saída (a VM $VM_NAME existe em $RG?)"

# Mostra só o resultado do sqlplus, sem o envelope do run-command
printf '%s\n' "$saida" | sed -e '/^Enable succeeded:/d' -e '/^\[stdout\]$/d' -e '/^\[stderr\]$/d'
if printf '%s\n' "$saida" | grep -qE '(ORA|SP2)-[0-9]+'; then exit 1; fi
