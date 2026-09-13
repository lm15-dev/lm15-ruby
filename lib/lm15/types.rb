# frozen_string_literal: true
require 'json'
require 'base64'
require 'time'

module LM15
  class ValueError < ArgumentError; end
  SCHEMA = JSON.parse(File.read(File.join(__dir__, 'data/schema.json'))).freeze
  VOCABULARIES = JSON.parse(File.read(File.join(__dir__, 'data/vocab.json'))).freeze
  KINDS = {
    'part' => 'Part', 'message' => 'Message', 'tool' => 'Tool',
    'tool_choice' => 'ToolChoice', 'reasoning' => 'Reasoning', 'config' => 'Config',
    'cache_config' => 'CacheConfig', 'cache_info' => 'CacheInfo', 'cache_page' => 'CachePage',
    'cached_prefix' => 'CachedPrefix', 'token_logprob' => 'TokenLogprob',
    'continuation_state' => 'ContinuationState', 'error_detail' => 'ErrorDetail',
    'delta' => 'Delta', 'usage' => 'Usage', 'credential' => 'Credential',
    'stream_event' => 'StreamEvent', 'request' => 'Request', 'response' => 'Response',
    'model_info' => 'ModelInfo', 'batch_request' => 'BatchRequest', 'batch_job' => 'BatchJobInfo',
    'batch_entry' => 'BatchEntry', 'file_upload_request' => 'FileUploadRequest',
    'file_info' => 'FileInfo', 'file_page' => 'FilePage',
    'image_generation_request' => 'ImageGenerationRequest', 'image_generation_response' => 'ImageGenerationResponse',
    'speech_generation_request' => 'SpeechGenerationRequest', 'speech_generation_response' => 'SpeechGenerationResponse',
    'video_generation_request' => 'VideoGenerationRequest', 'video_job' => 'VideoJobInfo',
    'audio_format' => 'AudioFormat', 'live_config' => 'LiveConfig',
    'live_client_event' => 'LiveClientEvent', 'live_server_event' => 'LiveServerEvent'
  }.freeze
  PART_NAMES = %w[Text Image Audio Video Document Binary ToolCall ToolResult Thinking Refusal Citation].freeze
  MEDIA_TYPES = {'image'=>'image/png','audio'=>'audio/wav','video'=>'video/mp4','document'=>'application/pdf','binary'=>'application/octet-stream'}.freeze
  SUMS = {
    'Part' => PART_NAMES.map { |n| "#{n}Part" },
    'PromptPart' => %w[TextPart ImagePart AudioPart VideoPart DocumentPart BinaryPart],
    'ToolResultContentPart' => %w[TextPart ImagePart AudioPart VideoPart DocumentPart BinaryPart CitationPart],
    'Delta' => %w[TextDelta ThinkingDelta AudioDelta ImageDelta ToolCallDelta CitationDelta ContinuationDelta],
    'Tool' => %w[FunctionTool BuiltinTool],
    'StreamEvent' => %w[StreamStartEvent StreamDeltaEvent StreamEndEvent StreamErrorEvent],
    'LiveClientEvent' => SCHEMA.keys.grep(/^LiveClient/),
    'LiveServerEvent' => SCHEMA.keys.grep(/^LiveServer/),
    'Credential' => %w[ApiKey BearerToken AwsCredentials]
  }.freeze

  def self.empty?(v)
    v.nil? || (v.respond_to?(:empty?) && v.empty?)
  end

  def self.json_value!(value)
    todo = [[value, {}]]
    until todo.empty?
      v, ancestors = todo.pop
      case v
      when NilClass, TrueClass, FalseClass, Integer, String
      when Float
        raise ValueError, 'JSON numbers must be finite' unless v.finite?
      when Hash, Array
        raise ValueError, 'cyclic JSON value' if ancestors.key?(v.object_id)
        below = ancestors.merge(v.object_id=>true)
        if v.is_a?(Hash)
          raise TypeError, 'JSON object keys must be strings' unless v.keys.all? { |k| k.is_a?(String) }
          v.each_value { |x| todo << [x, below] }
        else
          v.each { |x| todo << [x, below] }
        end
      else
        raise TypeError, "not a JSON value: #{v.class}"
      end
    end
    value
  end

  def self.base64_data(value)
    raise TypeError, 'data must be a string' unless value.is_a?(String)
    value = value.split(';base64,', 2).last if value.start_with?('data:') && value.include?(';base64,')
    value = value.gsub(/\s+/, '')
    raise ValueError, 'invalid base64 data' unless !value.empty? && value.length % 4 == 0 && /\A[A-Za-z0-9+\/]*={0,2}\z/.match?(value)
    value
  end

  def self.py_string(v)
    return 'None' if v.nil?
    return 'True' if v == true
    return 'False' if v == false
    v.to_s
  end

  def self.from_dict(kind, data)
    name = KINDS[kind.to_s] || kind.to_s
    raise ValueError, "unknown kind: #{kind}" unless SCHEMA.key?(name) || SUMS.key?(name)
    raise TypeError, "#{name} must be an object" unless data.is_a?(Hash)
    if SUMS.key?(name)
      discriminator = name == 'Credential' ? 'kind' : 'type'
      tag = data[discriminator] || data[discriminator.to_sym]
      tag = tag == 'builtin' ? 'builtin' : 'function' if name == 'Tool'
      name = SUMS[name].find { |n| SCHEMA[n].dig(discriminator,'default') == tag }
      raise ValueError, "unknown #{discriminator}: #{tag}" unless name
    end
    const_get(name).from_dict(data)
  end
  def self.from_json(kind, json)
    from_dict(kind, json.is_a?(String) ? JSON.parse(json) : json)
  end
  def self.to_dict(value, **opts) = value.to_h(**opts)
  def self.to_json(value, **opts) = JSON.generate(value.to_h(**opts))

  class Value
    class << self
      attr_accessor :fields
      def from_json(json) = from_dict(json.is_a?(String) ? JSON.parse(json) : json)
      def from_dict(data)
        raise TypeError, 'expected an object' unless data.is_a?(Hash)
        data = data.transform_keys(&:to_s)
        name = self.name.split('::').last
        d = data.select { |k,_| fields.key?(k) }.dup
        if name == 'Reasoning'
          d['effort'] = data.fetch('effort', data['enabled'] == false ? 'off' : 'medium')
          d['effort'] = 'medium' if d['effort'] == 'adaptive'
          d['thinking_budget'] = data.fetch('thinking_budget', data['budget'])
          d = {'effort'=>'off'} if d['effort'] == 'off'
        end
        d['text'] = '' if fields.key?('text') && !d.key?('text') && (name.end_with?('Part','Delta') || name.include?('TextEvent'))
        d['message'] = '' if name == 'ErrorDetail' && !d.key?('message')
        d['input'] = data.fetch('input', {}) if %w[ToolCallPart LiveServerToolCallEvent].include?(name)
        d['input'] = data.fetch('input', '') if name == 'ToolCallDelta'
        if name == 'Message'
          d['parts'] = (data['parts'] || []).map { |x| x.is_a?(Hash) ? LM15.from_dict('part',x) : TextPart.new(text: LM15.py_string(x)) }
        end
        if name == 'ToolResultPart'
          raw = data['content']
          d['content'] = if raw.is_a?(String)
            raw.empty? ? [] : [TextPart.new(text:raw)]
          elsif raw.is_a?(Array)
            raw.map { |x| x.is_a?(Hash) ? LM15.from_dict('part',x) : TextPart.new(text:LM15.py_string(x)) }
          else
            []
          end
        end
        if name == 'FileUploadRequest'
          d['bytes_data'] = Base64.strict_decode64(data['bytes_data']) if data['bytes_data']
        end
        {'Response'=>{'usage'=>{}}, 'StreamEndEvent'=>{'usage'=>nil}, 'ModelInfo'=>{'origin'=>{},'inference'=>nil},
         'InferenceModelInfo'=>{'pricing'=>nil}, 'LiveConfig'=>{'input_format'=>nil,'output_format'=>nil},
         'CachedPrefix'=>{'resource'=>nil}}.fetch(name,{}).each do |key,fallback|
          d[key] = fallback unless d[key].is_a?(Hash)
        end
        d['id'] = nil if name == 'Response' && !d.key?('id')
        %w[ImageGenerationResponse SpeechGenerationResponse LiveServerTurnEndEvent LiveServerUsageEvent].include?(name) && (d['usage'] ||= {})
        d.delete('type') if fields.key?('type') && !fields['type']['init']
        d.delete('kind') if fields.key?('kind') && !fields['kind']['init']
        new(**d.transform_keys(&:to_sym), _deserialize: true)
      end
    end

    def initialize(*args, _deserialize: false, **kwargs)
      schema = self.class.fields
      name = self.class.name.split('::').last
      input = kwargs.transform_keys(&:to_s)
      positional = schema.select { |_,f| f['init'] && !f.key?('default') }.keys
      raise ArgumentError, 'too many positional arguments; use keywords' if args.length > positional.length
      args.each_with_index { |v,i| raise ArgumentError, 'duplicate argument' if input.key?(positional[i]); input[positional[i]]=v }
      unknown = input.keys - schema.keys
      raise ArgumentError, "unknown fields: #{unknown.join(', ')}" unless unknown.empty?
      @attributes = {}
      schema.each do |field, desc|
        v = if input.key?(field)
          input[field]
        elsif desc.key?('default')
          Marshal.load(Marshal.dump(desc['default']))
        else
          raise ArgumentError, "missing #{name}.#{field}"
        end
        if !desc['init'] && v != desc['default']
          raise ValueError, "invalid discriminator #{field}"
        end
        @attributes[field] = convert(field, desc['type'], v, _deserialize)
      end
      validate!
      @attributes.freeze
      freeze
    end

    def convert(field, type, value, deserialize)
      optional = type.include?(' | None')
      return nil if value.nil? && optional
      type = type.sub(/ \| None\z/,'')
      name = self.class.name.split('::').last
      if field == 'system'
        return nil if value.nil?
        if value.is_a?(String)
          raise ValueError, 'system cannot be empty' if value.empty?
          return value
        end
        return LM15.content(value, prompt: true)
      end
      if type.start_with?('tuple[')
        element = type.sub(/^tuple\[/,'').sub(/, \.\.\.\]$/,'')
        value = [] if value.nil? && field == 'continuation'
        value = [value] unless value.is_a?(Array)
        values = value.map { |x| convert(field,element,x,deserialize) }
        return values.freeze
      end
      if SCHEMA.key?(type)
        return value if value.is_a?(LM15.const_get(type))
        return LM15.const_get(type).from_dict(value) if value.is_a?(Hash)
        raise TypeError, "#{field} must be #{type}"
      end
      if SUMS.key?(type)
        return value if value.is_a?(Value) && SUMS[type].include?(value.class.name.split('::').last)
        return LM15.from_dict(type,value) if value.is_a?(Hash)
        raise TypeError, "#{field} must be #{type}"
      end
      if VOCABULARIES.key?(type) || type.start_with?('Literal[')
        allowed = VOCABULARIES[type] || type.scan(/'([^']+)'/).flatten
        raise ValueError, "unsupported #{field}: #{value.inspect}" unless allowed.include?(value)
        return value
      end
      case type
      when 'int','float'
        raise TypeError, "#{field} must be numeric" unless value.is_a?(Integer) || value.is_a?(Float)
        raise ValueError, "#{field} must be finite" if value.is_a?(Float) && !value.finite?
        raise ValueError, "#{field} must be integral" if type == 'int' && value != value.to_i
        value = type == 'int' ? value.to_i : value.to_f
      when 'str','Path','ContinuationKind'
        value = value.to_path if type == 'Path' && value.respond_to?(:to_path)
        raise TypeError, "#{field} must be a string" unless value.is_a?(String)
        allow_empty = %w[text input input_delta token message description].include?(field)
        allow_empty &&= name != 'RefusalPart'
        raise ValueError, "#{field} cannot be empty" if !allow_empty && value.empty?
      when 'bool'
        raise TypeError, "#{field} must be boolean" unless value == true || value == false
      when 'JsonObject','ProviderData','Extensions'
        raise TypeError, "#{field} must be a JSON object" unless value.is_a?(Hash)
        LM15.json_value!(value)
        value = nil if field == 'extensions' && value.empty?
      when 'bytes'
        raise TypeError, 'bytes_data must be a binary String' unless value.is_a?(String)
      when 'datetime'
        value = Time.iso8601(value).utc if value.is_a?(String)
        raise TypeError, 'expires_at must be a Time or RFC3339 timestamp' unless value.is_a?(Time)
      else
        raise TypeError, "unsupported declaration #{type} for #{name}.#{field}"
      end
      value
    end

    def validate!
      n = self.class.name.split('::').last
      a = @attributes
      nonnegative = %w[part_index prefix_until_index logprobs index size_bytes tokens progress token_id context_window max_output_tokens]
      positive = %w[max_tokens top_k thinking_budget sample_rate channels seconds]
      a.each do |k,v|
        next if v.nil?
        raise ValueError, "#{k} must be nonnegative" if (nonnegative.include?(k) || (n == 'Usage' && k.end_with?('tokens'))) && v.is_a?(Numeric) && v < 0
        raise ValueError, "#{k} must be positive" if positive.include?(k) && v <= 0
      end
      raise ValueError, 'temperature must be nonnegative' if n == 'Config' && a['temperature'] && a['temperature'] < 0
      raise ValueError, 'top_p must be between zero and one' if n == 'Config' && a['top_p'] && !(0..1).cover?(a['top_p'])
      if MEDIA_TYPES.key?(a['type']) && n.end_with?('Part')
        sources = %w[data url file_id path].count { |k| !a[k].nil? }
        raise ValueError, 'media requires exactly one source' unless sources == 1
        a['data'] = LM15.base64_data(a['data']) if a['data']
      end
      if %w[ImageDelta AudioDelta].include?(n)
        raise ValueError, 'media delta allows at most one source' if %w[data url file_id].count { |k| !a[k].nil? } > 1
      end
      if %w[CitationPart CitationDelta].include?(n)
        raise ValueError, 'citation needs text, title or URL' unless %w[text url title].any? { |k| !LM15.empty?(a[k]) }
      end
      if %w[ToolResultPart LiveClientToolResultEvent].include?(n)
        raise ValueError, 'tool result content cannot be empty' if a['content'].empty?
        raise ValueError, 'tool results contain only presentational parts' unless a['content'].all? { |p| SUMS['ToolResultContentPart'].include?(p.class.name.split('::').last) }
      end
      if n == 'Message'
        raise ValueError, 'message parts cannot be empty' if a['parts'].empty?
        allowed = case a['role']
        when 'tool' then %w[ToolResultPart]
        when 'assistant' then SUMS['Part'] - %w[ToolResultPart]
        else SUMS['PromptPart']
        end
        raise ValueError, "parts incompatible with #{a['role']}" unless a['parts'].all? { |p| allowed.include?(p.class.name.split('::').last) }
      end
      if n == 'Reasoning' && a['effort'] == 'off' && (a['thinking_budget'] || a['summary'])
        raise ValueError, 'off reasoning cannot carry a budget or summary'
      end
      if n == 'CacheConfig'
        raise ValueError, 'off cache cannot carry other settings' if a['mode'] == 'off' && a.any? { |k,v| k != 'mode' && !v.nil? }
        raise ValueError, 'cache prefix choices conflict' if a['prefix'] && !a['prefix_until_index'].nil?
      end
      if n == 'ToolChoice' && a['mode'] == 'none' && (!a['allowed'].empty? || !a['parallel'].nil?)
        raise ValueError, 'none tool choice cannot specify allowed or parallel'
      end
      if n == 'Usage' && a['total_tokens'].nil? && !a['input_tokens'].nil? && !a['output_tokens'].nil?
        a['total_tokens'] = a['input_tokens'] + a['output_tokens']
      end
      if %w[Request LiveConfig].include?(n)
        names = a['tools'].map(&:name)
        raise ValueError, 'duplicate tool names' unless names.uniq == names
        if n == 'Request'
          raise ValueError, 'request messages cannot be empty' if a['messages'].empty?
          tc = a['config'].tool_choice
          raise ValueError, 'tool_choice names missing tools' if tc && (tc.allowed - names).any?
        end
      end
      if n == 'Config' && (f = a['response_format'])
        valid = f['type'] == 'json_object' && (f.keys - ['type']).empty?
        valid ||= f['type'] == 'json_schema' && f['schema'].is_a?(Hash) && (f.keys - %w[type schema name strict]).empty? && (!f.key?('name') || f['name'].is_a?(String)) && (!f.key?('strict') || [true,false].include?(f['strict']))
        raise ValueError, 'unsupported response_format shape' unless valid
      end
      if n == 'Response'
        raise ValueError, 'response message must be assistant' unless a['message'].role == 'assistant'
      end
      if n == 'FileUploadRequest'
        raise ValueError, 'provide exactly one of bytes_data or path' unless [a['bytes_data'],a['path']].count { |v| !LM15.empty?(v) } == 1
      end
      if n == 'BatchRequest'
        raise ValueError, 'batch cannot be empty' if a['requests'].empty?
        a['model'] ||= a['requests'].first.model
      end
      if n == 'BatchEntry'
        raise ValueError, 'succeeded entry requires response only' if a['outcome'] == 'succeeded' && (!a['response'] || a['error'])
        raise ValueError, 'errored entry requires error only' if a['outcome'] == 'errored' && (!a['error'] || a['response'])
        raise ValueError, 'cancelled/expired entry has no result' if %w[cancelled expired].include?(a['outcome']) && (a['error'] || a['response'])
      end
      if n == 'CachedPrefix'
        raise ValueError, 'cached prefix must use default config' unless a['prefix'].config.to_h.empty?
        raise ValueError, 'cached resource model differs' if a['resource'] && a['resource'].model != a['prefix'].model
      end
      if n == 'LiveClientTurnEvent'
        raise ValueError, 'turn cannot be empty' if a['parts'].empty?
      end
    end

    def [](key) = @attributes[key.to_s]
    def fetch(key, *default) = @attributes.fetch(key.to_s, *default)
    def with(**changes)
      self.class.new(**@attributes.merge(changes.transform_keys(&:to_s)).transform_keys(&:to_sym))
    end
    def ==(other) = other.instance_of?(self.class) && @attributes == other.instance_variable_get(:@attributes)
    alias eql? ==
    def hash = [self.class,@attributes].hash

    def to_h(include_provider_data: false)
      n = self.class.name.split('::').last
      out = {}
      required = case n
      when 'TextPart','ThinkingPart','RefusalPart' then %w[type text]
      when 'ToolCallPart' then %w[type id name input]
      when 'ToolResultPart' then %w[type id content]
      when 'FunctionTool' then %w[type name parameters]
      when 'ContinuationState','ContinuationDelta' then %w[type provider kind data]
      when 'Message' then %w[role parts]
      when 'Request' then %w[model messages]
      when 'Response' then %w[model message finish_reason]
      when 'TokenLogprob','TopLogprob' then %w[token logprob bytes]
      else []
      end
      @attributes.each do |k,v|
        next if n == 'Response' && k == 'provider_data' && !include_provider_data
        next if %w[is_error supports_reasoning].include?(k) && v == false
        v = case v
        when Value then v.to_h(include_provider_data: include_provider_data || (n == 'BatchEntry' && k == 'response'))
        when Array then v.map { |x| x.is_a?(Value) ? x.to_h(include_provider_data: include_provider_data) : x }
        when Time then v.utc.iso8601
        else v
        end
        v = Base64.strict_encode64(v) if n == 'FileUploadRequest' && k == 'bytes_data' && v
        next if n == 'ModelInfo' && k == 'origin' && v == {'type'=>'provider'}
        keep_empty = n.end_with?('Delta') || n.start_with?('LiveClient','LiveServer') || required.include?(k)
        next if v.nil? || (!keep_empty && LM15.empty?(v))
        next if n == 'TextDelta' && k == 'logprobs' && LM15.empty?(v)
        out[k] = v
      end
      out
    end
    alias to_dict to_h
    def to_json(*args) = JSON.generate(to_h, *args)
    def inspect
      return "#<#{self.class} [REDACTED]>" if SUMS['Credential'].include?(self.class.name.split('::').last)
      "#<#{self.class} #{@attributes.inspect}>"
    end
  end

  SCHEMA.each do |name, fields|
    cls = Class.new(Value)
    cls.fields = fields
    fields.each_key { |key| cls.define_method(key) { @attributes[key] } }
    const_set(name,cls)
  end
  SUMS.each_key do |name|
    next if const_defined?(name,false)
    mod = Module.new
    mod.define_singleton_method(:from_dict) { |d| LM15.from_dict(name,d) }
    mod.define_singleton_method(:from_json) { |d| LM15.from_json(name,d) }
    const_set(name,mod)
  end

  def self.content(value, prompt: false)
    values = value.is_a?(Array) ? value : [value]
    raise ValueError, 'content cannot be empty' if values.empty?
    values.map do |p|
      p = TextPart.new(text:p) if p.is_a?(String)
      p = from_dict('part',p) if p.is_a?(Hash)
      allowed = prompt ? SUMS['PromptPart'] : SUMS['Part']
      raise TypeError, 'expected a part or string' unless p.is_a?(Value) && allowed.include?(p.class.name.split('::').last)
      p
    end.freeze
  end
  class Message
    def self.user(content) = new(role:'user',parts:LM15.content(content,prompt:true))
    def self.developer(content) = new(role:'developer',parts:LM15.content(content,prompt:true))
    def self.assistant(content) = new(role:'assistant',parts:LM15.content(content))
    def self.tool(id_or_results, output = nil, **opts)
      parts = if id_or_results.is_a?(String)
        [LM15.tool_result(id_or_results,output,**opts)]
      elsif id_or_results.is_a?(Hash)
        id_or_results.map { |id,content| LM15.tool_result(id,content) }
      else
        Array(id_or_results)
      end
      new(role:'tool',parts:parts)
    end
    def parts_of(cls) = parts.select { |p| p.is_a?(cls) }
    def first(cls) = parts.find { |p| p.is_a?(cls) }
    def text = parts.all? { |p| p.is_a?(TextPart) } ? parts.map(&:text).join("\n") : nil
  end
  class Response
    def text
      text = message.parts.select { |p| p.is_a?(TextPart) }.map(&:text)
      text.empty? ? nil : text.join("\n")
    end
    def tool_calls = message.parts_of(ToolCallPart)
    def citations = message.parts_of(CitationPart)
    def json = JSON.parse(text || '')
    def parse_json(default: nil)
      json
    rescue JSON::ParserError
      default
    end
  end
  class Reasoning
    def is_off = effort == 'off'
  end
  class FileInfo
    def ready = readiness == 'ready'
    alias ready? ready
  end
  class BatchJobInfo
    def done = %w[completed failed cancelled expired].include?(status)
    alias done? done
  end
  class VideoJobInfo
    def done = %w[completed failed cancelled].include?(status)
    alias done? done
  end
  class ContinuationDelta
    def to_state = ContinuationState.new(provider:provider,kind:kind,data:data)
  end
  class ToolChoice
    def self.from_tools(tools, **opts) = new(allowed:Array(tools).map { |t| t.respond_to?(:name) ? t.name : t }, **opts)
  end
  def self.text(value, **opts) = TextPart.new(text:value,**opts)
  def self.thinking(value, **opts) = ThinkingPart.new(text:value,**opts)
  def self.refusal(value, **opts) = RefusalPart.new(text:value,**opts)
  def self.citation(**opts) = CitationPart.new(**opts)
  def self.tool_call(id,name,input,**opts) = ToolCallPart.new(id:id,name:name,input:input,**opts)
  def self.tool_result(id,content,**opts) = ToolResultPart.new(id:id,content:LM15.content(content),**opts)
  def self.tool(name,**opts) = FunctionTool.new(name:name,**opts)
  def self.system(content) = content.is_a?(String) ? content : LM15.content(content,prompt:true)
  MEDIA_TYPES.each do |kind, media_type|
    define_singleton_method(kind) do |**opts|
      const_get("#{kind.capitalize}Part").new(media_type:media_type,**opts)
    end
  end
  def self.continuation_data(value, provider, kind)
    states = value.respond_to?(:continuation) ? value.continuation : Array(value)
    states.find { |s| s.provider == provider && s.kind == kind }&.data
  end
end
