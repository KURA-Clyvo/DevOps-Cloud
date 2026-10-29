#!/usr/bin/env bash
# =============================================================================
# azure/tests/db-packages.test.sh — testes das fases db-packages / db-packages-remover (S4-DB-07)
#
#   bash azure/tests/db-packages.test.sh
#
# Nada aqui toca a Azure nem um Oracle: um `az` falso (que registra cada chamada e, no modo "exec",
# EXECUTA localmente o script que o deploy.sh mandaria à VM), um `docker` falso (finge inspect/cp e,
# em `exec ... sqlplus`, emite um log-fixture conforme o stdin) e `curl`/`python3` falsos (devolvem
# uma senha falsa conhecida). Os fixtures reproduzem a forma da saída medida no G4 da S4-DB-08
# (marcadores `DEMO S4-DB-0x: INICIO/FIM` e linhas `RESUMO:` copiados do .sql real).
# Imprime `RESUMO: n OK, m FALHOU` e sai com 1 se houver qualquer falha.
# =============================================================================
set -u
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
DEPLOY="$RAIZ/azure/deploy.sh"
SENHA=SenhaFalsa_KV_123
ARQ_INST=2TDSPF_2026_Packages_Integrantes.sql
ARQ_REM=2TDSPF_2026_Packages_Remover.sql
SENT_I=KURA_DB_PACKAGES_OK
SENT_R=KURA_DB_PACKAGES_REMOVIDO_OK
CONT_FALSO=kura_oracle_db

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
STUBS="$T/bin"; FX="$T/fx"; SQLDIR="$T/sql"
mkdir -p "$STUBS" "$FX" "$SQLDIR"

OKN=0; FALN=0
ok()  { OKN=$((OKN + 1)); printf 'OK: %s\n' "$1"; }
nok() { FALN=$((FALN + 1)); printf 'FALHOU: %s%s\n' "$1" "${2:+ :: $2}"; }
afirma() { local d=$1; shift; if "$@"; then ok "$d"; else nok "$d" "($*)"; fi; }

# ─── stubs ───────────────────────────────────────────────────────────────────
cat > "$STUBS/az" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AZ_LOG"
case "$1 ${2:-}" in
  "account show") echo "00000000-0000-0000-0000-000000000000"; exit 0 ;;
  "vm run-command")
    path=""; prev=""
    for a in "$@"; do [ "$prev" = "--scripts" ] && path="${a#@}"; prev="$a"; done
    cp "$path" "$AZ_SCRIPT_COPY"
    case "${AZ_MODE:-msg}" in
      exec) out="$(bash "$path" 2>&1)" ;;
      *)    out="$(cat "${AZ_MSG_FILE:-/dev/null}")" ;;
    esac
    full="$(printf 'Enable succeeded: \n[stdout]\n%s\n[stderr]\n' "$out")"
    if [ -n "${AZ_TAIL:-}" ]; then printf '%s\n' "$full" | tail -c 4096; else printf '%s\n' "$full"; fi
    exit "${AZ_RC:-0}" ;;
  *) echo "az falso: comando inesperado: $*" >&2; exit 99 ;;
esac
STUB
# chmod falso: REGISTRA o modo pedido (o chmod de NTFS/Git Bash é ignorado e o stat não o mostra) e chama o real.
# O docker falso lê esse registro para saber o modo que o `docker cp` levaria para dentro do container.
cat > "$STUBS/chmod" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in [0-7][0-7][0-7]) m=$1; shift; for f in "$@"; do echo "$f $m" >> "$CHMOD_LOG"; done; set -- "$m" "$@" ;; esac
for real in /usr/bin/chmod /bin/chmod; do [ -x "$real" ] && exec "$real" "$@"; done
exit 0
STUB
# docker falso COM modelo de sistema de arquivos do container ($DOCKER_CTR): cada arquivo tem um .meta "dono modo".
#  - `docker cp` cria o arquivo com dono root e o modo da origem (comportamento do docker cp);
#  - `docker exec` roda como o usuário oracle, salvo -u/--user; só root lê/apaga/altera arquivo de root:600;
#  - `sqlplus` que recebe `@/tmp/x` sem poder ler x emite SP2-0310 e sai com 0 (como o sqlplus real).
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_ARGV"
eh_root() { [ "$1" = root ] || [ "$1" = 0 ]; }
case "$1" in
  inspect) if [ -n "${FIX_NAO_RODANDO:-}" ]; then echo false; else echo true; fi ;;
  cp)
    src=$2; dest=${3#*:}
    [ -f "$src" ] || exit 1
    mkdir -p "$DOCKER_CTR$(dirname "$dest")"
    cp "$src" "$DOCKER_CTR$dest"
    modo="$(grep -F "$src " "$CHMOD_LOG" 2>/dev/null | tail -n 1 | sed 's/.* //')"
    [ -n "$modo" ] || modo="$(stat -c %a "$src")"
    echo "root $modo" > "$DOCKER_CTR$dest.meta"
    exit 0 ;;
  exec)
    shift; usuario=oracle
    while [ $# -gt 0 ]; do
      case "$1" in
        -u|--user) usuario=$2; shift 2 ;;
        -i|-t|-it|-d) shift ;;
        *) break ;;
      esac
    done
    shift   # nome do container
    comando=${1:-}
    case "$comando" in
      sqlplus)
        mkdir -p "$DOCKER_STDIN_DIR"
        n=$(( $(ls "$DOCKER_STDIN_DIR" 2>/dev/null | grep -c '^stdin') + 1 ))
        cat > "$DOCKER_STDIN_DIR/stdin$n"
        if grep -q '^set heading off feedback off pagesize 0 linesize 300' "$DOCKER_STDIN_DIR/stdin$n"; then cat "$FIX_QOUT"; exit "${FIX_EXIT2:-0}"; fi
        arq="$(grep -m1 '^@/tmp/' "$DOCKER_STDIN_DIR/stdin$n" | sed 's/^@//' | tr -d '\r')"
        if [ -n "$arq" ]; then
          if [ ! -f "$DOCKER_CTR$arq" ]; then echo "SP2-0310: unable to open file \"$arq\""; exit 0; fi
          dono="$(cut -d' ' -f1 "$DOCKER_CTR$arq.meta")"; modo="$(cut -d' ' -f2 "$DOCKER_CTR$arq.meta")"
          if ! eh_root "$usuario" && eh_root "$dono" && [ "$((8#$modo & 4))" = 0 ]; then
            echo "SP2-0310: unable to open file \"$arq\""; exit 0     # sqlplus segue e sai com 0
          fi
        fi
        cat "$FIX_LOG"; exit "${FIX_EXIT1:-0}" ;;
      rm)
        alvo=${!#}; f="$DOCKER_CTR$alvo"
        if [ -e "$f" ]; then
          dono="$(cut -d' ' -f1 "$f.meta")"
          if ! eh_root "$usuario" && eh_root "$dono"; then echo "rm: cannot remove '$alvo': Operation not permitted" >&2; exit 1; fi
          rm -f "$f" "$f.meta"
        fi
        exit 0 ;;
      chown)
        alvo=${!#}; novo=${2%%:*}; f="$DOCKER_CTR$alvo"
        eh_root "$usuario" || { echo "chown: Operation not permitted" >&2; exit 1; }
        [ -e "$f" ] && echo "$novo $(cut -d' ' -f2 "$f.meta")" > "$f.meta"
        exit 0 ;;
      chmod)
        alvo=${!#}; novo=$2; f="$DOCKER_CTR$alvo"
        eh_root "$usuario" || { echo "chmod: Operation not permitted" >&2; exit 1; }
        [ -e "$f" ] && echo "$(cut -d' ' -f1 "$f.meta") $novo" > "$f.meta"
        exit 0 ;;
    esac
    exit 0 ;;
esac
STUB
cat > "$STUBS/curl" <<STUB
#!/usr/bin/env bash
printf '%s' '{"access_token":"tokfalso","value":"$SENHA"}'
STUB
cat > "$STUBS/python3" <<'STUB'
#!/usr/bin/env bash
# achar_python (exigir_ferramentas) pergunta a versão; o script da VM chama python3 -c ...["access_token"] ou ["value"] lendo JSON no stdin
case "$*" in *version_info*) echo 3; exit 0 ;; esac
in="$(cat)"
case "$*" in
  *access_token*) printf '%s\n' "$in" | sed 's/.*"access_token":"\([^"]*\)".*/\1/' ;;
  *) printf '%s\n' "$in" | sed 's/.*"value":"\([^"]*\)".*/\1/' ;;
