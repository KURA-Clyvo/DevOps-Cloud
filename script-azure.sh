#!/usr/bin/env bash
# =============================================================================
# KURA · script-azure.sh — FIAP Challenge 2026
# DevOps Tools & Cloud Computing
#
# CORREÇÕES v4:
#   - Sentinel STEP_OK detecta falha real no script remoto
#   - Sem | jq (mascara exit codes) — usa python3 nativo do Cloud Shell
#   - #!/bin/bash + set -euo pipefail em CADA bloco remoto
#   - useradd sem --uid hardcoded (evita conflito com UID do admin Azure)
#   - docker compose roda como root (daemon exige; rubrica 2.2 = USER nos Dockerfiles)
# =============================================================================
set -eu

# ─── HELPER: executa script remoto e verifica falha real ─────────────────────
# Az run-command retorna exit 0 mesmo quando o script remoto falha.
# Solução: script remoto termina com "STEP_OK"; local verifica a presença.
run_remote() {
    local DESCRICAO="$1"
    local SCRIPT="$2"

    echo "  >>> Executando: $DESCRICAO"

    local OUTPUT
    OUTPUT=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "$SCRIPT" \
        --output json 2>&1) || {
        echo "  ❌ Azure CLI falhou para: $DESCRICAO"
        echo "$OUTPUT"
        exit 1
    }

    # Exibe stdout/stderr do script remoto (sem jq, usa python3)
    echo "$OUTPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('value', []):
        print(item.get('message', ''))
except Exception as e:
    print('(erro ao parsear output:', e, ')')
" 2>/dev/null || echo "$OUTPUT"

    # Verifica sentinel — sem ele, o script remoto falhou
    if ! echo "$OUTPUT" | grep -q "STEP_OK"; then
        echo ""
        echo "  ❌ FALHA REAL em: $DESCRICAO"
        echo "  O script remoto nao imprimiu STEP_OK — interrompendo."
        exit 1
    fi

    echo "  ✅ $DESCRICAO — OK"
    echo ""
}

# ─── VALIDAÇÃO LOCAL ──────────────────────────────────────────────────────────
if [ ! -f ".env" ]; then
    echo "❌ ERRO: .env nao encontrado!"
    exit 1
fi

ENV_B64=$(base64 -w 0 .env)
echo "✅ .env carregado e codificado."

# ─── CONFIGURAÇÕES ────────────────────────────────────────────────────────────
RESOURCE_GROUP="kura-rg-fiap2026"
LOCATION="centralus"
VM_NAME="kura-vm-fiap2026"
VM_SIZE="Standard_D2s_v3"
VM_IMAGE="Ubuntu2204"
ADMIN_USER="kuraadmin"
REPO_URL="https://github.com/KURA-Clyvo/DevOps-Cloud"
APP_DIR="/opt/kura"
PORTS=(22 8080 8081 8000 9092)

echo "========================================================"
echo " KURA · FIAP Challenge 2026 · Azure Provisioning Script"
echo "========================================================"

# ─── [1/8] Resource Group — RUBRICA 1.1 ──────────────────────────────────────
echo ""
echo "[1/8] Criando Resource Group: $RESOURCE_GROUP em $LOCATION..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table
echo "  ✅ Resource Group criado."

# ─── [2/8] VM Linux — RUBRICA 1.1 ────────────────────────────────────────────
echo ""
echo "[2/8] Provisionando VM Linux ($VM_IMAGE · $VM_SIZE)..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --output table

VM_PUBLIC_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --show-details \
    --query "publicIps" \
    --output tsv)
echo "  ✅ VM criada: $VM_PUBLIC_IP"

# ─── [3/8] Portas — RUBRICA 1.2 ──────────────────────────────────────────────
echo ""
echo "[3/8] Abrindo portas: ${PORTS[*]}..."
PRIORITY=1010
for PORT in "${PORTS[@]}"; do
    echo "  → Porta $PORT (prioridade $PRIORITY)..."
    az vm open-port \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --port "$PORT" \
        --priority "$PRIORITY" \
        --output none
    PRIORITY=$((PRIORITY + 10))
done
echo "  ✅ Portas abertas: ${PORTS[*]}"

echo ""
echo "⏳ Aguardando 60s para o agente da VM estabilizar..."
sleep 60

# ─── [4/8] Docker + Git + nano — RUBRICA 1.3 e 1.4 ──────────────────────────
echo ""
echo "[4/8] Instalando Docker Engine, Git e nano..."
run_remote "Instalar Docker Git nano" '#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Atualizando pacotes ==="
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git nano htop

echo "=== Adicionando repositorio Docker ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "=== Instalando Docker ==="
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "=== Versoes ==="
docker --version
docker compose version
echo "STEP_OK"
'

# ─── [5/8] Usuário kura-app — RUBRICA 2.2 ────────────────────────────────────
# Sem --uid hardcoded: evita conflito com UIDs ja alocados na VM Azure.
# Rubrica 2.2 = usuario nao-root existe no host E nos containers (USER kura/spring).
echo "[5/8] Criando usuario nao-root (kura-app)..."
run_remote "Criar usuario kura-app" '#!/bin/bash
set -euo pipefail

echo "=== Verificando usuario kura-app ==="
if id kura-app &>/dev/null; then
    echo "Usuario kura-app ja existe:"
    id kura-app
