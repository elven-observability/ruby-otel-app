# Ruby Rails API - OpenTelemetry Traces (Guia Didático)

Aplicação de exemplo em **Rails API + PostgreSQL** para ensinar, na prática, como instrumentar **somente traces** com OpenTelemetry no Ruby.

Aplicacao de referencia sobre os SDKs oficiais OpenTelemetry, nao um SDK Ruby Elven publicado separadamente.
Documentacao autoritativa: [docs.elven.works](https://docs.elven.works/).
Fonte da documentacao e correcoes: [elvenworks-ps/docs.elven.works](https://github.com/elvenworks-ps/docs.elven.works).

Quando habilitada, exporta traces via OTLP HTTP/protobuf. Metricas e exporters de logs estao fora do escopo.

## Seguranca e ciclo de vida

- `OTEL_SDK_DISABLED=true` ou `OTEL_TRACES_EXPORTER=none`, com reinicio, impede a criacao do exporter e da fila. Rollback: restaure o commit/lockfile anterior e reinicie.
- Erros de configuracao de telemetria nao impedem o boot da app; falhas de banco e erros de negocio continuam sendo erros reais.
- Fila limitada a 256 spans, lotes de 64, valores de atributos limitados a 256 caracteres, timeouts de I/O de 2 s e prazo de shutdown de 3 s. O exporter faz uma tentativa sem retry: o backoff do OTLP 0.37.0 pode ultrapassar o timeout. Sob saturacao ha descarte, nao entrega garantida. O prazo configurado nao e um teto absoluto de tempo de parede sob todas as condicoes de runtime/rede.
- O exporter copia os spans e permite somente atributos operacionais. SQL, URLs, headers, eventos de excecao, links e descricoes de erro nao sao exportados; nomes desconhecidos viram `application.operation`. Nao e uma garantia universal de ausencia de PII, inclusive nos logs da app.
- Coletores remotos exigem HTTPS e verificacao TLS. HTTP e permitido somente em loopback. Nao coloque credenciais na URL.
- O processor oficial reinicia sua fila/thread depois de fork; ha teste local de filho e pai. Nao ha Resque ou Sidekiq no bundle e nao ha validacao desses frameworks ou de todas as configuracoes Puma.
- Historico R-Q0 do baseline `b3fae32`: `start_thread_on_boot:false` impedia autoexport no processo inicial; flush/fork nao encerravam essa falha. A candidata usa a opcao publica `start_thread_on_boot:true` do BSP 1.13.1 e acrescenta teste real do primeiro span sem flush nem fork. A qualificacao da candidata e separada dos controles historicos abaixo.
- A candidata adiciona snapshot antes do BSP oficial: budget agregado de dados de 32 KiB por span, com cobrancas por campos/containers, cobrindo nome, atributos/keys/arrays, status, eventos, links, contextos, resource e scope. Envelope excessivo ou traceState invalido/multilinha e descartado antes da fila, sem impedir o trabalho da app. A redacao posterior no exporter permanece.
- Nao duplique a instrumentacao com outro agente/provider no mesmo processo. Veja [`lib/reference_telemetry.rb`](lib/reference_telemetry.rb) para a implementacao efetiva.
- A chamada interna usa loopback e `PORT` (3000 por padrao), nunca o header Host da requisicao. `INTERNAL_PING_URL` permite configurar um destino confiavel explicitamente.
- O exporter OTLP fica fixado em `0.37.0` no Gemfile/lockfile. O adaptador rejeita outra versao ou assinatura privada incompatível, deixando a app continuar sem exportacao; upgrades exigem atualizar o guard e repetir os testes. A CI usa `BUNDLE_FROZEN=true`.

Teste isolado do provider global (collector local, fila saturada, fork e contexto):
`bundle exec ruby test/telemetry_smoke.rb`. Execute os testes Rails em outro processo com `bin/rails test`.

Teste adicional: `bundle exec ruby test/envelope_smoke.rb`, incluindo GC, capacidade reservada e views pequenas de sufixo. Strings sao copiadas para buffer novo de tamanho limitado, nao `dup`/COW; a fila recebe somente SpanData/contexto destacados, sem delegate para o span original.

O adaptador e qualificado para API 1.11.1/SDK 1.13.1 exatos. `Span#to_span_data` e documentado pelo SDK para processors antes de exporters, mas marcado `@api private`; a forma dos itens lidos pelo BSP tambem exige revisao ao atualizar SDK. Guard, pins exatos e testes de contrato impedem aceitar silenciosamente uma versao diferente. Isso nao e um novo SDK publicado nem uma fila propria.

O budget limita dados admitidos na fila do helper, nao RSS, spans ativos, caches globais, providers externos ou alocacoes anteriores ao processor. R-Q1/R-Q2/R-Q3/R-Q4 sao falhas reproduzidas do baseline, nao garantias universais sobre todos os Strings/runtimes. Ha descarte por sobrecarga e custo de copia; nao ha promessa de overhead zero. A candidata exige CI em Ruby 3.3.13/4.0.9 e revisao independente. Docker/Linux ARM64 desta revisao aguarda liberacao do ambiente compartilhado.

## Objetivo de ensino

Ao final deste README, você deve conseguir:

1. Entender a diferença entre auto instrumentação e spans manuais.
2. Configurar exportação OTLP para um collector.
3. Criar spans que representam regras de negócio.
4. Capturar erro com `record_exception` e `status=error`.
5. Correlacionar requisição e trace pelo `trace_id` retornado na API.

## Stack e versões usadas

- Ruby `3.3.13` por padrao; perfil opcional `4.0.9`, sem mudar `.ruby-version` ou pins do bundle
- Rails `8.1.4`
- pg `1.7.0`
- Puma `~> 7.2` (sem migracao para a major 8)
- opentelemetry-api `1.11.1`
- opentelemetry-sdk `1.13.1`
- opentelemetry-exporter-otlp `0.37.0`
- opentelemetry-instrumentation-rails `0.42.0`
- opentelemetry-instrumentation-net_http `0.29.2`

### Perfis atuais e migracao opcional

As [versoes oficiais de 23/10/2026](https://www.ruby-lang.org/en/downloads/releases/) sao Ruby 4.0.9, 3.4.12 e 3.3.13. Ruby 3.3 recebe correcoes de seguranca; Ruby 3.2 esta EOL. Os controles antigos em 3.3.12 sao historicos, nao uma qualificacao de seguranca atual.

O baseline `b3fae32` foi executado em Ruby 3.3.13 e 4.0.9 Linux/ARM64 com o mesmo `Gemfile.lock` congelado: 14 testes de telemetry/59 assertions, 4 testes Rails/20 assertions e consumer HTTP real com Rack, ActiveRecord e Net::HTTP contra collector local. Contexto, fork, falha/backpressure e guard do exporter fazem parte desse controle historico. Esse resultado nao fechava R-Q0 e nao qualifica automaticamente os novos processors, todas as configuracoes Puma, outros SOs ou o Dockerfile final de producao.

Para optar por Ruby 4.0.9, instale esse runtime em ambiente isolado e reinstale o bundle com Bundler 2.7.1 e `BUNDLE_FROZEN=true`; nao reutilize extensoes nativas compiladas para Ruby 3.3. Nao foi necessaria mudanca de sintaxe, API ou lockfile nos controles. O default do Dockerfile continua 3.3.13; o argumento `RUBY_VERSION` permite testar a outra linha explicitamente. A CI testa ambas sem abandonar a linha anterior.

Audite runtime/stdlib separadamente dos gems do lockfile. As correcoes de [compilacao Regexp](https://www.ruby-lang.org/en/news/2026/10/23/regexp-fixes-for-gitlab-cves/) nao sao substituidas por `Regexp.timeout`; o bootstrap nao expoe compilacao de padroes controlados pelo usuario. Os runtimes testados carregaram `resolv` 0.3.2/0.7.2, respectivamente, corrigindo os [advisories da biblioteca](https://www.ruby-lang.org/en/news/2026/08/27/multiple-vulnerabilities-in-resolv/). Carregar a biblioteca nao prova uso de seu resolver; `Net::HTTP` ordinario usa o resolver do SO. Nao ha garantia universal de ausencia de CVEs ou PII.

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
gem "opentelemetry-api", "1.11.1"
gem "opentelemetry-sdk", "1.13.1"
gem "opentelemetry-exporter-otlp", "0.37.0"
gem "opentelemetry-instrumentation-rails", "0.42.0"
gem "opentelemetry-instrumentation-net_http", "0.29.2"
```

### 2) Initializer do OpenTelemetry

```ruby
# config/initializers/opentelemetry.rb
require_relative "../../lib/reference_telemetry"
ReferenceTelemetry.start(environment: ENV.fetch("OTEL_DEPLOYMENT_ENVIRONMENT", Rails.env.to_s))
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
2. A chamada `record_exception` pode existir na aplicação, mas o exporter de
   privacidade desta referência remove eventos, links e descrições de erro
   antes da exportação. Não espere a mensagem ou stacktrace bruta no backend.
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
