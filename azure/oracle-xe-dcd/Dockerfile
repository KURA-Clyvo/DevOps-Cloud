# =============================================================================
# KURA · Oracle XE + Dead Connection Detection (DCD)
#
# Camada fina sobre a imagem ESPELHADA no ACR (kura/oracle-xe:<base>), com uma
# única diferença: `SQLNET.EXPIRE_TIME` no sqlnet.ora do servidor.
#
# ─── POR QUE ESTA IMAGEM EXISTE ──────────────────────────────────────────────
# Os três clientes alcançam o Oracle pelo FQDN público (não há VNet comum entre
# container groups), e fluxo TCP ocioso nesse caminho é descartado quando a
# tradução de NAT expira — sem RST e sem FIN para nenhuma das pontas. Isso tem
# DOIS efeitos, e os pools das aplicações só resolvem o primeiro:
#
#   1. O cliente fica com socket morto no pool (ORA-12537 / ORA-17008 na próxima
#      requisição). Tratado no lado cliente — ver a seção "POR QUE OS POOLS
#      PRECISAM DE AJUSTE AQUI" em azure/deploy.sh.
#
#   2. O SERVIDOR não fica sabendo de nada. O processo servidor continua
#      esperando num socket que não existe mais, e a sessão correspondente
#      permanece aberta para sempre. Cada conexão que morre assim deixa uma
#      SESSÃO ÓRFÃ, que nada recolhe — o kernel só sondaria o socket com
#      SO_KEEPALIVE, que o Oracle ativa justamente quando DCD está configurado.
#      Num XE, onde o limite de sessões/processos é baixo, isso acumula até
#      novas conexões serem recusadas.
#
# `SQLNET.EXPIRE_TIME=<minutos>` resolve o item 2: o servidor sonda cada sessão
# ociosa nesse intervalo e derruba a que não responde, liberando processo e
# sessão. Com o valor abaixo da janela de NAT (4 min no default da plataforma),
# a própria sonda ainda mantém a tradução viva — então também reforça o item 1,
# para os três clientes de uma vez, sem depender da configuração de cada pool.
#
# ─── POR QUE IMAGEM DERIVADA, E NÃO VOLUME OU OVERRIDE DE COMANDO ────────────
# O ACI só monta volume `azureFile` (SMB): pendurar o script de inicialização do
# banco num share acrescentaria uma dependência de SMB ao BOOT do Oracle, que é
# o ponto mais sensível desta infra (sem volume para os datafiles, um boot que
# falha é banco perdido). Sobrescrever `command` no manifesto exigiria repetir o
# entrypoint da imagem base, que não é contrato nosso e muda sem aviso. A camada
# derivada mantém o entrypoint original intacto e deixa a configuração visível e
# versionada na tag.
#
# A base vem do ACR, não do Docker Hub: o espelhamento (passo [3/10]) continua
# sendo o único ponto que fala com o Docker Hub, e o build acontece DENTRO do
# ACR (`az acr build`), então nem a base nem o resultado passam pela máquina de
# quem roda o deploy.
#
# ─── ONDE FICA O sqlnet.ora (verificado na imagem, não suposto) ──────────────
# NÃO é $ORACLE_HOME/network/admin. O 21c usa read-only Oracle home, e nesta
# imagem o diretório de rede efetivo é $ORACLE_BASE_HOME/network/admin
# (= /opt/oracle/homes/OraDBHome21cXE/network/admin), onde a base já traz
# listener.ora, tnsnames.ora e um sqlnet.ora com DISABLE_OOB/BREAK_POLL_SKIP.
# $ORACLE_HOME/network/admin existe, mas só com shrept.lst — escrever lá produz
# um build que passa e um banco SEM DCD, silenciosamente. Por isso o RUN abaixo
# procura o diretório que REALMENTE contém um sqlnet.ora e falha se não achar:
# se uma base futura mudar o layout, o erro aparece no deploy, não em produção.
#
# Esse arquivo não fica parado onde está: no primeiro start, o
# container-entrypoint.sh move listener.ora/tnsnames.ora/sqlnet.ora para
# $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/ e devolve symlinks no lugar
# (funções create_dbconfig/sym_link_dbconfig). O `mv` preserva o conteúdo e o
# symlink aponta para o arquivo movido, então a linha acrescentada aqui continua
# valendo depois do boot.
# =============================================================================

