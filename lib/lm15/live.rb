# frozen_string_literal: true
module LM15
  Turn = Struct.new(:ended_by,:text,:audio,:audio_media_type,:tool_calls,:usage,:error,:events,keyword_init:true) do
    def ok = ended_by == 'turn_end'
    alias ok? ok
  end
  def self.sum_usage(a,b)
    return b unless a
    Usage.new(**Usage.fields.keys.to_h { |k| x,y = a.public_send(k),b.public_send(k); [k.to_sym,x && y ? x + y : nil] })
  end
  def self.materialize_turn(events)
    text = ''; audio = ''.b; mime = nil; calls = []; usage = nil; error = nil
    events.each do |e|
      case e.type
      when 'text' then text += e.text
      when 'audio'
        raise ValueError,'a turn cannot concatenate different audio media types' if mime && e.media_type && mime != e.media_type
        mime ||= e.media_type; audio << Base64.strict_decode64(e.data)
      when 'tool_call' then calls << ToolCallPart.new(id:e.id,name:e.name,input:e.input)
      when 'turn_end','usage' then usage = sum_usage(usage,e.usage)
      when 'error' then error = e.error
      end
    end
    ended = events.last&.type
    Turn.new(ended_by:%w[turn_end interrupted error tool_call].include?(ended) ? ended : 'incomplete',text:text,audio:audio,audio_media_type:mime,tool_calls:calls.freeze,usage:usage,error:error,events:events.dup.freeze).freeze
  end
  class TurnView
    include Enumerable
    def initialize(session)
      @session = session; @events = []; @done = false; @failure = nil; @reading = Mutex.new
    end
    def snapshot = LM15.materialize_turn(@events)
    def next
      raise TransportError,'turn view already has an active reader' unless @reading.try_lock
      begin
        raise @failure if @failure; raise StopIteration if @done
        event = @session.recv; raise TransportError,'live session closed before turn boundary' unless event
        @events << event; @done = true if %w[turn_end interrupted error].include?(event.type); event
      rescue StopIteration
        raise
      rescue StandardError => e
        @failure = e; raise
      ensure
        @reading.unlock
      end
    end
    def each
      return enum_for(:each) unless block_given?
      loop { yield self.next }; self
    end
    def result
      return @result if @result
      raise @failure if @failure
      each { |e| break if e.type == 'tool_call' } unless @events.last&.type == 'tool_call'
      value = snapshot; raise TransportError,'turn view closed before turn boundary; inspect snapshot' if value.ended_by == 'incomplete'
      @done = true; @result = value
    end
    def close
      raise TransportError,'stop the active turn reader before closing its view' unless @reading.try_lock
      begin @done = true; ensure @reading.unlock end
    end
  end
  class LiveSession
    include Enumerable
    def initialize(ws:,lm:,config:)
      @ws,@lm,@config = ws,lm,config; @pending = []; @closed = false; @send_lock = Mutex.new; @recv_lock = Mutex.new
    end
    def send(event)
      raise TransportError,'live session is closed' if @closed
      event = LM15.from_dict('live_client_event',event) if event.is_a?(Hash)
      @send_lock.synchronize { @lm.encode_live_event(event,@config).each { |f| @ws.send(JSON.generate(f)) } }
      self
    end
    def send_text(text) = send(LiveClientTextEvent.new(text:text))
    def send_turn(content,turn_complete:true) = send(LiveClientTurnEvent.new(parts:LM15.content(content),turn_complete:turn_complete))
    # Ruby strings carry either bytes or text: bytes are encoded by default;
    # base64:true makes already encoded data explicit.
    def send_audio(bytes,media_type:'audio/pcm;rate=16000',base64:false) = send(LiveClientAudioEvent.new(data:base64 ? bytes : Base64.strict_encode64(bytes),media_type:media_type))
    def send_image(bytes,media_type:'image/jpeg',base64:false) = send(LiveClientImageEvent.new(data:base64 ? bytes : Base64.strict_encode64(bytes),media_type:media_type))
    def send_tool_result(results)
      results.each { |id,value| send(LiveClientToolResultEvent.new(id:id,content:LM15.content(value))) }; self
    end
    def interrupt = send(LiveClientInterruptEvent.new)
    def end_audio = send(LiveClientEndAudioEvent.new)
    def recv
      raise TransportError,'live session already has an active receiver' unless @recv_lock.try_lock
      begin
        loop do
          return nil if @closed
          return @pending.shift unless @pending.empty?
          raw = @ws.recv; return nil unless raw
          @pending.concat(@lm.decode_live_event(raw))
        end
      ensure @recv_lock.unlock end
    end
    def each
      return enum_for(:each) unless block_given?
      while (e = recv); yield e; end; self
    end
    def turn = TurnView.new(self)
    def close
      return if @closed
      @closed = true; @ws.close
    end
    def inspect = "#<LM15::LiveSession provider=#{@lm.provider}>"
  end
  class ProviderLM
    def live(config,connect: ->(url,headers:) { WebSocket.new(url,headers:headers) })
      config = LiveConfig.from_dict(config) if config.is_a?(Hash)
      support!('live'); frames = live_setup_frames(config)
      # Reuse the access policy for auth and host settings, then change only
      # the websocket door. No credentials are cached in setup/config values.
      wire = emit('GET','realtime',params:dialect == 'gemini' ? {} : {'model'=>config.model})
      uri = URI.parse(wire.url); uri.scheme = uri.scheme == 'https' ? 'wss' : 'ws'; headers = wire.headers.dup
      if dialect == 'gemini'
        uri.path = '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
        key = headers.delete('x-goog-api-key')
        uri.query = URI.encode_www_form('key'=>key) if key
      end
      ws = connect.call(uri.to_s,headers:headers)
      begin
        frames.each { |f| ws.send(JSON.generate(f)) }
        if dialect == 'gemini'
          loop do
            raw = ws.recv; raise TransportError,'live connection closed during setup' unless raw
            d = begin JSON.parse(raw); rescue JSON::ParserError; nil end
            next unless d.is_a?(Hash)
            break if d.key?('setupComplete')
            if d.key?('error')
              err = hash_or(d['error']); raise InvalidRequestError.new("Live setup failed: #{err['message']}",provider:provider,provider_code:err['status'])
            end
          end
        end
        session = LiveSession.new(ws:ws,lm:self,config:config)
        return session unless block_given?
        begin yield session; ensure session.close end
      rescue Exception
        ws.close; raise
      end
    end
  end
end
