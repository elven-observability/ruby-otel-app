# frozen_string_literal: true

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
