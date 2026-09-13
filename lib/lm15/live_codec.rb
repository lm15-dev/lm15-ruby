# frozen_string_literal: true
module LM15
  class ProviderLM
    def audio_native?(model) = %w[native-audio live-preview].any? { |token| model.downcase.include?(token) }
    def live_audio_format(fmt) = fmt.encoding == 'pcm16' ? {'type'=>'audio/pcm','rate'=>fmt.sample_rate} : {'type'=>"audio/#{fmt.encoding}"}
    def live_setup_frames(config)
      support!('live')
      text = config.system.is_a?(String) ? config.system : config.system ? LM15.parts_text(config.system) : nil
      funcs = config.tools.grep(FunctionTool).map { |t| {'name'=>t.name,'description'=>t.description,'parameters'=>t.parameters} }
      if dialect == 'gemini'
        setup = {'model'=>config.model.start_with?('models/') ? config.model : "models/#{config.model}"}
        setup['systemInstruction'] = {'parts'=>[{'text'=>text}]} if text && !text.empty?
        setup['tools'] = [{'functionDeclarations'=>funcs}] unless funcs.empty?
        gen = {}; gen['responseModalities'] = ['AUDIO'] if config.output_format || audio_native?(config.model)
        gen['speechConfig'] = {'voiceConfig'=>{'prebuiltVoiceConfig'=>{'voiceName'=>config.voice}}} if config.voice
        setup['generationConfig'] = gen unless gen.empty?
        setup.merge!(config.extensions || {}); setup['outputAudioTranscription'] = {} if audio_native?(config.model)
        [{'setup'=>setup}]
      else
        session = {'type'=>'realtime','output_modalities'=>config.output_format || config.voice ? ['audio'] : ['text']}
        session['instructions'] = text if text && !text.empty?
        audio = {}
        if config.output_format || config.voice
          output = {}; output['format'] = live_audio_format(config.output_format) if config.output_format
          output['voice'] = config.voice if config.voice; audio['output'] = output
        end
        audio['input'] = {'format'=>live_audio_format(config.input_format),'turn_detection'=>nil} if config.input_format
        session['audio'] = audio unless audio.empty?
        session['tools'] = funcs.map { |t| {'type'=>'function'}.merge(t) } unless config.tools.empty?
        [{'type'=>'session.update','session'=>session.merge(config.extensions || {})}]
      end
    end
    def encode_live_event(event,config = nil)
      support!('live')
      if dialect == 'gemini'
        case event.type
        when 'audio','image' then [{'realtimeInput'=>{event.type == 'audio' ? 'audio' : 'video'=>{'mimeType'=>event.media_type,'data'=>event.data}}}]
        when 'end_audio' then [{'realtimeInput'=>{'audioStreamEnd'=>true}}]
        when 'interrupt' then [{'clientContent'=>{'turnComplete'=>true}}]
        when 'text'
          return [{'realtimeInput'=>{'text'=>event.text}}] if config && audio_native?(config.model)
          [{'clientContent'=>{'turns'=>[{'role'=>'user','parts'=>[{'text'=>event.text}]}],'turnComplete'=>true}}]
        when 'turn' then [{'clientContent'=>{'turns'=>[{'role'=>'user','parts'=>event.parts.map { |p| gemini_part(p) }}],'turnComplete'=>event.turn_complete}}]
        when 'tool_result' then [{'toolResponse'=>{'functionResponses'=>[{'id'=>event.id,'response'=>{'output'=>[{'text'=>LM15.parts_text(event.content)}]}}]}}]
        else [] end
      else
        case event.type
        when 'audio' then [{'type'=>'input_audio_buffer.append','audio'=>event.data}]
        when 'end_audio' then [{'type'=>'input_audio_buffer.commit'},{'type'=>'response.create'}]
        when 'interrupt' then [{'type'=>'response.cancel'}]
        else
          item = if event.type == 'tool_result'
            {'type'=>'function_call_output','call_id'=>event.id,'output'=>LM15.parts_text(event.content)}
          else
            parts = case event.type
            when 'text' then [{'type'=>'input_text','text'=>event.text}]
            when 'image' then [{'type'=>'input_image','image_url'=>"data:#{event.media_type};base64,#{event.data}"}]
            when 'turn' then event.parts.map { |p| openai_input(p) }
            else return [] end
            {'type'=>'message','role'=>'user','content'=>parts}
          end
          frames = [{'type'=>'conversation.item.create','item'=>item}]
          frames << {'type'=>'response.create'} unless event.type == 'turn' && !event.turn_complete
          frames
        end
      end
    end
    def live_openai_usage(response)
      u = response['usage']; return nil unless u.is_a?(Hash)
      u = u.dup; u['input_tokens_details'] = u['input_token_details'] || u['input_tokens_details']; u['output_tokens_details'] = u['output_token_details'] || u['output_tokens_details']
      openai_usage(u)
    end
    def decode_live_event(raw)
      support!('live'); d = JSON.parse(raw); return [] unless d.is_a?(Hash)
      events = []
      if dialect == 'gemini'
        if d.key?('error')
          err = hash_or(d['error']); return [LiveServerErrorEvent.new(error:error_detail((err['status'] || err['code'] || 'provider').to_s,(err['message'] || '').to_s))]
        end
        array_or(hash_or(d['toolCall'])['functionCalls']).each { |fc| events << live_tool_call(fc) if fc.is_a?(Hash) }
        server = d['serverContent']; return events unless server.is_a?(Hash)
        array_or(hash_or(server['modelTurn'])['parts']).each do |p|
          next unless p.is_a?(Hash)
          if p.key?('text') then events << LiveServerTextEvent.new(text:(p['text'] || '').to_s)
          elsif p['inlineData'].is_a?(Hash)
            inline = p['inlineData']; mime = inline['mimeType'].to_s
            events << LiveServerAudioEvent.new(data:(inline['data'] || '').to_s,media_type:mime) if mime.start_with?('audio/')
          elsif p['functionCall'].is_a?(Hash) then events << live_tool_call(p['functionCall']) end
        end
        tx = hash_or(server['outputTranscription'])['text']; events << LiveServerTextEvent.new(text:tx.to_s) if tx && !tx.to_s.empty?
        u = d['usageMetadata'].is_a?(Hash) ? d['usageMetadata'] : server['usageMetadata']
        u = u.merge('candidatesTokenCount'=>u['responseTokenCount']) if u.is_a?(Hash) && u.key?('responseTokenCount')
        events << LiveServerUsageEvent.new(usage:gemini_usage(u)) if u.is_a?(Hash) && !server['turnComplete']
        events << LiveServerInterruptedEvent.new if server['interrupted']
        events << LiveServerTurnEndEvent.new(usage:gemini_usage(u)) if server['turnComplete']
      else
        case d['type']
        when 'response.output_text.delta','response.text.delta','response.output_audio_transcript.delta','response.audio_transcript.delta'
          delta = present(d['delta']) || d['text']; events << LiveServerTextEvent.new(text:delta.to_s) if delta && !delta.to_s.empty?
        when 'response.output_audio.delta'
          events << LiveServerAudioEvent.new(data:d['delta'].to_s) if present(d['delta'])
        when 'response.function_call_arguments.delta'
          events << LiveServerToolCallDeltaEvent.new(input_delta:d['delta'].to_s,id:present(d['call_id']) || present(d['id']),name:present(d['name'])) if present(d['delta'])
        when 'response.output_item.done'
          item = hash_or(d['item']); id = present(item['call_id']) || present(item['id'])
          events << LiveServerToolCallEvent.new(id:id,name:present(item['name']) || 'tool',input:LM15.parse_object(item['arguments'])) if item['type'] == 'function_call' && id
        when 'response.done','response.completed'
          response = hash_or(d['response']); u = live_openai_usage(response)
          if response['status'] == 'cancelled'
            events << LiveServerUsageEvent.new(usage:u) if u; events << LiveServerInterruptedEvent.new
          elsif array_or(response['output']).any? { |i| i.is_a?(Hash) && i['type'] == 'function_call' }
            events << LiveServerUsageEvent.new(usage:u) if u
          else events << LiveServerTurnEndEvent.new(usage:u || Usage.new) end
        when 'response.cancelled','response.canceled' then events << LiveServerInterruptedEvent.new
        when 'error','response.error'
          err = hash_or(d['error']); pc = err['code'] || err['type'] || d['code'] || d['error_type'] || 'provider'
          events << LiveServerErrorEvent.new(error:error_detail(pc.to_s,(err['message'] || d['message'] || '').to_s)) unless pc == 'response_cancel_not_active'
        end
      end
      events
    rescue JSON::ParserError,EncodingError
      []
    end
    def live_tool_call(fc) = LiveServerToolCallEvent.new(id:(present(fc['id']) || 'fc_0').to_s,name:(present(fc['name']) || 'tool').to_s,input:hash_or(fc['args']))
  end
end
