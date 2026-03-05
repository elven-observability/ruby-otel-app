# Ruby Rails API - OpenTelemetry Traces (Guia Didático)

Aplicação de exemplo em **Rails API + PostgreSQL** para ensinar, na prática, como instrumentar **somente traces** com OpenTelemetry no Ruby.

Esta app **sempre exporta traces para um collector externo** (via OTLP HTTP/protobuf) e deixa métricas/logs fora do escopo.

## Objetivo de ensino

Ao final deste README, você deve conseguir:

1. Entender a diferença entre auto instrumentação e spans manuais.
2. Configurar exportação OTLP para um collector.
3. Criar spans que representam regras de negócio.
4. Capturar erro com `record_exception` e `status=error`.
5. Correlacionar requisição e trace pelo `trace_id` retornado na API.

## Stack e versões usadas

- Ruby `3.3.x`
- Rails `8.1.2`
- pg `1.6.3`
- opentelemetry-api `1.7.0`
- opentelemetry-sdk `1.10.0`
- opentelemetry-exporter-otlp `0.31.1`
- opentelemetry-instrumentation-rails `0.39.1`
- opentelemetry-instrumentation-net_http `0.27.0`

## O cenário que esta demo cobre

- Span inbound HTTP do Rails (`POST /checkout`)
- Span de banco (ActiveRecord ao salvar `orders`)
- Span outbound HTTP (`Net::HTTP` para `/internal/ping`)
- Spans manuais de negócio:
  - `checkout.validate_input`
  - `checkout.persist_order`
  - `checkout.call_internal_service`
  - `checkout.finalize`
- Cenário de erro com:
  - `span.record_exception(exception)`
  - `span.status = OpenTelemetry::Trace::Status.error(...)`

## Fluxo do trace (visão rápida)

```text
POST /checkout
  -> span Rails (server)
    -> span manual checkout.request
      -> span manual checkout.validate_input
      -> span manual checkout.persist_order
        -> span ActiveRecord (db)
      -> span manual checkout.call_internal_service
        -> span Net::HTTP (client) para /internal/ping
      -> span manual checkout.finalize
```

## Estrutura de código relevante

- `config/initializers/opentelemetry.rb`
  - Inicializa SDK
  - Define exporter OTLP HTTP
  - Adiciona `BatchSpanProcessor`
  - Liga instrumentações explícitas: Rails e Net::HTTP
- `app/controllers/checkout_controller.rb`
  - Endpoint principal
  - Span `checkout.request`
  - Tratamento de erro com status de span
  - Retorna `trace_id` na resposta
- `app/services/checkout_service.rb`
  - Spans manuais por etapa de negócio
  - Exemplo de erro forçado (`force_error`)
- `app/models/order.rb` e `db/migrate/*_create_orders.rb`
  - Persistência para gerar spans de DB

## Trechos reais de código (copiar e adaptar)

### 1) Gemfile (dependências de tracing)

```ruby
gem "opentelemetry-api", "1.7.0"
gem "opentelemetry-sdk", "1.10.0"
gem "opentelemetry-exporter-otlp", "0.31.1"
gem "opentelemetry-instrumentation-rails", "0.39.1"
gem "opentelemetry-instrumentation-net_http", "0.27.0"
```

### 2) Initializer do OpenTelemetry

```ruby
# config/initializers/opentelemetry.rb
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/rails"
require "opentelemetry/instrumentation/net/http"

otel_headers = ENV["OTEL_EXPORTER_OTLP_HEADERS"]
otel_headers = {} if otel_headers.nil? || otel_headers.strip.empty?

exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
  endpoint: ENV.fetch("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://localhost:4318/v1/traces"),
  headers: otel_headers
)

resource = OpenTelemetry::SDK::Resources::Resource.create(
  "deployment.environment" => ENV.fetch("OTEL_DEPLOYMENT_ENVIRONMENT", Rails.env.to_s)
)

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "ruby-rails-traces-demo")
  c.resource = resource
  c.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))

  c.use "OpenTelemetry::Instrumentation::Rails"
  c.use "OpenTelemetry::Instrumentation::Net::HTTP"
end
```

### 3) Span manual no controller (incluindo erro e trace_id)

```ruby
# app/controllers/checkout_controller.rb
TRACER = OpenTelemetry.tracer_provider.tracer("checkout-controller", "1.0.0")

def create
  TRACER.in_span("checkout.request") do |span|
    order = CheckoutService.new(
      customer_id: checkout_params.fetch(:customer_id),
      amount_cents: checkout_params.fetch(:amount_cents),
      force_error: checkout_params.fetch(:force_error),
      internal_url: internal_ping_url
    ).call

    render json: {
      order_id: order.id,
      status: order.status,
      trace_id: current_trace_id
    }, status: :ok
  rescue ActionController::ParameterMissing => e
    span.record_exception(e)
    span.status = OpenTelemetry::Trace::Status.error(e.message)
    render json: { error: e.message, trace_id: current_trace_id }, status: :unprocessable_entity
  rescue CheckoutService::CheckoutError => e
    span.record_exception(e)
    span.status = OpenTelemetry::Trace::Status.error(e.message)
    render json: { error: e.message, trace_id: current_trace_id }, status: :internal_server_error
  end
end
```

### 4) Spans manuais por etapa no service object