esac
STUB
chmod +x "$STUBS"/*

# ─── fixtures ────────────────────────────────────────────────────────────────
M2_INI='###################  DEMO S4-DB-02: INICIO  ###################'
M2_FIM='###################  DEMO S4-DB-02: FIM  ###################'
M3_INI='###################  DEMO S4-DB-03: INICIO  ###################'
M3_FIM='###################  DEMO S4-DB-03: FIM  ###################'

gerar_log() { # variáveis: L_ORA_INI L_PAD L_ORA_DEMO L_R3 L_DEMOS L_SENHA L_ORA_FORA
  [ -z "${L_ORA_INI:-}" ] || echo "ORA-00942: table or view does not exist"
  local i
  for ((i = 1; i <= ${L_PAD:-3}; i++)); do echo "=== BLOCO 3: PKG_KURA_LOG criado === (linha de enchimento $i)"; done
  echo "=== BLOCO 7: TRG_AUDITORIA_COBRANCA criada ==="
  [ -z "${L_SENHA:-}" ] || echo "connect KURA/$SENHA@//localhost:1521/XEPDB1"
  echo; echo "$M2_INI"
  echo "ancoras: clinica=100 outra=101 sem_cobranca=102 evento=100"
  [ -n "${L_SEM_RESUMO:-}" ] || echo "RESUMO: 60 OK, 0 FALHOU"
  echo "$M2_FIM"
  if [ "${L_DEMOS:-2}" = 2 ]; then
    echo
    [ -n "${L_SEM_INI3:-}" ] || echo "$M3_INI"
    if [ -n "${L_ORA_DEMO:-}" ]; then
      echo "ORA-06502: PL/SQL: numeric or value error: character string buffer too small"
      echo "ORA-20001: p_id_clinica e obrigatorio"
      echo "ORA-20001: p_id_clinica e obrigatorio"
      echo "ORA-20002: valor invalido"
      echo "ORA-20002: valor invalido"
    fi
    [ -n "${L_SEM_RESUMO:-}" ] || echo "RESUMO: ${L_R3:-70 OK, 0 FALHOU}"
    [ -n "${L_SEM_FIM3:-}" ] || echo "$M3_FIM"
  fi
  [ -z "${L_ORA_FORA:-}" ] || echo "ORA-04063: package body \"KURA.PKG_AUDITORIA\" has errors"
  echo "verificacao OK: 4 packages (spec + body) e TRG_AUDITORIA_COBRANCA VALID, 0 dependente(s) externo(s) recompilado(s) e VALID, 0 erros de compilacao, AUDITORIA_COBRANCA VALID."
  echo "=== FIM DO ARQUIVO $ARQ_INST ==="
}
gerar_log_remover() {
  echo "=== Remocao da trigger e dos packages (so codigo; nenhuma tabela/sequence e tocada) ==="
  echo "removido: TRIGGER TRG_AUDITORIA_COBRANCA"; echo "removido: PACKAGE PKG_AUDITORIA"
  echo "removido: PACKAGE PKG_COBRANCA"; echo "removido: PACKAGE PKG_TRIAGEM"; echo "removido: PACKAGE PKG_KURA_LOG"
  echo "no rows selected"; echo "objetos de dados: 32 tabela(s), 33 sequence(s)"
  [ -z "${L_ORA_FORA:-}" ] || echo "ORA-01031: insufficient privileges"
  echo "=== FIM DO ARQUIVO $ARQ_REM ==="
}
( gerar_log ) > "$FX/ok.log"
( L_ORA_DEMO=1 gerar_log ) > "$FX/ora-demo.log"
( L_ORA_INI=1 L_PAD=300 gerar_log ) > "$FX/ora-inicio-grande.log"
( L_R3="70 OK, 1 FALHOU" gerar_log ) > "$FX/falhou.log"
( L_DEMOS=1 gerar_log ) > "$FX/cortado.log"
( L_SEM_FIM3=1 gerar_log ) > "$FX/sem-fim3.log"
( L_SEM_INI3=1 gerar_log ) > "$FX/sem-ini3.log"
( L_SEM_RESUMO=1 gerar_log ) > "$FX/sem-resumo.log"
( L_R3="70 OK, 0 FALHOU" gerar_log; echo "RESUMO: 5 OK, 2 FALHOU" ) > "$FX/resumo-extra.log"
( L_SENHA=1 gerar_log ) > "$FX/senha.log"
( L_ORA_FORA=1 gerar_log ) > "$FX/ora-fora.log"
( gerar_log_remover ) > "$FX/rem-ok.log"
( L_ORA_FORA=1 gerar_log_remover ) > "$FX/rem-ora.log"
echo "PKGVALIDOS:9" > "$FX/q-ok.txt"
printf 'INVALIDO:VIEW VW_VACINAS_VENCENDO INVALID\nPKGVALIDOS:9\n' > "$FX/q-inv1.txt"
printf 'PKGVALIDOS:8\n' > "$FX/q-pk8.txt"
echo "ORA-01017: invalid username/password; logon denied" > "$FX/q-ora.txt"
echo "RESTANTES:0" > "$FX/qr-ok.txt"
printf 'PKGVALIDOS:9
connected as KURA/%s
' "$SENHA" > "$FX/q-senha.txt"
echo "RESTANTES:1" > "$FX/qr-1.txt"

# SQL de entrada: os arquivos reais do Mastering, se existirem ao lado; senão, sintéticos mínimos
MAST="$RAIZ/../Mastering-Relational-Database/src"
if [ -f "$MAST/$ARQ_INST" ] && [ -f "$MAST/$ARQ_REM" ]; then
  cp "$MAST/$ARQ_INST" "$MAST/$ARQ_REM" "$SQLDIR/"; FONTE_SQL="reais ($MAST)"
else
  printf 'CREATE OR REPLACE PACKAGE BODY PKG_COBRANCA AS\nEND;\n/\nEXIT\n' > "$SQLDIR/$ARQ_INST"
  printf 'DROP TRIGGER TRG_AUDITORIA_COBRANCA;\nEXIT\n' > "$SQLDIR/$ARQ_REM"; FONTE_SQL="sintéticos"
fi
echo "# fixtures de SQL: $FONTE_SQL"

# ─── execução ────────────────────────────────────────────────────────────────
BASE=(PATH="$STUBS:$PATH" KURA_BASE="$T/opt" DOCKER_ARGV="$T/docker.argv" DOCKER_STDIN_DIR="$T/stdin"
      DOCKER_CTR="$T/ctr" CHMOD_LOG="$T/chmod.log"
      AZ_LOG="$T/az.log" AZ_SCRIPT_COPY="$T/az.script" AZ_MODE=msg AZ_MSG_FILE="$T/az.msg"
      FIX_LOG="$FX/ok.log" FIX_QOUT="$FX/q-ok.txt" PYTHONUTF8=1)
reset() { rm -rf "$T/opt" "$T/stdin" "$T/ctr" "$T/docker.argv" "$T/az.log" "$T/az.script" "$T/az.msg" "$T/chmod.log"
          : > "$T/az.log"; : > "$T/docker.argv"; : > "$T/az.msg"; : > "$T/chmod.log"; }
vm_run()     { local s=$1; shift; reset; env "${BASE[@]}" "$@" bash "$s" > "$T/vm.out" 2>&1; VM_RC=$?; }
deploy_run() { local fase=$1; shift; reset; ( cd "$T" && env "${BASE[@]}" DB_PACKAGES_SQL_DIR="$SQLDIR" AZ_MODE=exec "$@" bash "$DEPLOY" "$fase" > "$T/dep.out" 2>&1 ); DEP_RC=$?; }

ultima_linha() { tail -n 1 "$1" | tr -d '\r'; }
ocorrencias()  { grep -cF -- "$2" "$1" || true; }
chamadas_run() { grep -c '^vm run-command' "$T/az.log" || true; }

# Gera (e guarda) os dois scripts de VM pelo gancho de geração do deploy.sh, sem executar nada
gerar_scripts() {
  reset
  ( cd "$T" && env "${BASE[@]}" DB_PACKAGES_SQL_DIR="$SQLDIR" DB_PACKAGES_SALVAR_SCRIPT="$T/vm-instalar.sh" bash "$DEPLOY" db-packages > /dev/null 2>&1 )
  ( cd "$T" && env "${BASE[@]}" DB_PACKAGES_SQL_DIR="$SQLDIR" DB_PACKAGES_SALVAR_SCRIPT="$T/vm-remover.sh" CONFIRMA=sim bash "$DEPLOY" db-packages-remover > /dev/null 2>&1 )
}

echo "== T0: pré-condições"
if bash -n "$DEPLOY"; then ok "bash -n azure/deploy.sh"; else nok "bash -n azure/deploy.sh"; fi
if bash -n "$AQUI/db-packages.test.sh"; then ok "bash -n do próprio teste"; else nok "bash -n do próprio teste"; fi
afirma "o az do PATH de teste é o falso" test "$(env PATH="$STUBS:$PATH" bash -c 'command -v az')" = "$STUBS/az"
gerar_scripts
afirma "script de instalação gerado (gancho DB_PACKAGES_SALVAR_SCRIPT)" test -s "$T/vm-instalar.sh"
afirma "script de remoção gerado" test -s "$T/vm-remover.sh"
afirma "script de instalação < 64 KB (limite do run-command é NÃO VERIFICADO)" test "$(wc -c < "$T/vm-instalar.sh")" -lt 65536
afirma "a senha falsa não está no script enviado ao az (instalar)" test "$(ocorrencias "$T/vm-instalar.sh" "$SENHA")" = 0
AI="$T/vm-instalar.sh"; AR="$T/vm-remover.sh"

echo "== T1: instalação feliz"
vm_run "$AI"
afirma "T1 VM: EXIT=0" test "$VM_RC" = 0
afirma "T1 VM: sentinela é a última linha" test "$(ultima_linha "$T/vm.out")" = "$SENT_I"
afirma "T1 VM: sentinela aparece uma única vez" test "$(grep -c "$SENT_I" "$T/vm.out")" = 1
afirma "T1 VM: saída < 3.500 bytes (o run-command devolve 4.096)" test "$(wc -c < "$T/vm.out")" -lt 3500
afirma "T1 VM: o sqlplus nº 1 foi alimentado (stdin1 existe e traz o connect)" grep -q '^connect ' "$T/stdin/stdin1"
touch "$T/probe"; chmod 600 "$T/probe"
if [ "$(stat -c %a "$T/probe")" = 600 ]; then
  afirma "T1 VM: log do sqlplus gravado com modo 600" test "$(stat -c %a "$T"/opt/logs/db-packages-*.log)" = 600
else
  echo "PULADO: modo 600 do log (este sistema de arquivos ignora chmod; NÃO VERIFICADO aqui, o umask 077 do script cobre na VM)"
fi
afirma "T1 VM: o .sql local foi apagado no fim (trap)" test ! -e "$T/opt/sql/$ARQ_INST"
deploy_run db-packages
afirma "T1 deploy.sh db-packages: EXIT=0" test "$DEP_RC" = 0
afirma "T1 deploy.sh: exatamente 1 vm run-command" test "$(chamadas_run)" = 1
echo "   chamadas à Azure (az falso) neste e2e feliz: $(wc -l < "$T/az.log" | tr -d ' ') no total; $(chamadas_run) run-command; $(grep -c '^account show' "$T/az.log") account show"

echo "== T2: B8-1 — ORA- no início de um log grande, fora da demo, sqlplus EXIT=0"
vm_run "$AI" FIX_LOG="$FX/ora-inicio-grande.log"
afirma "T2 fixture > 8 KB" test "$(wc -c < "$FX/ora-inicio-grande.log")" -gt 8192
afirma "T2 VM: EXIT≠0" test "$VM_RC" != 0
afirma "T2 VM: sem sentinela" test "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T2 VM: ORA_FORA_DEMO=1 no resumo" grep -q '^ORA_FORA_DEMO=1$' "$T/vm.out"
afirma "T2 o ORA- do início NÃO estaria nos últimos 4.096 B do log (o cenário B8-1 existe)" test "$(tail -c 4096 "$FX/ora-inicio-grande.log" | grep -c 'ORA-00942' || true)" = 0
deploy_run db-packages FIX_LOG="$FX/ora-inicio-grande.log" AZ_TAIL=1
afirma "T2 deploy.sh com az devolvendo só os últimos 4.096 B: EXIT≠0" test "$DEP_RC" != 0
printf 'Enable succeeded: \n[stdout]\n%s\n[stderr]\n' "$(tail -c 3900 "$FX/ora-inicio-grande.log")" > "$T/msg-cauda.txt"
reset; cp "$T/msg-cauda.txt" "$T/az.msg"
( cd "$T" && env "${BASE[@]}" DB_PACKAGES_SQL_DIR="$SQLDIR" bash "$DEPLOY" db-packages > "$T/dep.out" 2>&1 ); DEP_RC=$?
afirma "T2 deploy.sh com az devolvendo só a cauda do log (sem o ORA-): EXIT≠0" test "$DEP_RC" != 0

echo "== T3: ORA- só dentro das 2 regiões de demo"
vm_run "$AI" FIX_LOG="$FX/ora-demo.log"
afirma "T3 controle: o log tem 5 ORA- (o detector enxerga 1)" test "$(grep -c 'ORA-' "$FX/ora-demo.log")" = 5
afirma "T3 VM: sucesso" test "$VM_RC" = 0 -a "$(ultima_linha "$T/vm.out")" = "$SENT_I"
afirma "T3 VM: ORA_FORA_DEMO=0" grep -q '^ORA_FORA_DEMO=0$' "$T/vm.out"
vm_run "$AI" FIX_LOG="$FX/ora-fora.log"
afirma "T3b ORA- depois da última demo (fora): falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0

echo "== T4: RESUMO com FALHOU e sqlplus EXIT=166"
vm_run "$AI" FIX_LOG="$FX/falhou.log" FIX_EXIT1=166
afirma "T4 VM: falha (combinado)" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
vm_run "$AI" FIX_EXIT1=166
afirma "T4a só EXIT=166 (log limpo): falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T4a o resumo mostra EXIT_SQLPLUS=166" grep -q '^EXIT_SQLPLUS=166$' "$T/vm.out"
vm_run "$AI" FIX_LOG="$FX/falhou.log"
afirma "T4b só 'RESUMO: 70 OK, 1 FALHOU' (EXIT=0): falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T4b o resumo mostra RESUMOS_FALHOU=1" grep -q 'RESUMOS_FALHOU=1' "$T/vm.out"

echo "== T5: log cortado (1 FIM, 1 RESUMO), sqlplus EXIT=0"
vm_run "$AI" FIX_LOG="$FX/cortado.log"
afirma "T5 VM: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T5 o resumo mostra DEMOS_FECHADAS=1 e RESUMOS_OK=1" grep -qE 'DEMOS_FECHADAS=1|RESUMOS_OK=1' "$T/vm.out"
vm_run "$AI" FIX_LOG="$FX/sem-fim3.log"
afirma "T5b 2 demos abertas, RESUMO 2 OK, mas a 2a nunca fechou (log cortado antes do FIM): falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T5b o resumo mostra DEMOS_FECHADAS=1" grep -q "DEMOS_FECHADAS=1" "$T/vm.out"
vm_run "$AI" FIX_LOG="$FX/sem-ini3.log"
afirma "T5c FIM sem o INICIO correspondente: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T5c o resumo mostra DEMOS_ABERTAS=1" grep -q "DEMOS_ABERTAS=1" "$T/vm.out"
vm_run "$AI" FIX_LOG="$FX/resumo-extra.log"
afirma "T4c 2 RESUMO 0 FALHOU mais uma 3a linha com FALHOU diferente de 0: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T4c o resumo mostra RESUMOS_OK=2 RESUMOS_FALHOU=1" grep -q "RESUMOS_OK=2 RESUMOS_FALHOU=1" "$T/vm.out"
vm_run "$AI" FIX_LOG="$FX/sem-resumo.log"
afirma "T4d demos abertas e fechadas mas NENHUMA linha RESUMO (0 FALHOU, 0 OK): falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T4d o resumo mostra RESUMOS_OK=0 RESUMOS_FALHOU=0" grep -q "RESUMOS_OK=0 RESUMOS_FALHOU=0" "$T/vm.out"

echo "== T6: objetos inválidos / packages válidos ≠ 9 / consulta com ORA-"
vm_run "$AI" FIX_QOUT="$FX/q-inv1.txt"
afirma "T6a INVALIDOS=1: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T6a o resumo mostra INVALIDOS=1" grep -q 'INVALIDOS=1 ' "$T/vm.out"
vm_run "$AI" FIX_QOUT="$FX/q-pk8.txt"
afirma "T6b PACKAGES_VALIDOS=8: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
vm_run "$AI" FIX_QOUT="$FX/q-ora.txt" FIX_EXIT2=1
afirma "T6c consulta de objetos com ORA-: contagem inválida, falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
vm_run "$AI" FIX_QOUT="$FX/q-senha.txt"
afirma "T6d saída da consulta de objetos com a senha (valores corretos): falha, senha não impressa" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0 -a "$(ocorrencias "$T/vm.out" "$SENHA")" = 0

echo "== T7/T8: decisão do deploy.sh pela sentinela exata"
printf 'Enable succeeded: \n[stdout]\ndb-packages modo=instalar\nEXIT_SQLPLUS=0\n[stderr]\n' > "$T/msg7.txt"
reset; deploy_run db-packages AZ_MODE=msg AZ_MSG_FILE="$T/msg7.txt"
afirma "T7 az EXIT=0 com mensagem sem sentinela: deploy.sh EXIT≠0" test "$DEP_RC" != 0
printf 'Enable succeeded: \n[stdout]\nx%s\n[stderr]\n' "$SENT_I" > "$T/msg8.txt"
deploy_run db-packages AZ_MODE=msg AZ_MSG_FILE="$T/msg8.txt"
afirma "T8 'x$SENT_I' (sentinela como parte de outra linha): EXIT≠0" test "$DEP_RC" != 0
printf 'Enable succeeded: \n[stdout]\n%s extra\n[stderr]\n' "$SENT_I" > "$T/msg8b.txt"
deploy_run db-packages AZ_MODE=msg AZ_MSG_FILE="$T/msg8b.txt"
afirma "T8b sentinela seguida de texto na mesma linha: EXIT≠0" test "$DEP_RC" != 0
printf 'Enable succeeded: \n[stdout]\nresumo\n%s\n[stderr]\n' "$SENT_I" > "$T/msg8c.txt"
deploy_run db-packages AZ_MODE=msg AZ_MSG_FILE="$T/msg8c.txt"
afirma "T8c controle positivo: a linha exata é aceita (EXIT=0)" test "$DEP_RC" = 0

echo "== T9: o arquivo da Sprint 3 renomeado para o nome do Packages"
mkdir -p "$T/sql-s3" "$T/sql-s3r"
# (a) sintético COM o marcador positivo dos packages + a linha real do BLOCO 1 da S3: só o DROP TABLE pode recusar
printf "CREATE OR REPLACE PACKAGE BODY PKG_COBRANCA AS END;\n/\nBEGIN EXECUTE IMMEDIATE 'DROP TABLE AUDITORIA_COBRANCA CASCADE CONSTRAINTS PURGE';    EXCEPTION WHEN OTHERS THEN NULL; END;\n" > "$T/sql-s3/$ARQ_INST"
# (b) o arquivo real da S3, se existir ao lado
if [ -f "$MAST/2TDSPF_2026_CodigoSql_Integrantes.sql" ]; then cp "$MAST/2TDSPF_2026_CodigoSql_Integrantes.sql" "$T/sql-s3r/$ARQ_INST"; else cp "$T/sql-s3/$ARQ_INST" "$T/sql-s3r/$ARQ_INST"; fi
afirma "T9 controle: o fixture (a) tem DROP TABLE e o marcador de packages" test "$(grep -ciE 'drop table|package body pkg_cobranca' "$T/sql-s3/$ARQ_INST")" = 2
deploy_run db-packages DB_PACKAGES_SQL_DIR="$T/sql-s3"
afirma "T9 recusa: EXIT≠0" test "$DEP_RC" != 0
afirma "T9 recusa ANTES de qualquer run-command (0 chamadas)" test "$(chamadas_run)" = 0
afirma "T9 a recusa é por DROP TABLE (não pelo marcador ausente)" grep -q 'DROP TABLE' "$T/dep.out"
deploy_run db-packages DB_PACKAGES_SQL_DIR="$T/sql-s3r"
afirma "T9r arquivo real da S3 renomeado: EXIT≠0, 0 run-command, recusa por DROP TABLE" test "$DEP_RC" != 0 -a "$(chamadas_run)" = 0 -a "$(grep -c 'DROP TABLE' "$T/dep.out")" -ge 1
# regressão do flake de SIGPIPE/pipefail: 10 repetições, todas têm de recusar
rec=0; for i in 1 2 3 4 5 6 7 8 9 10; do deploy_run db-packages DB_PACKAGES_SQL_DIR="$T/sql-s3r"; if [ "$DEP_RC" != 0 ] && grep -q "DROP TABLE" "$T/dep.out" && [ "$(chamadas_run)" = 0 ]; then rec=$((rec + 1)); fi; done
afirma "T9r recusa estável: $rec/10 repetições recusadas por DROP TABLE" test "$rec" = 10
deploy_run db-packages DB_PACKAGES_SQL_DIR="$T/nao-existe"
afirma "T9b diretório sem os arquivos: EXIT≠0, 0 run-command, instrução de clonar" test "$DEP_RC" != 0 -a "$(chamadas_run)" = 0 -a "$(grep -c 'git clone' "$T/dep.out")" -ge 1

echo "== T10: remover sem CONFIRMA=sim"
deploy_run db-packages-remover
afirma "T10 recusa: EXIT≠0" test "$DEP_RC" != 0
afirma "T10 0 run-command" test "$(chamadas_run)" = 0
afirma "T10 a mensagem avisa do 503" grep -q '503' "$T/dep.out"

echo "== T11: remover"
deploy_run db-packages-remover CONFIRMA=sim FIX_LOG="$FX/rem-ok.log" FIX_QOUT="$FX/qr-ok.txt"
afirma "T11 remover feliz: deploy.sh EXIT=0" test "$DEP_RC" = 0
vm_run "$AR" FIX_LOG="$FX/rem-ok.log" FIX_QOUT="$FX/qr-ok.txt"
afirma "T11 remover VM: sentinela exata na última linha" test "$(ultima_linha "$T/vm.out")" = "$SENT_R"
afirma "T11 a sentinela do remover não contém a do instalar como linha" test "$(grep -cx "$SENT_I" "$T/vm.out")" = 0
vm_run "$AR" FIX_LOG="$FX/rem-ok.log" FIX_QOUT="$FX/qr-1.txt"
afirma "T11 remover com 1 objeto restante: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_R")" = 0
vm_run "$AR" FIX_LOG="$FX/rem-ora.log" FIX_QOUT="$FX/qr-ok.txt"
afirma "T11 remover com ORA- no log: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_R")" = 0
vm_run "$AR" FIX_LOG="$FX/rem-ok.log" FIX_QOUT="$FX/qr-ok.txt" FIX_EXIT1=1
afirma "T11 remover com sqlplus EXIT≠0: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_R")" = 0

echo "== T12: a senha"
afirma "T12 0 ocorrências no script enviado ao az (instalar)" test "$(ocorrencias "$AI" "$SENHA")" = 0
afirma "T12 0 ocorrências no script enviado ao az (remover)" test "$(ocorrencias "$AR" "$SENHA")" = 0
vm_run "$AI"
afirma "T12 0 ocorrências no argv do docker (instalar)" test "$(ocorrencias "$T/docker.argv" "$SENHA")" = 0
afirma "T12 controle positivo: o canal stdin carregou a senha (>=1 no stdin capturado)" test "$(grep -cF -- "$SENHA" "$T"/stdin/stdin1 || true)" -ge 1
afirma "T12 controle positivo: docker.argv registrou o sqlplus (o grep enxerga argv)" test "$(grep -c 'sqlplus' "$T/docker.argv")" -ge 2
afirma "T12 0 ocorrências na saída da VM" test "$(ocorrencias "$T/vm.out" "$SENHA")" = 0
afirma "T12 0 ocorrências no log gravado" test "$(cat "$T"/opt/logs/*.log | grep -cF -- "$SENHA" || true)" = 0
vm_run "$AI" FIX_LOG="$FX/senha.log"
afirma "T12 log-fixture que contém a senha: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T12 o log foi apagado" test "$(find "$T/opt/logs" -name '*.log' 2>/dev/null | wc -l | tr -d ' ')" = 0
afirma "T12 a senha não foi impressa" test "$(ocorrencias "$T/vm.out" "$SENHA")" = 0
afirma "T12 o resumo diz 'log apagado'" grep -q 'log apagado' "$T/vm.out"

echo "== T13: sha256 do SQL decodificado diferente do esperado"
sed 's/^PKG_SQL_SHA256=.*/PKG_SQL_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' "$AI" > "$T/vm-sha.sh"
afirma "T13 controle: a linha do sha foi trocada" grep -q '^PKG_SQL_SHA256=0000' "$T/vm-sha.sh"
vm_run "$T/vm-sha.sh"
afirma "T13 VM: EXIT≠0, sem sentinela" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T13 falha ANTES do sqlplus (nenhum sqlplus no argv do docker)" test "$(grep -c 'sqlplus' "$T/docker.argv")" = 0
afirma "T13 a mensagem cita o sha256" grep -q 'sha256' "$T/vm.out"

