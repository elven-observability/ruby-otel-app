# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "json"
require "timeout"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require_relative "../lib/reference_telemetry"
require_relative "../lib/reference_telemetry/exporter"

class ReferenceTelemetryTest < Minitest::Test
  def setup
    @saved_env = ENV.to_h
    ENV.delete("OTEL_SDK_DISABLED")
    ENV.delete("OTEL_TRACES_EXPORTER")
    @server = TCPServer.new("127.0.0.1", 0)
    @bodies = Queue.new
    @code = 200
    @retry_after = "0"
    @requests = 0
    @receiver = Thread.new do
      loop do
        socket = @server.accept
        headers = +""
        headers << socket.read(1) until headers.end_with?("\r\n\r\n")
        size = headers[/content-length: (\d+)/i, 1].to_i
        @bodies << socket.read(size)
        @requests += 1
        socket.write("HTTP/1.1 #{@code} Test\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: #{@retry_after}\r\n\r\n")
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "http://127.0.0.1:#{@server.addr[1]}/v1/traces"
  end

  def teardown
    ReferenceTelemetry.shutdown
    @server.close
    @receiver.join(2)
    ENV.replace(@saved_env)
  end

  def tracer
    OpenTelemetry.tracer_provider.tracer("audit-test")
  end

  def test_healthy_export_context_and_privacy
    assert ReferenceTelemetry.start
    tracer.in_span("checkout.finalize", attributes: { "db.statement" => "select 'audit-secret-PII'", "http.method" => "POST" }) do |parent|
      tracer.in_span("checkout.persist_order") do |child|
        child.record_exception(StandardError.new("audit-secret-PII"))
        child.status = OpenTelemetry::Trace::Status.error("audit-secret-PII")
        assert_equal parent.context.trace_id, child.context.trace_id
      end
    end
    assert_equal 0, OpenTelemetry.tracer_provider.force_flush(timeout: 3)
    bytes = Timeout.timeout(3) { @bodies.pop }
    decoded = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(bytes)
    spans = decoded.resource_spans.flat_map(&:scope_spans).flat_map(&:spans)
    assert_equal 2, spans.size
    child = spans.find { |span| span.name == "checkout.persist_order" }
    parent = spans.find { |span| span.name == "checkout.finalize" }
    assert_equal parent.span_id, child.parent_span_id
    refute_includes bytes, "audit-secret-PII"
    assert_includes bytes, "checkout.finalize"
    assert_includes bytes, "http.method"
    puts "healthy_otlp_payload_bytes=#{bytes.bytesize}"
  end

  def test_disabled_does_not_create_sdk_provider
    ENV["OTEL_SDK_DISABLED"] = "TRUE"
    ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "%invalid"
    refute ReferenceTelemetry.start
    assert_equal 0, @requests
  end

  def test_invalid_configuration_fails_open_without_echoing_secrets
    ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "https://secret:password@collector.example"
    _out, error = capture_io { refute ReferenceTelemetry.start }
    refute_includes error, "password"
    assert_includes error, "application continues"
    assert_equal 0, @requests
  end

  def test_endpoint_security
    assert ReferenceTelemetry.safe_endpoint?("https://collector.example/v1/traces")
    assert ReferenceTelemetry.safe_endpoint?("http://127.0.0.1:4318/v1/traces")
    refute ReferenceTelemetry.safe_endpoint?("http://collector.example/v1/traces")
    refute ReferenceTelemetry.safe_endpoint?("https://collector.example/v1/traces?token=secret")
  end

  def test_tls_peer_verification_cannot_be_disabled_by_exporter_environment
    ENV["OTEL_RUBY_EXPORTER_OTLP_SSL_VERIFY_NONE"] = "true"
    ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "https://127.0.0.1:4318/v1/traces"
    assert ReferenceTelemetry.start
    processor = OpenTelemetry.tracer_provider.instance_variable_get(:@span_processors).first
    batcher = processor.instance_variable_get(:@next)
    exporter = batcher.instance_variable_get(:@exporter).instance_variable_get(:@exporter)
    assert_equal OpenSSL::SSL::VERIFY_PEER, exporter.instance_variable_get(:@http).verify_mode
  end

  def test_context_is_not_leaked_to_unrelated_threads
    assert ReferenceTelemetry.start
    tracer.in_span("checkout.request") do |parent|
      thread_context = Thread.new { OpenTelemetry::Trace.current_span.context }.value
      refute thread_context.valid?
      tracer.in_span("checkout.finalize") { |child| assert_equal parent.context.trace_id, child.context.trace_id }
    end
  end

  def test_backpressure_bounds_queue_and_business_continues
    @code = 503
    assert ReferenceTelemetry.start
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    GC.start
    before = GC.stat(:heap_live_slots)
    20_000.times do
      tracer.in_span("checkout.finalize", attributes: { "payload" => "x" * 4096 }) { 1 + 1 }
    end
    GC.start
    retained = GC.stat(:heap_live_slots) - before
    provider = OpenTelemetry.tracer_provider
    processor = provider.instance_variable_get(:@span_processors).first
    batcher = processor.instance_variable_get(:@next)
    assert_operator batcher.instance_variable_get(:@spans).size, :<=, ReferenceTelemetry::QUEUE_SIZE
    assert_operator retained, :<, 100_000
    ReferenceTelemetry.shutdown
    assert_operator @requests, :<, 100
    puts JSON.generate(shared_host_noisy: true, completed: 20_000, retained_slots: retained,
                       elapsed: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                       cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu, requests: @requests)
  end

  def test_retry_after_does_not_stall_shutdown
    @code = 503
    @retry_after = "3600"
    assert ReferenceTelemetry.start
    tracer.in_span("checkout.request") { 42 }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ReferenceTelemetry.shutdown
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_equal 1, @requests
  end

  def test_exporter_pin_and_upstream_hook_contract
    dependency = Bundler.definition.dependencies.find { |item| item.name == "opentelemetry-exporter-otlp" }
    assert_equal Gem::Requirement.new("= 0.37.0"), dependency.requirement
    locked = Bundler.locked_gems.specs.find { |item| item.name == "opentelemetry-exporter-otlp" }
    assert_equal "0.37.0", locked.version.to_s
    assert_equal "0.37.0", Gem.loaded_specs.fetch("opentelemetry-exporter-otlp").version.to_s
    assert_nil ReferenceTelemetry::Exporter.validate_upstream!
  end

  def test_initial_span_automatically_exports_without_flush_or_fork
    assert ReferenceTelemetry.start
    tracer.in_span("checkout.finalize") { 42 }
    bytes = Timeout.timeout(4) { @bodies.pop }
    decoded = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(bytes)
    spans = decoded.resource_spans.flat_map(&:scope_spans).flat_map(&:spans)
    assert_equal [ "checkout.finalize" ], spans.map(&:name)
    assert_equal 1, @requests
  end

  def test_snapshot_contract_change_fails_open_before_network
    require_relative "../lib/reference_telemetry/envelope"
    original = ReferenceTelemetry::Envelope.method(:validate_versions!)
    singleton = ReferenceTelemetry::Envelope.singleton_class
    singleton.define_method(:validate_versions!) do
      original.call("1.14.0", "1.11.1")
    end
    _out, error = capture_io { refute ReferenceTelemetry.start }
    assert_includes error, "application continues"
    assert_equal 0, @requests
    refute OpenTelemetry::Trace.current_span.recording?
  ensure
    singleton.define_method(:validate_versions!, original) if original
  end

  def test_oversized_envelopes_and_multiline_state_never_reach_collector
    assert ReferenceTelemetry.start
    tracer.in_span("n" * (1 << 20)) { nil }
    tracer.in_span("event") { |span| span.add_event("e" * (1 << 20)) }
    tracer.in_span("n" * 12_000, attributes: { "k" * 12_000 => "value" }) do |span|
      span.add_event("e" * 12_000)
    end
    state = OpenTelemetry::Trace::Tracestate.from_hash("tenant" => "valid\n" + ("x" * (1 << 20)))
    refute state.empty?
    remote = OpenTelemetry::Trace::SpanContext.new(
      trace_id: "t" * 16, span_id: "s" * 8,
      trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED, tracestate: state, remote: true
    )
    parent = OpenTelemetry::Trace.context_with_span(OpenTelemetry::Trace::Span.new(span_context: remote))
    OpenTelemetry::Context.with_current(parent) { tracer.in_span("checkout.finalize") { nil } }
    tracer.in_span("checkout.finalize") { nil }
    assert_equal 0, OpenTelemetry.tracer_provider.force_flush(timeout: 3)
    decoded = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(Timeout.timeout(3) { @bodies.pop })
    spans = decoded.resource_spans.flat_map(&:scope_spans).flat_map(&:spans)
    assert_equal [ "checkout.finalize" ], spans.map(&:name)
    processor = OpenTelemetry.tracer_provider.instance_variable_get(:@span_processors).first
    assert_equal 4, processor.rejected_count
  end

  def test_unsupported_exporter_version_is_rejected
    assert_raises(ArgumentError) do
      ReferenceTelemetry::Exporter.validate_upstream!(version: Gem::Version.new("0.38.0"))
    end
  end

  def test_changed_private_hook_signature_is_rejected
    incompatible = Class.new do
      private

      def backoff?(**)
        false
      end
    end
    assert_raises(ArgumentError) do
      ReferenceTelemetry::Exporter.validate_upstream!(exporter: incompatible)
    end
  end

  def test_contract_guard_failure_disables_telemetry_without_network
    original = ReferenceTelemetry::Exporter.method(:validate_upstream!)
    singleton = ReferenceTelemetry::Exporter.singleton_class
    singleton.define_method(:validate_upstream!) do |**|
      original.call(version: Gem::Version.new("0.38.0"))
    end
    assert_raises(ArgumentError) { ReferenceTelemetry::Exporter.new }
    _out, error = capture_io { refute ReferenceTelemetry.start }
    assert_includes error, "application continues"
    refute OpenTelemetry::Trace.current_span.recording?
    assert_equal 0, @requests
  ensure
    singleton.define_method(:validate_upstream!, original) if original
  end

  def test_fork_restarts_processor_and_preserves_parent_export
    assert ReferenceTelemetry.start
    pid = fork do
      tracer.in_span("checkout.finalize") { 42 }
      result = OpenTelemetry.tracer_provider.force_flush(timeout: 3)
      exit!(result)
    end
    _, status = Process.wait2(pid)
    assert status.success?
    tracer.in_span("checkout.finalize") { 42 }
    assert_equal 0, OpenTelemetry.tracer_provider.force_flush(timeout: 3)
    Timeout.timeout(3) { 2.times { @bodies.pop } }
  end

  def test_privacy_does_not_mutate_input
    require "opentelemetry/sdk"
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter))
    provider.tracer("test").in_span("unsafe-secret", attributes: { "db.statement" => "audit-secret-PII" }) { nil }
    original = exporter.finished_spans.first
    destination = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    assert_equal 0, ReferenceTelemetry::PrivateExporter.new(destination).export([ original ])
    assert_equal "audit-secret-PII", original.attributes["db.statement"]
    assert_empty destination.finished_spans.first.attributes
    assert_equal "application.operation", destination.finished_spans.first.name
  ensure
    provider&.shutdown(timeout: 1)
  end
end
