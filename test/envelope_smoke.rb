# frozen_string_literal: true

require "minitest/autorun"
require "opentelemetry/sdk"
require "objspace"
require "json"
require "weakref"
require "timeout"
require_relative "../lib/reference_telemetry"
require_relative "../lib/reference_telemetry/envelope"

class EnvelopeTest < Minitest::Test
  class Capture
    attr_reader :items
    def initialize; @items = []; end
    def on_finish(item); @items << item; end
    def force_flush(timeout: nil); 0; end
    def shutdown(timeout: nil); 0; end
  end

  def fixture
    ctx = OpenTelemetry::Trace::SpanContext.new(
      trace_id: "t" * 16, span_id: "s" * 8, trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED,
      tracestate: OpenTelemetry::Trace::Tracestate.from_hash("tenant" => "value"), remote: true
    )
    OpenTelemetry::SDK::Trace::SpanData.new(
      +"operation", :server, OpenTelemetry::Trace::Status.error(+"description"), +("p" * 8),
      3, 4, 5, 100, 200, { +"key" => +"value", "array" => [ +"one", 2, 3.0, true, false ] },
      [ OpenTelemetry::Trace::Link.new(ctx, { +"link.key" => +"value" }) ],
      [ OpenTelemetry::SDK::Trace::Event.new(+"event", { +"event.key" => +"value" }, 150) ],
      OpenTelemetry::SDK::Resources::Resource.create(+"service.name" => +"test"),
      OpenTelemetry::SDK::InstrumentationScope.new(+"scope", +"version", { +"scope.key" => +"value" }),
      +("s" * 8), +("t" * 16), ctx.trace_flags, ctx.tracestate, true
    )
  end

  def test_all_span_data_fields_preserved_and_detached
    input = fixture
    budget = ReferenceTelemetry::Envelope.new
    output = budget.snapshot(input)
    # Resource/Scope/Status use identity equality; compare their public fields separately.
    assert_equal input.members, output.members
    (input.members - [ :resource, :instrumentation_scope, :status, :trace_flags, :links ]).each do |field|
      assert_equal input[field], output[field], field.to_s
    end
    assert_equal input.resource.attribute_enumerator.to_h, output.resource.attribute_enumerator.to_h
    assert_equal input.instrumentation_scope.to_a, output.instrumentation_scope.to_a
    assert_equal input.status.code, output.status.code
    assert_equal input.status.description, output.status.description
    assert_equal input.trace_flags.sampled?, output.trace_flags.sampled?
    assert_equal input.links.first.span_context.trace_id, output.links.first.span_context.trace_id
    assert output.links.first.span_context.remote?
    assert_equal input.links.first.attributes, output.links.first.attributes
    assert_operator budget.used, :<=, ReferenceTelemetry::Envelope::LIMIT
    refute_same input.resource, output.resource
    refute_same input.instrumentation_scope, output.instrumentation_scope
    refute_same input.trace_flags, output.trace_flags
    refute_same input.tracestate, output.tracestate
    input.name.replace("changed")
    input.attributes["key"].replace("changed")
    input.attributes["array"][0].replace("changed")
    input.events.first.name.replace("changed")
    input.links.first.attributes["link.key"].replace("changed")
    input.instrumentation_scope.name.replace("changed")
    assert_equal "operation", output.name
    assert_equal "value", output.attributes["key"]
    assert_equal "one", output.attributes["array"][0]
    assert_equal "event", output.events.first.name
    assert_equal "value", output.links.first.attributes["link.key"]
    assert_equal "scope", output.instrumentation_scope.name
    assert output.frozen?
    puts JSON.generate(aggregate_data_charge: budget.used, cap: ReferenceTelemetry::Envelope::LIMIT)
  end

  def test_full_envelope_rejects_before_downstream
    large = "x" * (ReferenceTelemetry::Envelope::LIMIT + 1)
    changes = {
      name: ->(s) { s.name = large }, key: ->(s) { s.attributes = { large => "v" } },
      value: ->(s) { s.attributes = { "k" => large } },
      resource: ->(s) { s.resource = OpenTelemetry::SDK::Resources::Resource.create("resource" => large) },
      scope: ->(s) { s.instrumentation_scope.name = large },
      scope_version: ->(s) { s.instrumentation_scope.version = large },
      scope_attributes: ->(s) { s.instrumentation_scope.attributes = { "scope" => large } },
      event: ->(s) { s.events.first.name = large },
      event_attributes: ->(s) { s.events.first.attributes = { "event" => large } },
      link_attributes: ->(s) { s.links = [ OpenTelemetry::Trace::Link.new(s.links.first.span_context, "link" => large) ] },
      status: ->(s) { s.status = OpenTelemetry::Trace::Status.error(large) },
      aggregate: ->(s) { s.attributes = (1..16).to_h { |i| [ i.to_s, "x" * 2048 ] } },
      array: ->(s) { s.attributes = { "array" => Array.new(4096, true) } }
    }
    changes.each do |name, change|
      data = fixture
      change.call(data)
      downstream = Capture.new
      processor = ReferenceTelemetry::EnvelopeProcessor.new(downstream)
      assert_nil processor.on_finish(Struct.new(:to_span_data).new(data)), name.to_s
      assert_empty downstream.items, name.to_s
      assert_equal 1, processor.rejected_count, name.to_s
    end
  end

  def test_tracestate_strict_single_line
    bad = [
      [ "tenant\nother", "value" ], [ "tenant", "valid\n" + ("x" * (1 << 20)) ],
      [ "tenant", "valid\nother" ], [ "tenant", "trailing " ]
    ]
    bad.each do |key, value|
      state = OpenTelemetry::Trace::Tracestate.from_hash(key => value)
      next if state.empty?
      assert_raises(ReferenceTelemetry::Envelope::Rejected) { ReferenceTelemetry::Envelope.new.tracestate(state) }
    end
    original = OpenTelemetry::Trace::Tracestate.from_string("first=value,1tenant@vendor=opaque")
    output = ReferenceTelemetry::Envelope.new.tracestate(original)
    assert_equal original.to_h, output.to_h
    refute_same original, output
  end

  def test_version_guard_and_closed_processor
    assert_raises(ReferenceTelemetry::Envelope::Rejected) { ReferenceTelemetry::Envelope.validate_versions!("1.14.0", "1.11.1") }
    assert_raises(ReferenceTelemetry::Envelope::Rejected) { ReferenceTelemetry::Envelope.validate_versions!("1.13.1", "1.12.0") }
    downstream = Capture.new
    processor = ReferenceTelemetry::EnvelopeProcessor.new(downstream)
    assert_equal 0, processor.shutdown(timeout: 1)
    processor.on_finish(Struct.new(:to_span_data).new(fixture))
    assert_empty downstream.items
  end

  def test_strings_detach_capacity_and_already_small_tail_views
    [ :capacity, :slice, :byteslice ].each do |mode|
      parent = "p" * (1 << 20)
      value = case mode
      when :capacity then String.new(capacity: 1 << 20).concat("v" * 128)
      when :slice then parent[-128, 128]
      else parent.byteslice(-128, 128)
      end
      copied = ReferenceTelemetry::Envelope.new.string(value)
      assert_equal value, copied
      refute_same value, copied
      assert_operator ObjectSpace.memsize_of(copied), :<, 1024
      refute JSON.parse(ObjectSpace.dump(copied))["shared"], mode.to_s
      puts JSON.generate(mode: mode, source_memsize: ObjectSpace.memsize_of(value),
                         copied_memsize: ObjectSpace.memsize_of(copied), copied_shared: false)
    end
  end

  class BlockedExporter
    attr_reader :entered, :release
    def initialize; @entered = Queue.new; @release = Queue.new; end
    def export(spans, timeout: nil); @entered << true; @release.pop; 0; end
    def shutdown(timeout: nil); 0; end
    def force_flush(timeout: nil); 0; end
  end

  def metadata_with_borrowed_roots(bounded)
    roots = []
    tail = lambda do
      parent = ("p" * (1 << 20)).freeze
      roots << WeakRef.new(parent)
      parent.byteslice(-128, 128)
    end
    input = fixture
    input.name = tail.call
    input.attributes = { tail.call => tail.call, "array" => [ tail.call ] }
    input.resource = OpenTelemetry::SDK::Resources::Resource.create(tail.call => tail.call)
    input.instrumentation_scope = OpenTelemetry::SDK::InstrumentationScope.new(
      tail.call, tail.call, { tail.call => tail.call })
    input.events.first.name = tail.call
    input.events.first.attributes = { tail.call => tail.call }
    input.links = [ OpenTelemetry::Trace::Link.new(input.links.first.span_context, tail.call => tail.call) ]
    input.status = OpenTelemetry::Trace::Status.error(tail.call)
    input.tracestate = OpenTelemetry::Trace::Tracestate.from_hash("tenant" => tail.call)
    [ bounded ? ReferenceTelemetry::Envelope.new.snapshot(input) : input, roots ]
  end

  def test_all_metadata_backing_is_detached
    [ false, true ].each do |bounded|
      # Release the caller's native/VM stack before testing queue ownership;
      # conservative GC can otherwise retain dead input temporaries on Linux.
      data, roots = Thread.new { metadata_with_borrowed_roots(bounded) }.value
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
      alive = roots.count(&:weakref_alive?)
      if bounded
        assert_equal 0, alive
      else
        # Native Hash key handling may already detach some small keys.
        assert_operator alive, :>=, 8
      end
      assert_equal 128, data.name.bytesize
      assert_equal 128, data.instrumentation_scope.name.bytesize
      assert_equal 128, data.events.first.name.bytesize
      assert_equal 128, data.tracestate["tenant"].bytesize
      puts JSON.generate(bounded: bounded, metadata_source_roots: roots.size, roots_alive: roots.count(&:weakref_alive?))
    end
  end

  def enqueue_roots(processor, mode)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    tracer = provider.tracer("retainer-probe")
    roots = []
    8.times do
      parent = ("p" * (1 << 20)).freeze
      value = mode == :capacity ? String.new(capacity: 1 << 20).concat("v" * 128) : parent.byteslice(-128, 128)
      roots << WeakRef.new(mode == :capacity ? value : parent)
      tracer.in_span("operation", attributes: { "value" => value }) { nil }
    end
    roots
  end

  def test_actual_blocked_bsp_has_no_source_roots
    [ [ :capacity, false ], [ :capacity, true ], [ :tail, false ], [ :tail, true ] ].each do |mode, bounded|
      exporter = BlockedExporter.new
      batcher = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter,
        max_queue_size: 16, max_export_batch_size: 1, schedule_delay: 60_000, start_thread_on_boot: true)
      processor = bounded ? ReferenceTelemetry::EnvelopeProcessor.new(batcher) : batcher
      provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      provider.add_span_processor(processor)
      provider.tracer("blocker").in_span("initial") { nil }
      Timeout.timeout(3) { exporter.entered.pop }
      roots = enqueue_roots(processor, mode)
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
      assert_equal bounded ? 0 : 8, roots.count(&:weakref_alive?), "source roots: #{mode}"
      queued = batcher.instance_variable_get(:@spans)
      assert_equal 8, queued.size
      assert queued.all? { |item| item.instance_of?(ReferenceTelemetry::EnvelopeProcessor::QueueItem) } if bounded
      queued.each do |item|
        value = item.to_span_data.attributes.fetch("value")
        dump = JSON.parse(ObjectSpace.dump(value))
        if bounded
          assert_operator ObjectSpace.memsize_of(value), :<, 1024
          refute dump["shared"]
        elsif mode == :capacity
          assert_operator ObjectSpace.memsize_of(value), :>=, 1 << 20
        else
          assert dump["shared"]
        end
      end
      puts JSON.generate(mode: mode, bounded: bounded, queued: queued.size, source_roots_alive: roots.count(&:weakref_alive?))
    ensure
      16.times { exporter.release << true } if exporter
      processor&.shutdown(timeout: 2)
    end
  end
end
