# KURA — Infraestrutura Cloud & DevOps

> **FIAP Challenge 2026 · 2TDS · Disciplina: DevOps Tools & Cloud Computing**
> Parceiro: **Clyvo Vet**

---

## Equip

| Membro | Função |
|---|---|
| **Felipe Ferrete** *(líder técnico)* | .NET · IoT/IA |
| **Nikolas Brisola** | Java · Backend Tutor |
| **Guilherme Sola** | Mobile Tutor · UX |
| **Gustavo Bosak** | Mobile Clínica · QA |
| **Clayton** | DevOps · BD |

---

## Índice

1. [Descrição do Projeto](#1-descrição-do-projeto)
2. [Benefícios para o Negócio](#2-benefícios-para-o-negócio)
3. [Arquitetura Macro (Desenho)](#3-arquitetura-macro)
4. [Rotas da API](#4-rotas-da-api)
5. [Como Instalar e Executar (How To)](#5-como-instalar-e-executar)
6. [Docker Compose — Detalhamento](#6-docker-compose--detalhamento)
7. [Scripts do Azure CLI](#7-scripts-do-azure-cli)

---

## 1. Descrição do Projeto

O **KURA** é um sistema de gestão veterinária digital desenvolvido para a **Clyvo Vet**, com foco em **continuidade do cuidado e engajamento na jornada de saúde do pet**.

O sistema resolve um problema central da veterinária moderna: a jornada do pet é **episódica e reativa**. O tutor só interage com a clínica em momentos de crise. O Kura transforma isso em uma experiência **contínua, preventiva e inteligente**.

### Microsserviços que compõem o sistema

| Serviço | Tecnologia | Responsabilidade |
|---|---|---|
| **kura-api** (.NET) | ASP.NET Core 10 + EF Core | Backend clínico: veterinários, pets, eventos clínicos, IoT, dashboard |
| **kura-tutor** (Java) | Spring Boot 3.2 + Java 21 | Portal do tutor: auth JWT, agendamentos, timeline, LGPD |
| **luna-ai** (Python) | FastAPI + YOLOv8n + MobileNetV3 | IA de triagem, lembretes de vacinas via WhatsApp, identificação de raça por foto |
| **oracle-db** | Oracle XE 21c (slim) | Banco de dados relacional único compartilhado pelos serviços |

---

## 2. Benefícios para o Negócio

### Para o Tutor (responsável pelo pet)
- **Lembretes automáticos** de vacinas via WhatsApp antes do vencimento, eliminando o esquecimento
- **Portal digital** para acompanhar a timeline de saúde, agendamentos e exames do pet
- **Identificação de raça por foto** com recomendações preventivas personalizadas para a raça

### Para a Clínica Veterinária
- **Dashboard operacional** com alertas de temperatura (IoT/ESP32), agenda do dia e métricas
- **Triagem inteligente** via IA: tutores que enviam mensagens recebem classificação automática do nível de urgência antes de falar com o veterinário
- **Maior recorrência e fidelização**: o sistema mantém contato proativo entre consultas, aumentando o LTV

### Para a Clyvo Vet (plataforma B2B)
- **Diferencial competitivo** com stack de IA própria (visão computacional + NLP)
- **Dados longitudinais** de saúde por raça viabilizam analytics preditivos e expansão de produto
- **Modelo de receita recorrente**: SaaS mensal por clínica

---

## 3. Arquitetura Macro

```
                         ┌─────────────────────────────────────────────────────┐
                         │           AZURE VM (Ubuntu 22.04 · Standard_B2s)    │
                         │                                                     │
                         │  ┌──────────────┐     ┌──────────────────────────┐  │
  Veterinário/           │  │  kura-api    │     │      kura-tutor          │  │
  Gestor da Clínica ─────┼─►│  (.NET 10)   │     │   (Java 21 / Spring)     │◄─┼── Tutor (App Mobile)
  :8080/swagger          │  │  porta 8080  │     │      porta 8081          │  │   :8081/swagger
                         │  └──────┬───────┘     └────────────┬─────────────┘  │
                         │         │                           │                │
  Luna IA               │  ┌──────▼───────────────────────────▼──────────────┐ │
  (Python / FastAPI) ───┼─►│                   oracle-db                      │ │
  porta 8000            │  │          gvenzl/oracle-xe:21-slim                 │ │
                         │  │         porta 9092 (ext) · 1521 (int)            │ │
  Twilio WhatsApp ───────┼─►│         Named Volume: kura_oracle_data           │ │
  (lembretes/triagem)   │  └──────────────────────────────────────────────────┘ │
                         │                                                     │
  Dispositivos IoT       │  ┌──────────────────────────────────────────────────┐ │
  (ESP32 sensores) ──────┼─►│                Docker Network: kura_network      │ │
                         │  │          (bridge — serviços se comunicam         │ │
                         │  │           por nome: oracle-db, kura-api, etc.)   │ │
                         │  └──────────────────────────────────────────────────┘ │
                         └─────────────────────────────────────────────────────┘

  Fluxo de dados Luna → .NET:
  Tutor WhatsApp → Twilio → POST /webhook/twilio/whatsapp (Luna)
    → GET /api/v1/tutores/telefone/{nr}  [.NET kura-api]
    → TriageEngine.classificar()         [local Luna]
    → POST /api/v1/luna/triage           [.NET kura-api]
    → TwilioGateway.enviar()             [resposta ao tutor]
```

> Fonte versionável e editável deste diagrama: [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) (Mermaid, renderiza no GitHub)
> e [`docs/arquitetura-kura.drawio`](docs/arquitetura-kura.drawio) (editável em [draw.io](https://app.diagrams.net/)).
> Versão para entrega: [`docs/Kura_Docs_DevOps.pdf`](docs/Kura_Docs_DevOps.pdf).

---

## 4. Rotas da API

### .NET API — Backend Clínica (`http://<VM_IP>:8080`)

Documentação interativa completa: `http://<VM_IP>:8080/swagger`

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| `POST` | `/api/v1/auth/login` | Pública | Login → retorna JWT |
| `POST` | `/api/v1/auth/register-clinica` | Pública | Cadastro de clínica |
| `GET` | `/api/v1/tutores` | JWT | Lista tutores (filtros: nome, CPF) |
| `POST` | `/api/v1/tutores` | JWT | Cria tutor + gera invite UUID |
| `GET` | `/api/v1/pets/{id}/timeline` | JWT | Timeline de atendimentos |
| `POST` | `/api/v1/eventos-clinicos/vacinas` | JWT | Registra vacina (atômico) |
| `POST` | `/api/v1/agendamentos` | JWT | Cria agendamento |
| `PATCH` | `/api/v1/agendamentos/{id}/status` | JWT | Atualiza status (otimistic lock) |
| `GET` | `/api/v1/dashboard/hoje` | JWT | Resumo do dia |
| `POST` | `/api/v1/iot/leituras` | API Key | Ingere leitura de temperatura (IoT) |
| `GET` | `/health` | Pública | Health check |
| `GET` | `/metrics` | Pública | Métricas SLO |

### Java API — Backend Tutor (`http://<VM_IP>:8081`)

Documentação: `http://<VM_IP>:8081/api/swagger-ui/index.html`

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| `POST` | `/api/auth/register-invite` | Pública | Onboarding por token de convite |
| `POST` | `/api/auth/login` | Pública | Login → access + refresh token |
| `POST` | `/api/auth/refresh` | Pública | Rotação do refresh token |
| `GET` | `/api/tutores/{id}/pets` | JWT | Pets do tutor (paginado) |
| `GET` | `/api/pets/{id}/timeline` | JWT | Linha do tempo do pet |
| `POST` | `/api/agendamentos` | JWT | Cria agendamento |
| `PUT` | `/api/agendamentos/{id}` | JWT | Atualiza (requer nrVersion) |
| `POST` | `/api/tutores/{id}/consentimentos` | JWT | Registra aceite LGPD |
| `GET` | `/api/tutores/{id}/lgpd/relatorio` | JWT | Relatório LGPD (art. 18) |

### Luna IA — Python FastAPI (`http://<VM_IP>:8000`)

Documentação: `http://<VM_IP>:8000/docs`

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| `POST` | `/webhook/twilio/whatsapp` | Twilio Signature | Recebe mensagens do tutor |
| `GET` | `/health` | Pública | Health check |

---

## 5. Como Instalar e Executar

### Pré-requisitos locais

| Ferramenta | Versão mínima |
|---|---|
| Azure CLI | 2.50+ |
| Git | 2.x |
| Conta Azure | crédito ativo |

### Passo 1 — Clone do repositório de infraestrutura

```bash
git clone https://github.com/FelipeFerrete/kura-infra.git
cd kura-infra
```

A estrutura de diretórios esperada é:

```
kura-infra/
├── docker-compose.yml      ← orquestra todos os serviços
├── script-azure.sh         ← provisiona a VM na Azure
├── .env.example            ← template de variáveis de ambiente
├── README.md
├── dotnet-backend/         ← código-fonte da .NET API (submodule ou clone)
├── java-backend/           ← código-fonte da Java API  (submodule ou clone)
└── luna-ia/                ← código-fonte do Luna IA   (submodule ou clone)
```

### Passo 2 — Configure as variáveis de ambiente

```bash
cp .env.example .env
nano .env   # preencha as credenciais
```

Variáveis obrigatórias no `.env`:

```dotenv
# ─── Oracle ───────────────────────────────────────────────────────────────────
ORACLE_SYS_PASSWORD=KuraFiap@2026        # senha do SYS/SYSTEM
ORACLE_APP_USER=RM562999                  # usuário de aplicação
ORACLE_APP_PASSWORD=fiap2026             # senha do usuário de aplicação

# ─── .NET ─────────────────────────────────────────────────────────────────────
DOTNET_JWT_KEY=kura-api-secret-key-fiap-2026-clyvovet
IOT_API_KEY=kura-iot-device-key-2026
LUNA_API_KEY=kura-luna-integration-key-2026

# ─── Java ─────────────────────────────────────────────────────────────────────
JAVA_JWT_SECRET=    # mín 64 bytes: openssl rand -base64 64

# ─── Twilio (Luna) ────────────────────────────────────────────────────────────
TWILIO_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_TOKEN=your_twilio_auth_token
TWILIO_FROM_NUMBER=+14155238886
WEBHOOK_PUBLIC_URL=https://xxxx.ngrok.io/webhook/twilio/whatsapp
```

### Passo 3 — Execute na Azure (produção)

```bash
# Login na Azure
az login

# Provisiona VM, instala dependências e sobe a stack
chmod +x script-azure.sh
./script-azure.sh
```

O script retorna o IP público da VM ao final. Aguarde ~5 minutos para o Oracle XE inicializar.

### Execução local (desenvolvimento)

```bash
# Build e start de todos os containers em background
docker compose up --build -d

# Verificar status
docker compose ps

# Acompanhar logs em tempo real
docker compose logs -f

# Parar tudo
docker compose down

# Parar e remover volume (CUIDADO: apaga dados do banco)
docker compose down -v
```

### Verificação de saúde dos serviços

```bash
# .NET API
curl http://localhost:8080/health

# Java API
curl http://localhost:8081/api/actuator/health

# Luna IA
curl http://localhost:8000/health
```

### Teste rápido de CRUD — .NET API

```bash
# 1. Login e captura do token
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"dsEmail":"admin@clyvovet.com","dsSenha":"Senha123!"}' \
  | jq -r '.token')

# 2. Listar tutores (GET)
curl -H "Authorization: Bearer $TOKEN" \
     http://localhost:8080/api/v1/tutores

# 3. Criar pet (POST)
curl -X POST http://localhost:8080/api/v1/pets \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"nmPet":"Rex","tutorId":1,"especieId":1,"racaId":2,"dtNascimento":"2020-03-15"}'

# 4. Atualizar pet (PUT)
curl -X PUT http://localhost:8080/api/v1/pets/1 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"nmPet":"Rex Atualizado"}'

# 5. Remover pet (DELETE)
curl -X DELETE http://localhost:8080/api/v1/pets/1 \
  -H "Authorization: Bearer $TOKEN"
```

---

## 6. Docker Compose — Detalhamento

### Topologia dos containers

```
docker-compose.yml
│
├── oracle-db         (gvenzl/oracle-xe:21-slim)
│   ├── porta:  9092:1521
│   ├── volume: kura_oracle_data → /opt/oracle/oradata  [NAMED VOLUME]
│   └── health: sqlplus SELECT 1
│
├── kura-storage-init (mesma imagem do kura-api · roda uma vez, como root)
│   ├── cria STORAGE_BASE_PATH dentro do volume kura_storage_documentos e
│   │   entrega a posse ao usuário 'kura' — um named volume novo nasce
│   │   root:root, o que quebraria a escrita do receituário sem este passo
│   └── volume: kura_storage_documentos → STORAGE_BASE_PATH  [NAMED VOLUME]
│
├── kura-api          (./dotnet-backend · Dockerfile multistage)
│   ├── porta:  8080:8080
│   ├── user:   kura (não-root, uid definido no Dockerfile)
│   ├── volume: kura_storage_documentos → STORAGE_BASE_PATH (PDFs de receituário)
│   └── depends_on: oracle-db (healthy) + kura-storage-init (completed)
│
├── kura-tutor        (./java-backend · Dockerfile multistage)
│   ├── porta:  8081:8081
│   ├── user:   spring (uid=1000, definido no Dockerfile)
│   ├── depends_on: oracle-db (healthy)
│   └── Flyway (baseline-version 0) cria o schema completo (V1→V12+) do zero
│       contra o volume vazio na primeira subida — não há mais bootstrap SQL
│       manual em `db/init/`. Isso foi possível porque a V9 e a V12 do Flyway
│       passaram a criar, respectivamente, as 11 tabelas .NET que faltavam e
│       as 20 sequences que o EF Core exige.
│
└── luna-ai           (./luna-ia · Dockerfile python:3.12-slim)
    ├── porta:  8000:8000
    ├── user:   "1000:1000" (forçado via compose — Dockerfile não define USER)
    └── depends_on: kura-api (healthy) + oracle-db (healthy)
```

### Segurança: usuários não-root (RUBRICA 2.2)

| Container | Como é garantido | UID |
|---|---|---|
| `kura-api` (.NET) | `USER kura` no Dockerfile (Stage runtime) | não-root |
| `kura-tutor` (Java) | `USER spring` no Dockerfile (uid=1000) | 1000 |
| `luna-ai` (Python) | `user: "1000:1000"` no docker-compose.yml | 1000 |
| `oracle-db` | Imagem `gvenzl/oracle-xe` usa usuário `oracle` internamente | não-root |

### Volume nomeado (RUBRICA 2.3)

```yaml
volumes:
  kura-oracle-data:        # volume nomeado — persiste dados entre restarts
    name: kura_oracle_data

services:
  oracle-db:
    volumes:
      - kura-oracle-data:/opt/oracle/oradata
```

O volume `kura_oracle_data` é gerenciado pelo Docker e **não é apagado** com `docker compose down`. Para apagá-lo intencionalmente: `docker compose down -v`.

```yaml
volumes:
  kura-storage-documentos:  # volume nomeado — PDFs de receituário (Documento.DsCaminho)
    name: kura_storage_documentos

services:
  kura-api:
    volumes:
      - kura-storage-documentos:${STORAGE_BASE_PATH:-/data/kura/receituarios}
```

Mesma regra do `kura_oracle_data`: sobrevive a `docker compose down`, só some com `down -v`. Sem este volume, os PDFs viveriam só na camada gravável do container `kura-api` e sumiriam a cada `down`/recreate — não precisa de `-v` para isso acontecer, basta o container ser recriado.

### Rede interna

Todos os serviços compartilham a rede `kura_network` (bridge). A comunicação entre serviços usa o **nome do serviço como hostname**:

- Luna → `.NET`: `http://kura-api:8080`
- `.NET` → Luna: `http://luna-ai:8000` (transcrição de áudio → draft SOAP, `Luna__BaseUrl`)
- Java → Oracle: `jdbc:oracle:thin:@//oracle-db:1521/XEPDB1`
- .NET → Oracle: `Data Source=oracle-db:1521/XEPDB1`

### Variáveis de ambiente por serviço

**oracle-db:**
```
ORACLE_PASSWORD        → senha SYS/SYSTEM
APP_USER               → usuário de aplicação (criado automaticamente)
APP_USER_PASSWORD      → senha do usuário de aplicação
```

**kura-api (.NET):**
```
ASPNETCORE_ENVIRONMENT          → Production
ConnectionStrings__DefaultConnection → aponta para oracle-db:1521/XEPDB1
Jwt__Key                        → chave secreta JWT
IoT__ApiKey                     → chave dos dispositivos ESP32
Luna__ApiKey                    → chave da Luna IA (Luna → .NET, TriagemLuna/tutores)
Daily__ApiKey                   → chave da Daily.co (FEAT-01 teleconsulta). Sem ela —
                                   ou com valor inválido — DailyService aplica fallback
                                   de link manual em vez de falhar; env: DAILY_API_KEY
Luna__BaseUrl                   → URL da Luna vista pelo .NET (FEAT-02 transcrição de
                                   áudio → draft SOAP), default http://luna-ai:8000;
                                   env: LUNA_BASE_URL
Luna__InboundApiKey             → mesma chave do LUNA_INBOUND_API_KEY do serviço luna-ai
                                   (não duplicar literal) — vai no header X-API-Key que
                                   a Luna valida em POST /transcricao; env: LUNA_INBOUND_API_KEY
Storage__BasePath               → pasta onde o kura-api grava PDFs de receituário
                                   (FEAT-03, Documento.DsCaminho); montada como named
                                   volume (kura_storage_documentos) para persistir entre
                                   `down`/recreate; env: STORAGE_BASE_PATH
```

Binding confirmado em `dotnet-backend/src/Kura.Api/Extensions/ServiceCollectionExtensions.cs`
(`configuration["Daily:ApiKey"]`, `configuration["Luna:BaseUrl"]`, `configuration["Luna:InboundApiKey"]`)
e `dotnet-backend/src/Kura.Application/Services/ReceituarioPdfService.cs`
(`configuration["Storage:BasePath"]`) — o binding padrão do .NET usa `__` como separador de
hierarquia em variável de ambiente (`Daily__ApiKey`), não `:`; o `.env`/`.env.example` deste
repo usa nomes com `_` simples (`DAILY_API_KEY` etc.), mapeados para as chaves `__` no
`docker-compose.yml`, seguindo o mesmo padrão já usado por `Jwt__Key`/`IoT__ApiKey`/`Luna__ApiKey`.

**kura-tutor (Java):**
```
SPRING_PROFILES_ACTIVE → prod
DB_URL                 → jdbc:oracle:thin:@//oracle-db:1521/XEPDB1
DB_USERNAME            → usuário Oracle
DB_PASSWORD            → senha Oracle
JWT_SECRET             → mínimo 64 bytes
```

**luna-ai (Python):**
```
ORACLE_DSN             → oracle-db:1521/XEPDB1
KURA_API_BASE_URL      → http://kura-api:8080
TWILIO_SID/TOKEN       → credenciais WhatsApp Sandbox
YOLO_WEIGHTS_PATH      → caminho dos pesos YOLOv8n
```

---

## 7. Scripts do Azure CLI

O arquivo `script-azure.sh` executa **em sequência** as seguintes tarefas:

### Tarefa 1 — Provisiona a VM Linux (RUBRICA 1.1)

```bash
az group create \
    --name "kura-rg-fiap2026" \
    --location "brazilsouth"

az vm create \
    --resource-group "kura-rg-fiap2026" \
    --name "kura-vm-fiap2026" \
    --image Ubuntu2204 \
    --size Standard_B2s \
    --admin-username "kuraadmin" \
    --generate-ssh-keys \
    --public-ip-sku Standard
```

### Tarefa 1.2 — Abre as portas (RUBRICA 1.2)

```bash
# Portas abertas: 22 (SSH), 8080 (.NET), 8081 (Java), 8000 (Luna), 9092 (Oracle)
az vm open-port --resource-group "kura-rg-fiap2026" --name "kura-vm-fiap2026" --port 22
az vm open-port --resource-group "kura-rg-fiap2026" --name "kura-vm-fiap2026" --port 8080
az vm open-port --resource-group "kura-rg-fiap2026" --name "kura-vm-fiap2026" --port 8081
az vm open-port --resource-group "kura-rg-fiap2026" --name "kura-vm-fiap2026" --port 8000
az vm open-port --resource-group "kura-rg-fiap2026" --name "kura-vm-fiap2026" --port 9092
```

### Tarefa 1.3 + 1.4 — Instala Docker, Git e nano (RUBRICA 1.3 e 1.4)

```bash
az vm run-command invoke \
    --resource-group "kura-rg-fiap2026" \
    --name "kura-vm-fiap2026" \
    --command-id RunShellScript \
    --scripts '
        apt-get update -y
        apt-get install -y git nano curl gnupg ca-certificates lsb-release
        # Adiciona repositório oficial Docker
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable docker && systemctl start docker
    '
```

### Tarefa 2.1 — Executa em background (RUBRICA 2.1)

```bash
az vm run-command invoke \
    --resource-group "kura-rg-fiap2026" \
    --name "kura-vm-fiap2026" \
    --command-id RunShellScript \
    --scripts 'cd /opt/kura && docker compose up --build -d'
```

### Tarefa 2.2 — Usuário sem privilégios (RUBRICA 2.2)

```bash
az vm run-command invoke \
    --resource-group "kura-rg-fiap2026" \
    --name "kura-vm-fiap2026" \
    --command-id RunShellScript \
    --scripts '
        useradd --system --uid 1000 --shell /bin/bash --create-home kura-app
        usermod -aG docker kura-app
        chown -R kura-app:kura-app /opt/kura
    '
```

### Tarefa 4 (OBRIGATÓRIO) — Deletar a VM após avaliação (RUBRICA 04)

```bash
# Execute APÓS a avaliação do professor para evitar cobranças
az group delete \
    --name "kura-rg-fiap2026" \
    --yes \
    --no-wait
```

> **Evidência de deleção:** Tire um print do portal Azure ou do output do comando `az group show --name kura-rg-fiap2026` retornando erro 404 após a deleção.

---

## Links

| Recurso | URL |
|---|---|
| Repositório Infra | `https://github.com/KURA-Clyvo/DevOps-Cloud` |
| Repositório .NET | `https://github.com/KURA-Clyvo/backend-clinica-dotnet` |
| Repositório Java | `https://github.com/KURA-Clyvo/backend-tutor-java` |
| Repositório Luna IA | `https://github.com/KURA-Clyvo/kura-luna-ai` |
| Diagrama de arquitetura (Mermaid) | [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) |
| Diagrama de arquitetura (draw.io) | [`docs/arquitetura-kura.drawio`](docs/arquitetura-kura.drawio) |
| Vídeo YouTube | *(inserir link após gravação)* |

---

*Projeto acadêmico — FIAP Challenge 2026 · Parceiro: Clyvo Vet*
