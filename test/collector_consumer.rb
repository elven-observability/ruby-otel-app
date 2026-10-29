# frozen_string_literal: true

require "net/http"
require "socket"
require "json"
require "timeout"
require "opentelemetry/exporter/otlp"

server = TCPServer.new("127.0.0.1", 0)
bodies = Queue.new
receiver = Thread.new do
  loop do
    socket = server.accept
    headers = +""
    headers << socket.read(1) until headers.end_with?("\r\n\r\n")
    bodies << socket.read(headers[/content-length: (\d+)/i, 1].to_i)
    socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    socket.close
  end
rescue IOError, Errno::EBADF
  nil
end

pid = nil
begin
  pid = Process.spawn({ "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" => "http://127.0.0.1:#{server.addr[1]}/v1/traces" }, "bundle", "exec", "rails", "server", "-b", "127.0.0.1", out: File::NULL, err: File::NULL)
  Timeout.timeout(30) do
    loop do
      begin
        break if Net::HTTP.get_response(URI("http://127.0.0.1:3000/health")).code == "200"
      rescue Errno::ECONNREFUSED, EOFError
        nil
      end
      sleep 0.1
    end
  end
  uri = URI("http://127.0.0.1:3000/checkout")
  request = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" })
  request.body = JSON.generate(customer_id: "audit-secret-PII", amount_cents: 100)
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) { |http| http.request(request) }
  raise "checkout failed #{response.code}" unless response.code == "200"

  result = JSON.parse(response.body)
  raise "no trace identity" unless result["trace_id"]&.match?(/\A[0-9a-f]{32}\z/)

  shutdown_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Process.kill("TERM", pid)
  _, status = Timeout.timeout(10) { Process.wait2(pid) }
  pid = nil
  shutdown_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - shutdown_started
  payloads = []
  payloads << bodies.pop until bodies.empty?
  spans, scopes = [], []
  payloads.each do |bytes|
    raise "PII exported" if bytes.include?("audit-secret-PII")

    decoded = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(bytes)
    decoded.resource_spans.flat_map(&:scope_spans).each do |scope|
      scopes << scope.scope.name
      spans.concat(scope.spans)
    end
  end
  names = spans.map(&:name).uniq
  raise "missing manual spans" unless names.include?("checkout.request") && names.include?("checkout.persist_order")
  raise "missing DB instrumentation" unless scopes.any? { |name| name.include?("ActiveRecord") }
  raise "missing inbound HTTP instrumentation" unless scopes.any? { |name| name.include?("Rack") }
  raise "missing HTTP client instrumentation" unless scopes.any? { |name| name.include?("Net::HTTP") }

  puts JSON.generate(runtime: RUBY_DESCRIPTION, web_concurrency: ENV.fetch("WEB_CONCURRENCY", "single"), checkout: result["status"], packets: payloads.size,
                     payload_bytes: payloads.sum(&:bytesize), spans: spans.size, names: names, scopes: scopes.uniq, private_value_exported: false,
                     shutdown_seconds: shutdown_seconds, signaled: status.signaled?, termsig: status.termsig, exit_status: status.exitstatus)
ensure
  if pid
    Process.kill("TERM", pid) rescue nil
    begin
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end
  server.close
  receiver.join(2)
end