else
    useradd \
        --shell /bin/bash \
        --create-home \
        --home-dir /home/kura-app \
        kura-app
    echo "Usuario kura-app criado:"
    id kura-app
fi

usermod -aG docker kura-app
echo "=== Usuario final ==="
id kura-app
echo "STEP_OK"
'

# ─── [6/8] Clone + injecao do .env ───────────────────────────────────────────
echo "[6/8] Clonando repositorio e injetando .env..."
run_remote "Clone repositorio" "#!/bin/bash
set -euo pipefail

echo '=== Preparando diretorio ==='
mkdir -p $APP_DIR

if [ -d '$APP_DIR/.git' ]; then
    echo 'Repo ja existe, atualizando...'
    git -C $APP_DIR pull --recurse-submodules
else
    echo 'Clonando repositorio...'
    git clone --recurse-submodules $REPO_URL $APP_DIR
fi

echo '=== Injetando .env ==='
echo '$ENV_B64' | base64 --decode > $APP_DIR/.env
chmod 600 $APP_DIR/.env
chown -R kura-app:kura-app $APP_DIR

echo '=== Estrutura final ==='
ls -la $APP_DIR
echo 'STEP_OK'
"

# ─── [7/8] Docker Compose up — RUBRICA 2.1 ───────────────────────────────────
# Docker Compose roda como root no host (daemon exige privilegio root).
# Usuarios nao-root estao DENTRO dos containers via Dockerfile:
#   kura-api  → USER kura   (nao-root)
#   kura-tutor → USER spring (uid=1000, nao-root)
#   luna-ai   → user: 1000:1000 (compose)
echo "[7/8] Subindo stack Docker Compose em background..."
run_remote "Docker Compose up" "#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/usr/local/bin:\$PATH

echo '=== Iniciando containers ==='
cd $APP_DIR
docker compose up --build -d

echo '=== Status dos containers ==='
docker compose ps
echo 'STEP_OK'
"

# ─── [8/8] Loop de verificacao real ──────────────────────────────────────────
echo "[8/8] Verificando saude dos servicos..."
echo "      Oracle XE leva ate 5 min para registrar o XEPDB1."
echo "      Aguardando (max 10 min | 20 x 30s)..."
echo ""

DOTNET_OK=false

for i in $(seq 1 20); do
    echo "  ⏳ Tentativa $i/20 — aguardando 30s..."
    sleep 30

    # Status interno dos containers
    CONTAINER_STATUS=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "#!/bin/bash
export PATH=/usr/bin:/usr/local/bin:\$PATH
cd $APP_DIR 2>/dev/null || { echo 'APP_DIR nao encontrado'; exit 0; }
docker compose ps 2>/dev/null || echo 'compose nao iniciado'
" --output json 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('value', []):
        print(item.get('message', ''))
except:
    pass
" 2>/dev/null || echo "  (falha ao consultar VM)")

    echo "$CONTAINER_STATUS"
    echo ""

    # Health checks de FORA da VM — prova real de acessibilidade publica
    DOTNET_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://$VM_PUBLIC_IP:8080/health" 2>/dev/null || echo "000")
    JAVA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://$VM_PUBLIC_IP:8081/api/actuator/health" 2>/dev/null || echo "000")
    LUNA_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "http://$VM_PUBLIC_IP:8000/health" 2>/dev/null || echo "000")

    echo "  Health checks externos:"
    echo "  ├── .NET  :8080 → HTTP $DOTNET_HTTP"
    echo "  ├── Java  :8081 → HTTP $JAVA_HTTP"
    echo "  └── Luna  :8000 → HTTP $LUNA_HTTP"
    echo ""

    if [ "$DOTNET_HTTP" = "200" ]; then
        DOTNET_OK=true
        echo "  ✅ Stack operacional!"
        break
    fi
done

# ─── SUMARIO FINAL ────────────────────────────────────────────────────────────
echo "========================================================"
echo " PROVISIONAMENTO CONCLUIDO"
echo "========================================================"
echo ""
echo "  VM:     $VM_NAME"
echo "  IP:     $VM_PUBLIC_IP"
echo "  Regiao: $LOCATION"
echo ""
echo "  .NET swagger: http://$VM_PUBLIC_IP:8080/swagger"
echo "  .NET health:  http://$VM_PUBLIC_IP:8080/health"
echo "  Java swagger: http://$VM_PUBLIC_IP:8081/api/swagger-ui/index.html"
echo "  Luna docs:    http://$VM_PUBLIC_IP:8000/docs"
echo "  Oracle:       $VM_PUBLIC_IP:9092 (XEPDB1)"
echo ""
echo "  SSH:    ssh $ADMIN_USER@$VM_PUBLIC_IP"
echo "  Logs:   ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs -f'"
echo "  Status: ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose ps'"
echo ""

if [ "$DOTNET_OK" = false ]; then
    echo "⚠️  .NET nao respondeu em 10 min. Verifique manualmente:"
    echo "  ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs kura-api --tail=50'"
    echo ""
fi

echo "⚠️  RUBRICA 4: Delete a VM apos a avaliacao!"
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "========================================================"

# ─── RUBRICA 4: descomente apos a avaliacao ───────────────────────────────────
# az group delete --name "$RESOURCE_GROUP" --yes --no-wait