echo "== T14: o script da VM sob /bin/sh e a reexecução em bash"
# shellcheck disable=SC2016  # literal de propósito
afirma "T14 primeira linha = a do bootstrap (reexecuta no bash)" test "$(head -n 1 "$AI")" = '[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"'
if command -v dash >/dev/null 2>&1; then
  reset; env "${BASE[@]}" dash "$AI" > "$T/vm.out" 2>&1; VM_RC=$?
  afirma "T14 dash script: EXIT=0 e sentinela na última linha (reexecutou no bash)" test "$VM_RC" = 0 -a "$(ultima_linha "$T/vm.out")" = "$SENT_I"
  if dash -n "$AI"; then ok "T14 dash -n (sintaxe da 1ª linha em POSIX sh)"; else nok "T14 dash -n"; fi
else
  nok "T14 dash indisponível nesta máquina" "NÃO VERIFICADO sob dash; ver sh abaixo"
fi
reset; env "${BASE[@]}" sh "$AI" > "$T/vm.out" 2>&1; VM_RC=$?
afirma "T14 sh script: EXIT=0 e sentinela na última linha" test "$VM_RC" = 0 -a "$(ultima_linha "$T/vm.out")" = "$SENT_I"

echo "== T15: I-1 — dono e modo do arquivo dentro do container (modelo explícito no docker falso)"
# Controle positivo do MODELO (independe do deploy.sh): docker cp de um arquivo 600 o deixa root:600; o sqlplus como oracle
# não o lê (SP2-0310, EXIT=0); o rm como oracle falha; só root (-u 0) consegue chown/rm. Sem isto o teste abaixo seria circular.
reset
printf 'select 1 from dual;\n' > "$T/modelo.sql"; env "${BASE[@]}" chmod 600 "$T/modelo.sql"
env "${BASE[@]}" docker cp "$T/modelo.sql" "$CONT_FALSO:/tmp/modelo.sql" > /dev/null 2>&1
afirma "T15 modelo: docker cp deixa o arquivo com dono root e modo 600" test "$(cat "$T/ctr/tmp/modelo.sql.meta")" = "root 600"
printf 'connect u/p@x\n@/tmp/modelo.sql\nexit\n' | env "${BASE[@]}" docker exec -i "$CONT_FALSO" sqlplus -s /nolog > "$T/modelo.out" 2>&1
MODELO_RC=$?
afirma "T15 modelo: sqlplus como oracle em root:600 emite SP2-0310 com EXIT=0" test "$MODELO_RC" = 0 -a "$(grep -c 'SP2-0310' "$T/modelo.out")" = 1
env "${BASE[@]}" docker exec "$CONT_FALSO" rm -f /tmp/modelo.sql > /dev/null 2>&1
afirma "T15 modelo: rm como oracle de arquivo root não apaga (EXIT≠0, arquivo continua)" test -e "$T/ctr/tmp/modelo.sql"
env "${BASE[@]}" docker exec -u 0 "$CONT_FALSO" chown oracle: /tmp/modelo.sql > /dev/null 2>&1
printf 'connect u/p@x\n@/tmp/modelo.sql\nexit\n' | env "${BASE[@]}" FIX_LOG="$FX/ok.log" docker exec -i "$CONT_FALSO" sqlplus -s /nolog > "$T/modelo.out" 2>&1
afirma "T15 modelo: depois de chown oracle (como root) o sqlplus lê o arquivo (sem SP2-0310)" test "$(grep -c 'SP2-0310' "$T/modelo.out")" = 0
# Teste do deploy: o caminho feliz nunca pode depender de arquivo no container
vm_run "$AI"
afirma "T15 VM: EXIT=0 e sentinela (o sqlplus real do modelo não deu SP2-0310)" test "$VM_RC" = 0 -a "$(ultima_linha "$T/vm.out")" = "$SENT_I"
afirma "T15 VM: nenhum 'docker cp' foi chamado (o arquivo não vai para o container)" test "$(grep -c '^docker cp' "$T/docker.argv")" = 0
afirma "T15 VM: nenhum arquivo ficou no container" test "$(find "$T/ctr" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0
afirma "T15 VM: stdin do sqlplus nº 1 não usa '@/tmp/' (nada para ler no container)" test "$(grep -c '^@' "$T/stdin/stdin1")" = 0
SQL_SEM_CR="$T/sql-sem-cr.sql"; tr -d '\r' < "$SQLDIR/$ARQ_INST" > "$SQL_SEM_CR"
afirma "T15 VM: o SQL chega íntegro pelo stdin (3 linhas de cabeçalho + o .sql sem CR, byte a byte)" \
  cmp -s <(tail -n +4 "$T/stdin/stdin1" | head -n "$(wc -l < "$SQL_SEM_CR")") "$SQL_SEM_CR"
