# Arquitetura KURA — Diagrama de Referência

> Fonte committável e versionável (Mermaid, renderiza nativamente no GitHub). Equivalente ao
> `docs/arquitetura-kura.drawio` (editável no [draw.io](https://app.diagrams.net/)) e ao PDF em
> `docs/Kura_Docs_DevOps.pdf`. Refletido a partir do `docker-compose.yml` real deste repositório —
> atualizar aqui sempre que portas, serviços ou volumes mudarem no compose.

> **Dois ambientes, dois diagramas.** O primeiro diagrama descreve o
> `docker-compose.yml`, que é o ambiente de **desenvolvimento local**. A seção
> "Topologia em produção (ACR/ACI)" descreve o que o `azure/deploy.sh` provisiona no Azure.
> Os serviços e as portas são os mesmos; o que muda é o isolamento entre eles e,
> por consequência, como um encontra o outro.

## Diagrama de contêineres — desenvolvimento local (docker compose)

```mermaid
flowchart TB
    subgraph externo["Atores externos"]
        vet["Veterinário / Gestor\n(App Clínica)"]
        tutor["Tutor\n(App Mobile)"]
        twilio["Twilio WhatsApp"]
        iot["Dispositivos IoT\n(ESP32 sensores)"]
    end

    subgraph vm["Máquina de desenvolvimento — Docker Network: kura_network (bridge)"]
        api["kura-api\n.NET 10 · Clean Architecture\nporta 8080\nuser: kura (non-root)"]
        tutorapi["kura-tutor\nSpring Boot 3.2.5 / Java 21\nporta 8081 (context /api)\nuser: spring uid=1000 (non-root)"]
        luna["luna-ai\nPython 3.12 / FastAPI\nporta 8000\nuser: 1000:1000 (non-root)"]
        oracle[("oracle-db\ngvenzl/oracle-xe:21-slim\nporta 9092→1521\nvolume nomeado: kura_oracle_data")]
    end

    vet -->|"JWT clínica / X-Api-Key IoT"| api
    tutor -->|"JWT tutor"| tutorapi
    twilio -->|"webhook assinado"| luna
    iot -->|"X-Api-Key"| api

    api -->|"jdbc/oracle thin"| oracle
    tutorapi -->|"jdbc oracle:thin\nFlyway = autoridade de DDL"| oracle
    luna -->|"httpx + KURA_API_KEY\n(outbound apenas)"| api
    luna -->|"X-API-Key inbound\nPOST /whatsapp/enviar"| api

    style oracle fill:#1A3A52,color:#fff
    style api fill:#1A3A52,color:#fff
    style tutorapi fill:#4A6944,color:#fff
    style luna fill:#333,color:#fff
```

## Legenda — serviços, portas e ownership

| Serviço | Imagem/contexto | Porta (host→container) | Owner de dados |
|---|---|---|---|
| `oracle-db` | `gvenzl/oracle-xe:21-slim` | `9092:1521` | Schema único compartilhado — volume nomeado `kura_oracle_data` (RUBRICA 2.3), persiste entre restarts |
| `kura-api` | build local (.NET 10) | `8080:8080` | `CLINICA`, `VETERINARIO`, `PET`, `EVENTO_CLINICO`, `NOTIFICACAO`, IoT, `TRIAGEM_LUNA`; `AGENDAMENTO` compartilhada (lock otimista) |
| `kura-tutor` | build local (Spring Boot 3.2.5 / Java 21) | `8081:8081` | `CONTA_TUTOR`, `CONSENTIMENTO`, `IDEMPOTENCY_KEY`; autoridade única de DDL (Flyway) |
| `luna-ai` | build local (FastAPI / Python 3.12) | `8000:8000` | Não persiste no Oracle — integra via `httpx` ao `kura-api` (outbound) e recebe webhooks Twilio/inbound `/whatsapp/enviar` |

## Rede e volume

- Rede: `kura_network` (bridge) — serviços resolvem uns aos outros pelo nome do container (`oracle-db`, `kura-api`, `kura-tutor`, `luna-ai`).
- Volume nomeado: `kura_oracle_data` montado em `/opt/oracle/oradata` — **não** é removido por `docker compose down`; requer `down -v` explícito para apagar.
- Todos os três serviços de aplicação rodam como usuário não-root no container (RUBRICA 2.2).

## Topologia em produção (ACR/ACI)

Cada serviço é um **container group** próprio no Azure Container Instances, com imagem vinda do
Azure Container Registry e segredos do Azure Key Vault. Não existe rede compartilhada entre
container groups: cada um tem seu FQDN público e é por ele que os outros o alcançam.

```mermaid
flowchart TB
    subgraph externo["Atores externos"]
        vet2["Veterinário / Gestor"]
        tutor2["Tutor"]
        twilio2["Twilio WhatsApp"]
        iot2["Dispositivos IoT"]
    end

    subgraph azure["Azure · resource group kura-prod-rg · eastus2"]
        kv["Key Vault<br/>kura-prod-kv<br/>11 segredos"]
        acr["Container Registry<br/>kuraprodacr<br/>4 repositórios"]
        st["Storage Account<br/>share de backup (dumps)<br/>share de documentos (PDFs)"]

        subgraph acis["Container Instances — um container group por serviço"]
            api2["kura-prod-clinica-api<br/>:8080"]
            tutorapi2["kura-prod-tutor-api<br/>:8081 · Flyway"]
            luna2["kura-prod-luna-ai<br/>:8000"]
            oracle2[("kura-prod-oracle-db<br/>:1521 · disco efêmero")]
        end
    end

    vet2 --> api2
    iot2 --> api2
    tutor2 --> tutorapi2
    twilio2 --> luna2

    api2 -->|FQDN público| oracle2
    tutorapi2 -->|FQDN público · DDL| oracle2
    luna2 -->|FQDN público| oracle2
    api2 <-->|FQDN público| luna2

    acr -.imagem.-> api2
    acr -.imagem.-> tutorapi2
    acr -.imagem.-> luna2
    acr -.imagem.-> oracle2
    kv -.secureValue.-> api2
    kv -.secureValue.-> tutorapi2
    kv -.secureValue.-> luna2
    kv -.secureValue.-> oracle2
    oracle2 -.expdp.-> st
    api2 -.PDFs.-> st

    style oracle2 fill:#1A3A52,color:#fff
    style api2 fill:#1A3A52,color:#fff
    style tutorapi2 fill:#4A6944,color:#fff
    style luna2 fill:#333,color:#fff
    style kv fill:#6B4A6E,color:#fff
    style acr fill:#6B4A6E,color:#fff
    style st fill:#6B4A6E,color:#fff
```

### Três diferenças que o ACI impõe

| Tema | Compose (local) | ACI (produção) |
|---|---|---|
| Descoberta de serviço | hostname na bridge (`oracle-db`, `kura-api`) | FQDN público `<nome>.eastus2.azurecontainer.io`, pré-calculado pelo `deploy.sh` |
| Persistência do banco | named volume `kura_oracle_data` | **nenhuma** — o único volume do ACI é SMB, e o Oracle não abre com datafiles em SMB. Durabilidade vem de `azure/backup-db.sh` (Data Pump) |
| Usuário não-root | `.NET` e Java pelo Dockerfile; Luna via `user:` do compose | `.NET` e Java seguem não-root; **a Luna não**, porque o ACI não tem campo equivalente a `user:` |

O FQDN ser determinístico é o que resolve a dependência circular entre `clinica-api` e `luna-ai`
(cada um precisa do endereço do outro): os quatro endereços são calculados antes de qualquer
container group existir.

## Fluxo de dados — Luna → .NET (triagem via WhatsApp)

```mermaid
sequenceDiagram
    participant T as Tutor (WhatsApp)
    participant Tw as Twilio
    participant L as Luna (FastAPI :8000)
    participant N as kura-api (.NET :8080)

    T->>Tw: Mensagem WhatsApp
    Tw->>L: POST /webhook/twilio/whatsapp (assinatura validada)
    L->>N: GET /api/v1/tutores/telefone/{nr} (X-Api-Key)
    L->>L: TriageEngine.classificar() (local)
    L->>N: POST /api/v1/luna/triage (X-Api-Key)
    L->>Tw: TwilioGateway.enviar_whatsapp() — resposta ao tutor
```
