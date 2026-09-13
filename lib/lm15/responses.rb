# frozen_string_literal: true
module LM15
  class ProviderLM
    GEMINI_FINISH_ERRORS = %w[SAFETY RECITATION LANGUAGE BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_OTHER NO_IMAGE IMAGE_RECITATION UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS MISSING_THOUGHT_SIGNATURE MALFORMED_RESPONSE].freeze
    CHAT_FINISH = {'stop'=>'stop','length'=>'length','tool_calls'=>'tool_call','function_call'=>'tool_call','content_filter'=>'content_filter'}.freeze
    def hash_or(value) = value.is_a?(Hash) ? value : {}
    def array_or(value) = value.is_a?(Array) ? value : []
    def present(value) = value.nil? || value == false || value == '' ? nil : value
    def wire_type(v)
      {String=>'str',Integer=>'int',Float=>'float',Array=>'list',Hash=>'dict',NilClass=>'NoneType',TrueClass=>'bool',FalseClass=>'bool'}.fetch(v.class,v.class.name)
    end
    def unmapped!(list,path,type)
      list << {'path'=>path,'type'=>present(type)&.to_s || '<missing>'}
    end
    def continuation(provider,kind,data) = [ContinuationState.new(provider:provider,kind:kind,data:data)]
    def unnamed!(path) = raise(ProviderError.new("#{provider}: #{path} is a tool call with no name; lm15 does not guess which tool the model meant (MAP-9)",provider:provider))
    def openai_usage(data,chat: false)
      u = hash_or(data)
      ind = hash_or(u[chat ? 'prompt_tokens_details' : 'input_tokens_details'])
      outd = hash_or(u[chat ? 'completion_tokens_details' : 'output_tokens_details'])
      Usage.new(input_tokens:u[chat ? 'prompt_tokens' : 'input_tokens'],output_tokens:u[chat ? 'completion_tokens' : 'output_tokens'],total_tokens:u['total_tokens'],reasoning_tokens:outd['reasoning_tokens'],cache_read_tokens:ind['cached_tokens'],cache_write_tokens:ind['cache_write_tokens'],input_audio_tokens:ind['audio_tokens'],output_audio_tokens:outd['audio_tokens'])
    end
    def anthropic_usage(data)
      u = hash_or(data)
      Usage.new(input_tokens:u['input_tokens'],output_tokens:u['output_tokens'],cache_read_tokens:u['cache_read_input_tokens'],cache_write_tokens:u['cache_creation_input_tokens'],reasoning_tokens:hash_or(u['output_tokens_details'])['thinking_tokens'])
    end
    def modality_tokens(details)
      values = array_or(details).select { |e| e.is_a?(Hash) && e['modality'] == 'AUDIO' }.map { |e| e.fetch('tokenCount',0) }
      values.empty? ? nil : values.sum
    end
    def gemini_usage(data)
      u = hash_or(data); return Usage.new if u.empty?
      Usage.new(input_tokens:u.fetch('promptTokenCount',0),output_tokens:u.fetch('candidatesTokenCount',u.fetch('responseTokenCount',0)),total_tokens:u['totalTokenCount'],cache_read_tokens:u['cachedContentTokenCount'],reasoning_tokens:u['thoughtsTokenCount'],input_audio_tokens:modality_tokens(u['promptTokensDetails']),output_audio_tokens:modality_tokens(u['candidatesTokensDetails'] || u['responseTokensDetails']))
    end
    def openai_logprobs(entries)
      array_or(entries).filter_map do |e|
        next unless e.is_a?(Hash) && e.key?('token') && e.key?('logprob')
        top = array_or(e['top_logprobs']).filter_map do |a|
          next unless a.is_a?(Hash) && a.key?('token') && a.key?('logprob')
          TopLogprob.new(token:a['token'].to_s,logprob:a['logprob'].to_f,bytes:a['bytes'].is_a?(Array) ? a['bytes'] : nil)
        end
        TokenLogprob.new(token:e['token'].to_s,logprob:e['logprob'].to_f,bytes:e['bytes'].is_a?(Array) ? e['bytes'] : nil,top:top)
      end
    end
    def gemini_logprobs(data)
      d = hash_or(data)
      array_or(d['chosenCandidates']).each_with_index.filter_map do |e,i|
        next unless e.is_a?(Hash)
        top = array_or(hash_or(array_or(d['topCandidates'])[i])['candidates']).filter_map { |a| TopLogprob.new(token:(a['token'] || '').to_s,logprob:(a['logProbability'] || 0).to_f,token_id:a['tokenId']) if a.is_a?(Hash) }
        TokenLogprob.new(token:(e['token'] || '').to_s,logprob:(e['logProbability'] || 0).to_f,token_id:e['tokenId'],top:top)
      end
    end
    def citation_part(data,source = nil,anthropic: false)
      return nil unless data.is_a?(Hash)
      url = present(data['url']) || present(data['uri'])
      title = if anthropic then present(data['title']) || present(data['document_title']) || present(data['source_title'])
      else present(data['title']) || present(data['filename']) || present(data['file_id']) end
      text = (anthropic ? %w[cited_text text quote] : %w[text snippet cited_text quote]).filter_map { |k| present(data[k]) }.first
      if !text && source && data['start_index'].is_a?(Numeric) && data['end_index'].is_a?(Numeric)
        a,b = data.values_at('start_index','end_index').map(&:to_i)
        text = source[a...b] if a >= 0 && a < b && b <= source.length
      end
      return nil unless url || title || text
      CitationPart.new(url:url&.to_s,title:title&.to_s,text:text&.to_s)
    end
    def finish_reason(raw,tool: false,data: nil,unmapped: nil,path: 'choices[0]')
      return 'tool_call' if tool
      case dialect
      when 'anthropic'
        return 'length' if %w[max_tokens model_context_window_exceeded].include?(raw)
        return 'tool_call' if %w[tool_use pause_turn].include?(raw)
        return 'content_filter' if %w[refusal safety content_filter].include?(raw)
      when 'gemini'
        return 'length' if raw == 'MAX_TOKENS'
        return 'content_filter' if %w[SAFETY RECITATION BLOCKLIST PROHIBITED_CONTENT SPII].include?(raw)
      when 'openai-chat'
        return CHAT_FINISH[raw] if CHAT_FINISH[raw]
        unmapped!(unmapped,"#{path}.finish_reason",raw) if present(raw) && unmapped
      else
        d = hash_or(data); reason = hash_or(d['incomplete_details'])['reason'].to_s.downcase
        return 'length' if d['status'] == 'incomplete' && reason.include?('token')
        return 'content_filter' if reason.include?('content_filter') || reason.include?('safety')
      end
      'stop'
    end
    def response_error!(data)
      return unless data['error'].is_a?(Hash)
      e = data['error']; pc = present(e['code'])&.to_s
      code = OPENAI_ERRORS.fetch(pc,'server')
      raise LM15.error_from_code(code,(e['message'] || pc || 'provider error').to_s,provider:provider,provider_code:pc)
    end
    def parse_response(request,response)
      raise normalize_error(response.status,response.body,headers:response.headers) if response.status >= 400
      data = response.json
      raise TypeError,'provider response must be a JSON object' unless data.is_a?(Hash)
      case dialect
      when 'openai-chat' then response_from_openai_chat(data,model:request.model)
      when 'openai-responses' then parse_responses(data,request.model)
      when 'anthropic' then parse_anthropic(data,request.model)
      when 'gemini' then parse_gemini(data,request.model)
      end
    end
    def make_response(data,model,parts,usage,finish,unmapped,logprobs = [],id: data['id'])
      parts = [TextPart.new(text:'')] if parts.empty?
      raw = unmapped.empty? ? data : data.merge('_lm15_unmapped'=>unmapped)
      Response.new(id:present(id)&.to_s,model:model,message:Message.new(role:'assistant',parts:parts),usage:usage,finish_reason:finish,provider_data:raw,logprobs:logprobs.empty? ? nil : logprobs)
    end
    def response_from_openai_chat(data,model: nil,choice: nil)
      response_error!(data)
      choices = data['choices'] || []
      raise TypeError,'choices must be an array' unless choices.is_a?(Array)
      unsupported('multiple choices; pass choice: to select one') if choice.nil? && choices.length > 1
      raise ValueError,'choice index out of bounds' if choice && !(0...choices.length).cover?(choice)
      idx = choice || 0; path = "choices[#{idx}]"; unmapped = []; parts = []
      ch = hash_or(choices[idx]); m = hash_or(ch['message'])
      unmapped!(unmapped,path,wire_type(choices[idx])) if choices.any? && !choices[idx].is_a?(Hash)
      thought = present(m['reasoning_content']) || present(m['reasoning'])
      parts << ThinkingPart.new(text:thought.to_s) if thought
      content = m['content']
      if content.is_a?(String)
        parts << TextPart.new(text:content) unless content.empty?
      elsif content.is_a?(Array)
        content.each_with_index do |b,i|
          if b.is_a?(Hash) && b['type'] == 'text'
            parts << TextPart.new(text:(b['text'] || '').to_s)
          else
            unmapped!(unmapped,"#{path}.message.content[#{i}]",b.is_a?(Hash) ? b['type'] : wire_type(b))
          end
        end
      elsif !content.nil?
        unmapped!(unmapped,"#{path}.message.content",wire_type(content))
      end
      parts << RefusalPart.new(text:m['refusal'].to_s) if present(m['refusal'])
      array_or(m['tool_calls']).each_with_index do |b,i|
        bpath = "#{path}.message.tool_calls[#{i}]"
        unless b.is_a?(Hash) && (!b['type'] || b['type'] == 'function')
          unmapped!(unmapped,bpath,b.is_a?(Hash) ? b['type'] : wire_type(b)); next
        end
        f = hash_or(b['function']); unnamed!(bpath) unless present(f['name'])
        parts << ToolCallPart.new(id:(present(b['id']) || "call_#{parts.length}").to_s,name:f['name'].to_s,input:LM15.parse_object(f['arguments']))
      end
      model = present(data['model']) || model
      raise ValueError,'response carries no model; pass model:' unless model
      finish = finish_reason(ch['finish_reason'],tool:parts.any? { |p| p.type == 'tool_call' },unmapped:unmapped,path:path)
      make_response(data,model,parts,openai_usage(data['usage'],chat:true),finish,unmapped,openai_logprobs(hash_or(ch['logprobs'])['content']))
    end
    def parse_responses(data,model)
      response_error!(data)
      parts,unmapped,logprobs = [],[],[]
      array_or(data['output']).each_with_index do |item,i|
        path = "output[#{i}]"
        unless item.is_a?(Hash)
          unmapped!(unmapped,path,wire_type(item)); next
        end
        case item['type']
        when 'message'
          array_or(item['content']).each_with_index do |c,j|
            cpath = "#{path}.content[#{j}]"
            unless c.is_a?(Hash)
              unmapped!(unmapped,cpath,wire_type(c)); next
            end
            case c['type']
            when 'output_text','text'
              text = (c['text'] || '').to_s; parts << TextPart.new(text:text)
              logprobs.concat(openai_logprobs(c['logprobs']))
              parts.concat(array_or(c['annotations']).filter_map { |a| citation_part(a,text) })
            when 'refusal'
              text = (present(c['refusal']) || c['text'] || '').to_s
              parts << (text.empty? ? TextPart.new(text:'') : RefusalPart.new(text:text))
            when 'output_image'
              b64 = present(c['b64_json']) || present(c['image_base64'])
              parts << ImagePart.new(media_type:'image/png',data:b64.to_s) if b64
            when 'output_audio'
              b64 = present(hash_or(c['audio'])['data']) || present(c['b64_json'])
              parts << AudioPart.new(media_type:'audio/wav',data:b64.to_s) if b64
            else unmapped!(unmapped,cpath,c['type']) end
          end
        when 'function_call'
          unnamed!(path) unless present(item['name'])
          parts << ToolCallPart.new(id:(present(item['call_id']) || present(item['id']) || "call_#{parts.length}").to_s,name:item['name'].to_s,input:LM15.parse_object(item['arguments']))
        when 'reasoning'
          summary = item['summary']
          text = summary.is_a?(Array) ? summary.map { |x| LM15.py_string(x.is_a?(Hash) ? x['text'] : x) }.join("\n") : (present(summary) || item['text'] || '').to_s
          state = item.select { |k,v| %w[id encrypted_content].include?(k) && present(v) }.transform_values(&:to_s)
          parts << ThinkingPart.new(text:text,continuation:state.empty? ? [] : continuation('openai','reasoning_item',state)) if !text.empty? || !state.empty?
        when 'web_search_call','file_search_call','code_interpreter_call','computer_call','computer_use_call'
          next
        else unmapped!(unmapped,path,item['type']) end
      end
      parts = [TextPart.new(text:(data['output_text'] || '').to_s)] if parts.empty?
      make_response(data,present(data['model']) || model,parts,openai_usage(data['usage']),finish_reason(nil,tool:parts.any? { |p| p.type == 'tool_call' },data:data),unmapped,logprobs)
    end
    def parse_anthropic(data,model)
      parts,unmapped = [],[]
      array_or(data['content']).each_with_index do |b,i|
        path = "content[#{i}]"
        unless b.is_a?(Hash)
          unmapped!(unmapped,path,wire_type(b)); next
        end
        case b['type']
        when 'text'
          parts << TextPart.new(text:(b['text'] || '').to_s)
          parts.concat(array_or(b['citations']).filter_map { |a| citation_part(a,anthropic:true) })
        when 'tool_use'
          unnamed!(path) unless present(b['name'])
          parts << ToolCallPart.new(id:(present(b['id']) || "tool_#{parts.length}").to_s,name:b['name'].to_s,input:hash_or(b['input']))
        when 'thinking'
          state = present(b['signature']) ? continuation('anthropic','thinking_signature',{'signature'=>b['signature'].to_s}) : []
          parts << ThinkingPart.new(text:(present(b['thinking']) || b['text'] || '').to_s,continuation:state)
        when 'redacted_thinking'
          state = b['data'].nil? ? [] : continuation('anthropic','redacted_thinking',{'data'=>b['data']})
          parts << ThinkingPart.new(text:'',continuation:state)
        when 'server_tool_use','web_search_tool_result','code_execution_tool_result' then next
        else unmapped!(unmapped,path,b['type']) end
      end
      make_response(data,present(data['model']) || model,parts,anthropic_usage(data['usage']),finish_reason(data['stop_reason'],tool:parts.any? { |p| p.type == 'tool_call' }),unmapped)
    end
    def gemini_inband_error(data)
      block = hash_or(data['promptFeedback'])['blockReason']
      return InvalidRequestError.new("Prompt blocked: #{block}",provider:provider,provider_code:'promptFeedback') if present(block) && block != 'BLOCK_REASON_UNSPECIFIED'
      c = hash_or(array_or(data['candidates']).first)
      if GEMINI_FINISH_ERRORS.include?(c['finishReason'])
        InvalidRequestError.new(present(c['finishMessage']) || "Candidate blocked: #{c['finishReason']}",provider:provider,provider_code:c['finishReason'])
      end
    end
    def gemini_citations(candidate,full_text)
      g = hash_or(candidate['groundingMetadata']); chunks = array_or(g['groundingChunks']); out = []
      array_or(g['groundingSupports']).each do |support|
        next unless support.is_a?(Hash)
        s = hash_or(support['segment']); text = present(s['text'])
        if !text && s['startIndex'].is_a?(Numeric) && s['endIndex'].is_a?(Numeric)
          a,b = s.values_at('startIndex','endIndex').map(&:to_i)
          text = full_text[a...b] if a >= 0 && a < b && b <= full_text.length
        end
        array_or(support['groundingChunkIndices']).each do |i|
          c = i.is_a?(Integer) && i >= 0 ? hash_or(chunks[i]) : {}
          source = hash_or(c['web'] || c['retrievedContext'] || c['googleSearch'])
          url = present(source['uri']) || present(source['url']); title = present(source['title']) || present(source['name'])
          next unless url || title || text
          part = CitationPart.new(url:url&.to_s,title:title&.to_s,text:text)
          out << part unless out.include?(part)
        end
      end
      out
    end
    def gemini_parts(blocks,unmapped = [],path_prefix: 'parts')
      parts = []
      array_or(blocks).each_with_index do |b,i|
        path = "#{path_prefix}[#{i}]"
        unless b.is_a?(Hash)
          unmapped!(unmapped,path,wire_type(b)); next
        end
        state = b['thoughtSignature'].nil? ? [] : continuation('gemini','thought_signature',{'value'=>b['thoughtSignature'].to_s})
        if b.key?('text')
          cls = b['thought'] ? ThinkingPart : TextPart
          parts << cls.new(text:(b['text'] || '').to_s,continuation:state)
        elsif b['functionCall'].is_a?(Hash)
          fc = b['functionCall']; unnamed!(path) unless present(fc['name'])
          signature = b['thoughtSignature'] || fc['thoughtSignature']
          state = signature.nil? ? [] : continuation('gemini','thought_signature',{'value'=>signature.to_s})
          parts << ToolCallPart.new(id:(present(fc['id']) || "tool_call_#{parts.length}").to_s,name:fc['name'].to_s,input:hash_or(fc['args']),continuation:state)
        elsif b['inlineData'].is_a?(Hash) || b['fileData'].is_a?(Hash)
          inline = b['inlineData'].is_a?(Hash); d = b[inline ? 'inlineData' : 'fileData']
          source = present(d[inline ? 'data' : 'fileUri']); next unless source
          mime = present(d['mimeType']) || 'application/octet-stream'
          cls = mime.start_with?('image/') ? ImagePart : mime.start_with?('audio/') ? AudioPart : DocumentPart
          parts << cls.new(media_type:mime,**{inline ? :data : :url=>source.to_s})
        elsif b.key?('executableCode') || b.key?('codeExecutionResult')
          next
        else
          unmapped!(unmapped,path,b.empty? ? '<empty>' : b.keys.sort.join('+'))
        end
      end
      parts
    end
    def parse_gemini(data,model)
      err = gemini_inband_error(data); raise err if err
      candidate = hash_or(array_or(data['candidates']).first)
      unmapped = []
      parts = gemini_parts(hash_or(candidate['content'])['parts'],unmapped,path_prefix:'candidates[0].content.parts')
      parts.concat(gemini_citations(candidate,parts.select { |p| p.type == 'text' }.map(&:text).join))
      make_response(data,model,parts,gemini_usage(data['usageMetadata']),finish_reason(candidate['finishReason'],tool:parts.any? { |p| p.type == 'tool_call' }),unmapped,gemini_logprobs(candidate['logprobsResult']),id:data['responseId'])
    end
  end
  def self.response_from_openai_chat(body,model: nil,choice: nil)
    adapter_for('openai-chat').response_from_openai_chat(body,model:model,choice:choice)
  end
end
