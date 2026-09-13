# frozen_string_literal: true
module LM15
  class ProviderLM
    OPENAI_BUILTINS = {'web_search'=>'web_search_preview','code_execution'=>'code_interpreter','file_search'=>'file_search','computer_use'=>'computer_use_preview'}.freeze
    ANTHROPIC_BUILTINS = {'web_search'=>'web_search_20250305','code_execution'=>'code_execution_20250522'}.freeze
    GEMINI_BUILTINS = {'web_search'=>'googleSearch','code_execution'=>'codeExecution'}.freeze
    ADAPTIVE_MARKERS = %w[sonnet-5 opus-5 sonnet-4-6 opus-4-6 opus-4-7 opus-4-8 fable mythos haiku-5].freeze

    def build_request(request, stream = false)
      request = Request.from_dict(request) if request.is_a?(Hash)
      support!(stream ? 'stream' : 'complete')
      headers,params = {},{}
      payload,path = case dialect
      when 'openai-chat' then [chat_payload(request,stream),'chat/completions']
      when 'openai-responses' then [responses_payload(request,stream),'responses']
      when 'anthropic'
        headers['anthropic-version'] = '2023-06-01'
        headers['anthropic-beta'] = 'code-execution-2025-05-22' if request.tools.any? { |t| t.type == 'builtin' && t.name == 'code_execution' }
        [anthropic_payload(request,stream),'messages']
      when 'gemini'
        params['alt'] = 'sse' if stream
        model = LM15.path_id(request.model,resource_name:true).gsub('%3A',':').gsub('%40','@')
        model = "models/#{model}" unless model.start_with?('models/')
        [gemini_payload(request),"#{model}:#{stream ? 'streamGenerateContent' : 'generateContent'}"]
      end
      emit('POST',path,payload:payload,params:params,headers:headers,request:request)
    end
    def system_text(r) = r.system.is_a?(String) ? r.system : LM15.parts_text(r.system)
    def builtin_type(t,c) = c['builtin_tools'] == 'verbatim' ? t.name : OPENAI_BUILTINS.fetch(t.name,t.name)
    def mark_block!(blocks,type)
      unsupported('cache breakpoint on this message') unless blocks.is_a?(Array) && blocks.last && blocks.last['type'] == type
      blocks.last['prompt_cache_breakpoint'] = {'mode'=>'explicit'}
    end
    def chat_part(p)
      if p.type == 'image'
        unsupported('image file_id on the Chat Completions wire') if p.file_id
        image = {'url'=>p.url || LM15.media_uri(p)}
        image['detail'] = p.detail if p.detail
        {'type'=>'image_url','image_url'=>image}
      else
        {'type'=>'text','text'=>LM15.parts_text([p])}
      end
    end
    def chat_messages(r,c)
      mark = c['cache_control'] == 'openai' ? cache_mark(r) : nil
      rows = []
      if r.system
        content = system_text(r)
        content = [{'type'=>'text','text'=>content,'prompt_cache_breakpoint'=>{'mode'=>'explicit'}}] if mark == :system
        rows << {'role'=>c['instruction_role'],'content'=>content}
      end
      r.messages.each_with_index do |m,i|
        unsupported('cache breakpoint on assistant or tool message') if mark == i && %w[assistant tool].include?(m.role)
        case m.role
        when 'tool'
          m.parts.each do |p|
            row = {'role'=>'tool','tool_call_id'=>p.id,'content'=>tool_output(p,c['tool_result_media'],text_type:'text') { |x| chat_part(x) }}
            row['name'] = p.name if c['tool_result_name'] == 'include' && p.name
            rows << row
          end
        when 'assistant'
          m.parts.each { |part| unsupported("#{part.type} in an assistant Chat Completions message") if MEDIA_KINDS.include?(part.type) }
          words = m.parts.filter_map do |part|
            case part.type
            when 'text', 'refusal' then part.text
            when 'citation' then LM15.parts_text([part])
            when 'thinking' then part.text if c['thinking_replay'] == 'as_text' && !part.text.empty?
            end
          end
          row = {'role'=>'assistant','content'=>words.empty? ? nil : words.join("\n")}
          if c['thinking_replay'] == 'native'
            thought = m.parts.select { |p| p.type == 'thinking' }.map(&:text).reject(&:empty?).join("\n")
            row['reasoning_content'] = thought if !thought.empty? || c['assistant_reasoning_content'] == 'include_empty'
          end
          calls = m.parts.select { |p| p.type == 'tool_call' }.map { |p| {'id'=>p.id,'type'=>'function','function'=>{'name'=>p.name,'arguments'=>JSON.generate(p.input)}} }
          row['tool_calls'] = calls unless calls.empty?
          rows << row
        else
          content = m.parts.length == 1 && m.parts.first.type == 'text' && mark != i ? m.parts.first.text : m.parts.reject { |p| p.type == 'thinking' }.map { |p| chat_part(p) }
          mark_block!(content,'text') if mark == i
          rows << {'role'=>m.role == 'developer' ? c['instruction_role'] : m.role,'content'=>content} unless content.is_a?(Array) && content.empty?
        end
      end
      if c['assistant_after_tool_result'] == 'empty' && rows.last && rows.last['role'] == 'tool'
        rows << {'role'=>'assistant','content'=>''}
      end
      rows
    end
    def openai_tool_choice(r,c,chat: false)
      tc = r.config.tool_choice; return nil unless tc
      return tc.mode if tc.allowed.empty?
      entries = tc.allowed.map { |name| r.tools.find { |t| t.name == name } }.map do |t|
        if t.type == 'builtin'
          unsupported('forcing builtin tools on Chat Completions') if chat
          {'type'=>builtin_type(t,c)}
        else
          chat ? {'type'=>'function','function'=>{'name'=>t.name}} : {'type'=>'function','name'=>t.name}
        end
      end
      return entries.first if entries.length == 1 && tc.mode == 'required'
      body = {'mode'=>tc.mode,'tools'=>entries}
      chat ? {'type'=>'allowed_tools','allowed_tools'=>body} : {'type'=>'allowed_tools'}.merge(body)
    end
    def openai_reasoning(payload,reasoning,c,chat: false)
      return unless reasoning
      fmt = c[chat ? 'thinking_format' : 'reasoning_format']
      unsupported('reasoning on this endpoint') if fmt == 'none'
      off = reasoning.effort == 'off'
      unless off
        unsupported('thinking_budget on this endpoint') if reasoning.thinking_budget
        unsupported('reasoning summary detail') if %w[concise detailed].include?(reasoning.summary) && fmt != 'responses_reasoning'
        unsupported("reasoning effort #{reasoning.effort}") if c['reasoning_efforts'] && !c['reasoning_efforts'].include?(reasoning.effort)
      end
      effort = off ? 'none' : reasoning.effort
      case fmt
      when 'responses_reasoning'
        payload['reasoning'] = {'effort'=>effort}
        payload['reasoning']['summary'] = reasoning.summary if !off && reasoning.summary
      when 'reasoning_effort' then payload['reasoning_effort'] = effort
      when 'openrouter' then payload['reasoning'] = off ? {'enabled'=>false} : {'effort'=>effort}
      when 'deepseek'
        payload['thinking'] = {'type'=>off ? 'disabled' : 'enabled'}
        payload['reasoning_effort'] = effort unless off
      when 'kimi'
        off ? payload['thinking'] = {'type'=>'disabled'} : payload['reasoning_effort'] = effort
      when 'qwen','zai' then payload['enable_thinking'] = !off
      when 'qwen_chat_template'
        payload['chat_template_kwargs'] = {'enable_thinking'=>!off}
        payload['chat_template_kwargs']['preserve_thinking'] = true unless off
      end
      payload['reasoning_format'] = 'parsed' if chat && c['builtin_tools'] == 'groq' && !off && reasoning.summary == 'auto'
    end
    def format_schema(f)
      h = {'name'=>f['name'].to_s.empty? ? 'response' : f['name'],'schema'=>f['schema']}
      h['strict'] = f['strict'] if f.key?('strict')
      h
    end
    def chat_payload(r,stream)
      c,conf = compatible(r),r.config
      if provider == 'xai'
        unsupported('reasoning off on xAI') if conf.reasoning&.is_off
        tc = conf.tool_choice
        unsupported('tool allowlists on xAI') if tc && !tc.allowed.empty? && !(tc.allowed.length == 1 && tc.mode == 'required')
        unsupported('forced tool with response_format on xAI') if tc && tc.mode == 'required' && conf.response_format
      end
      p = {'model'=>r.model,'messages'=>chat_messages(r,c)}
      p['stream'] = true if stream
      p['stream_options'] = {'include_usage'=>true} if stream && c['stream_usage'] == 'include'
      p[c['max_tokens_field']] = conf.max_tokens if conf.max_tokens
      %w[temperature top_p service_tier store].each { |k| p[k] = conf[k] unless conf[k].nil? }
      p[c['user_field']] = conf.user_id if conf.user_id
      unsupported('top_k') if conf.top_k
      p['stop'] = conf.stop unless conf.stop.empty?
      unless conf.logprobs.nil?
        unsupported('logprobs') if provider == 'xai'
        p['logprobs'] = true; p['top_logprobs'] = conf.logprobs if conf.logprobs > 0
      end
      unless r.tools.empty?
        p['tools'] = r.tools.map do |t|
          if t.type == 'builtin'
            map = {'web_search'=>'browser_search','code_execution'=>'code_interpreter'}
            unsupported("builtin tool #{t.name}") unless c['builtin_tools'] == 'groq' && map[t.name]
            {'type'=>map[t.name]}.merge(t.config || {})
          else
            f = {'name'=>t.name,'description'=>t.description,'parameters'=>t.parameters}
            f['strict'] = false if c['strict_tools'] == 'include'
            {'type'=>'function','function'=>f}
          end
        end
      end
      if (tc = conf.tool_choice)
        unsupported('tool_choice') if c['forced_tool_choice'] == 'reject' && (tc.mode != 'auto' || !tc.allowed.empty?)
        p['tool_choice'] = openai_tool_choice(r,c,chat:true)
        p['parallel_tool_calls'] = tc.parallel unless tc.parallel.nil?
      end
      if (f = conf.response_format)
        unsupported('json_schema') if c['json_schema'] == 'reject' && f['type'] == 'json_schema'
        p['response_format'] = f['type'] == 'json_object' ? {'type'=>'json_object'} : {'type'=>'json_schema','json_schema'=>format_schema(f)}
      end
      openai_reasoning(p,conf.reasoning,c,chat:true)
      openai_cache(p,r,c['cache_control'])
      p['provider'] = c['routing'] if c['routing']
      extensions(p,conf,c)
    end
    def responses_input(r,c)
      mark = c['cache_control'] == 'openai' ? cache_mark(r) : nil
      items = []
      r.messages.each_with_index do |m,i|
        unsupported('cache breakpoint on assistant or tool message') if mark == i && %w[assistant tool].include?(m.role)
        if m.role == 'tool'
          m.parts.each do |part|
            row = {'type'=>'function_call_output','call_id'=>part.id,'output'=>tool_output(part,c['tool_result_media']) { |p| openai_input(p) }}
            row['name'] = part.name if c['tool_result_name'] == 'include' && part.name
            items << row
          end
          next
        end
        content = if m.role == 'assistant'
          media = m.parts.any? { |part| MEDIA_KINDS.include?(part.type) }
          if media
            # Responses EasyInputMessage accepts assistant text, images and files,
            # but not output/refusal blocks mixed into its input-content list.
            m.parts.each do |part|
              unsupported("#{part.type} in an assistant Responses message") if %w[audio video].include?(part.type)
              unsupported('refusal mixed with assistant media on Responses') if part.type == 'refusal'
            end
          end
          text_type = media ? 'input_text' : 'output_text'
          m.parts.filter_map do |part|
            case part.type
            when 'text' then {'type'=>text_type,'text'=>part.text}
            when 'citation' then {'type'=>text_type,'text'=>LM15.parts_text([part])}
            when 'image', 'document', 'binary' then openai_input(part)
            when 'refusal' then {'type'=>'refusal','refusal'=>part.text}
            when 'thinking'
              state = LM15.continuation_data(part,'openai','reasoning_item')
              if state
                items << {'type'=>'reasoning'}.merge(state.select { |k,_| %w[id encrypted_content].include?(k) }).merge('summary'=>part.text.empty? ? [] : [{'type'=>'summary_text','text'=>part.text}])
                nil
              elsif !part.text.empty?
                {'type'=>text_type,'text'=>part.text}
              end
            end
          end
        else
          m.parts.map { |part| openai_input(part) }
        end
        mark_block!(content,'input_text') if mark == i
        unless content.empty?
          row = {'role'=>m.role == 'developer' ? c['developer_role'] : m.role,'content'=>content}
          row['phase'] = 'commentary' if c['commentary_phase'] == 'tag' && m.role == 'assistant' && m.parts.any? { |p| p.type == 'tool_call' }
          items << row
        end
        m.parts.each { |part| items << {'type'=>'function_call','call_id'=>part.id,'name'=>part.name,'arguments'=>JSON.generate(part.input)} if part.type == 'tool_call' }
      end
      if r.system && mark == :system
        items.unshift({'role'=>c['developer_role'],'content'=>[{'type'=>'input_text','text'=>system_text(r),'prompt_cache_breakpoint'=>{'mode'=>'explicit'}}]})
      end
      items
    end
    def responses_payload(r,stream)
      c,conf = compatible(r),r.config
      p = {'model'=>r.model,'input'=>responses_input(r,c),'stream'=>stream}
      p['instructions'] = system_text(r) if r.system && !(c['cache_control'] == 'openai' && cache_mark(r) == :system)
      p[c['max_output_tokens_field']] = conf.max_tokens if conf.max_tokens
      %w[temperature top_p service_tier store].each { |k| p[k] = conf[k] unless conf[k].nil? }
      p['safety_identifier'] = conf.user_id if conf.user_id
      unsupported('stop sequences on Responses') unless conf.stop.empty?
      unsupported('top_k on Responses') if conf.top_k
      unless conf.logprobs.nil?
        p['top_logprobs'] = conf.logprobs; p['include'] = ['message.output_text.logprobs']
      end
      unless r.tools.empty?
        p['tools'] = r.tools.map do |t|
          if t.type == 'builtin'
            out = {'type'=>builtin_type(t,c)}
            out['container'] = {'type'=>'auto'} if out['type'] == 'code_interpreter'
            out.merge(t.config || {})
          else
            out = {'type'=>'function','name'=>t.name,'description'=>t.description,'parameters'=>t.parameters}
            out['strict'] = false if c['strict_tools'] == 'include'
            out
          end
        end
      end
      if (tc = conf.tool_choice)
        p['tool_choice'] = openai_tool_choice(r,c)
        p['parallel_tool_calls'] = tc.parallel unless tc.parallel.nil?
      end
      if (f = conf.response_format)
        p['text'] = {'format'=>f['type'] == 'json_object' ? {'type'=>'json_object'} : {'type'=>'json_schema'}.merge(format_schema(f))}
      end
      openai_reasoning(p,conf.reasoning,c)
      openai_cache(p,r,c['cache_control'])
      p['provider'] = c['routing'] if c['routing']
      extensions(p,conf,c)
      if provider == 'openai-codex'
        p['instructions'] ||= access['system_prefix']
        p['store'] = false; p['stream'] = true
        %w[max_tokens max_completion_tokens max_output_tokens].each { |k| p.delete(k) }
      end
      p
    end
    def anthropic_source(p)
      return {'type'=>'url','url'=>p.url} if p.url
      return {'type'=>'file','file_id'=>p.file_id} if p.file_id
      {'type'=>'base64','media_type'=>p.media_type,'data'=>LM15.media_base64(p)}
    end
    def anthropic_part(p,c)
      case p.type
      when 'text','refusal' then {'type'=>'text','text'=>p.text}
      when 'citation' then {'type'=>'text','text'=>LM15.parts_text([p])}
      when 'image','document' then {'type'=>p.type,'source'=>anthropic_source(p)}
      when 'audio','video','binary' then unsupported("#{p.type} on Anthropic")
      when 'tool_call' then {'type'=>'tool_use','id'=>p.id,'name'=>p.name,'input'=>p.input}
      when 'tool_result'
        check_tool_media(p,c['tool_result_media'])
        blocks = p.content.map { |x| %w[image document].include?(x.type) ? anthropic_part(x,c) : {'type'=>'text','text'=>LM15.parts_text([x])} }
        row = {'type'=>'tool_result','tool_use_id'=>p.id,'content'=>blocks.length == 1 && blocks[0]['type'] == 'text' ? blocks[0]['text'] : blocks}
        row['is_error'] = true if p.is_error
        row
      when 'thinking'
        redacted = LM15.continuation_data(p,'anthropic','redacted_thinking')
        return {'type'=>'redacted_thinking'}.merge(redacted) if redacted
        signature = LM15.continuation_data(p,'anthropic','thinking_signature')
        return {'type'=>'thinking','thinking'=>p.text,'signature'=>signature['signature']} if signature && signature['signature']
        return {'type'=>'thinking','thinking'=>p.text} if c['thinking_replay'] == 'unsigned' && !p.text.empty?
        {'type'=>'text','text'=>p.text}
      else {'type'=>'text','text'=>p.respond_to?(:text) ? p.text || '' : ''} end
    end
    def anthropic_payload(r,stream)
      c,conf = compatible(r),r.config
      raise UnsupportedModelError,"#{provider}: model would be substituted" if c['model_prefixes'] && !c['model_prefixes'].any? { |x| r.model.start_with?(x) }
      rows = r.messages.map do |m|
        blocks = m.role == 'developer' ? [{'type'=>'text','text'=>"[developer]\n#{LM15.parts_text(m.parts)}"}] : m.parts.map { |p| anthropic_part(p,c) }
        {'role'=>m.role == 'assistant' ? 'assistant' : 'user','content'=>blocks}
      end
      cache = conf.cache
      use_cache = cache && cache.mode != 'off' && c['cache_control'] == 'anthropic'
      marker = {'type'=>'ephemeral'}
      marker['ttl'] = '1h' if cache && cache.retention == 'long'
      if use_cache
        unsupported('cache key or resource on Anthropic') if cache.key || cache.resource
        idx = cache.prefix == 'history' ? rows.length - 1 : cache.prefix_until_index && [cache.prefix_until_index,rows.length - 1].min
        rows[idx]['content'].last['cache_control'] = marker if idx && rows[idx]['content'].last
      end
      reason = conf.reasoning
      format = c['thinking_format']
      adaptive = reason && !reason.is_off && (%w[deepseek adaptive effort].include?(format) || ADAPTIVE_MARKERS.any? { |s| r.model.downcase.include?(s) })
      budget = nil
      if reason && !reason.is_off
        unsupported("reasoning effort #{reason.effort}") if c['reasoning_efforts'] && !c['reasoning_efforts'].include?(reason.effort)
        unsupported('reasoning summary detail') if %w[concise detailed].include?(reason.summary)
        unsupported('thinking_budget on adaptive models') if adaptive && reason.thinking_budget
        unsupported('minimal effort on adaptive Anthropic models') if adaptive && reason.effort == 'minimal' && !%w[deepseek adaptive effort].include?(format)
        budget = reason.thinking_budget || TABLES['effort_budgets'][reason.effort] unless adaptive
      end
      p = {'model'=>r.model,'messages'=>rows,'stream'=>stream,'max_tokens'=>(conf.max_tokens || 1024) + (budget || 0)}
      p['system'] = use_cache ? [{'type'=>'text','text'=>system_text(r),'cache_control'=>marker}] : system_text(r) if r.system
      %w[temperature top_p top_k].each do |k|
        next if conf[k].nil?
        unsupported("#{k} on this endpoint") if c['sampling_params'] == 'reject'
        p[k] = conf[k]
      end
      p['stop_sequences'] = conf.stop unless conf.stop.empty?
      unless r.tools.empty?
        p['tools'] = r.tools.map { |t| t.type == 'builtin' ? {'type'=>ANTHROPIC_BUILTINS.fetch(t.name,t.name),'name'=>t.name}.merge(t.config || {}) : {'name'=>t.name,'description'=>t.description,'input_schema'=>t.parameters} }
      end
      if (tc = conf.tool_choice)
        unsupported('parallel tool preference') if c['parallel_tool_calls'] == 'reject' && !tc.parallel.nil?
        choice = {'type'=>{'none'=>'none','auto'=>'auto','required'=>'any'}[tc.mode]}
        unless tc.allowed.empty?
          if tc.allowed.length == 1 && tc.mode == 'required'
            choice = {'type'=>'tool','name'=>tc.allowed.first}
          elsif tc.allowed.sort != r.tools.map(&:name).sort
            unsupported('tool allowlist subset')
          end
        end
        choice['disable_parallel_tool_use'] = true if tc.parallel == false && tc.mode != 'none'
        p['tool_choice'] = choice
      end
      if reason
        if reason.is_off
          p['thinking'] = {'type'=>'disabled'} if %w[deepseek adaptive effort].include?(format)
        elsif adaptive
          p['thinking'] = {'type'=>format == 'deepseek' ? 'enabled' : 'adaptive'} unless format == 'effort'
          p['output_config'] = {'effort'=>reason.effort}
        elsif budget
          p['thinking'] = {'type'=>'enabled','budget_tokens'=>budget}
        end
      end
      if (f = conf.response_format)
        unsupported('response_format') if c['structured_output'] == 'reject' || f['type'] == 'json_object'
        (p['output_config'] ||= {})['format'] = {'type'=>'json_schema','schema'=>f['schema']}
      end
      unsupported('store') unless conf.store.nil?
      unsupported('logprobs') unless conf.logprobs.nil?
      p['service_tier'] = conf.service_tier if conf.service_tier
      p['metadata'] = {'user_id'=>conf.user_id} if conf.user_id
      extensions(p,conf,c)
      if access['system_prefix']
        previous = p['system']
        p['system'] = [{'type'=>'text','text'=>access['system_prefix']}]
        p['system'].concat(previous.is_a?(Array) ? previous : [{'type'=>'text','text'=>previous}]) if previous
      end
      p
    end
    def gemini_part(p,names = {})
      out = case p.type
      when 'text','thinking','refusal' then {'text'=>p.text}
      when 'citation' then {'text'=>LM15.parts_text([p])}
      when *MEDIA_KINDS
        if p.url || p.file_id
          {'fileData'=>{'mimeType'=>p.media_type,'fileUri'=>p.url || p.file_id}}
        else
          {'inlineData'=>{'mimeType'=>p.media_type,'data'=>LM15.media_base64(p)}}
        end
      when 'tool_call' then {'functionCall'=>{'name'=>p.name,'args'=>p.input,'id'=>p.id}}
      when 'tool_result'
        name = p.name || names[p.id]
        unsupported('tool result without a name or preceding call') unless name
        media,words = p.content.partition { |x| MEDIA_KINDS.include?(x.type) }
        check_tool_media(p,'native')
        response = p.is_error ? {'error'=>LM15.parts_text(words)} : media.any? && words.empty? ? {} : {'result'=>LM15.parts_text(words)}
        fr = {'name'=>name,'response'=>response,'id'=>p.id}
        fr['parts'] = media.map { |x| gemini_part(x,names) } unless media.empty?
        {'functionResponse'=>fr}
      else {'text'=>p.respond_to?(:text) ? p.text || '' : ''} end
      if %w[text thinking tool_call].include?(p.type)
        state = LM15.continuation_data(p,'gemini','thought_signature')
        if state && state['value']
          out['thoughtSignature'] = state['value']; out['thought'] = true if p.type == 'thinking'
        end
      end
      out
    end
    def contains_key?(value,key)
      return value.key?(key) || value.values.any? { |v| contains_key?(v,key) } if value.is_a?(Hash)
      value.is_a?(Array) && value.any? { |v| contains_key?(v,key) }
    end
    def gemini_payload(r)
      conf = r.config; cache = conf.cache
      resource,start = nil,0
      if cache && cache.mode != 'off'
        unsupported('cache key') if cache.key
        unsupported('cache retention in request') if cache.retention && cache.retention != 'short'
        resource = cache.resource
        start = [cache.prefix_until_index,r.messages.length - 1].min + 1 if resource && cache.prefix_until_index
      end
      messages = r.messages.drop(start)
      raise ValueError,'stored-cache request requires a suffix message' if resource && messages.empty?
      names = r.messages.flat_map(&:parts).select { |p| p.type == 'tool_call' }.to_h { |p| [p.id,p.name] }
      p = {'contents'=>messages.map { |m| {'role'=>m.role == 'assistant' ? 'model' : 'user','parts'=>m.role == 'developer' ? [{'text'=>"[developer]\n#{LM15.parts_text(m.parts)}"}] : m.parts.map { |part| gemini_part(part,names) }} }}
      p['cachedContent'] = resource.start_with?('cachedContents/') ? resource : "cachedContents/#{resource}" if resource
      p['systemInstruction'] = {'parts'=>[{'text'=>system_text(r)}]} if r.system && !resource
      g = {}
      {'temperature'=>'temperature','max_tokens'=>'maxOutputTokens','top_p'=>'topP','top_k'=>'topK'}.each { |from,to| g[to] = conf[from].is_a?(Float) && conf[from] == conf[from].to_i ? conf[from].to_i : conf[from] unless conf[from].nil? }
      g['stopSequences'] = conf.stop unless conf.stop.empty?
      unless conf.logprobs.nil?
        g['responseLogprobs'] = true; g['logprobs'] = conf.logprobs if conf.logprobs > 0
      end
      if (f = conf.response_format)
        g['responseMimeType'] = 'application/json'
        if f['type'] == 'json_schema'
          unsupported('response_format.strict=false on Gemini') if f['strict'] == false
          g[contains_key?(f['schema'],'additionalProperties') ? 'responseJsonSchema' : 'responseSchema'] = f['schema']
        end
      end
      if (reason = conf.reasoning)
        level = r.model.delete_prefix('models/').downcase.start_with?('gemini-3')
        if reason.is_off
          unsupported('reasoning off on Gemini 3') if level
          g['thinkingConfig'] = {'thinkingBudget'=>0}
        else
          unsupported('reasoning summary detail') if %w[concise detailed].include?(reason.summary)
          thinking = {}
          thinking['includeThoughts'] = true if reason.summary
          if reason.thinking_budget
            thinking['thinkingBudget'] = reason.thinking_budget
          elsif level
            unsupported("reasoning effort #{reason.effort}") if %w[xhigh max].include?(reason.effort)
            thinking['thinkingLevel'] = reason.effort
          else
            thinking['thinkingBudget'] = TABLES['effort_budgets'][reason.effort]
          end
          g['thinkingConfig'] = thinking
        end
      end
      p['generationConfig'] = g unless g.empty?
      unless resource
        functions = r.tools.select { |t| t.type == 'function' }.map { |t| {'name'=>t.name,'description'=>t.description,'parameters'=>t.parameters} }
        ts = functions.empty? ? [] : [{'functionDeclarations'=>functions}]
        ts.concat(r.tools.select { |t| t.type == 'builtin' }.map { |t| {GEMINI_BUILTINS.fetch(t.name,t.name)=>t.config || {}} })
        p['tools'] = ts unless ts.empty?
        if (tc = conf.tool_choice)
          unsupported('parallel=false on Gemini') if tc.parallel == false
          cfg = {'mode'=>{'none'=>'NONE','required'=>'ANY','auto'=>'AUTO'}[tc.mode]}
          unless tc.allowed.empty?
            unsupported('forcing builtin tools on Gemini') if r.tools.any? { |t| tc.allowed.include?(t.name) && t.type == 'builtin' }
            cfg['allowedFunctionNames'] = tc.allowed; cfg['mode'] = 'VALIDATED' if tc.mode == 'auto'
          end
          p['toolConfig'] = {'functionCallingConfig'=>cfg}
        end
      end
      unsupported('user_id on Gemini') if conf.user_id
      p['store'] = conf.store unless conf.store.nil?
      p['serviceTier'] = conf.service_tier if conf.service_tier
      ext = conf.extensions || {}
      (p['generationConfig'] ||= {})['responseModalities'] = [ext['output'].upcase] if %w[image audio].include?(ext['output'])
      p.merge(ext.reject { |k,_| %w[prompt_caching output].include?(k) })
    end
  end
end