# Sem default de propósito: a base tem de vir do ACR (kura/oracle-xe:<base>), e
# um default apontando para o Docker Hub contornaria o espelhamento justamente
# no caso em que ele mais importa. O aviso "InvalidDefaultArgInFrom" do builder é
# esperado e inofensivo — azure/deploy.sh sempre passa --build-arg IMAGEM_BASE.
ARG IMAGEM_BASE
FROM ${IMAGEM_BASE}

# Minutos entre as sondas de DCD. Entra na tag da imagem
# (kura/oracle-xe:<base>-dcd<minutos>) de propósito: mudar o valor produz tag
# nova, e o ACI puxa imagem nova em vez de reaproveitar a que já conhece.
ARG DCD_MINUTOS=2

# Roda com o usuário da imagem base (`oracle`), dono de ORACLE_BASE_HOME — não há
# `USER root` aqui para não alterar o usuário efetivo do container.
#
# Precedência na escolha do diretório: TNS_ADMIN (se definido, ganha de tudo no
# lado servidor), depois $ORACLE_BASE_HOME/network/admin (layout read-only home,
# o caso desta base), depois $ORACLE_HOME/network/admin (layout antigo). Em todos
# os casos exige um sqlnet.ora JÁ EXISTENTE: é ele que prova que o diretório é o
# que o Oracle lê.
#
# Se a base já trouxer um SQLNET.EXPIRE_TIME, a linha é SUBSTITUÍDA — em
# sqlnet.ora a primeira ocorrência de um parâmetro é a que vale, então
# acrescentar outra não teria efeito. Isso também torna o build idempotente sobre
# uma imagem que já passou por aqui.
RUN set -eu; \
    dir=""; \
    for candidato in ${TNS_ADMIN:-} ${ORACLE_BASE_HOME:-}/network/admin ${ORACLE_HOME:-}/network/admin; do \
        if [ -f "$candidato/sqlnet.ora" ]; then dir="$candidato"; break; fi; \
    done; \
    if [ -z "$dir" ]; then \
        echo "ERRO: nenhum sqlnet.ora encontrado nos caminhos conhecidos desta imagem." >&2; \
        echo "  TNS_ADMIN=[${TNS_ADMIN:-}]  ORACLE_BASE_HOME=[${ORACLE_BASE_HOME:-}]  ORACLE_HOME=[${ORACLE_HOME:-}]" >&2; \
        echo "  O layout da base mudou. Localize o arquivo e ajuste este Dockerfile:" >&2; \
        echo "    docker run --rm --entrypoint bash <base> -c 'find / -name sqlnet.ora 2>/dev/null'" >&2; \
        exit 1; \
    fi; \
    if grep -Eqi '^[[:space:]]*SQLNET\.EXPIRE_TIME' "$dir/sqlnet.ora"; then \
        sed -i -E "s/^[[:space:]]*SQLNET\.EXPIRE_TIME[[:space:]]*=.*/SQLNET.EXPIRE_TIME=${DCD_MINUTOS}/I" "$dir/sqlnet.ora"; \
    else \
        printf '\n# KURA: dead connection detection — ver azure/oracle-xe-dcd/Dockerfile\nSQLNET.EXPIRE_TIME=%s\n' "${DCD_MINUTOS}" >> "$dir/sqlnet.ora"; \
    fi; \
    echo "--- $dir/sqlnet.ora ---"; \
    cat "$dir/sqlnet.ora"
