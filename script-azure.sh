#!/usr/bin/env bash
# =============================================================================
# KURA · script-azure.sh
# Provisiona VM Linux na Azure, instala Docker, Git, nano e executa a stack
# FIAP Challenge 2026 — DevOps Tools & Cloud Computing
#
# USO LOCAL:
#   chmod +x script-azure.sh
#   az login
#   ./script-azure.sh
#
# RUBRICA:
#   1.1 ✅ Provisiona VM Linux (Ubuntu 22.04)
#   1.2 ✅ Abre portas: 8080, 8081, 8000, 9092, 22
#   1.3 ✅ Instala Docker (Engine + Compose Plugin)
#   1.4 ✅ Instala Git e nano
#   2.x ✅ Executa aplicação em background (detached)
#   2.2 ✅ Cria usuário sem privilégios administrativos (kura-app)
# =============================================================================

set -euo pipefail   # Aborta em qualquer erro, variável não definida ou pipe falho

# ─── CONFIGURAÇÕES ────────────────────────────────────────────────────────────
RESOURCE_GROUP="kura-rg-fiap2026"
LOCATION="brazilsouth"
VM_NAME="kura-vm-fiap2026"
VM_SIZE="Standard_B2s"          # 2 vCPUs, 4 GB RAM — suficiente para a stack
VM_IMAGE="Ubuntu2204"
ADMIN_USER="kuraadmin"          # Usuário administrador da VM (não-root)
REPO_URL="https://github.com/FelipeFerrete/kura-infra.git"  # ajuste para o seu repo
APP_DIR="/opt/kura"

# Portas da aplicação
PORTS=(22 8080 8081 8000 9092)

echo "========================================================"
echo " KURA · FIAP Challenge 2026 · Azure Provisioning Script"
echo "========================================================"

# ─── PASSO 1.1: Resource Group ───────────────────────────────────────────────
echo ""
echo "[1/8] Criando Resource Group: $RESOURCE_GROUP em $LOCATION..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output table

# ─── PASSO 1.1: Máquina Virtual Linux ────────────────────────────────────────
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

# Captura o IP público para uso posterior
VM_PUBLIC_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --show-details \
    --query "publicIps" \
    --output tsv)

echo "  ✅ VM criada com IP público: $VM_PUBLIC_IP"

# ─── PASSO 1.2: Abertura de Portas ───────────────────────────────────────────
echo ""
echo "[3/8] Abrindo portas necessárias: ${PORTS[*]}..."

for PORT in "${PORTS[@]}"; do
    echo "  → Abrindo porta $PORT..."
    az vm open-port \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --port "$PORT" \
        --priority $((200 + PORT)) \
        --output none
done

echo "  ✅ Portas abertas: ${PORTS[*]}"

# ─── PASSO 1.3 + 1.4: Instalação de Docker, Git e nano via cloud-init ────────
# Envia um script shell para ser executado DENTRO da VM via SSH.
# A opção --command-id RunShellScript é a forma oficial do Azure CLI.
echo ""
echo "[4/8] Instalando Docker Engine, Git e nano na VM..."

az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts '
        set -euo pipefail

        echo ">>> Atualizando pacotes do sistema..."
        apt-get update -y
        apt-get upgrade -y

        # ─── Pré-requisitos do Docker ─────────────────────────────────────────
        echo ">>> Instalando dependências do Docker..."
        apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release \
            git \
            nano \
            htop

        # ─── Docker Engine (repositório oficial) ─────────────────────────────
        echo ">>> Adicionando repositório oficial do Docker..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # ─── Habilita Docker no boot ──────────────────────────────────────────
        systemctl enable docker
        systemctl start docker

        echo ">>> Versões instaladas:"
        docker --version
        docker compose version
        git --version
        nano --version | head -1
        echo "✅ Instalação concluída."
    ' \
    --output table

echo "  ✅ Docker, Git e nano instalados."

# ─── PASSO 2.2: Criação de usuário sem privilégios administrativos ────────────
echo ""
echo "[5/8] Criando usuário de aplicação sem privilégios (kura-app)..."

