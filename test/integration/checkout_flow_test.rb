# frozen_string_literal: true

require "test_helper"
require "net/http"

class CheckoutFlowTest < ActionDispatch::IntegrationTest
  setup do
    Order.delete_all
  end

  test "POST /checkout returns success, persists order, and runs outbound HTTP call" do
    outbound_called = false
    requested_path = nil
    requested_host = nil
    mock_response = Struct.new(:code, :body).new("200", "{\"message\":\"pong\"}")

    with_stubbed_get_response(->(uri) do
      outbound_called = true
      requested_path = uri.path
      requested_host = uri.host
      mock_response
    end) do
      post "/checkout",
           params: {
             customer_id: "cust-001",
             amount_cents: 1500
           }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
    end

    assert_response :success
    assert outbound_called
    assert_equal "/internal/ping", requested_path
    assert_equal "127.0.0.1", requested_host
    assert_equal 1, Order.count
    assert_equal "completed", Order.last.status

    body = response.parsed_body
    assert body["trace_id"].present?
    assert_match(/\A[0-9a-f]{32}\z/, body["trace_id"])
  end

  test "POST /checkout with force_error returns 500 and keeps persisted order" do
    mock_response = Struct.new(:code, :body).new("200", "{\"message\":\"pong\"}")

    with_stubbed_get_response(->(_uri) do
      mock_response
    end) do
      post "/checkout",
           params: {
             customer_id: "cust-002",
             amount_cents: 2500,
             force_error: true
           }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
    end

    assert_response :internal_server_error
    assert_equal 1, Order.count
    assert_equal "processing", Order.last.status

    body = response.parsed_body
    assert_includes body["error"], "forced checkout error"
    assert body["trace_id"].present?
  end

  private

  def with_stubbed_get_response(http_block, &test_block)
    original_get_response = Net::HTTP.method(:get_response)
    Net::HTTP.define_singleton_method(:get_response, &http_block)
    test_block.call
  ensure
    Net::HTTP.define_singleton_method(:get_response, original_get_response)
  end
end
