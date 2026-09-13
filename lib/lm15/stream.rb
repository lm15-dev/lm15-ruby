# frozen_string_literal: true
module LM15
  SSEEvent = Struct.new(:data,:event, keyword_init: true)
  def self.parse_sse(lines, max_line_bytes: 65_536, max_event_bytes: 1_048_576)
    Enumerator.new do |out|
      name,data,size = nil,[],0
      lines.each do |raw|
        raise TransportError,'SSE line exceeds limit' if raw.bytesize > max_line_bytes
        size += raw.bytesize
        raise TransportError,'SSE event exceeds limit' if size > max_event_bytes
        line = raw.dup.force_encoding(Encoding::UTF_8).scrub.sub(/[\r\n]+\z/,'')
        if line.empty?
          out << SSEEvent.new(data:data.join("\n"),event:name) unless data.empty?
          name,data,size = nil,[],0
        elsif line.start_with?('event:')
          name = line.delete_prefix('event:').strip
        elsif line.start_with?('data:')
          data << line.delete_prefix('data:').delete_prefix(' ')
        end
      end
      out << SSEEvent.new(data:data.join("\n"),event:name) unless data.empty?
    end
  end
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
    def initialize(events,request)
      @source = events.to_enum; @acc = StreamAccumulator.new(request); @done = false; @reading = false; @cleanup_errors = []
    end
    def each
      return enum_for(:each) unless block_given?
      events { |e| yield e.delta.text if e.type == 'delta' && e.delta.type == 'text' }
    end
    def events
      return enum_for(:events) unless block_given?
      raise @failure if @failure
      return if @done
      raise TypeError,'ResponseStream already has an active reader' if @reading
      @reading = true
      begin
        loop do
          begin
            e = @source.next
          rescue StopIteration
            @done = true
            raise StreamAssemblyError.new('Stream ended without an end event (MAP-3)',partial:@acc.partial) unless @result
            break
          rescue StandardError => error
            raise unless @result
            @cleanup_errors << error
            warn "StreamCleanupWarning: #{error.class}: #{error.message}"
            @done = true; break
          end
          raise StreamAssemblyError.new('Stream emitted an event after its end event (MAP-3)',partial:@result) if @result
          raise LM15.error_from_code(e.error.code,e.error.message,provider_code:e.error.provider_code) if e.type == 'error'
          @acc.push(e)
          @result = @acc.response if e.type == 'end'
          yield e
        end
      rescue StandardError => error
        @failure = error
        raise
      ensure
        @reading = false
      end
    end
    def response
      events { |_| }
      @result
    end
    def close
      return if @done
      @done = true
      @failure = StreamAssemblyError.new('Stream closed before its end event (MAP-3)',partial:@acc.partial) unless @result
      @source.close if @source.respond_to?(:close)
      nil
    end
  end
  def self.materialize_response(events,request) = ResponseStream.new(events,request).response
end
