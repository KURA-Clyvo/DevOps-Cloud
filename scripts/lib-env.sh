# lib-env.sh — leitura tolerante de UMA chave do .env (REC-19 fix wave, G4-I1).
# Uso:  . ./scripts/lib-env.sh
#       VALOR=$(ler_chave_env DEMO_SENHA)          # .env do cwd (os scripts ja fazem cd para a raiz do repo)
#       VALOR=$(ler_chave_env CHAVE /outro/.env)
# Contrato: SEMPRE retorna 0 e imprime o valor (vazio se arquivo ou chave nao existem).
# Existe porque `grep` sem match sai 1 e, sob `set -euo pipefail`, mata o script mudo
# (G4-I1: seed-demo*.sh morriam sem mensagem quando o .env nao tinha DEMO_SENHA — o caso
# padrao, pois o .env.example traz a chave comentada). NAO usa `source`: nao exporta segredo.
ler_chave_env() {
  local chave=$1 arquivo=${2:-.env}
  [ -f "$arquivo" ] || return 0
  { grep -E "^${chave}=" "$arquivo" || true; } | tail -1 | cut -d= -f2- | tr -d '\r"'
  return 0
}
