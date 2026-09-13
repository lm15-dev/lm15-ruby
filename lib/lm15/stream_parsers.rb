# frozen_string_literal: true
module LM15
  class ProviderLM
    def delta(klass,**attrs) = StreamDeltaEvent.new(delta:klass.new(**attrs))
    def stream_error(payload,preferred)
      err = hash_or(payload['error'])
      code = present(err[preferred]) || present(err['code']) || present(err['type']) || present(payload['code']) || present(payload['error_type']) || 'provider'
      msg = present(err['message']) || payload['message'] || ''
      StreamErrorEvent.new(error:error_detail(code.to_s,msg.to_s))
    end
    def parse_stream_events(request,event)
      return [] if event.data.empty?
      return [StreamEndEvent.new] if event.data == '[DONE]'
      data = JSON.parse(event.data)
      return [] unless data.is_a?(Hash)
      case dialect
      when 'openai-chat' then chat_stream_events(data)
      when 'openai-responses' then responses_stream_events(request,data)
      when 'anthropic' then anthropic_stream_events(request,data)
      when 'gemini' then gemini_stream_events(data)
      end
    end
    def chat_stream_events(p)
      return [stream_error(p,'code')] if p['error'].is_a?(Hash)
      ch = hash_or(array_or(p['choices']).first); d = hash_or(ch['delta']); out = []
      thought = present(d['reasoning_content']) || present(d['reasoning'])
      out << delta(ThinkingDelta,text:thought.to_s) if thought
      out << delta(TextDelta,text:d['content'],logprobs:openai_logprobs(hash_or(ch['logprobs'])['content'])) if d['content'].is_a?(String) && !d['content'].empty?
      array_or(d['tool_calls']).each do |c|
        next unless c.is_a?(Hash)
        f = hash_or(c['function'])
        out << delta(ToolCallDelta,input:(f['arguments'] || '').to_s,part_index:c['index'] || 0,id:present(c['id'])&.to_s,name:present(f['name'])&.to_s)
      end
      if present(ch['finish_reason'])
        out << StreamEndEvent.new(finish_reason:CHAT_FINISH.fetch(ch['finish_reason'],'stop'),usage:p['usage'].is_a?(Hash) ? openai_usage(p['usage'],chat:true) : nil,provider_data:p)
      elsif p['usage'].is_a?(Hash)
        out << StreamEndEvent.new(usage:openai_usage(p['usage'],chat:true),provider_data:p)
      end
      out
    end
    def responses_stream_events(request,p)
      type = p['type']; idx = p['output_index'] || 0; item = hash_or(p['item'])
      if %w[response.output_item.added response.output_item.done].include?(type) && item['type'] == 'reasoning'
        return [delta(ThinkingDelta,text:'',part_index:idx)] if type == 'response.output_item.added'
        state = item.select { |k,v| %w[id encrypted_content].include?(k) && present(v) }
        return state.empty? ? [] : [delta(ContinuationDelta,provider:'openai',kind:'reasoning_item',data:state,part_index:idx)]
      end
      e = case type
      when 'response.created'
        r = hash_or(p['response']); StreamStartEvent.new(id:present(r['id'])&.to_s,model:present(r['model']) || request.model)
      when 'response.output_text.delta','response.refusal.delta'
        delta(TextDelta,text:(p['delta'] || '').to_s,part_index:idx,logprobs:openai_logprobs(p['logprobs']))
      when 'response.reasoning_summary_text.delta','response.reasoning_text.delta'
        delta(ThinkingDelta,text:(p['delta'] || '').to_s,part_index:idx)
      when 'response.output_text.annotation.added'
        c = citation_part(p['annotation'])
        delta(CitationDelta,text:c.text,url:c.url,title:c.title,part_index:idx) if c
      when 'response.output_audio.delta' then delta(AudioDelta,data:(p['delta'] || '').to_s,part_index:idx,media_type:'audio/wav')
      when 'response.output_image.delta','response.image.delta' then delta(ImageDelta,data:(p['delta'] || '').to_s,part_index:idx,media_type:'image/png')
      when 'response.output_item.added'
        delta(ToolCallDelta,input:(item['arguments'] || '').to_s,part_index:idx,id:(present(item['call_id']) || present(item['id']))&.to_s,name:present(item['name'])&.to_s) if item['type'] == 'function_call'
      when 'response.function_call_arguments.delta'
        delta(ToolCallDelta,input:(p['delta'] || '').to_s,part_index:idx,id:(present(p['call_id']) || present(p['id']))&.to_s,name:present(p['name'])&.to_s)
      when 'response.completed'
        r = hash_or(p['response']); tool = array_or(r['output']).any? { |x| x.is_a?(Hash) && x['type'] == 'function_call' }
        StreamEndEvent.new(finish_reason:tool ? 'tool_call' : 'stop',usage:openai_usage(r['usage']),provider_data:r)
      when 'response.error','error' then stream_error(p,'code')
      end
      e ? [e] : []
    end
    def anthropic_stream_events(request,p)
      idx = p['index'] || 0
      case p['type']
      when 'message_start'
        m = hash_or(p['message']); [StreamStartEvent.new(id:present(m['id'])&.to_s,model:present(m['model']) || request.model)]
      when 'content_block_start'
        b = hash_or(p['content_block'])
        if b['type'] == 'tool_use'
          input = b['input'].is_a?(Hash) ? b['input'].empty? ? '' : JSON.generate(b['input']) : (b['input'] || '').to_s
          [delta(ToolCallDelta,input:input,part_index:idx,id:present(b['id'])&.to_s,name:present(b['name'])&.to_s)]
        elsif b['type'] == 'redacted_thinking' && !b['data'].nil?
          [delta(ThinkingDelta,text:'',part_index:idx),delta(ContinuationDelta,provider:'anthropic',kind:'redacted_thinking',data:{'data'=>b['data']},part_index:idx)]
        else [] end
      when 'content_block_delta'
        d = hash_or(p['delta'])
        e = case d['type']
        when 'text_delta' then delta(TextDelta,text:(d['text'] || '').to_s,part_index:idx)
        when 'input_json_delta' then delta(ToolCallDelta,input:(d['partial_json'] || '').to_s,part_index:idx)
        when 'thinking_delta' then delta(ThinkingDelta,text:(d['thinking'] || '').to_s,part_index:idx)
        when 'signature_delta'
          delta(ContinuationDelta,provider:'anthropic',kind:'thinking_signature',data:{'signature'=>d['signature'].to_s},part_index:idx) if present(d['signature'])
        when 'citation_delta','citations_delta'
          c = d['citation'].is_a?(Hash) ? d['citation'] : d
          delta(CitationDelta,text:(present(c['cited_text']) || present(c['text']))&.to_s,url:present(c['url'])&.to_s,title:present(c['title'])&.to_s,part_index:idx)
        end
        e ? [e] : []
      when 'message_delta'
        d = hash_or(p['delta']); usage = hash_or(p['usage']).empty? ? nil : anthropic_usage(p['usage'])
        reason = d['stop_reason']
        reason || usage ? [StreamEndEvent.new(finish_reason:reason ? finish_reason(reason) : nil,usage:usage,provider_data:p)] : []
      when 'message_stop' then [StreamEndEvent.new]
      when 'error' then [stream_error(p,'type')]
      else [] end
    end
    def gemini_stream_events(p)
      return [stream_error(p,'status')] if p.key?('error')
      err = gemini_inband_error(p)
      return [StreamErrorEvent.new(error:ErrorDetail.new(code:err.code,provider_code:'inband_finish_reason',message:err.message))] if err
      c = hash_or(array_or(p['candidates']).first); logs = gemini_logprobs(c['logprobsResult']); out = []; tool = false
      array_or(hash_or(c['content'])['parts']).each_with_index do |b,i|
        next unless b.is_a?(Hash)
        if b.key?('text')
          klass = b['thought'] ? ThinkingDelta : TextDelta
          attrs = {text:(b['text'] || '').to_s,part_index:i}
          if klass == TextDelta
            attrs[:logprobs] = logs; logs = []
          end
          out << delta(klass,**attrs)
          out << delta(ContinuationDelta,provider:'gemini',kind:'thought_signature',data:{'value'=>b['thoughtSignature'].to_s},part_index:i) unless b['thoughtSignature'].nil?
        elsif b['functionCall'].is_a?(Hash)
          fc = b['functionCall']; tool = true
          out << delta(ToolCallDelta,input:JSON.generate(fc.fetch('args',{})),part_index:i,id:present(fc['id'])&.to_s,name:present(fc['name'])&.to_s)
          signature = b['thoughtSignature'] || fc['thoughtSignature']
          out << delta(ContinuationDelta,provider:'gemini',kind:'thought_signature',data:{'value'=>signature.to_s},part_index:i) unless signature.nil?
        elsif b['inlineData'].is_a?(Hash)
          inline = b['inlineData']; mime = inline['mimeType'] || 'application/octet-stream'
          klass = mime.start_with?('audio/') ? AudioDelta : mime.start_with?('image/') ? ImageDelta : nil
          out << delta(klass,data:(inline['data'] || '').to_s,part_index:i,media_type:mime) if klass
        end
      end
      if present(c['finishReason'])
        out << StreamEndEvent.new(finish_reason:finish_reason(c['finishReason'],tool:tool),usage:gemini_usage(p['usageMetadata']),provider_data:p)
      elsif out.empty? && p.key?('usageMetadata')
        out << StreamEndEvent.new(finish_reason:'stop',usage:gemini_usage(p['usageMetadata']),provider_data:p)
      end
      out
    end
    def replay_stream(request,body)
      raw = Enumerator.new { |out| LM15.parse_sse_chunks([body]).each { |sse| parse_stream_events(request,sse).each { |e| out << e } } }
      LM15.coalesce_stream(raw,model:request.model)
    end
  end
end
