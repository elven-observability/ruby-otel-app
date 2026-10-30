# frozen_string_literal: true

require "opentelemetry"
require "uri"
require "ipaddr"
require "logger"

# Application-local bootstrap, not a separately published language SDK.
module ReferenceTelemetry
  QUEUE_SIZE = 256
  BATCH_SIZE = 64
  EXPORT_TIMEOUT = 2.0
  SHUTDOWN_TIMEOUT = 3.0
  ATTRIBUTES = %w[http.request.method http.method http.response.status_code http.status_code http.route db.system db.system.name db.operation db.operation.name].freeze
  RESOURCES = %w[service.name service.version deployment.environment telemetry.sdk.name telemetry.sdk.language telemetry.sdk.version].freeze

  class PrivateExporter
    def initialize(exporter)
      @exporter = exporter
    end

    def export(spans, timeout: nil)
      clean = spans.map do |span|
        copy = span.dup
        copy.attributes = (span.attributes || {}).select { |key, value| ATTRIBUTES.include?(key) && value.to_s.bytesize <= 256 }
        copy.events = []
        copy.links = []
        copy.status = case span.status.code
        when OpenTelemetry::Trace::Status::ERROR then OpenTelemetry::Trace::Status.error
        when OpenTelemetry::Trace::Status::OK then OpenTelemetry::Trace::Status.ok
        else OpenTelemetry::Trace::Status.unset
        end
        copy.name = safe_name(span.name)
        copy.resource = OpenTelemetry::SDK::Resources::Resource.create(span.resource.attribute_enumerator.to_h.select { |key, _| RESOURCES.include?(key) })
        copy
      end
      @exporter.export(clean, timeout: [ timeout || EXPORT_TIMEOUT, EXPORT_TIMEOUT ].min)
    rescue StandardError
      OpenTelemetry::SDK::Trace::Export::FAILURE
    end

    def force_flush(timeout: nil)
      @exporter.force_flush(timeout: [ timeout || EXPORT_TIMEOUT, EXPORT_TIMEOUT ].min)
    end

    def shutdown(timeout: nil)
      @exporter.shutdown(timeout: [ timeout || SHUTDOWN_TIMEOUT, SHUTDOWN_TIMEOUT ].min)
    end

    private

    def safe_name(name)
      return name if %w[checkout.request checkout.validate_input checkout.persist_order checkout.call_internal_service checkout.finalize GET POST HTTP\ GET HTTP\ POST].include?(name)

      "application.operation"
    end
  end

  class << self
    def start(environment: "local")
      return false if ENV["OTEL_SDK_DISABLED"].to_s.casecmp?("true") || ENV["OTEL_TRACES_EXPORTER"] == "none"
      return true if @provider

      endpoint = ENV.fetch("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://localhost:4318/v1/traces")
      raise ArgumentError unless safe_endpoint?(endpoint)

      require "opentelemetry/sdk"
      require "opentelemetry/exporter/otlp"
      require_relative "reference_telemetry/exporter"
      require_relative "reference_telemetry/envelope"
      require "opentelemetry/instrumentation/rails"
      require "opentelemetry/instrumentation/net/http"

      Envelope.validate_versions!
      %w[OTEL_SERVICE_NAME OTEL_RESOURCE_ATTRIBUTES].each do |key|
        raise Envelope::Rejected if ENV[key]&.bytesize.to_i > Envelope::LIMIT
      end
      effective_resource = Envelope.new.resource(
        OpenTelemetry::SDK::Resources::Resource.default.merge(
          OpenTelemetry::SDK::Resources::Resource.create(
            "service.name" => ENV.fetch("OTEL_SERVICE_NAME", "ruby-rails-traces-demo"),
            "deployment.environment" => environment
          )
        )
      )

      exporter = Exporter.new(
        endpoint: endpoint, timeout: EXPORT_TIMEOUT, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER
      )
      batcher = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
        PrivateExporter.new(exporter), max_queue_size: QUEUE_SIZE, max_export_batch_size: BATCH_SIZE,
        exporter_timeout: EXPORT_TIMEOUT * 1000, schedule_delay: 1000, start_thread_on_boot: true
      )
      processor = EnvelopeProcessor.new(batcher)
      OpenTelemetry::SDK.configure do |c|
        c.logger = Logger.new(File::NULL)
        c.error_handler = ->(**) { nil }
        c.resource = effective_resource
        c.add_span_processor(processor)
        c.use "OpenTelemetry::Instrumentation::Rails"
        c.use "OpenTelemetry::Instrumentation::Rack"
        c.use "OpenTelemetry::Instrumentation::ActionPack"
        c.use "OpenTelemetry::Instrumentation::ActiveRecord"
        c.use "OpenTelemetry::Instrumentation::Net::HTTP"
      end
      @provider = OpenTelemetry.tracer_provider
      @provider.span_limits = OpenTelemetry::SDK::Trace::SpanLimits.new(
        attribute_count_limit: 32, attribute_length_limit: 256, event_count_limit: 8,
        link_count_limit: 8, event_attribute_count_limit: 8, event_attribute_length_limit: 256, link_attribute_count_limit: 8
      )
      at_exit { shutdown } unless @exit_hook
      @exit_hook = true
      true
    rescue StandardError, LoadError
      begin
        (processor || batcher)&.shutdown(timeout: SHUTDOWN_TIMEOUT)
      rescue StandardError
        nil
      end
      OpenTelemetry.tracer_provider = OpenTelemetry::Trace::TracerProvider.new
      @provider = nil
      warn "Telemetry unavailable; application continues without export"
      false
    end

    def shutdown
      provider = @provider
      @provider = nil
      provider&.shutdown(timeout: SHUTDOWN_TIMEOUT)
    rescue StandardError
      nil
    end

    def safe_endpoint?(endpoint)
      uri = URI.parse(endpoint)
      return false unless uri.host && !uri.userinfo && !uri.query && !uri.fragment
      return true if uri.scheme == "https"

      loopback = uri.hostname == "localhost"
      begin
        loopback ||= IPAddr.new(uri.hostname).loopback?
      rescue IPAddr::InvalidAddressError
        loopback = false
      end
      uri.scheme == "http" && loopback
    rescue URI::InvalidURIError
      false
    end
  end
end