afirma "T15 VM: a senha chega pelo stdin (controle positivo) e NÃO está no argv do docker" \
  test "$(grep -cF -- "$SENHA" "$T/stdin/stdin1")" -ge 1 -a "$(ocorrencias "$T/docker.argv" "$SENHA")" = 0
afirma "T15 VM: o .sql do host continua apagado no fim e o container não recebeu 'rm' (nada a limpar)" \
  test ! -e "$T/opt/sql/$ARQ_INST" -a "$(grep -c ' rm ' "$T/docker.argv")" = 0
# Mesmo caminho pelo remover
vm_run "$AR" FIX_LOG="$FX/rem-ok.log" FIX_QOUT="$FX/qr-ok.txt"
afirma "T15 remover VM: sentinela, sem docker cp e sem arquivo no container" test "$(ultima_linha "$T/vm.out")" = "$SENT_R" -a "$(grep -c '^docker cp' "$T/docker.argv")" = 0 -a "$(find "$T/ctr" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0

echo "== T16: M-1 — linha 'commit do arquivo'"
GITSQL="$T/sql-git"; mkdir -p "$GITSQL"; cp "$SQLDIR/$ARQ_INST" "$SQLDIR/$ARQ_REM" "$GITSQL/"
( cd "$GITSQL" && git init -q . && git add . && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "fixture" ) > /dev/null 2>&1
HASH_GIT="$(git -C "$(cd "$GITSQL" && pwd)" log -1 --format=%h -- "$ARQ_INST" 2>/dev/null || true)"
afirma "T16 controle: o repositório git temporário tem o commit (hash não vazio)" test -n "$HASH_GIT"
deploy_run db-packages DB_PACKAGES_SQL_DIR="$GITSQL"
afirma "T16 checkout git: a linha mostra o hash do commit ($HASH_GIT)" grep -q "commit do arquivo: $HASH_GIT\$" "$T/dep.out"
deploy_run db-packages
afirma "T16 diretório sem git: a linha mostra (desconhecido), nunca vazio" grep -q 'commit do arquivo: (desconhecido)$' "$T/dep.out"

