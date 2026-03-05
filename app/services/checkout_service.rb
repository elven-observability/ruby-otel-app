# frozen_string_literal: true

require "net/http"
require "uri"

class CheckoutService
  class CheckoutError < StandardError; end

  TRACER = OpenTelemetry.tracer_provider.tracer("checkout-service", "1.0.0")

  def initialize(customer_id:, amount_cents:, force_error:, internal_url:)
    @customer_id = customer_id
    @amount_cents = amount_cents
    @force_error = force_error
    @internal_url = internal_url
  end

  def call
    valid_amount = with_span("checkout.validate_input") { validate_input! }
    order = with_span("checkout.persist_order") { persist_order!(valid_amount) }
    with_span("checkout.call_internal_service") { call_internal_service! }
    with_span("checkout.finalize") { finalize_order!(order) }
    order
  rescue CheckoutError
    raise
  rescue StandardError => e
    raise CheckoutError, e.message
  end

  private

  def with_span(name, attributes = {})
    TRACER.in_span(name, attributes: attributes) do |span|
      yield
    rescue StandardError => e
      span.record_exception(e)
      span.status = OpenTelemetry::Trace::Status.error(e.message)
      raise
    end
  end

  def validate_input!
    raise CheckoutError, "customer_id must be provided" if @customer_id.to_s.strip.empty?

    amount = Integer(@amount_cents, exception: false)
    raise CheckoutError, "amount_cents must be a positive integer" unless amount&.positive?

    amount
  end

  def persist_order!(amount)
    Order.create!(
      customer_id: @customer_id,
      amount_cents: amount,
      status: "processing"
    )
  end

  def call_internal_service!
    uri = URI.parse(@internal_url)
    response = Net::HTTP.get_response(uri)

    return response if response.code.to_i.between?(200, 299)

    raise CheckoutError, "internal ping failed with status #{response.code}"
  end

  def finalize_order!(order)
    raise CheckoutError, "forced checkout error for trace demonstration" if @force_error

    order.update!(status: "completed")
    order
  end
end
