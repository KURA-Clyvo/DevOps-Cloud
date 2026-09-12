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
7. [Deploy em ACR/ACI (produção)](#7-deploy-em-acraci-produção)
8. [Segredos no Azure Key Vault](#8-segredos-no-azure-key-vault)

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

O sistema roda em **dois ambientes**, com os mesmos quatro serviços e as mesmas portas.
O que muda é o isolamento entre eles — e, por consequência, como um encontra o outro.

**Produção — Azure Container Instances (`azure/deploy.sh`)**

```
   ┌───────────────────────── Azure · kura-prod-rg · eastus2 ──────────────────────────┐
   │                                                                                   │
   │  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────────────────┐   │
   │  │  Key Vault       │   │ Container        │   │ Storage Account              │   │
   │  │  kura-prod-kv    │   │ Registry         │   │ · share de backup (dumps)    │   │
   │  │  11 segredos     │   │ kuraprodacr      │   │ · share de documentos (PDFs) │   │
   │  └────────┬─────────┘   └────────┬─────────┘   └───────────▲──────────────────┘   │
   │           │ secureValue          │ imagem                  │ expdp / PDFs         │
   │  ┌────────▼──────────────────────▼─────────────────────────┴──────────────────┐   │
   │  │            Container Instances — um container group por serviço            │   │
   │  │                                                                            │   │
   │  │   kura-prod-clinica-api      kura-prod-tutor-api      kura-prod-luna-ai     │   │
   │  │        :8080                     :8081                    :8000            │   │
   │  │      (.NET 10)              (Java 21 · Flyway)        (Python/FastAPI)      │   │
   │  │           └──────────────────────┬┴───────────────────────┘                │   │
   │  │                      ┌───────────▼──────────────┐                          │   │
   │  │                      │  kura-prod-oracle-db     │                          │   │
   │  │                      │  :1521 · disco EFÊMERO   │                          │   │
   │  └──────────────────────┴──────────────────────────┴──────────────────────────┘   │
   └───────────────────────────────────────────────────────────────────────────────────┘

   Não há rede compartilhada entre container groups. Cada serviço tem seu FQDN público
   <nome>.eastus2.azurecontainer.io, e é por ele que os outros o alcançam.
```

**Desenvolvimento local — `docker compose`**

```
   ┌────────────── Máquina do desenvolvedor · rede kura_network (bridge) ──────────────┐
   │   kura-api :8080   ·   kura-tutor :8081   ·   luna-ai :8000                       │
   │                            └──────┬───────────────┘                               │
   │                   oracle-db  9092 (host) → 1521 (container)                       │
   │                   named volume kura_oracle_data                                   │
   │   Serviços se resolvem por NOME (oracle-db, kura-api, luna-ai).                   │
   └───────────────────────────────────────────────────────────────────────────────────┘
```

  Fluxo de dados Luna → .NET:

```
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

### .NET API — Backend Clínica (`http://kura-prod-clinica-api.eastus2.azurecontainer.io:8080`)

Documentação interativa completa: `http://kura-prod-clinica-api.eastus2.azurecontainer.io:8080/swagger`

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

### Java API — Backend Tutor (`http://kura-prod-tutor-api.eastus2.azurecontainer.io:8081`)

Documentação: `http://kura-prod-tutor-api.eastus2.azurecontainer.io:8081/api/swagger-ui/index.html`

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

### Luna IA — Python FastAPI (`http://kura-prod-luna-ai.eastus2.azurecontainer.io:8000`)

Documentação: `http://kura-prod-luna-ai.eastus2.azurecontainer.io:8000/docs`

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| `POST` | `/webhook/twilio/whatsapp` | Twilio Signature | Recebe mensagens do tutor |
| `GET` | `/health` | Pública | Health check |

---

## 5. Como Instalar e Executar

### Pré-requisitos locais

| Ferramenta | Versão mínima | Necessária para |
|---|---|---|
| Git | 2.x | clone + submódulos |
| Docker | 24+ | build das imagens e execução local |
| Azure CLI | 2.50+ | deploy em ACR/ACI |
| Python | 3.8+ | usado pelos scripts em `azure/` para renderizar os manifestos |
| Conta Azure | crédito ativo | — |
| Conta Docker Hub | gratuita | **só no primeiro deploy de um ACR novo** — espelhar a imagem do Oracle (§7). Há alternativa sem conta. |

### Passo 1 — Clone do repositório de infraestrutura

```bash
git clone --recurse-submodules https://github.com/KURA-Clyvo/DevOps-Cloud.git
cd DevOps-Cloud
```

Se já tiver clonado sem `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

O conteúdo dos submódulos é **obrigatório para buildar** as imagens. Para apenas
reimplantar uma tag que já está no ACR (`--skip-build`), o clone raso basta — o
`deploy.sh` lê o commit fixado direto da árvore deste repositório.

Estrutura do repositório:

```
DevOps-Cloud/
├── docker-compose.yml        ← ambiente de desenvolvimento local
├── azure/
│   ├── deploy.sh             ← provisiona e implanta tudo em ACR/ACI
│   ├── verify.sh             ← valida cofre, ACR e os 4 serviços por FQDN público
│   ├── backup-db.sh          ← dump lógico do Oracle (Data Pump) para o Azure Files
│   ├── restore-db.sh         ← restaura um dump
│   ├── teardown.sh           ← apaga o ambiente inteiro (operação excepcional)
│   └── aci-*.yaml            ← manifestos de container group (templates)
├── scripts/
│   ├── smoke-contratos.sh    ← smoke de contrato app → API
│   └── seed-demo.sh          ← popula uma clínica de demonstração
├── docs/                     ← arquitetura (Mermaid, draw.io, PDF)
├── .env.example              ← template de variáveis de ambiente
├── dotnet-backend/           ← submódulo · backend-clinica-dotnet
├── java-backend/             ← submódulo · backend-tutor-java
└── luna-ia/                  ← submódulo · kura-luna-ai
```

### Passo 2 — Configure as variáveis de ambiente

```bash
cp .env.example .env
nano .env   # preencha as credenciais
```

⚠️ **Este passo não é mais opcional.** Desde a TASK-39, o `docker-compose.yml` usa a
sintaxe `${VAR:?mensagem}` para as 7 chaves de autenticação abaixo — sem elas
preenchidas no `.env`, `docker compose up`/`docker compose config` **aborta com erro
explicativo** em vez de subir com um segredo padrão. Isso é intencional: um
`docker-compose.yml` público não pode ter default funcional de JWT/senha/API key.

Variáveis **obrigatórias** no `.env` (sem valor → `docker compose` falha ao subir):

```dotenv
# ─── Oracle ───────────────────────────────────────────────────────────────────
ORACLE_SYS_PASSWORD=      # openssl rand -base64 32
ORACLE_APP_USER=RM562999  # identificador de schema FIAP, não é segredo — pode manter
ORACLE_APP_PASSWORD=      # openssl rand -base64 32

# ─── .NET ─────────────────────────────────────────────────────────────────────
DOTNET_JWT_KEY=       # openssl rand -base64 48
IOT_API_KEY=          # openssl rand -base64 32
LUNA_API_KEY=         # openssl rand -base64 32
LUNA_INBOUND_API_KEY= # openssl rand -base64 32

# ─── Java ─────────────────────────────────────────────────────────────────────
JAVA_JWT_SECRET=    # mín 64 bytes: openssl rand -base64 64

# ─── Twilio (Luna) ────────────────────────────────────────────────────────────
TWILIO_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_TOKEN=your_twilio_auth_token
TWILIO_FROM_NUMBER=+14155238886
WEBHOOK_PUBLIC_URL=https://xxxx.ngrok.io/webhook/twilio/whatsapp
```

> 🔴 **Segredo queimado:** até a TASK-39, o `docker-compose.yml` deste repositório
> público definia defaults *funcionais* (não placeholders) para `DOTNET_JWT_KEY`,
> `JAVA_JWT_SECRET`, `ORACLE_APP_PASSWORD`, `ORACLE_SYS_PASSWORD`, `IOT_API_KEY`,
> `LUNA_API_KEY` e `LUNA_INBOUND_API_KEY` — esses valores continuam no histórico git
> e devem ser considerados comprometidos. Qualquer ambiente (local ou Azure) que já
> tenha subido usando os defaults antigos precisa trocar as 7 chaves por valores
> novos antes de ser considerado seguro.

### Passo 3 — Execute na Azure (produção)

```bash
az login
chmod +x azure/*.sh
./azure/deploy.sh
```

O `deploy.sh` cria o resource group, o Key Vault (com todos os segredos), o ACR, a
storage account e os quatro container groups — nessa ordem, e todos os passos de
infraestrutura são idempotentes. Ao final imprime os quatro endereços públicos.

Detalhes importantes na primeira execução:

- **Demora.** O Oracle XE cria o PDB no primeiro boot (vários minutos) e a imagem da
  Luna tem ~9,8 GB para buildar e enviar ao ACR.
- **O `tutor-api` sobe antes do `clinica-api`**, de propósito: o Flyway roda no boot
  dele e é a autoridade de DDL. Com essa ordem, o `.NET` já encontra o schema pronto.
- **Nada de `.env` é obrigatório aqui.** Ver §8.
- **O espelhamento da imagem do Oracle pode pedir credencial do Docker Hub.** É o
  único ponto do deploy que fala com um registry de terceiro, e acontece só quando
  `kura/oracle-xe:<tag>` ainda não está no ACR. Ver §7.

#### Credencial do Docker Hub — quando é preciso, e quando não é

O passo `[3/10]` espelha `gvenzl/oracle-xe` para o ACR com `az acr import`. Esse import
sai por IPs do Azure compartilhados entre assinaturas, e a quota de pull **anônimo** do
Docker Hub é aplicada por IP de origem — então ele falha com `401`/`TOOMANYREQUESTS` por
tráfego que não é seu, mesmo quando `docker pull` da mesma imagem pública funciona
normalmente da sua máquina. Autenticando a origem, o import conta contra a quota da sua
conta (100 pulls/h) em vez da quota anônima compartilhada.

```dotenv
DOCKERHUB_USERNAME=     # o dono do token — não é segredo, mas não tem valor fixo
DOCKERHUB_TOKEN=        # PAT, escopo "Public Repo Read-only"
```

O PAT sai de *hub.docker.com → Account Settings → Personal access tokens*. **Os dois
andam juntos:** o PAT só autentica com o username do seu dono, então o `deploy.sh` recusa
meio par em vez de deixar o `az` responder `401` sem explicação. É também por isso que o
repositório não traz um usuário fixo — herdar o username de outra pessoa sem o token dela
não serve para nada, e token de terceiro não se compartilha (a quota é por conta, uma
revogação derruba todo mundo junto, e PAT em repositório público é revogado
automaticamente pelo secret scanning).

Na prática, quase nenhum deploy precisa disso:

| Situação | Precisa de credencial? |
|---|---|
| ACR novo, primeiro deploy completo | **Sim** (ou a alternativa abaixo) |
| Qualquer deploy seguinte | Não — o import é pulado quando a imagem já está no ACR |
| `--apps-only` / `--service <x>` | Não — esses escopos nem chegam no import |
| Workflow `deploy-aci.yml` | Não — ele só usa os dois escopos acima, e por isso segue sem nenhum `secrets.*` |
| Deploy contra um ambiente já provisionado por outra pessoa | Não; e se o import rodar, o par vem do Key Vault |

**Sem conta no Docker Hub:** deixe as duas vazias. O `deploy.sh` tenta o import anônimo e,
se falhar, imprime o caminho alternativo — espelhar pela sua própria máquina:

```bash
docker pull gvenzl/oracle-xe:21-slim
az acr login --name kuraprodacr
docker tag gvenzl/oracle-xe:21-slim kuraprodacr.azurecr.io/kura/oracle-xe:21-slim
docker push kuraprodacr.azurecr.io/kura/oracle-xe:21-slim
```

São ~2,6 GB de download e upload, **uma vez** — e sem efeito nenhum sobre o SKU do ACR,
que já é Standard por causa da Luna (§7). Feito isso, rode o `deploy.sh` de novo: ele
encontra a imagem e pula o import.

Depois:

```bash
./azure/verify.sh      # valida cofre, imagens no ACR e os 4 serviços, de fora
./azure/backup-db.sh   # primeiro dump do banco
```

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

### ⚠️ Smoke de contrato app → API (obrigatório antes de qualquer demo)

Nenhuma suíte automatizada deste projeto detecta a classe de bug `'' → NULL` do Oracle
nem divergência de contrato entre os apps e as APIs: os testes .NET usam
`.UseInMemoryDatabase` (sem `NOT NULL`, sem a semântica Oracle de string vazia virando
`NULL`) e os testes mobile batem em mocks sintéticos que sempre respondem sucesso. Já
custou 3 ciclos de correção sem detecção automatizada (ver `TASK-56`/`TASK-57` do
backlog `KURA_BACKLOG_FIX_4`).

`scripts/smoke-contratos.sh` é o único detector real: sobe contra o compose vivo e
exercita payloads com origem citada em comentário acima de cada chamada — não payload
inventado sem rastro. Para os checks com tela real no app, o payload é **copiado
literalmente** do código do app, com `arquivo:linha` de origem; para os 5 pares
DTO × `NOT NULL` da TASK-60 (nenhum tem tela no app hoje), o payload é construído
direto contra o DTO/validator .NET correspondente, citado como origem em vez de uma
tela. Rodar **antes de considerar qualquer mudança de contrato pronta para
demonstração**:

```bash
# Confirmar que o compose está de pé (5/5 healthy/Exited(0)) antes de rodar
docker compose ps -a

bash scripts/smoke-contratos.sh
```

Sai com código 0 e "TUDO OK" quando os 17 checks respondem com o status esperado:
registro de clínica, listagem de pets/medicamentos/dashboard, os 4 endpoints de evento
clínico (consulta/prescrição/vacina/exame, incluindo os casos sem `dsObservacao` que
motivaram o backlog), registro de tutor por convite, os 5 pares DTO × `NOT NULL`
confirmados pela TASK-60 (medicamento sem `dsApresentacao`, tutor sem `nrTelefone` em
create e update — 2 casos —, vacina sem `dsFabricante`, pet com `dsVinculo` vazio
explícito — 4 colunas Oracle distintas, ver comentários no script para a lista
completa) e a checagem da TASK-63 de que
`GET /pets/{id}/timeline` não devolve mais 500 contra o Oracle real. Qualquer `5xx`
(ou qualquer status divergente do esperado) conta como falha e o script sai com código
≠ 0. Idempotente — pode ser rodado quantas vezes for preciso, cada execução gera
CPF/CNPJ/e-mails novos. Requer `curl` e `python` (ou `python3`) no PATH — sem
dependência de `jq`. Não roda no CI (exige Oracle real no runner, ~20min + imagem da
Luna ~9-10GB — mesma razão que excluiu o build completo do workflow deste repo, ver
`.github/workflows/`); é um gate local, operado manualmente.

### 🎬 Seed de demonstração (`scripts/seed-demo.sh`)

Complementar ao smoke acima, não substituto: `smoke-contratos.sh` **valida contrato**
antes de uma mudança (roda quantas vezes for preciso, dados descartáveis, sufixo
aleatório a cada execução); `seed-demo.sh` **prepara uma demonstração** (roda uma vez
por ambiente, credenciais fixas e conhecidas, para reapresentar a mesma demo em
sessões diferentes). Em modo real (`EXPO_PUBLIC_USE_MOCKS=false`) a clínica nasce
vazia — o seed de dado fictício (clínica/tutor/pet) é callback exclusivo do profile
`dev` do Flyway e nunca roda em `prod`, que é o profile do compose (ver `CLAUDE.md`).
Sem este script, a única saída era `curl` improvisado no meio de uma demonstração.

```bash
docker compose ps -a   # confirmar 5/5 healthy/Exited(0) antes de rodar

bash scripts/seed-demo.sh
```

Cria, via as mesmas rotas HTTP que os apps reais usam (nunca por migration/SQL direto):
1 clínica de demo (`demo@kura.local` / `SenhaDemo123!`), o veterinário admin dela, 2
tutores com convite gerado, 3 pets (usando `idEspecie`/`idRaca` do catálogo semeado
pela `V14__seed_referencia.sql`, com verificação em runtime de que `nmEspecie`/`nmRaca`
da resposta batem com o esperado — não apenas presume os IDs), 1 consulta e 1
prescrição com `dsObservacao` preenchida (para a demo mostrar o campo populado, não o
sentinela "Sem observações") + o receituário PDF gerado a partir dela. Termina
imprimindo um bloco copiável com as credenciais, os UUIDs de convite dos 2 tutores e os
IDs de cada entidade criada.

**Idempotência — decisão documentada:** o script **não** é idempotente por escolha.
Como CNPJ/CPF são fixos (não gerados por sufixo aleatório, ao contrário do smoke), uma
segunda execução contra o mesmo ambiente encontraria a clínica de demo já cadastrada; em
vez de tentar mesclar/pular passo a passo (risco de duplicar tutor/pet pela metade), o
script verifica isso logo no início (tenta logar com as credenciais fixas) e **falha
com mensagem clara**, orientando a resetar o ambiente (`docker compose down -v && up -d`)
antes de rodar de novo. Requer `curl` e `python`/`python3` no PATH, mesmos pré-requisitos
do smoke. Não roda no CI pelo mesmo motivo do smoke (exige Oracle real).

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

## 7. Deploy em ACR/ACI (produção)

Produção roda em **Azure Container Instances**: um container group por serviço, imagens
no **Azure Container Registry**, segredos no **Azure Key Vault**. Tudo é provisionado por
`azure/deploy.sh`.

### Modos de execução

| Comando | O que faz |
|---|---|
| `./azure/deploy.sh` | Implantação completa. Se o container group do Oracle **já existe, é preservado** — o banco não é tocado. |
| `./azure/deploy.sh --apps-only` | Redeploy só das três aplicações. Nem olha para o Oracle. É o modo usado pelo GitHub Actions. |
| `./azure/deploy.sh --service luna-ai` | Redeploy de um serviço só (`clinica-api`, `tutor-api`, `luna-ai`). |
| `./azure/deploy.sh --db-only` | Só a infraestrutura e o Oracle, sem tocar em aplicação. Usado no fluxo de restauração. |
| `./azure/deploy.sh --recreate-db` | **Apaga e recria o banco.** Pede confirmação digitada. |
| `./azure/deploy.sh --skip-build` | Não builda; usa a tag que já está no ACR. |

### O banco: por que não há volume, e o que garante a durabilidade

O único tipo de volume do ACI é `azureFile`, que é **SMB** — e o Oracle não abre a
instância com os datafiles em SMB (`ORA-00205`/`ORA-00210`: falta o locking POSIX/O_DIRECT
que control files e redo logs exigem). Não é questão de configuração: **não existe volume
persistente possível para o banco neste modelo.**

Duas consequências, ambas tratadas explicitamente:

1. **Recriar o container group do Oracle apaga o banco.** Por isso o `deploy.sh` nunca o
   recria sem `--recreate-db`, e o modo `--apps-only` existe justamente para que um
   redeploy de aplicação não chegue perto dele.
2. **A durabilidade vem de dump lógico**, não de volume:

```bash
./azure/backup-db.sh                     # dump nomeado pela data/hora UTC
./azure/backup-db.sh antes-da-migracao   # dump com rótulo próprio
./azure/restore-db.sh --list             # o que existe no share
```

O dump usa **Data Pump** (`expdp` com `FLASHBACK_TIME`), que é consistente por construção.
Copiar `/opt/oracle/oradata` com o banco aberto — abordagem tentadora e usada em versões
anteriores deste projeto — produz datafiles *fuzzy*, que só seriam recuperáveis com o redo
do intervalo; em `NOARCHIVELOG` (padrão do XE) esse redo não existe, então **aquela cópia
não restaura**. Este é o motivo de a persistência ter mudado de mecanismo.

**Restaurar** exige uma ordem específica, porque o Flyway roda no boot do `tutor-api` e
recriaria um schema vazio antes do import:

```bash
./azure/deploy.sh --db-only --recreate-db   # banco novo e vazio, sem apps
./azure/restore-db.sh kura-20260910T143000Z
./azure/deploy.sh --apps-only               # sobe as três aplicações
```

Funciona porque o dump inclui a `flyway_schema_history`: ao subir, o Flyway lê o histórico
restaurado e não reaplica nada.

### Endereçamento: FQDN pré-calculado

No compose os serviços se resolvem por nome na bridge network. Em ACI, container groups
são recursos isolados — sem rede compartilhada, sem resolução de nome. O endereço passa a
ser o FQDN público.

Isso cria uma dependência circular: o `.NET` chama a Luna (transcrição, FEAT-02) e a Luna
chama o `.NET` (triagem). Nenhum poderia ser criado "depois" do outro para herdar seu
endereço. A saída é que o FQDN do ACI é **determinístico**:

```
<nome-do-container-group>.<região>.azurecontainer.io
```

Então o `deploy.sh` calcula os quatro endereços **antes** de criar qualquer container
group, e o ciclo deixa de existir.

### Consequência do endereço público: pool de conexões do Oracle

Como não há VNet comum, o tráfego de banco **sai** do container group, passa pelo NAT de
saída do Azure e volta pelo IP público do Oracle. Esse caminho tem uma propriedade que
precisa estar refletida na configuração dos pools: **o fluxo TCP que fica ocioso é
descartado no meio do caminho** — a tradução de NAT expira (o default documentado da
plataforma é 4 minutos) e nenhuma das duas pontas recebe `RST` ou `FIN`.

Nada avisa o cliente. A conexão segue no pool, aparentemente saudável, e o defeito aparece
na próxima requisição que a usar:

| Cliente | Erro |
|---|---|
| .NET (ODP.NET) | `ORA-12537: TNS:connection closed` → HTTP 500 no endpoint |
| Java (JDBC/Hikari) | `ORA-17008: Closed connection` → `CannotGetJdbcConnectionException`, `/actuator/health` **DOWN** |
| Luna (python-oracledb) | absorvido: o pool *thin* faz `ping` ao adquirir conexão ociosa há mais de 60s |

É um erro **intermitente por construção**: depende de quanto tempo o serviço ficou sem
tráfego, não do endpoint chamado. Com tráfego constante nunca aparece; depois de alguns
minutos parado, a primeira chamada falha e a segunda funciona — porque a primeira foi o que
expurgou a conexão morta do pool.

Como distinguir isso de banco fora do ar, ao reinvestigar:

- o `alert_XE.log` (`az container logs --name kura-prod-oracle-db`) **não** registra erro
  nem restart na janela da falha — o banco não caiu;
- o log do `tutor-api` mostra o Hikari reprovando uma a uma as conexões abertas dezenas de
  minutos antes (`Failed to validate connection ... ORA-17008`), e a requisição seguinte
  já responde `UP`;
- cuidado com um falso negativo: um socket ocioso aberto **de fora** contra o IP público do
  Oracle sobrevive a 300s. O caminho que expira é o de **saída** dos container groups das
  aplicações, que é justamente onde os pools vivem.

Por isso cada pool é configurado para que **nenhuma conexão fique ociosa perto dos 4
minutos sem ser validada ou renovada**:

- **.NET** — `deploy.sh` monta a connection string com `Validate Connection=true`
  (valida ao tirar do pool), `Connection Lifetime=180` (aposenta em 3 min) e
  `Min Pool Size=0` (o default, 1, mantém justamente uma conexão parada para sempre).
- **Java** — `aci-java-api.yaml` injeta `SPRING_DATASOURCE_HIKARI_KEEPALIVE_TIME=120000`
  e `SPRING_DATASOURCE_HIKARI_MAX_LIFETIME=180000`. Os defaults do Hikari fazem o oposto do
  necessário aqui: `minimumIdle = maximumPoolSize`, `maxLifetime` de 30 min e nenhum
  keepalive — as 5 conexões ficam paradas até morrerem todas juntas.

Renovar a conexão **antes** da janela, e não só validá-la depois, tem um segundo efeito que
importa no XE: o fechamento acontece com o socket ainda vivo, então o `logoff` chega ao
servidor. Conexão que morre no meio do caminho deixa **sessão órfã** no banco — o processo
servidor fica esperando para sempre num socket que não existe mais, e sem
`SQLNET.EXPIRE_TIME` configurado no servidor nada as recolhe antes de um restart.

> A alternativa estrutural é colocar os quatro container groups na mesma VNet, onde o
> tráfego de banco nunca passa por NAT e o problema não existe. O custo é que ACI
> com VNet **não aceita IP público nem `dnsNameLabel`**: os FQDNs determinísticos desta
> seção deixariam de existir e expor as APIs passaria a exigir um Application Gateway na
> frente. Para o escopo deste projeto, ajustar os pools resolve o mesmo sintoma sem esse
> acréscimo.

### Imagens: tag por commit, nunca `latest`

Cada imagem é marcada com o SHA do commit fixado do submódulo correspondente
(`kura/clinica-api:de96c70e9f82`). É isso que permite saber o que está no ar e voltar
atrás — rollback é recriar o container group apontando para a tag anterior, que continua
no ACR.

A imagem do Oracle é espelhada do Docker Hub para o ACR com `az acr import`, que copia
**server-side**, sem baixar os ~2,6 GB para a máquina de quem faz o deploy. Espelhar evita
o rate limit de pull anônimo do Docker Hub, aplicado por IP de origem — e os IPs de saída
do ACI são compartilhados entre assinaturas, o que torna esse limite uma falha
intermitente e difícil de diagnosticar.

Isso não é teórico para este container group em particular: o Oracle roda com
`restartPolicy: Always` e **sem volume para os datafiles**. Puxar direto do Docker Hub
significaria que todo reagendamento do container group depende de uma quota compartilhada
com terceiros — um limite estourado por outra assinatura viraria banco que não volta do
restart, com os dados no disco local e nenhum caminho de recuperação além de esperar.
Espelhar move essa dependência para um momento controlado, que acontece uma vez.

O mesmo compartilhamento de IPs afeta o próprio serviço de import, que por isso aceita
credencial na origem: `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` (PAT com escopo *Public
Repo Read-only*). É opcional e necessário no máximo uma vez por ACR — ver
[§5, Credencial do Docker Hub](#credencial-do-docker-hub--quando-é-preciso-e-quando-não-é)
para quando isso se aplica e para a alternativa sem conta no Docker Hub.

### Deploy por GitHub Actions

`.github/workflows/deploy-aci.yml` faz o rollout manual (`workflow_dispatch`), autenticando
por **OIDC / workload identity federation** — nenhuma credencial de longa duração fica
guardada no repositório.

O workflow **não builda a imagem da Luna**: os quatro images somam ~13,6 GB, com a Luna
sozinha em ~9,8 GB, e um runner `ubuntu-latest` documenta ~14 GB livres. A Luna é buildada
numa estação de trabalho (`./azure/deploy.sh` sem `--skip-build`) e o workflow apenas a
implanta. É a mesma medição que já justificava a ausência do build completo em `ci.yml`.

O principal do Actions precisa, além do papel no resource group, de acesso ao cofre — que o
`deploy.sh` cria em modo *access policy*, cobrindo apenas quem rodou primeiro:

```bash
az keyvault set-policy --name kura-prod-kv \
  --spn <client-id> --secret-permissions get list set
```

### Encerrar o ambiente

```bash
./azure/teardown.sh                  # apaga o resource group inteiro
./azure/teardown.sh --purge-keyvault # e apaga os segredos de vez
```

⚠️ Isto apaga também a storage account — **onde moram os dumps de backup**. Baixe o que
precisar antes:

```bash
az storage file download-batch --account-name kuraprodstorage \
  --source kura-oracle-backup --destination ./dumps
```

---

## 8. Segredos no Azure Key Vault

Em produção os segredos vivem no cofre `kura-prod-kv`, criado pelo próprio `deploy.sh`
dentro do mesmo resource group. **O `.env` não é usado no caminho Azure.**

> O `.env` continua **obrigatório para o `docker compose` local** — o compose usa
> `${VAR:?mensagem}` nas chaves de auth de propósito, e o `ci.yml` tem um guard (TASK-39)
> que quebra o build se isso deixar de ser verdade. Os dois caminhos são independentes.

| Segredo no cofre | Variável | Consumido por |
|---|---|---|
| `oracle-sys-password` | `ORACLE_SYS_PASSWORD` | Oracle (`ORACLE_PASSWORD`) |
| `oracle-app-password` | `ORACLE_APP_PASSWORD` | Oracle, connection string do .NET, `DB_PASSWORD` do Java, `ORACLE_PASSWORD` da Luna |
| `dotnet-jwt-key` | `DOTNET_JWT_KEY` | .NET (`Jwt__Key`) |
| `iot-api-key` | `IOT_API_KEY` | .NET (`IoT__ApiKey`) |
| `luna-api-key` | `LUNA_API_KEY` | .NET (`Luna__ApiKey`), Luna (`KURA_API_KEY`) |
| `luna-inbound-api-key` | `LUNA_INBOUND_API_KEY` | .NET e Luna — mesmo valor dos dois lados |
| `java-jwt-secret` | `JAVA_JWT_SECRET` | Java (`JWT_SECRET`) |
| `daily-api-key` | `DAILY_API_KEY` | .NET — **externa, opcional** |
| `twilio-sid` / `twilio-token` | `TWILIO_SID` / `TWILIO_TOKEN` | Luna — **externas, opcionais** |
| `openai-api-key` | `OPENAI_API_KEY` | Luna — **externa, opcional** |
| `dockerhub-username` / `dockerhub-token` | `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | `deploy.sh` `[3/10]`, `az acr import` — **externas, opcionais, par indivisível**. Nenhum container as recebe. |

O nome no cofre é a variável em kebab-case minúsculo porque o Key Vault não aceita `_`.

### Como cada segredo converge

1. Veio do ambiente/`.env` e difere do cofre → `az keyvault secret set`;
2. veio do ambiente e é igual ao do cofre → nada é feito (sem versão nova a cada deploy);
3. não veio do ambiente mas já está no cofre → reaproveitado;
4. não existe em lugar nenhum → **gerado** na hora e guardado.

O passo 4 tem uma exceção deliberada: as credenciais marcadas como **externas** (Daily,
Twilio, OpenAI, Docker Hub) nunca são geradas. São emitidas por terceiros, e inventar um
valor aleatório produziria uma credencial inválida em vez de um erro claro — quem as
consome degrada de forma tratada quando elas faltam: os três serviços de aplicação
conforme o `docker-compose.yml`, e o espelhamento do Oracle caindo para import anônimo.

`dockerhub-username` é o único item do cofre que **não é segredo** (é público no perfil do
Docker Hub). Está lá de propósito: o Docker Hub autentica com o par username+PAT, e o PAT
só vale para o seu dono — guardar só o token faria o cofre conter meia credencial, e o
segundo deploy herdaria um `401` sem explicação.

As senhas do Oracle são geradas com 28 caracteres **alfanuméricos**, não base64: elas
entram numa connection string ADO.NET (`User Id=...;Password=...;Data Source=...`) e num
JDBC URL, onde `;` `/` `+` `=` quebrariam o parsing.

Depois de convergir, **todos são relidos do cofre** com `az keyvault secret show` —
inclusive os que vieram do `.env` — e só então preenchem os manifestos, onde entram como
`secureValue` (não aparecem em `az container show` nem nos logs). O YAML preenchido fica
em `azure/.generated/` (gitignored) e é recriado a cada execução.

### Operar os segredos

```bash
az keyvault secret list --vault-name kura-prod-kv -o table
az keyvault secret set  --vault-name kura-prod-kv --name dotnet-jwt-key --value "<novo>"
./azure/deploy.sh --apps-only     # recria os container groups com o valor girado
```

⚠️ Girar `oracle-app-password` no cofre **não gira a senha dentro do banco**. Credencial de
banco é sempre um par coordenado: `ALTER USER` no Oracle **e** o cofre. Girar só um lado
derruba as três aplicações no próximo deploy com `ORA-01017`.

O `verify.sh` confere no passo `[1/6]` que os segredos obrigatórios existem — presença,
nunca valor.

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