az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
        set -euo pipefail

        # Cria usuário 'kura-app' sem senha de login e sem sudo
        if id kura-app &>/dev/null; then
            echo 'Usuário kura-app já existe. Pulando criação.'
        else
            useradd --system \
                    --uid 1000 \
                    --gid 1000 \
                    --shell /bin/bash \
                    --create-home \
                    --home-dir /home/kura-app \
                    kura-app || true

            # Adiciona kura-app ao grupo docker para executar containers
            usermod -aG docker kura-app
            echo '✅ Usuário kura-app criado e adicionado ao grupo docker.'
        fi

        # Cria diretório da aplicação e cede ownership ao usuário kura-app
        mkdir -p $APP_DIR
        chown kura-app:kura-app $APP_DIR
    " \
    --output table

echo "  ✅ Usuário kura-app configurado."

# ─── PASSO: Clone do repositório ─────────────────────────────────────────────
echo ""
echo "[6/8] Clonando repositório da aplicação na VM..."

az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
        set -euo pipefail

        # Executa o clone como o usuário kura-app
        if [ -d '$APP_DIR/.git' ]; then
            echo 'Repositório já existe. Fazendo git pull...'
            sudo -u kura-app git -C $APP_DIR pull --rebase
        else
            sudo -u kura-app git clone $REPO_URL $APP_DIR
            echo '✅ Repositório clonado em $APP_DIR'
        fi

        ls -la $APP_DIR
    " \
    --output table

echo "  ✅ Repositório clonado."

# ─── PASSO 2.1: Iniciar aplicação em background (detached) ───────────────────
echo ""
echo "[7/8] Iniciando a stack Kura com Docker Compose em background..."

az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "
        set -euo pipefail
        cd $APP_DIR

        # RUBRICA 2.1 — Executa em background (detached mode)
        # RUBRICA 2.2 — Roda como kura-app (não-root)
        sudo -u kura-app docker compose up --build -d

        echo ''
        echo '✅ Stack iniciada. Status dos containers:'
        docker compose ps
    " \
    --output table

echo "  ✅ Aplicação rodando em background."

# ─── SUMÁRIO FINAL ────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " ✅ PROVISIONAMENTO CONCLUÍDO"
echo "========================================================"
echo ""
echo "  VM:           $VM_NAME"
echo "  IP Público:   $VM_PUBLIC_IP"
echo "  Região:       $LOCATION"
echo ""
echo "  URLs de Acesso:"
echo "  ├── .NET API (Clínica):  http://$VM_PUBLIC_IP:8080/swagger"
echo "  ├── .NET Health:         http://$VM_PUBLIC_IP:8080/health"
echo "  ├── Java API (Tutor):    http://$VM_PUBLIC_IP:8081/api/swagger-ui/index.html"
echo "  ├── Luna IA (Python):    http://$VM_PUBLIC_IP:8000/docs"
echo "  └── Oracle DB:           $VM_PUBLIC_IP:9092 (XEPDB1)"
echo ""
echo "  SSH:  ssh $ADMIN_USER@$VM_PUBLIC_IP"
echo ""
echo "  Para ver logs:     ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose logs -f'"
echo "  Para parar:        ssh $ADMIN_USER@$VM_PUBLIC_IP 'cd $APP_DIR && docker compose down'"
echo ""
echo "⚠️  LEMBRETE: Delete a VM após a avaliação para evitar cobranças!"
echo "   az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "========================================================"

# ─── PASSO 4 (RUBRICA): Ao final da apresentação, delete a VM ────────────────
# DESCOMENTE as linhas abaixo SOMENTE após a avaliação do professor.
# echo ""
# echo "[8/8] Deletando Resource Group e todos os recursos..."
# az group delete \
#     --name "$RESOURCE_GROUP" \
#     --yes \
#     --no-wait
# echo "  ✅ Resource Group '$RESOURCE_GROUP' enviado para deleção."
