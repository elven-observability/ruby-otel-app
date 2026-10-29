# frozen_string_literal: true

module ReferenceTelemetry
  # OTLP 0.37.0 sleeps in backoff without clamping to its remaining timeout.
  # This application makes one attempt; durable retry belongs in the Collector.
  # Keep the pinned exporter and the Retry-After regression test together.
  class Exporter < OpenTelemetry::Exporter::OTLP::Exporter
    SUPPORTED_VERSION = "0.37.0"
    BACKOFF_PARAMETERS = [ [ :keyreq, :retry_count ], [ :keyreq, :reason ], [ :key, :retry_after ] ].freeze

    def self.validate_upstream!(version: Gem.loaded_specs["opentelemetry-exporter-otlp"]&.version,
                                exporter: OpenTelemetry::Exporter::OTLP::Exporter)
      compatible = version.to_s == SUPPORTED_VERSION &&
        exporter.private_method_defined?(:backoff?) &&
        exporter.instance_method(:backoff?).parameters == BACKOFF_PARAMETERS
      raise ArgumentError, "unsupported OTLP exporter contract" unless compatible
    end

    def initialize(**options)
      self.class.validate_upstream!
      super
    end

    private

    def backoff?(**)
      false
    end
  end
end
