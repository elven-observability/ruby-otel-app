# Ruby Rails API - OpenTelemetry Traces (OTLP HTTP)

Aplicação de exemplo em **Rails API + PostgreSQL** para demonstrar instrumentação de **traces** com OpenTelemetry Ruby.

Este projeto envia traces para um **collector externo** via **OTLP HTTP/protobuf** (`/v1/traces`).

## Stack e versões

- Ruby `3.3.x`
- Rails `8.1.2`
- pg `1.6.3`
- opentelemetry-api `1.7.0`
- opentelemetry-sdk `1.10.0`
- opentelemetry-exporter-otlp `0.31.1`
- opentelemetry-instrumentation-rails `0.39.1`
- opentelemetry-instrumentation-net_http `0.27.0`

## O que a demo cobre

- Span inbound HTTP do Rails (`POST /checkout`)
- Span de banco (ActiveRecord ao salvar `orders`)
- Span outbound HTTP (`Net::HTTP` chamando `/internal/ping`)
- Spans manuais no serviço:
  - `checkout.validate_input`
  - `checkout.persist_order`
  - `checkout.call_internal_service`
  - `checkout.finalize`
- Exemplo de erro com `record_exception` e `status=error`

## Endpoints

- `GET /health`
- `GET /internal/ping`
- `POST /checkout`

Payload de `POST /checkout`:

```json
{
  "customer_id": "cust-001",
  "amount_cents": 1500,
  "force_error": false
}
```

`force_error=true` força falha controlada para demonstrar span com erro.

## Variáveis de ambiente

Use `.env.example` como base:

```bash
cp .env.example .env
```

Principais variáveis de tracing:

- `OTEL_SERVICE_NAME` (default `ruby-rails-traces-demo`)
- `OTEL_RESOURCE_ATTRIBUTES` (default `deployment.environment=local,service.version=1.0.0`)
- `OTEL_TRACES_EXPORTER=otlp`
- `OTEL_METRICS_EXPORTER=none`
- `OTEL_LOGS_EXPORTER=none`
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (ex.: `http://localhost:4318/v1/traces`)
- `OTEL_EXPORTER_OTLP_HEADERS` (opcional; formato `k=v`, URL-encoded, separado por vírgula)

Exemplo de header:

```bash
OTEL_EXPORTER_OTLP_HEADERS=authorization=Bearer%20TOKEN
```

## Rodando localmente

### 1) Subir PostgreSQL local

```bash
docker compose up -d
```

Se a porta `5432` já estiver em uso, rode com outra porta:

```bash
POSTGRES_PORT=5433 docker compose up -d
```

### 2) Preparar ambiente Ruby/Bundler

Se necessário, garanta Ruby `3.3.x` no `PATH`.

```bash
bundle install
```

### 3) Carregar variáveis

```bash
set -a
source .env
set +a
```

### 4) Criar e migrar banco

```bash
bin/rails db:prepare
```

### 5) Subir aplicação

```bash
bin/rails s
```

## Gerando traces de exemplo

### Health check

```bash
curl -s http://localhost:3000/health
```

### Fluxo feliz (inbound + DB + outbound + spans manuais)

```bash
curl -s -X POST http://localhost:3000/checkout \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-001","amount_cents":1500}'
```

### Fluxo com erro controlado

```bash
curl -s -X POST http://localhost:3000/checkout \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-002","amount_cents":2500,"force_error":true}'
```

A resposta inclui `trace_id` para facilitar correlação na sua stack.

## Testes

```bash
bin/rails test
```

## Estrutura principal

- `config/initializers/opentelemetry.rb`: setup SDK/exporter/instrumentações
- `app/services/checkout_service.rb`: spans manuais + regra de negócio
- `app/controllers/checkout_controller.rb`: endpoint principal e retorno de `trace_id`
- `app/models/order.rb`: entidade persistida
- `db/migrate/*_create_orders.rb`: schema de `orders`

## Referências oficiais

- [OpenTelemetry Ruby Docs](https://opentelemetry.io/docs/languages/ruby/)
- [OpenTelemetry Ruby SDK](https://github.com/open-telemetry/opentelemetry-ruby)
- [OpenTelemetry Ruby Contrib](https://github.com/open-telemetry/opentelemetry-ruby-contrib)
