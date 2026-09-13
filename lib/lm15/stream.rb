# frozen_string_literal: true
require_relative 'sse'

module LM15
  def self.coalesce_stream(events,model: nil)
    Enumerator.new do |out|
      started,ended,finish,usage,data,rank = false,false,nil,nil,nil,-1
      events.each do |e|
        case e.type
        when 'start'
          unless started
            out << e; started = true
          end
        when 'end'
          ended = true; finish = e.finish_reason unless e.finish_reason.nil?; usage = e.usage unless e.usage.nil?
          if e.provider_data
            r = e.usage ? 2 : e.finish_reason ? 1 : 0
            if r >= rank
              data,rank = e.provider_data,r
            end
          end
        else
          if !started && e.type == 'delta'
            out << StreamStartEvent.new(model:model); started = true
          end
          out << e
        end
      end
      if ended
        out << StreamStartEvent.new(model:model) unless started
        out << StreamEndEvent.new(finish_reason:finish,usage:usage,provider_data:data)
      end
    end
  end
  def self.pcm_to_wav(bytes,sample_rate: 24_000,channels: 1,bits: 16)
    'RIFF'.b + [36 + bytes.bytesize].pack('V') + 'WAVEfmt '.b + [16,1,channels,sample_rate,sample_rate * channels * bits / 8,channels * bits / 8,bits].pack('VvvVVvv') + 'data'.b + [bytes.bytesize].pack('V') + bytes.b
  end
  class StreamAccumulator
    attr_reader :request
    def initialize(request)
      @request = request; @parts = {}; @continuation = []; @logprobs = []
      @id,@model,@finish,@usage,@provider_data = nil,nil,nil,nil,nil
    end
    def push(event)
      case event.type
      when 'start' then @id = event.id if event.id; @model = event.model if event.model
      when 'end'
        @finish = event.finish_reason if event.finish_reason; @usage = event.usage if event.usage; @provider_data = event.provider_data if event.provider_data
      when 'delta'
        d = event.delta; i = d.part_index
        if d.type == 'continuation' && i.nil?
          @continuation << d.to_state; return
        end
        b = (@parts[i || 0] ||= {})
        case d.type
        when 'text','thinking'
          (b[d.type] ||= []) << d.text
          @logprobs.concat(d.logprobs) if d.type == 'text'
        when 'tool_call'
          t = (b['tool_call'] ||= {'raw'=>''})
          t['id'] = d.id if d.id; t['name'] = d.name if d.name
          t['raw'] += d.input
        when 'audio'
          (b['audio'] ||= []) << (d.data || '')
          b['audio_type'] = d.media_type unless b.key?('audio_type')
        when 'image'
          attrs = {media_type:d.media_type || 'image/png'}
          %w[data url file_id].each { |k| attrs[k.to_sym] = d[k] unless d[k].nil? }
          b['image'] = ImagePart.new(**attrs) if attrs.length > 1
        when 'citation'
          (b['citation'] ||= []) << CitationPart.new(text:d.text,url:d.url,title:d.title)
        when 'continuation' then (b['continuation'] ||= []) << d.to_state
        end
      end
      self
    end
    def response
      unnamed = @parts.keys.sort.select { |i| @parts[i]['tool_call'] && !@parts[i]['tool_call']['name'] }
      raise StreamAssemblyError.new("tool call at part #{unnamed.first} arrived without a name (MAP-9)",partial:assemble(unnamed),part_index:unnamed.first) unless unnamed.empty?
      assemble([])
    end
    def partial
      response
    rescue StreamAssemblyError => e
      e.partial
    end
    def assemble(skip)
      parts = []
      @parts.keys.sort.each do |i|
        b = @parts[i]; c = b['continuation'] || []; start = parts.length
        parts << ThinkingPart.new(text:b['thinking'].join,continuation:c) if b['thinking']
        parts << TextPart.new(text:b['text'].join,continuation:c) if b['text']
        parts << b['image'].with(continuation:c) if b['image']
        if b['audio']
          bytes = b['audio'].filter_map do |s|
            next if s.empty?
            Base64.strict_decode64(s + '=' * ((4 - s.length % 4) % 4))
          rescue ArgumentError
            nil
          end.join.b
          mime = b['audio_type']
          if mime.nil? || %w[audio/pcm audio/pcm16].include?(mime)
            bytes = LM15.pcm_to_wav(bytes); mime = 'audio/wav'
          end
          parts << AudioPart.new(media_type:mime,data:Base64.strict_encode64(bytes),continuation:c)
        end
        parts.concat(b['citation'].map { |p| p.with(continuation:c) }) if b['citation']
        if b['tool_call'] && !skip.include?(i)
          t = b['tool_call']
          parts << ToolCallPart.new(id:t['id'] || "tool_call_#{i}",name:t['name'],input:LM15.parse_object(t['raw']),continuation:c)
        elsif parts.length == start && !skip.include?(i)
          parts << TextPart.new(text:'',continuation:c)
        end
      end
      parts << TextPart.new(text:'') if parts.empty?
      tool = parts.any? { |p| p.type == 'tool_call' }
      finish = @finish || (tool ? 'tool_call' : 'stop'); finish = 'tool_call' if finish == 'stop' && tool
      Response.new(id:@id,model:@model || request.model,message:Message.new(role:'assistant',parts:parts,continuation:@continuation),finish_reason:finish,usage:@usage || Usage.new,provider_data:@provider_data,logprobs:@logprobs.empty? ? nil : @logprobs)
    end
  end
  class ResponseStream
    include Enumerable
    attr_reader :cleanup_errors

    def initialize(events, request)
      @source = events.respond_to?(:next) ? events : events.to_enum
      @resource = events.respond_to?(:close) ? events : @source
      @acc = StreamAccumulator.new(request)
      @done = false
      @closed = false
      @reading = false
      @cleanup_errors = []
    end

    def each
      return enum_for(:each) unless block_given?
      events { |e| yield e.delta.text if e.type == 'delta' && e.delta.type == 'text' }
    end

    def events
      return enum_for(:events) unless block_given?
      raise @failure if @failure
      return if @done
      check_owner!
      @owner ||= Thread.current
      raise TypeError, 'ResponseStream already has an active reader' if @reading
      @reading = true
      begin
        until @done
          begin
            event = @source.next
          rescue StopIteration
            @done = true
            raise StreamAssemblyError.new('Stream ended without an end event (MAP-3)', partial: @acc.partial) unless @result
            break
          rescue StandardError => error
            raise unless @result
            report_cleanup_error(error)
            @done = true
            break
          end
          raise StreamAssemblyError.new('Stream emitted an event after its end event (MAP-3)', partial: @result) if @result
          if event.type == 'error'
            raise LM15.error_from_code(event.error.code, event.error.message, provider_code: event.error.provider_code)
          end
          @acc.push(event)
          @result = @acc.response if event.type == 'end'
          yield event
        end
      rescue Exception => error
        # Interrupt must unwind the transport too; preserve and re-raise it.
        @failure = error
        @done = true
        raise
      ensure
        @reading = false
        close_source if @done
      end
    end

    def response
      events { |_| }
      raise @failure if @failure
      @result
    end

    def close
      return if @closed
      check_owner!
      @done = true
      begin
        unless @result || @failure
          @failure = StreamAssemblyError.new('Stream closed before its end event (MAP-3)', partial: @acc.partial)
        end
      rescue Exception => error
        @failure = error
        raise
      ensure
        close_source
      end
      nil
    end

    private

    def check_owner!
      raise ThreadError, 'consume and close a stream on its owning thread' if @owner && @owner != Thread.current
    end

    def close_source
      return if @closed
      @closed = true
      @resource.close if @resource.respond_to?(:close)
    rescue StandardError => error
      # A close failure must not replace the original error or a valid answer.
      report_cleanup_error(error)
    end

    def report_cleanup_error(error)
      @cleanup_errors << error
      # MAP-3 requires a warning too. Avoid printing arbitrary transport messages
      # that could include credentials; details remain available to the caller.
      warn "StreamCleanupWarning: #{error.class} during stream cleanup; see cleanup_errors"
    rescue StandardError => warning_error
      # A broken warning destination cannot invalidate a completed response.
      @cleanup_errors << warning_error
    end
  end
  def self.materialize_response(events,request) = ResponseStream.new(events,request).response
end