echo "== T17: M-2 — veredito por demo, em ordem (P1/P2/P5/P8 da G2 e fora de ordem)"
sent_ok() { test "$VM_RC" = 0 -a "$(ultima_linha "$T/vm.out")" = "$SENT_I"; }
sent_no() { test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0; }
# P1/P2: saída real do .sql com PULADO/PULADOS continua aceita
( gerar_log | sed 's/^RESUMO: 70 OK, 0 FALHOU$/PULADO: E.3j (sem cobranca neste schema)\nPULADO: E.3k (sem cobranca neste schema)\nPULADOS: 2\nRESUMO: 68 OK, 0 FALHOU/' ) > "$FX/p1.log"
afirma "T17 P1 controle: a fixture tem PULADOS: 2 e RESUMO: 68 OK" test "$(grep -c '^PULADOS: 2$' "$FX/p1.log")$(grep -c '^RESUMO: 68 OK, 0 FALHOU$' "$FX/p1.log")" = 11
vm_run "$AI" FIX_LOG="$FX/p1.log"
afirma "T17 P1 PULADO + PULADOS: 2 + RESUMO 68 OK: sucesso" sent_ok
( gerar_log | sed 's/^RESUMO: 70 OK, 0 FALHOU$/PULADO: E.3j (x)\nPULADOS: 1\nRESUMO: 70 OK, 0 FALHOU/' ) > "$FX/p2.log"
vm_run "$AI" FIX_LOG="$FX/p2.log"
afirma "T17 P2 PULADO + PULADOS: 1 + RESUMO 70 OK: sucesso" sent_ok
# P5: RESUMO da demo 02 duplicado e demo 03 sem RESUMO (2 RESUMO no log inteiro, mas não 1 por demo)
( gerar_log | awk '{print} /^RESUMO: 60 OK/{print}' | grep -v "RESUMO: 70" ) > "$FX/p5.log"
afirma "T17 P5 controle: o log tem 2 RESUMO, os dois da demo 02" test "$(grep -c '^RESUMO: 60 OK' "$FX/p5.log")$(grep -c '^RESUMO: 70' "$FX/p5.log")" = 20
vm_run "$AI" FIX_LOG="$FX/p5.log"
afirma "T17 P5 RESUMO duplicado na demo 02 e ausente na 03: falha" sent_no
afirma "T17 P5 o resumo mostra SEQUENCIA_DEMOS com desordem" grep -qE 'SEQUENCIA_DEMOS fase=[0-9]/6 desordem=[1-9]' "$T/vm.out"
# P8: FIM da 02 duplicado, demo 03 sem FIM e um ORA- depois (fora do que deveria ser demo)
( gerar_log | awk -v f="$M2_FIM" '{print} $0==f{print}' | grep -vxF "$M3_FIM" | sed "s/^=== FIM DO ARQUIVO/ORA-00942: table or view does not exist\n=== FIM DO ARQUIVO/" ) > "$FX/p8.log"
afirma "T17 P8 controle: 2 FIM (ambos da 02), 2 INICIO, 1 ORA-" test "$(grep -c ': FIM ' "$FX/p8.log")$(grep -c ': INICIO ' "$FX/p8.log")$(grep -c 'ORA-' "$FX/p8.log")" = 221
vm_run "$AI" FIX_LOG="$FX/p8.log"
afirma "T17 P8 FIM duplicado + demo sem FIM escondendo ORA-: falha" sent_no
# ORA- ENTRE as duas demos (depois do FIM da 02, antes do INICIO da 03): fora de região, tem de reprovar
( gerar_log | awk -v f="$M2_FIM" '{print} $0==f{print "ORA-01555: snapshot too old"}' ) > "$FX/entre.log"
afirma "T17 entre-demos controle: 1 ORA- e as contagens globais todas certas (2 INICIO, 2 FIM)" \
  test "$(grep -c 'ORA-' "$FX/entre.log")$(grep -c ': INICIO ' "$FX/entre.log")$(grep -c ': FIM ' "$FX/entre.log")" = 122
