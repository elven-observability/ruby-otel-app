# frozen_string_literal: true

module ReferenceTelemetry
  # Application-local qualification of SDK 1.13.1's processor -> BSP contract.
  # The SDK supplies SpanData through its public exporter interface; the helper
  # does not call or override the private-annotated Span conversion method.
  class Envelope
    LIMIT = 32 * 1024
    SDK_VERSION = "1.13.1"
    API_VERSION = "1.11.1"
    class Rejected < StandardError; end

    attr_reader :used

    def self.validate_versions!(sdk = Gem.loaded_specs.fetch("opentelemetry-sdk").version.to_s,
      api = Gem.loaded_specs.fetch("opentelemetry-api").version.to_s)
      raise Rejected unless sdk == SDK_VERSION && api == API_VERSION
    end

    def initialize
      @used = 0
    end

    def charge(bytes)
      raise Rejected unless bytes.is_a?(Integer) && bytes >= 0 && bytes <= LIMIT - @used

      @used += bytes
    end

    def items(count, size)
      raise Rejected unless count <= (LIMIT - @used) / size

      charge(count * size)
    end

    def string(value, binary: false, size: nil)
      raise Rejected unless value.instance_of?(String)
      bytes = value.bytesize
      raise Rejected if size && bytes != size

      charge(64 + bytes)
      raise Rejected if !binary && !value.valid_encoding?
      # dup/String.new(value) can retain the original shared string root.
      # Appending into a fresh, bounded buffer copies the actual bytes.
      String.new(capacity: bytes, encoding: value.encoding).concat(value).freeze
    end

    def scalar(value)
      charge(16)
      case value
      when String then string(value)
      when Integer
        raise Rejected unless value.between?(-(2**63), (2**63) - 1)
        value
      when Float, TrueClass, FalseClass then value
      else raise Rejected
      end
    end

    def attributes(input)
      input ||= {}
      raise Rejected unless input.instance_of?(Hash)

      items(input.size, 96)
      input.each_with_object({}) do |(key, value), result|
        result[string(key)] = attribute_value(value)
      end.freeze
    end

    def attribute_value(value)
      return scalar(value) unless value.instance_of?(Array)

      items(value.size, 32)
      value.map { |item| scalar(item) }.freeze
    end

    def resource(input)
      charge(128)
      copied = {}
      input.attribute_enumerator.each do |key, value|
        charge(96)
        copied[string(key)] = attribute_value(value)
      end
      OpenTelemetry::SDK::Resources::Resource.create(copied.freeze)
    end

    def scope(input)
      charge(128)
      OpenTelemetry::SDK::InstrumentationScope.new(
        string(input.name), string(input.version), attributes(input.attributes)
      ).freeze
    end

    def tracestate(input)
      charge(64)
      values = input.to_h
      raise Rejected if values.size > 32

      items(values.size, 96)
      copied = values.each_with_object({}) do |(key, value), result|
        raise Rejected unless key.instance_of?(String) && value.instance_of?(String)
        raise Rejected unless key.bytesize.between?(1, 256) && value.bytesize.between?(1, 256)
        # Absolute anchors, ASCII ranges, and bounded inputs. Upstream's ^/$
        # validators otherwise accept a valid line within a multiline string.
        raise Rejected unless /\A(?:[a-z][a-z0-9_\-*\/]{0,255}|[a-z0-9][a-z0-9_\-*\/]{0,240}@[a-z][a-z0-9_\-*\/]{0,13})\z/.match?(key)
        raise Rejected unless /\A[\x20-\x2b\x2d-\x3c\x3e-\x7e]*[\x21-\x2b\x2d-\x3c\x3e-\x7e]\z/.match?(value)

        result[string(key)] = string(value)
      end
      OpenTelemetry::Trace::Tracestate.from_hash(copied.freeze).freeze
    end

    def context(input)
      charge(96)
      raise Rejected unless input.trace_flags.instance_of?(OpenTelemetry::Trace::TraceFlags)

      OpenTelemetry::Trace::SpanContext.new(
        trace_id: string(input.trace_id, binary: true, size: 16),
        span_id: string(input.span_id, binary: true, size: 8),
        trace_flags: input.trace_flags.clone(freeze: true),
        tracestate: tracestate(input.tracestate), remote: input.remote?
      ).freeze
    end

    def status(input)
      charge(64)
      description = string(input.description)
      case input.code
      when OpenTelemetry::Trace::Status::ERROR then OpenTelemetry::Trace::Status.error(description).freeze
      when OpenTelemetry::Trace::Status::OK then OpenTelemetry::Trace::Status.ok.freeze
      when OpenTelemetry::Trace::Status::UNSET then OpenTelemetry::Trace::Status.unset.freeze
      else raise Rejected
      end
    end

    def snapshot(input)
      charge(512)
      raise Rejected unless %i[internal producer consumer client server].include?(input.kind)

      out = OpenTelemetry::SDK::Trace::SpanData.new
      out.name = string(input.name)
      out.kind = input.kind
      out.status = status(input.status)
      out.parent_span_id = string(input.parent_span_id, binary: true, size: 8)
      out.total_recorded_attributes = scalar(input.total_recorded_attributes)
      out.total_recorded_events = scalar(input.total_recorded_events)
      out.total_recorded_links = scalar(input.total_recorded_links)
      out.start_timestamp = scalar(input.start_timestamp)
      out.end_timestamp = scalar(input.end_timestamp)
      out.attributes = attributes(input.attributes)
      out.resource = resource(input.resource)
      out.instrumentation_scope = scope(input.instrumentation_scope)
      out.span_id = string(input.span_id, binary: true, size: 8)
      out.trace_id = string(input.trace_id, binary: true, size: 16)
      raise Rejected unless input.trace_flags.instance_of?(OpenTelemetry::Trace::TraceFlags)

      # The pinned API TraceFlags object contains only an integer, no strings.
      out.trace_flags = input.trace_flags.clone(freeze: true)
      out.tracestate = tracestate(input.tracestate)
      out.parent_span_is_remote = !!input.parent_span_is_remote
      links = input.links || []
      items(links.size, 128)
      out.links = links.map do |link|
        OpenTelemetry::Trace::Link.new(context(link.span_context), attributes(link.attributes)).freeze
      end.freeze
      events = input.events || []
      items(events.size, 128)
      out.events = events.map do |event|
        OpenTelemetry::SDK::Trace::Event.new(string(event.name), attributes(event.attributes), scalar(event.timestamp)).freeze
      end.freeze
      out.freeze
    end
  end

  class EnvelopeProcessor
    # The pinned BSP reads only #context and #to_span_data from each queue item.
    # No ended SDK span, shallow SpanData, or original delegate is stored here.
    class QueueItem
      attr_reader :context

      def initialize(data)
        @data = data
        @context = OpenTelemetry::Trace::SpanContext.new(
          trace_id: data.trace_id, span_id: data.span_id,
          trace_flags: data.trace_flags, tracestate: data.tracestate
        ).freeze
        freeze
      end

      def to_span_data
        @data
      end
    end

    attr_reader :rejected_count

    def initialize(next_processor)
      Envelope.validate_versions!
      @next = next_processor
      @rejected_count = 0
      @closed = false
      @conversion = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(self)
    end

    def on_start(_span, _parent_context); end

    def on_finish(span)
      return if @closed

      @conversion.on_finish(span)
    end

    # This exporter performs admission only: no network I/O on Span#finish.
    def export(spans, timeout: nil)
      return OpenTelemetry::SDK::Trace::Export::SUCCESS if @closed

      spans.each do |input|
        next unless input.trace_flags.sampled?

        data = Envelope.new.snapshot(input)
        @next.on_finish(QueueItem.new(data))
      rescue StandardError
        @rejected_count += 1 if @rejected_count < (2**63) - 1
      end
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end

    def force_flush(timeout: nil)
      return OpenTelemetry::SDK::Trace::Export::SUCCESS if @closed

      @next.force_flush(timeout: timeout)
    end

    def shutdown(timeout: nil)
      return OpenTelemetry::SDK::Trace::Export::SUCCESS if @closed

      @closed = true
      @next.shutdown(timeout: timeout)
    end
  end
end
