# frozen_string_literal: true
module LM15
  SSEEvent = Struct.new(:data, :event, keyword_init: true)

  # Keep byte framing separate from UTF-8 decoding: either a character or a
  # CRLF pair can straddle transport chunks. All entry points use this parser.
  class SSEParser
    def initialize(max_line_bytes:, max_event_bytes:)
      [max_line_bytes, max_event_bytes].each do |limit|
        raise ValueError, 'SSE limits must be positive integers' unless limit.is_a?(Integer) && limit.positive?
      end
      @max_line_bytes = max_line_bytes
      @max_event_bytes = max_event_bytes
      @line = ''.b
      @skip_lf = false
      @first_line = true
      reset_event
    end

    def feed(chunk)
      bytes = chunk.b
      offset = 0
      unless bytes.empty?
        offset = 1 if @skip_lf && bytes.getbyte(0) == 10
        @skip_lf = false
      end
      while offset < bytes.bytesize
        ending = bytes.index(/[\r\n]/, offset)
        length = (ending || bytes.bytesize) - offset
        raise TransportError, 'SSE line exceeds limit' if @line.bytesize + length > @max_line_bytes
        @line << bytes.byteslice(offset, length)
        break unless ending

        @skip_lf = bytes.getbyte(ending) == 13
        consume_line { |event| yield event }
        offset = ending + 1
        if @skip_lf && offset < bytes.bytesize
          offset += 1 if bytes.getbyte(offset) == 10
          @skip_lf = false
        end
      end
    end

    def finish
      consume_line { |event| yield event } unless @line.empty?
      # Preserve the existing API's handling of a final record without a
      # trailing blank line. Response assembly still requires an end event.
      dispatch { |event| yield event }
    end

    private

    def reset_event
      @name = nil
      @data = []
      @event_bytes = 0
    end

    def consume_line
      # Charge one separator per line, independent of LF/CR/CRLF spelling.
      @event_bytes += @line.bytesize + 1
      raise TransportError, 'SSE event exceeds limit' if @event_bytes > @max_event_bytes
      raw = @line
      @line = ''.b
      if @first_line
        raw = raw.delete_prefix("\xEF\xBB\xBF".b)
        @first_line = false
      end
      line = raw.force_encoding(Encoding::UTF_8).scrub
      if line.empty?
        dispatch { |event| yield event }
        return
      end
      field, value = line.split(':', 2)
      value = (value || '').delete_prefix(' ')
      case field
      when 'event' then @name = value
      when 'data' then @data << value
      end
    end

    def dispatch
      event = SSEEvent.new(data: @data.join("\n"), event: @name) unless @data.empty?
      reset_event
      yield event if event
    end
  end
  private_constant :SSEParser

  # Raw chunks include their line separators; chunk boundaries carry no meaning.
  def self.parse_sse_chunks(chunks, max_line_bytes: 65_536, max_event_bytes: 1_048_576)
    Enumerator.new do |out|
      parser = SSEParser.new(max_line_bytes: max_line_bytes, max_event_bytes: max_event_bytes)
      chunks.each { |chunk| parser.feed(chunk) { |event| out << event } }
      parser.finish { |event| out << event }
    end
  end

  # Retain the line-oriented API, including lines with their separator removed.
  def self.parse_sse(lines, **limits)
    chunks = Enumerator.new do |out|
      lines.each do |line|
        out << line
        out << "\n" unless line.end_with?("\r", "\n")
      end
    end
    parse_sse_chunks(chunks, **limits)
  end
end