vm_run "$AI" FIX_LOG="$FX/entre.log"
afirma "T17 ORA- entre as demos (fase 3): falha" sent_no
afirma "T17 ORA- entre as demos: o resumo mostra ORA_FORA_DEMO=1" grep -q '^ORA_FORA_DEMO=1$' "$T/vm.out"
# Id errado no INICIO (04 e 05 no lugar de 02 e 03; os FIM continuam 02 e 03): contagens globais e fase certas, id errado
( gerar_log | sed "s/^\(#*  DEMO S4-DB-\)02\(: INICIO\)/\104\2/" ) > "$FX/id-errado-a.log"
( gerar_log | sed "s/^\(#*  DEMO S4-DB-\)03\(: INICIO\)/\105\2/" ) > "$FX/id-errado-b.log"
afirma "T17 id errado controle: a.log tem INICIO 04 e 1 INICIO 03; b.log tem INICIO 05 e 1 INICIO 02" \
  test "$(grep -c 'S4-DB-04: INICIO' "$FX/id-errado-a.log")$(grep -c 'S4-DB-03: INICIO' "$FX/id-errado-a.log")$(grep -c 'S4-DB-05: INICIO' "$FX/id-errado-b.log")$(grep -c 'S4-DB-02: INICIO' "$FX/id-errado-b.log")" = 1111
