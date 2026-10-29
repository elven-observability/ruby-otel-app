# frozen_string_literal: true

class CheckoutController < ApplicationController
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

  private

  def checkout_params
    payload = params.permit(:customer_id, :amount_cents, :force_error)
    {
      customer_id: payload.fetch(:customer_id),
      amount_cents: payload.fetch(:amount_cents),
      force_error: ActiveModel::Type::Boolean.new.cast(payload[:force_error])
    }
  end

  def internal_ping_url
    ENV.fetch("INTERNAL_PING_URL", "http://127.0.0.1:#{ENV.fetch('PORT', 3000)}/internal/ping")
  end

  def current_trace_id
    span_context = OpenTelemetry::Trace.current_span.context
    return nil unless span_context.valid?

    span_context.hex_trace_id
  end
end
