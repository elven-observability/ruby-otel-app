# frozen_string_literal: true

require "test_helper"

class HealthAndInternalTest < ActionDispatch::IntegrationTest
  test "GET /health returns app status" do
    get "/health"

    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert body["timestamp"].present?
  end

  test "GET /internal/ping returns pong" do
    get "/internal/ping"

    assert_response :success
    body = response.parsed_body
    assert_equal "pong", body["message"]
  end
end
