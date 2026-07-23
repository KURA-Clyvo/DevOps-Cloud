# Arquitetura KURA — Diagrama de Referência

> Fonte committável e versionável (Mermaid, renderiza nativamente no GitHub). Equivalente ao
> `docs/arquitetura-kura.drawio` (editável no [draw.io](https://app.diagrams.net/)) e ao PDF em
> `docs/Kura_Docs_DevOps.pdf`. Refletido a partir do `docker-compose.yml` real deste repositório —
> atualizar aqui sempre que portas, serviços ou volumes mudarem no compose.

## Diagrama de contêineres

```mermaid
flowchart TB
    subgraph externo["Atores externos"]
        vet["Veterinário / Gestor\n(App Clínica)"]
        tutor["Tutor\n(App Mobile)"]
        twilio["Twilio WhatsApp"]
        iot["Dispositivos IoT\n(ESP32 sensores)"]
    end

    subgraph vm["Azure VM (Ubuntu 22.04) — Docker Network: kura_network (bridge)"]
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