```ruby
# app/services/checkout_service.rb
TRACER = OpenTelemetry.tracer_provider.tracer("checkout-service", "1.0.0")

def call
  valid_amount = with_span("checkout.validate_input") { validate_input! }
  order = with_span("checkout.persist_order") { persist_order!(valid_amount) }
  with_span("checkout.call_internal_service") { call_internal_service! }
  with_span("checkout.finalize") { finalize_order!(order) }
  order
end

def with_span(name, attributes = {})
  TRACER.in_span(name, attributes: attributes) do |span|
    yield
  rescue StandardError => e
    span.record_exception(e)
    span.status = OpenTelemetry::Trace::Status.error(e.message)
    raise
  end
end
```

### 5) Chamada HTTP de saída (gera span client)

```ruby
def call_internal_service!
  uri = URI.parse(@internal_url)
  response = Net::HTTP.get_response(uri)
  return response if response.code.to_i.between?(200, 299)

  raise CheckoutError, "internal ping failed with status #{response.code}"
end
```

### 6) Rotas mínimas da demo

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get "health", to: "health#show"
  get "internal/ping", to: "internal#ping"
  post "checkout", to: "checkout#create"
end
```

## Endpoints da demo

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

Se `force_error=true`, a app força erro para demonstrar o trace com falha.

## Configuração de ambiente

Copie o template:

```bash
cp .env.example .env
```

### Variáveis principais de tracing

- `OTEL_SERVICE_NAME`
- `OTEL_RESOURCE_ATTRIBUTES`
- `OTEL_TRACES_EXPORTER=otlp`
- `OTEL_METRICS_EXPORTER=none`
- `OTEL_LOGS_EXPORTER=none`
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (ex.: `http://localhost:4318/v1/traces`)
- `OTEL_EXPORTER_OTLP_HEADERS` (opcional, para auth)

Exemplo com token:

```bash
OTEL_EXPORTER_OTLP_HEADERS=authorization=Bearer%20TOKEN
```

### Variáveis de banco

- `POSTGRES_HOST`
- `POSTGRES_PORT`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `DATABASE_URL`
- `DATABASE_TEST_URL`

## Como rodar localmente

### 1) Suba PostgreSQL

```bash
docker compose up -d
```

Se a porta `5432` já estiver em uso:

```bash
POSTGRES_PORT=5433 docker compose up -d
```

### 2) Instale dependências

```bash
bundle install
```

### 3) Exporte variáveis do `.env`

```bash
set -a
source .env
set +a
```

### 4) Prepare o banco

```bash
bin/rails db:prepare
```

### 5) Suba a app

```bash
bin/rails s
```

## Gerando traces de demonstração

### Fluxo saudável

```bash
curl -s -X POST http://localhost:3000/checkout \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-001","amount_cents":1500}'
```

### Fluxo com erro

```bash
curl -s -X POST http://localhost:3000/checkout \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-002","amount_cents":2500,"force_error":true}'
```

A resposta inclui `trace_id`. Use esse ID para buscar o trace na sua stack.

## O que você deve ver no backend de observabilidade

No fluxo saudável:

1. Um trace contendo spans Rails, DB, HTTP client e spans manuais `checkout.*`.
2. Hierarquia de spans mostrando claramente cada etapa do checkout.

No fluxo com erro:

1. Span `checkout.finalize` com status de erro.
2. Exceção registrada no span (`record_exception`).
3. Mesmo `trace_id` disponível na resposta da API.

## Passo a passo para instrumentar uma app Ruby real

Use esta sequência no projeto do cliente:

1. Adicione gems `opentelemetry-api`, `opentelemetry-sdk`, exporter OTLP e instrumentações necessárias.
2. Crie um initializer de OTel (igual ao desta demo) com `BatchSpanProcessor` e endpoint do collector por env var.
3. Ative instrumentações da stack usada (ex.: Rails, Net::HTTP, Faraday, Sidekiq, etc.).
4. Mapeie os pontos de negócio críticos e envolva em spans manuais curtos e estáveis.
5. Em blocos de erro, sempre faça `record_exception` e `status=error`.
6. Retorne `trace_id` em respostas de erro/sucesso (quando fizer sentido) para acelerar troubleshooting.

## Convenções recomendadas para spans manuais

1. Nomeie spans com verbo e domínio (`checkout.persist_order`, `payment.authorize`).
2. Evite spans excessivos: só etapas que agregam diagnóstico.
3. Adicione atributos úteis para investigação, sem expor dados sensíveis.
4. Não coloque PII (CPF, e-mail, token, senha) em atributos de span.

## Troubleshooting rápido

Se não aparecer trace:

1. Confirme se `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` está correto e acessível.
2. Confira autenticação em `OTEL_EXPORTER_OTLP_HEADERS`.
3. Verifique se `OTEL_TRACES_EXPORTER=otlp`.
4. Confira logs da app ao subir: as instrumentações devem aparecer como instaladas.
5. Gere uma requisição nova e procure pelo `trace_id` retornado no JSON.

## Testes

```bash
bin/rails test
```

Cobertura atual de testes:

1. Health check e endpoint interno.
2. Checkout com sucesso (persistência + chamada HTTP de saída).
3. Checkout com erro forçado (500 + trace_id na resposta).

## Referências oficiais

- [OpenTelemetry Ruby Docs](https://opentelemetry.io/docs/languages/ruby/)
- [OpenTelemetry Ruby SDK](https://github.com/open-telemetry/opentelemetry-ruby)
- [OpenTelemetry Ruby Contrib](https://github.com/open-telemetry/opentelemetry-ruby-contrib)
