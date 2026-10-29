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
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_ARGV"
case "$1" in
  inspect) if [ -n "${FIX_NAO_RODANDO:-}" ]; then echo false; else echo true; fi ;;
  cp) mkdir -p "$DOCKER_STDIN_DIR"; [ -f "$2" ] && cp "$2" "$DOCKER_STDIN_DIR/copiado.sql"; exit 0 ;;
  exec)
    if printf ' %s ' "$@" | grep -q ' sqlplus '; then
      mkdir -p "$DOCKER_STDIN_DIR"
      n=$(( $(ls "$DOCKER_STDIN_DIR" 2>/dev/null | grep -c '^stdin') + 1 ))
      cat > "$DOCKER_STDIN_DIR/stdin$n"
      if grep -q '^@/tmp/' "$DOCKER_STDIN_DIR/stdin$n"; then cat "$FIX_LOG"; exit "${FIX_EXIT1:-0}"
      else cat "$FIX_QOUT"; exit "${FIX_EXIT2:-0}"; fi
    fi
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
  echo "RESUMO: 60 OK, 0 FALHOU"
  echo "$M2_FIM"
  if [ "${L_DEMOS:-2}" = 2 ]; then
    echo; echo "$M3_INI"
    if [ -n "${L_ORA_DEMO:-}" ]; then
      echo "ORA-06502: PL/SQL: numeric or value error: character string buffer too small"
      echo "ORA-20001: p_id_clinica e obrigatorio"
      echo "ORA-20001: p_id_clinica e obrigatorio"
      echo "ORA-20002: valor invalido"
      echo "ORA-20002: valor invalido"
    fi
    echo "RESUMO: ${L_R3:-70 OK, 0 FALHOU}"
    echo "$M3_FIM"
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
( L_SENHA=1 gerar_log ) > "$FX/senha.log"
( L_ORA_FORA=1 gerar_log ) > "$FX/ora-fora.log"
( gerar_log_remover ) > "$FX/rem-ok.log"
( L_ORA_FORA=1 gerar_log_remover ) > "$FX/rem-ora.log"
echo "PKGVALIDOS:9" > "$FX/q-ok.txt"
printf 'INVALIDO:VIEW VW_VACINAS_VENCENDO INVALID\nPKGVALIDOS:9\n' > "$FX/q-inv1.txt"
printf 'PKGVALIDOS:8\n' > "$FX/q-pk8.txt"
echo "ORA-01017: invalid username/password; logon denied" > "$FX/q-ora.txt"
echo "RESTANTES:0" > "$FX/qr-ok.txt"
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
      AZ_LOG="$T/az.log" AZ_SCRIPT_COPY="$T/az.script" AZ_MODE=msg AZ_MSG_FILE="$T/az.msg"
      FIX_LOG="$FX/ok.log" FIX_QOUT="$FX/q-ok.txt" PYTHONUTF8=1)
reset() { rm -rf "$T/opt" "$T/stdin" "$T/docker.argv" "$T/az.log" "$T/az.script" "$T/az.msg"; : > "$T/az.log"; : > "$T/docker.argv"; : > "$T/az.msg"; }
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
afirma "T1 VM: o SQL decodificado chegou ao container (docker cp)" test -s "$T/stdin/copiado.sql"
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

echo "== T6: objetos inválidos / packages válidos ≠ 9 / consulta com ORA-"
vm_run "$AI" FIX_QOUT="$FX/q-inv1.txt"
afirma "T6a INVALIDOS=1: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
afirma "T6a o resumo mostra INVALIDOS=1" grep -q 'INVALIDOS=1 ' "$T/vm.out"
vm_run "$AI" FIX_QOUT="$FX/q-pk8.txt"
afirma "T6b PACKAGES_VALIDOS=8: falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0
vm_run "$AI" FIX_QOUT="$FX/q-ora.txt" FIX_EXIT2=1
afirma "T6c consulta de objetos com ORA-: contagem inválida, falha" test "$VM_RC" != 0 -a "$(ocorrencias "$T/vm.out" "$SENT_I")" = 0

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
mkdir -p "$T/sql-s3"
if [ -f "$MAST/2TDSPF_2026_CodigoSql_Integrantes.sql" ]; then
  cp "$MAST/2TDSPF_2026_CodigoSql_Integrantes.sql" "$T/sql-s3/$ARQ_INST"; FONTE_S3="arquivo real da S3"
else
  printf "CREATE OR REPLACE PACKAGE BODY PKG_COBRANCA AS END;\n/\nBEGIN EXECUTE IMMEDIATE 'DROP TABLE AUDITORIA_COBRANCA CASCADE CONSTRAINTS PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;\n" > "$T/sql-s3/$ARQ_INST"; FONTE_S3="sintético"
fi
echo "   (fixture da S3: $FONTE_S3)"
afirma "T9 controle: o fixture tem DROP TABLE" grep -qi 'drop table' "$T/sql-s3/$ARQ_INST"
deploy_run db-packages DB_PACKAGES_SQL_DIR="$T/sql-s3"
afirma "T9 recusa: EXIT≠0" test "$DEP_RC" != 0
afirma "T9 recusa ANTES de qualquer run-command (0 chamadas)" test "$(chamadas_run)" = 0
afirma "T9 a mensagem diz 'recusado'" grep -q 'recusado' "$T/dep.out"
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

echo
echo "RESUMO: $OKN OK, $FALN FALHOU"
[ "$FALN" = 0 ]