vm_run "$AI" FIX_LOG="$FX/id-errado-a.log"
afirma "T17 INICIO da 1ª demo com id 04 (em vez de 02): falha" sent_no
vm_run "$AI" FIX_LOG="$FX/id-errado-b.log"
afirma "T17 INICIO da 2ª demo com id 05 (em vez de 03): falha" sent_no
# Fora de ordem: bloco da demo 03 inteiro antes do da demo 02 (cada marcador 1x, RESUMO 1x por demo, sem ORA-)
{ echo "=== BLOCO 7: TRG_AUDITORIA_COBRANCA criada ==="; echo "$M3_INI"; echo "RESUMO: 70 OK, 0 FALHOU"; echo "$M3_FIM"
  echo "$M2_INI"; echo "RESUMO: 60 OK, 0 FALHOU"; echo "$M2_FIM"; echo "=== FIM DO ARQUIVO $ARQ_INST ==="; } > "$FX/ordem.log"
afirma "T17 fora de ordem controle: 2 INICIO, 2 FIM, 2 RESUMO 0 FALHOU (as contagens globais antigas passariam)" \
  test "$(grep -c ': INICIO ' "$FX/ordem.log")$(grep -c ': FIM ' "$FX/ordem.log")$(grep -c '^RESUMO: [1-9][0-9]* OK, 0 FALHOU$' "$FX/ordem.log")" = 222
