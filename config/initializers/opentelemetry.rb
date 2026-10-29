# frozen_string_literal: true

require_relative "../../lib/reference_telemetry"

ReferenceTelemetry.start(environment: ENV.fetch("OTEL_DEPLOYMENT_ENVIRONMENT", Rails.env.to_s))
