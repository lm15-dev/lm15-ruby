# frozen_string_literal: true
module LM15
  # MAP-12 is deliberately strict: unknown keys never disappear in conversion.
  class ChatIngest
    EXTENSIONS = %w[seed logit_bias presence_penalty frequency_penalty metadata verbosity moderation provider].freeze
    CONFIG = %w[model messages tools tool_choice parallel_tool_calls max_completion_tokens max_tokens temperature top_p stop logprobs top_logprobs response_format service_tier store user safety_identifier user_id reasoning_effort reasoning thinking enable_thinking chat_template_kwargs reasoning_format prompt_cache_key prompt_cache_retention prompt_cache_options].freeze
    CLIENT_KEYS = %w[provider_specific_fields thinking_blocks images].freeze
    def initialize(lm) = (@lm = lm)
    def unsupported(key) = raise(UnsupportedFeatureError.new("#{key} has no canonical mapping for this provider",provider:@lm.provider))
    def object(v,where)
      raise TypeError,"#{where} must be an object" unless v.is_a?(Hash); v
    end
    def string(v,where)
      raise TypeError,"#{where} must be a string" unless v.is_a?(String); v
    end
    def array(v,where)
      raise TypeError,"#{where} must be an array" unless v.is_a?(Array); v
    end
    def keys(d,allowed,where)
      extra = (object(d,where).keys - allowed).sort; unsupported("#{where}.#{extra.first}") unless extra.empty?; d
    end
    def data_uri(s)
      match = s.match(/\Adata:(.+);base64,(.+)\z/m); raise ValueError,'invalid base64 data URI' unless match
      {'media_type'=>match[1],'data'=>match[2]}
    end
    def content(value,role)
      return [[TextPart.new(text:value)],false] if value.is_a?(String)
      blocks = array(value,'content'); marked = false
      parts = blocks.each_with_index.map do |b,i|
        object(b,'content block'); kind = b['type']
        if b['prompt_cache_breakpoint']
          raise ValueError,'cache breakpoint must mark the last text block' unless b['prompt_cache_breakpoint'] == {'mode'=>'explicit'} && kind == 'text' && i == blocks.size - 1
          marked = true
        end
        case kind
        when 'text'
          keys(b,%w[type text prompt_cache_breakpoint],'text'); TextPart.new(text:string(b['text'],'text'))
        when 'image_url'
          unsupported("#{role}.image_url") unless %w[user tool].include?(role)
          keys(b,%w[type image_url prompt_cache_breakpoint],'image_url'); spec = keys(b['image_url'],%w[url detail],'image_url')
          url = string(spec['url'],'image_url.url')
          attrs = if url.start_with?('data:') then data_uri(url)
          else
            ext = File.extname(url).downcase; mime = {'.png'=>'image/png','.jpg'=>'image/jpeg','.jpeg'=>'image/jpeg','.gif'=>'image/gif','.webp'=>'image/webp','.svg'=>'image/svg+xml','.bmp'=>'image/bmp','.tiff'=>'image/tiff'}[ext]
            {'url'=>url}.merge(mime ? {'media_type'=>mime} : {})
          end
          ImagePart.from_dict(attrs.merge('detail'=>spec['detail']))
        when 'input_audio'
          unsupported("#{role}.input_audio") unless role == 'user'
          keys(b,%w[type input_audio prompt_cache_breakpoint],'input_audio'); spec = keys(b['input_audio'],%w[data format],'input_audio')
          mime = {'wav'=>'audio/wav','mp3'=>'audio/mpeg'}[spec['format']]; raise ValueError,'input_audio.format must be wav or mp3' unless mime
          AudioPart.new(data:string(spec['data'],'input_audio.data'),media_type:mime)
        when 'file'
          unsupported("#{role}.file") unless role == 'user'
          keys(b,%w[type file prompt_cache_breakpoint],'file'); spec = keys(b['file'],%w[file_data file_id filename],'file')
          unsupported('file.filename') unless spec['filename'].nil?
          raise ValueError,'file needs exactly one source' unless [spec['file_data'],spec['file_id']].compact.size == 1
          spec['file_id'] ? DocumentPart.new(file_id:string(spec['file_id'],'file.file_id')) : DocumentPart.from_dict(data_uri(string(spec['file_data'],'file.file_data')))
        when 'refusal'
          unsupported("#{role}.refusal") unless role == 'assistant'
          keys(b,%w[type refusal],'refusal'); RefusalPart.new(text:string(b['refusal'],'refusal'))
        else unsupported("#{role}.content.type=#{kind}") end
      end
      [parts,marked]
    end
    def calls(raw)
      array(raw,'tool_calls').map do |call|
        keys(call,%w[id type function],'tool_calls'); unsupported('tool_calls.type') unless call.fetch('type','function') == 'function'
        f = keys(call['function'],%w[name arguments],'tool_calls.function'); args = f.fetch('arguments','{}')
        begin args = JSON.parse(args.empty? ? '{}' : args) if args.is_a?(String); rescue JSON::ParserError; raise ValueError,'tool-call arguments are not JSON' end
        raise ValueError,'tool-call arguments must be an object' unless args.is_a?(Hash)
        ToolCallPart.new(id:string(call['id'],'call.id'),name:string(f['name'],'function.name'),input:args)
      end
    end
    def annotations(raw,text)
      array(raw,'annotations').map do |entry|
        keys(entry,%w[type url_citation],'annotations'); unsupported('annotations.type') unless entry['type'] == 'url_citation'
        s = keys(entry['url_citation'],%w[url title start_index end_index],'url_citation'); a,b = s.values_at('start_index','end_index')
        excerpt = text[a...b] if text.is_a?(String) && a.is_a?(Integer) && b.is_a?(Integer) && a >= 0 && b >= a && b <= text.length
        CitationPart.new(url:string(s['url'],'citation.url'),title:s['title'].nil? ? nil : string(s['title'],'citation.title'),text:excerpt&.empty? ? nil : excerpt)
      end
    end
    def messages(rows)
      messages = []; system = nil; system_mark = false; mark_index = nil; pending = []
      flush = -> { unless pending.empty?; messages << Message.new(role:'tool',parts:pending); pending = []; end }
      array(rows,'messages').each_with_index do |row,i|
        object(row,'message'); role = row['role']; unsupported('message.name') if row['name'] && role != 'tool'
        case role
        when 'system','developer','user'
          flush.call; keys(row,role == 'user' ? %w[role content name] : %w[role content],'message')
          parts,mark = content(row['content'],role == 'user' ? 'user' : 'system')
          if i.zero? && role != 'user'
            system = parts.size == 1 && parts.first.is_a?(TextPart) ? parts.first.text : parts; system_mark = mark
          else
            raise ValueError,'only one prompt cache breakpoint is allowed' if mark && role == 'user' && (system_mark || mark_index)
            mark_index = messages.size if mark; messages << Message.new(role:role == 'user' ? 'user' : 'developer',parts:parts)
          end
        when 'assistant'
          flush.call; keys(row,%w[role content tool_calls refusal reasoning_content name audio function_call annotations] + CLIENT_KEYS,'assistant')
          %w[audio function_call].each { |k| unsupported("assistant.#{k}") unless row[k].nil? }
          CLIENT_KEYS.each do |k|
            v = row[k]; empty = v.nil? || v == [] || v == {} || (v.is_a?(Hash) && v.values.all? { |x| x.nil? || x == [] || x == {} })
            unsupported("assistant.#{k}") unless empty
          end
          parts = []; parts << ThinkingPart.new(text:string(row['reasoning_content'],'reasoning_content')) unless row['reasoning_content'].nil?
          unless row['content'].nil?
            more,mark = content(row['content'],'assistant'); raise ValueError,'assistant cache breakpoint is invalid' if mark; parts.concat(more)
          end
          parts << RefusalPart.new(text:string(row['refusal'],'refusal')) unless row['refusal'].nil?
          parts.concat(calls(row['tool_calls'])) unless row['tool_calls'].nil?
          parts.concat(annotations(row['annotations'],row['content'])) unless row['annotations'].nil?
          parts << TextPart.new(text:'') if parts.empty?; messages << Message.assistant(parts)
        when 'tool'
          keys(row,%w[role content tool_call_id name],'tool'); parts,mark = content(row['content'],'tool'); raise ValueError,'tool cache breakpoint is invalid' if mark
          pending << ToolResultPart.new(id:string(row['tool_call_id'],'tool_call_id'),content:parts,name:row['name'].nil? ? nil : string(row['name'],'tool.name'))
        when 'function' then unsupported('message.role=function')
        else raise ValueError,"invalid message role #{role.inspect}" end
      end
      flush.call; [system,messages,system_mark,mark_index]
    end
    def tools(raw)
      return [] if raw.nil?
      array(raw,'tools').map do |t|
        object(t,'tool')
        if t['type'] == 'function'
          keys(t,%w[type function],'tool'); f = keys(t['function'],%w[name description parameters strict],'function'); unsupported('function.strict=true') if f['strict'] == true
          attrs = {'name'=>string(f['name'],'function.name')}
          attrs['description'] = string(f['description'],'function.description') unless f['description'].nil?
          attrs['parameters'] = object(f['parameters'],'function.parameters') unless f['parameters'].nil?
          FunctionTool.from_dict(attrs)
        elsif @compat['builtin_tools'] == 'groq' && {'web_search'=>'browser_search','code_execution'=>'code_interpreter'}.value?(t['type'])
          BuiltinTool.new(name:{'web_search'=>'browser_search','code_execution'=>'code_interpreter'}.key(t['type']),config:t.reject { |k,_| k == 'type' }.then { |h| h.empty? ? nil : h })
        else unsupported("tools.type=#{t['type']}") end
      end
    end
    def choice(raw,parallel)
      mode = nil; allowed = []
      unless raw.nil?
        if %w[none auto required].include?(raw) then mode = raw
        elsif raw.is_a?(Hash)
          case raw['type']
          when 'function'
            keys(raw,%w[type function],'tool_choice'); f = keys(raw['function'],%w[name],'tool_choice.function'); mode = 'required'; allowed = [string(f['name'],'tool_choice.name')]
          when 'allowed_tools'
            keys(raw,%w[type allowed_tools],'tool_choice'); s = keys(raw['allowed_tools'],%w[mode tools],'allowed_tools'); mode = string(s['mode'],'allowed_tools.mode')
            entries = array(s['tools'],'allowed_tools.tools'); raise ValueError,'allowed_tools must not be empty' if entries.empty?
            allowed = entries.map { |e| object(e,'allowed tool'); unsupported('allowed tool type') unless e['type'] == 'function'; string(object(e['function'],'function')['name'],'function.name') }
          when 'custom' then unsupported('tool_choice.type=custom')
          else raise ValueError,'unknown tool_choice.type' end
        else raise ValueError,'invalid tool_choice' end
      end
      raise TypeError,'parallel_tool_calls must be a boolean' unless parallel.nil? || parallel == true || parallel == false
      mode.nil? && parallel.nil? ? nil : ToolChoice.new(mode:mode || 'auto',allowed:allowed,parallel:parallel)
    end
    def response_format(raw)
      object(raw,'response_format')
      case raw['type']
      when 'text','json_object'
        keys(raw,%w[type],'response_format'); raw['type'] == 'text' ? nil : raw
      when 'json_schema'
        keys(raw,%w[type json_schema],'response_format'); s = keys(raw['json_schema'],%w[name schema strict description],'json_schema'); unsupported('response_format.json_schema.description') unless s['description'].nil?
        out = {'type'=>'json_schema','schema'=>object(s['schema'],'json_schema.schema')}
        out['name'] = string(s['name'],'json_schema.name') if s['name'] && s['name'] != 'response'
        unless s['strict'].nil?
          raise TypeError,'json_schema.strict must be a boolean' unless s['strict'] == true || s['strict'] == false; out['strict'] = s['strict']
        end
        out
      else raise ValueError,'unknown response_format.type' end
    end
    def reasoning(b)
      present = b.keys & %w[reasoning_effort reasoning thinking enable_thinking chat_template_kwargs reasoning_format]
      allowed = {'reasoning_effort'=>%w[reasoning_effort],'openrouter'=>%w[reasoning],'deepseek'=>%w[thinking reasoning_effort],'kimi'=>%w[thinking reasoning_effort],'qwen'=>%w[enable_thinking],'qwen_chat_template'=>%w[chat_template_kwargs],'none'=>[]}.fetch(@compat['thinking_format'],[]).dup
      allowed << 'reasoning_format' if @compat['builtin_tools'] == 'groq'
      foreign = present - allowed; unsupported(foreign.sort.first) unless foreign.empty?
      effort = nil; off = false; ext = {}; summary = nil
      if present.include?('reasoning_effort')
        word = string(b['reasoning_effort'],'reasoning_effort'); word == 'none' ? off = true : effort = word
      end
      if present.include?('thinking')
        s = keys(b['thinking'],%w[type],'thinking')
        case s['type']
        when 'disabled' then raise ValueError,'contradictory thinking and effort' if effort; off = true
        when 'enabled' then unsupported('thinking.type=enabled without effort') unless effort || off
        else raise ValueError,'invalid thinking.type' end
      end
      if present.include?('reasoning')
        s = keys(b['reasoning'],%w[effort enabled],'reasoning')
        if s['enabled'] == false then off = true
        elsif s['effort'] then effort = string(s['effort'],'reasoning.effort')
        else raise ValueError,'reasoning needs effort or enabled:false' end
      end
      %w[enable_thinking chat_template_kwargs].each do |key|
        next unless present.include?(key)
        v = key == 'enable_thinking' ? b[key] : keys(b[key],%w[enable_thinking preserve_thinking],key)['enable_thinking']
        if v == false then off = true
        elsif v == true then unsupported("#{key}=true without effort level")
        else raise TypeError,"#{key} requires a boolean" end
      end
      if present.include?('reasoning_format')
        unsupported('reasoning_format') unless b['reasoning_format'] == 'parsed'
        effort ? summary = 'auto' : ext['reasoning_format'] = 'parsed'
      end
      [off ? Reasoning.new(effort:'off') : effort ? Reasoning.new(effort:effort,summary:summary) : nil,ext]
    end
    def cache(b,system_mark,index)
      marked = system_mark || !index.nil?
      return nil unless marked || (b.keys & %w[prompt_cache_key prompt_cache_retention prompt_cache_options]).any?
      unsupported((b.keys & %w[prompt_cache_key prompt_cache_retention prompt_cache_options]).first || 'prompt_cache_breakpoint') unless %w[openai openai_implicit].include?(@compat['cache_control'])
      unsupported('prompt_cache_breakpoint') if marked && @compat['cache_control'] != 'openai'
      key = b['prompt_cache_key']; retention = nil
      if b.key?('prompt_cache_retention')
        unsupported('prompt_cache_retention') unless b['prompt_cache_retention'] == '24h'; retention = 'long'
      end
      explicit = false
      if b.key?('prompt_cache_options')
        s = keys(b['prompt_cache_options'],%w[mode ttl],'prompt_cache_options'); unsupported('prompt_cache_options.ttl') unless s['ttl'].nil?
        unsupported('prompt_cache_options.mode=implicit') if s['mode'] == 'implicit'
        raise ValueError,'invalid prompt_cache_options.mode' unless s['mode'] == 'explicit'; explicit = true
      end
      if explicit && !marked
        raise ValueError,'cache off cannot have key or retention' if key || retention; return CacheConfig.new(mode:'off')
      end
      attrs = {key:key,retention:retention}; attrs[:prefix] = 'stable' if system_mark; attrs[:prefix_until_index] = index unless index.nil?
      CacheConfig.new(**attrs)
    end
    def read(b)
      object(b,'request'); keys(b,CONFIG + EXTENSIONS + %w[stream stream_options],'request')
      model = b['model']; raise ValueError,'model must be a nonempty string' unless model.is_a?(String) && !model.empty?
      raise ValueError,'messages is required' unless b.key?('messages')
      @compat = @lm.compatible(model)
      system,msgs,mark,index = messages(b['messages']); attrs = b.slice('temperature','top_p','service_tier','store','stop')
      limits = b.slice('max_tokens','max_completion_tokens').values
      raise ValueError,'max_tokens and max_completion_tokens disagree' if limits.map { |v| [v.class,v] }.uniq.size > 1
      attrs['max_tokens'] = limits.first unless limits.empty?
      if b['logprobs'] == true then attrs['logprobs'] = b.fetch('top_logprobs',0)
      elsif !b['logprobs'].nil? && b['logprobs'] != false then raise TypeError,'logprobs must be boolean'
      elsif b.key?('top_logprobs') then raise ValueError,'top_logprobs requires logprobs:true' end
      attrs['response_format'] = response_format(b['response_format']) if b.key?('response_format')
      attrs['tool_choice'] = choice(b['tool_choice'],b['parallel_tool_calls'])
      users = b.keys & %w[user safety_identifier user_id]
      unsupported('user_id') if users.include?('user_id') && @compat['user_field'] != 'user_id'
      raise ValueError,'only one end-user identifier is allowed' if users.size > 1
      attrs['user_id'] = b[users.first] unless users.empty?
      attrs['reasoning'],ext = reasoning(b); attrs['cache'] = cache(b,mark,index); ext.merge!(b.slice(*EXTENSIONS)); attrs['extensions'] = ext.empty? ? nil : ext
      Request.new(model:model,messages:msgs,system:system,tools:tools(b['tools']),config:Config.new(**attrs.transform_keys(&:to_sym)))
    end
  end
  class ProviderLM
    def request_from_openai_chat(body)
      unsupported('Chat Completions ingestion on this dialect') unless dialect == 'openai-chat'
      ChatIngest.new(self).read(body)
    end
  end
  def self.request_from_openai_chat(body,compat:nil)
    # The module conversion needs no server address or credential.
    ChatIngest.new(OpenAIChatLM.new(compat:compat,base_url:'http://localhost/v1')).read(body)
  end
end
