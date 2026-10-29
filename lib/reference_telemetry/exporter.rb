# frozen_string_literal: true

module ReferenceTelemetry
  # OTLP 0.37.0 sleeps in backoff without clamping to its remaining timeout.
  # This application makes one attempt; durable retry belongs in the Collector.
  # Keep the pinned exporter and the Retry-After regression test together.
  class Exporter < OpenTelemetry::Exporter::OTLP::Exporter
    private

    def backoff?(**)
      false
    end
  end
end