vm_run "$AI" FIX_LOG="$FX/ordem.log"
afirma "T17 demo 03 antes da 02: falha" sent_no
# ORA- dentro de região bem formada continua perdoado (T3 também cobre); controle da máquina de estados
vm_run "$AI" FIX_LOG="$FX/ora-demo.log"
afirma "T17 ORA- dentro das duas regiões bem formadas: sucesso" sent_ok

echo "== T18: M-3 — SP2-, ORA_Q e ec_q da consulta (sondas P12/P14/P15 da G2)"
( gerar_log | sed 's/^=== FIM DO ARQUIVO/SP2-0734: unknown command\n=== FIM DO ARQUIVO/' ) > "$FX/p12.log"
vm_run "$AI" FIX_LOG="$FX/p12.log"
afirma "T18 P12 SP2- fora da demo num log completo: falha" sent_no
afirma "T18 P12 o resumo mostra ORA_FORA_DEMO=1" grep -q '^ORA_FORA_DEMO=1$' "$T/vm.out"
printf 'ORA-04068: existing state of packages has been discarded\nPKGVALIDOS:9\n' > "$FX/q-ora9.txt"
vm_run "$AI" FIX_QOUT="$FX/q-ora9.txt"
afirma "T18 P14 consulta com ORA- mas PKGVALIDOS:9 e EXIT=0: falha (o ORA_Q da consulta)" sent_no
vm_run "$AI" FIX_EXIT2=1
afirma "T18 P15 consulta com EXIT=1 e PKGVALIDOS:9, sem ORA-: falha (o ec_q da consulta)" sent_no
vm_run "$AI"
afirma "T18 controle: o mesmo log e a mesma consulta sem o defeito: sucesso" sent_ok

echo "== extras"
vm_run "$AI" FIX_NAO_RODANDO=1
afirma "container parado: falha com mensagem, sem sqlplus" test "$VM_RC" != 0 -a "$(grep -c 'sqlplus' "$T/docker.argv")" = 0
afirma "o texto de uma sentinela não aparece em nenhuma linha de falha" test "$(grep -c 'KURA_DB_PACKAGES' "$T/vm.out")" = 0
# âncora dos marcadores: os fixtures têm de ser os do .sql real (anti-circularidade)
if [ -f "$MAST/$ARQ_INST" ]; then
  for m in "$M2_INI" "$M2_FIM" "$M3_INI" "$M3_FIM"; do
    afirma "marcador do fixture existe no .sql real: ${m:20:26}" test "$(grep -cF -- "PROMPT $m" "$MAST/$ARQ_INST")" = 1
  done
  afirma "o .sql real emite 'RESUMO: ' duas vezes (DBMS_OUTPUT)" test "$(grep -c "PUT_LINE('RESUMO: '" "$MAST/$ARQ_INST")" = 2
else
  echo "PULADO: âncora dos marcadores (Mastering-Relational-Database não está ao lado)"
fi

# Para a revisão/ShellCheck dos scripts da VM gerados (nada é executado): SALVAR_SCRIPTS_EM=<pasta> bash azure/tests/db-packages.test.sh
if [ -n "${SALVAR_SCRIPTS_EM:-}" ]; then mkdir -p "$SALVAR_SCRIPTS_EM"; cp "$AI" "$AR" "$SALVAR_SCRIPTS_EM/"; fi

echo
echo "RESUMO: $OKN OK, $FALN FALHOU"
[ "$FALN" = 0 ]
