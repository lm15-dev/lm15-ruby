# frozen_string_literal: true
require 'uri'
require 'net/http'
require 'openssl'
require 'time'

module LM15
  TABLES = JSON.parse(File.read(File.join(__dir__, 'data/tables.json'))).freeze
  PROVIDERS = TABLES.fetch('providers').freeze
  MEDIA_KINDS = %w[image audio video document binary].freeze

  def self.path_id(value, resource_name: false)
    value.to_s.b.bytes.map { |b| (b.chr.match?(/[A-Za-z0-9_.~-]/) || (resource_name && b == 47)) ? b.chr : '%%%02X' % b }.join
  end
  def self.parts_text(parts)
    Array(parts).filter_map do |p|
      raise UnsupportedFeatureError, "#{p.type} cannot reach a text-only field" if MEDIA_KINDS.include?(p.type)
      case p.type
      when 'text','thinking','refusal' then p.text
      when 'citation' then [p.title,p.url,p.text].compact.reject(&:empty?).join(' — ')
      end
    end.join("\n")
  end
  def self.media_base64(p) = p.data || Base64.strict_encode64(File.binread(p.path))
  def self.media_uri(p) = "data:#{p.media_type};base64,#{media_base64(p)}"
  def self.parse_object(value)
    return value if value.is_a?(Hash)
    return {} unless value.is_a?(String) && !value.empty?
    result = JSON.parse(value)
    result.is_a?(Hash) ? result : {'value'=>result}
  rescue JSON::ParserError
    {'partial_json'=>value}
  end
  def self.iso_utc(value)
    (value.is_a?(Numeric) ? Time.at(value) : Time.parse(value)).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  rescue ArgumentError, TypeError, RangeError
    nil
  end

  # Immutable wire objects; adapters build them without performing I/O.
  class TransportRequest
    attr_reader :method, :url, :headers, :body, :connect_timeout, :read_timeout, :write_timeout
    def initialize(method:, url:, headers: {}, body: '', params: {}, connect_timeout: nil, read_timeout: nil, write_timeout: nil)
      @method = method.upcase
      query = URI.encode_www_form(params.reject { |_,v| v.nil? })
      @url = url + (query.empty? ? '' : "#{url.include?('?') ? '&' : '?'}#{query}")
      @headers = headers.to_h.transform_keys(&:downcase).freeze
      @body = body.b.freeze
      @connect_timeout,@read_timeout,@write_timeout = connect_timeout,read_timeout,write_timeout
      freeze
    end
    def normalized
      uri = URI.parse(url)
      params = URI.decode_www_form(uri.query || '').to_h
      uri.query = nil
      out = {'method'=>method,'url'=>uri.to_s,'params'=>params,'headers'=>headers,'body'=>nil}
      unless body.empty?
        if headers.fetch('content-type','').include?('json')
          out['body'] = JSON.parse(body)
        else
          out['body_b64'] = Base64.strict_encode64(body)
        end
      end
      out
    end
    def inspect = "#<#{self.class} #{method} #{URI.parse(url).tap { |u| u.query = nil }}>"
  end
  class HttpResponse
    attr_reader :status, :headers, :body
    def initialize(status: 200, headers: {}, body: '')
      @status,@headers,@body = status,headers.to_h.transform_keys(&:downcase),body
    end
    def json = JSON.parse(body)
  end
  class NetHTTPTransport
    def call(request)
      uri = URI.parse(request.url)
      http = Net::HTTP.new(uri.host,uri.port)
      http.max_retries = 0
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = request.connect_timeout || 10
      http.read_timeout = request.read_timeout || 120
      http.write_timeout = request.write_timeout || 120
      req = Net::HTTPGenericRequest.new(request.method,!request.body.empty?,true,uri.request_uri,request.headers)
      req.body = request.body unless request.body.empty?
      if block_given?
        http.request(req) do |res|
          response = HttpResponse.new(status:res.code.to_i,headers:res.each_header.to_h)
          yield response, res
        end
      else
        res = http.request(req)
        HttpResponse.new(status:res.code.to_i,headers:res.each_header.to_h,body:res.body || '')
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TimeoutError,e.message
    rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      raise TransportError,e.message
    end
  end

  class ProviderLM
    attr_reader :provider, :dialect, :base_url, :access, :settings, :transport
    ANTHROPIC_ERRORS = {'authentication_error'=>'auth','permission_error'=>'auth','billing_error'=>'billing','rate_limit_error'=>'rate_limit','request_too_large'=>'invalid_request','not_found_error'=>'invalid_request','resource_not_found_error'=>'invalid_request','DeploymentNotFound'=>'unsupported_model','invalid_authentication_error'=>'auth','invalid_request_error'=>'invalid_request','api_error'=>'server','overloaded_error'=>'server','timeout_error'=>'timeout'}.freeze
    GEMINI_ERRORS = {'INVALID_ARGUMENT'=>'invalid_request','FAILED_PRECONDITION'=>'billing','PERMISSION_DENIED'=>'auth','UNAUTHENTICATED'=>'auth','NOT_FOUND'=>'invalid_request','RESOURCE_EXHAUSTED'=>'rate_limit','INTERNAL'=>'server','UNAVAILABLE'=>'server','DEADLINE_EXCEEDED'=>'timeout'}.freeze
    MODEL_ERRORS = %w[model_not_found model_not_available unsupported_model DeploymentNotFound].freeze
    OPENAI_ERRORS = {'context_length_exceeded'=>'context_length','invalid_api_key'=>'auth','insufficient_quota'=>'billing','1113'=>'billing','exceeded_current_quota_error'=>'billing','authentication_error'=>'auth','rate_limit_error'=>'rate_limit','server_error'=>'server','rate_limit_exceeded'=>'rate_limit','invalid_prompt'=>'invalid_request','vector_store_timeout'=>'timeout'}.merge(MODEL_ERRORS.to_h { |x| [x,'unsupported_model'] }).merge(%w[invalid_image invalid_image_format invalid_base64_image invalid_image_url image_too_large image_too_small image_parse_error image_content_policy_violation invalid_image_mode image_file_too_large unsupported_image_media_type empty_image_file failed_to_download_image image_file_not_found].to_h { |x| [x,'invalid_request'] }).freeze

    def initialize(provider: 'openai', api_key: nil, credential: nil, base_url: nil, settings: {}, compat: nil, clock: -> { Time.now.utc }, transport: NetHTTPTransport.new, account_id: nil, **options)
      extra_options = options.keys - %i[env credentials_path]
      raise ArgumentError,"unknown provider options: #{extra_options.join(', ')}" unless extra_options.empty?
      @provider = provider.tr('_','-')
      @definition = PROVIDERS[@provider] || raise(ValueError,"unknown provider: #{provider}")
      @dialect,@access = @definition.values_at('dialect','access')
      @settings = (settings || {}).transform_keys(&:to_s)
      @credential = credential || api_key
      @env = options.fetch(:env,ENV)
      @credentials_path = options[:credentials_path]
      @compat,@clock,@transport,@account_id = compat,clock,transport,account_id
      @base_url = base_url || access['base_url'] || {'openai-chat'=>'https://api.openai.com/v1','openai-responses'=>'https://api.openai.com/v1','anthropic'=>'https://api.anthropic.com/v1','gemini'=>'https://generativelanguage.googleapis.com/v1beta'}[dialect]
      if compat.is_a?(String) && !base_url
        table = {'openai-chat'=>'OPENAI_CHAT','openai-responses'=>'OPENAI_RESPONSES','anthropic'=>'ANTHROPIC'}[dialect]
        raise ValueError,'compat presets are not available for this dialect' unless table
        name = compat.downcase.tr('- .','___'); name = TABLES['compat_aliases'].fetch(name,name)
        raise ValueError,"unknown compat preset: #{compat}" unless TABLES['compat']["#{table}_PRESETS"].key?(name)
        @base_url = TABLES['compat']["#{table}_PRESET_BASE_URLS"][name]
        raise NotConfiguredError,"#{compat}: configure base_url for this server" unless @base_url
      end
      @explicit_url = base_url
      @base_url = @base_url.sub(%r{/+$},'')
    end
    def unsupported(feature) = raise(UnsupportedFeatureError.new("#{provider}: #{feature} is not supported",provider:provider))
    def support!(feature)
      unsupported(feature) unless access.dig('supports',feature)
    end
    def model_error?(message)
      s = message.downcase
      s.include?('model') && ['not found','does not exist','not exist','not supported','unsupported','not available','unknown'].any? { |m| s.include?(m) }
    end
    def context_error?(message)
      s = message.downcase
      (s.include?('token') && (s.include?('limit') || s.include?('exceed'))) || s.include?('context length') || (dialect == 'gemini' ? s.include?('too long') : ['prompt is too long','too many tokens','context window'].any? { |x| s.include?(x) })
    end
    def normalize_error(status, body, headers: {})
      msg,pc,code,rid = body.strip[0,500],nil,nil,nil
      begin
        data = JSON.parse(body)
        data = {} unless data.is_a?(Hash)
        if provider == 'openai-codex' && data['detail'].is_a?(String)
          msg = data['detail']; code = 'unsupported_model' if model_error?(msg)
        else
          err = data.fetch('error',{})
          err = data if dialect == 'anthropic' && !err.is_a?(String) && (!err.is_a?(Hash) || err.empty?)
          err = {'message'=>err,'code'=>data['code']} if provider == 'xai' && err.is_a?(String)
          msg = err.is_a?(Hash) ? (err['message'] || '').to_s : err.to_s
          e = err.is_a?(Hash) ? err : {}
          case dialect
          when 'anthropic'
            pc = e['type'] || e['code']; rid = data['request_id']
            code = if context_error?(msg) then 'context_length'
            elsif pc == 'DeploymentNotFound' || (%w[not_found_error resource_not_found_error].include?(pc) && model_error?(msg)) then 'unsupported_model'
            else ANTHROPIC_ERRORS[pc] end
          when 'gemini'
            pc = e['status']
            code = context_error?(msg) ? 'context_length' : (pc == 'NOT_FOUND' && model_error?(msg) ? 'unsupported_model' : GEMINI_ERRORS[pc])
          else
            c,t = e.values_at('code','type'); pc = c || t
            code = if c == 'context_length_exceeded' then 'context_length'
            elsif MODEL_ERRORS.include?(c) || (status == 404 && model_error?([msg,c,t].compact.join(' '))) then 'unsupported_model'
            elsif %w[insufficient_quota 1113].include?(c) || %w[insufficient_quota exceeded_current_quota_error].include?(t) then 'billing'
            elsif c == 'invalid_api_key' || t == 'authentication_error' then 'auth'
            elsif c == 'rate_limit_exceeded' || t == 'rate_limit_error' then 'rate_limit' end
          end
          msg += " (#{pc})" if !code && pc && !msg.include?(pc.to_s)
        end
      rescue JSON::ParserError
        # Non-JSON HTTP failures retain a bounded diagnostic.
      end
      code ||= case status
      when 401,403 then 'auth'
      when 402 then 'billing'
      when 429 then 'rate_limit'
      when 408,504 then 'timeout'
      when 400,404,409,413,422 then 'invalid_request'
      when 500..599 then 'server'
      else 'provider' end
      msg = "HTTP #{status}" if msg.empty?
      h = headers.to_h.transform_keys(&:downcase)
      rid ||= %w[x-request-id request-id x-amzn-requestid x-amz-request-id x-ms-request-id].filter_map { |k| h[k] }.first
      retry_after = begin
        h['retry-after'] && (Float(h['retry-after']) rescue [Time.httpdate(h['retry-after']) - @clock.call,0].max)
      rescue ArgumentError
        nil
      end
      LM15.error_from_code(code,msg,provider:provider,status:status,provider_code:pc&.to_s,request_id:rid,retry_after:retry_after)
    end
    def error_detail(pc, message)
      code = case dialect
      when 'anthropic' then context_error?(message) ? 'context_length' : (pc == 'not_found_error' && model_error?(message) ? 'unsupported_model' : ANTHROPIC_ERRORS[pc])
      when 'gemini' then context_error?(message) ? 'context_length' : (pc == 'NOT_FOUND' && model_error?(message) ? 'unsupported_model' : GEMINI_ERRORS[pc])
      else OPENAI_ERRORS[pc] end
      ErrorDetail.new(code:code || 'provider',message:message.to_s.empty? ? (pc || 'provider error') : message,provider_code:pc.to_s.empty? ? 'provider' : pc)
    end

    def configure_host(explicit_url)
      host = access['host']
      return unless host
      allowed = host.fetch('settings',[])
      # The host schema names required and optional settings separately.
      allowed = allowed.keys if allowed.is_a?(Hash)
      # Host normalization and signing live in the cloud layer.
      if respond_to?(:resolve_host)
        resolve_host(explicit_url)
      else
        unsupported('hosted authentication')
      end
    end
    def credential
      value = @credential
      explicit = !value.nil?
      value = value.call if value.respond_to?(:call)
      raise NotConfiguredError,"#{provider}: explicit credential is empty; no fallback" if explicit && (value.nil? || value == '')
      value ||= resolve_credential if respond_to?(:resolve_credential)
      value = ApiKey.new(value:value) if value.is_a?(String)
      raise NotConfiguredError.new("#{provider}: configure credentials",provider:provider) unless value
      value
    end
    def emit(method, path, payload: nil, params: {}, headers: {}, body: nil, request: nil)
      if access['host']
        chain = CloudChain.new(provider,env:@env,settings:settings.dup,clock:@clock,transport:transport)
        @settings = chain.resolve_settings
        resolve_host(@explicit_url)
      end
      url = path.start_with?('http://','https://') ? path : "#{base_url}/#{path.sub(%r{^/},'')}"
      headers = headers.to_h.transform_keys(&:downcase)
      headers['content-type'] ||= 'application/json' unless payload.nil?
      (access['headers'] || []).each do |k,v|
        k = k.downcase
        headers[k] = k == 'anthropic-beta' && headers[k] ? [headers[k],v].join(',').split(',').uniq.join(',') : v
      end
      params = params.dup
      c = credential
      schemes = access['auth_scheme']
      case c
      when ApiKey
        scheme = schemes.find { |s| s != 'sigv4' }
        case scheme
        when 'bearer' then headers['authorization'] = "Bearer #{c.value}"
        when 'x-api-key','api-key','x-goog-api-key' then headers[dialect == 'gemini' && scheme == 'x-api-key' ? 'x-goog-api-key' : scheme] = c.value
        when 'query-key' then params['key'] = c.value
        else raise NotConfiguredError,"#{provider}: API key is incompatible with this access policy" end
      when BearerToken
        if schemes.include?('bearer')
          headers['authorization'] = "Bearer #{c.value}"
        elsif schemes.include?('x-api-key')
          headers[dialect == 'gemini' ? 'x-goog-api-key' : 'x-api-key'] = c.value
        else
          raise NotConfiguredError,"#{provider}: bearer credential is incompatible with #{schemes.join(',')}"
        end
      when AwsCredentials
        raise NotConfiguredError,"#{provider}: AWS credentials are incompatible with this access policy" unless schemes.include?('sigv4')
      else
        raise TypeError,'expected a credential or credential callable'
      end
      headers['chatgpt-account-id'] = @account_id if provider == 'openai-codex' && @account_id
      if respond_to?(:finish_host_request)
        url,payload,headers = finish_host_request(url,payload,headers,request)
      end
      wire = TransportRequest.new(method:method,url:url,params:params,headers:headers,body:body || (payload.nil? ? '' : JSON.generate(payload)))
      wire = sign_request(wire,c) if c.is_a?(AwsCredentials)
      wire
    end
    def compatible(model)
      request = model if model.is_a?(Request)
      model = request.model if request
      kind = {'openai-chat'=>'OpenAIChat','openai-responses'=>'OpenAIResponses','anthropic'=>'Anthropic'}[dialect]
      return {} unless kind
      key = {'openai-chat'=>'OPENAI_CHAT','openai-responses'=>'OPENAI_RESPONSES','anthropic'=>'ANTHROPIC'}[dialect]
      defaults = TABLES['compat_defaults']["Resolved#{kind}Compat"].dup
      preset = @compat.is_a?(String) ? @compat : (@definition['compat'] || (dialect == 'anthropic' ? 'anthropic' : 'openai'))
      preset = 'xai' if provider == 'xai' && @compat.nil?
      preset = preset.downcase.tr('- .','___')
      preset = TABLES['compat_aliases'].fetch(preset,preset)
      raw = TABLES['compat']["#{key}_PRESETS"][preset] || raise(ValueError,"unknown compat preset: #{preset}")
      custom = @compat.is_a?(Hash) ? @compat.transform_keys(&:to_s) : {}
      extra = custom.keys - raw.keys
      raise ValueError,"unknown compat fields: #{extra.join(', ')}" unless extra.empty?
      partial = raw.merge(custom.reject { |_,v| v.nil? })
      overrides = partial.delete('model_overrides') || []
      defaults.merge!(partial.reject { |_,v| v.nil? || v == 'auto' })
      overrides.each do |prefix,knobs|
        if model.start_with?(prefix)
          defaults.merge!(knobs.reject { |_,v| v.nil? || v == 'auto' })
          break
        end
      end
      if request && dialect == 'openai-responses'
        ext = request.config.extensions || {}
        override = ext['openai_responses_compat'] || ext['openai_compat']
        nested = ext['compat']
        override ||= nested['openai_responses'] || nested['openai'] if nested.is_a?(Hash)
        if override.is_a?(Hash)
          standard = TABLES['compat_defaults']['ResolvedOpenAIResponsesCompat']
          override.each do |k,v|
            next unless standard.key?(k) && !v.nil?
            defaults[k] = if k == 'extensions'
              (defaults[k] || {}).merge(v)
            else v == 'auto' ? standard[k] : v end
          end
        end
      end
      defaults
    end
    def extensions(payload, config, compat = {})
      payload.merge!(compat['extensions'] || {})
      payload.merge!((config.extensions || {}).reject { |k,_| %w[prompt_caching cache compat openai_responses_compat openai_compat openai_chat_compat].include?(k) })
      payload
    end
    def check_tool_media(part, policy)
      admits = {'native'=>%w[image document],'images'=>%w[image],'reject'=>[]}.fetch(policy)
      part.content.each { |p| unsupported("#{p.type} in tool results") if MEDIA_KINDS.include?(p.type) && !admits.include?(p.type) }
    end
    def cache_mark(request)
      c = request.config.cache
      return nil unless c && c.mode != 'off'
      return [c.prefix_until_index,request.messages.length - 1].min unless c.prefix_until_index.nil?
      c.prefix == 'stable' && request.system ? :system : nil
    end
    def openai_cache(payload, request, policy)
      c = request.config.cache
      return unless c
      unsupported('cache resources') if c.resource
      return unless %w[openai openai_implicit].include?(policy)
      explicit = request.model.match?(/\Agpt-([6-9]|5\.(?:[6-9]|\d{2,}))/)
      if c.mode == 'off'
        payload['prompt_cache_options'] = {'mode'=>'explicit'} if policy == 'openai' && explicit
        return
      end
      payload['prompt_cache_key'] = c.key if c.key
      payload['prompt_cache_retention'] = '24h' if c.retention == 'long'
      payload['prompt_cache_options'] = {'mode'=>'explicit'} if policy == 'openai' && explicit && cache_mark(request)
    end
    def openai_input(p)
      case p.type
      when 'text','thinking','citation' then {'type'=>'input_text','text'=>LM15.parts_text([p])}
      when 'image'
        return {'type'=>'input_image','file_id'=>p.file_id} if p.file_id
        out = {'type'=>'input_image','image_url'=>p.url || LM15.media_uri(p)}
        out['detail'] = p.detail if p.detail
        out
      when 'audio'
        return {'type'=>'input_audio','audio_url'=>p.url} if p.url
        return {'type'=>'input_audio','file_id'=>p.file_id} if p.file_id
        format = p.media_type.split('/').last
        {'type'=>'input_audio','audio'=>LM15.media_base64(p),'format'=>%w[mpeg mp3].include?(format) ? 'mp3' : format}
      when 'document','binary'
        return {'type'=>'input_file','file_url'=>p.url} if p.url
        return {'type'=>'input_file','file_id'=>p.file_id} if p.file_id
        {'type'=>'input_file','filename'=>"file.#{p.media_type.split('/').last.split('+').first}",'file_data'=>LM15.media_uri(p)}
      when 'video'
        {'type'=>'input_video'}.merge(p.url ? {'video_url'=>p.url} : p.file_id ? {'file_id'=>p.file_id} : {'video_data'=>LM15.media_uri(p)})
      else unsupported("#{p.type} as Responses input") end
    end
    def tool_output(p, policy, text_type: 'input_text')
      check_tool_media(p,policy)
      unless p.content.any? { |x| MEDIA_KINDS.include?(x.type) }
        return "#{p.is_error ? '[error] ' : ''}#{LM15.parts_text(p.content)}"
      end
      blocks = p.content.map { |x| yield x }
      if p.is_error
        t = blocks.find { |x| x['type'] == text_type }
        t ? t['text'] = '[error] ' + t['text'] : blocks.unshift({'type'=>text_type,'text'=>'[error]'})
      end
      blocks
    end
  end

  def self.adapter_for(provider, **opts) = ProviderLM.new(provider:provider,**opts)
  PROVIDERS.each do |id,d|
    name = d['adapter']
    next if const_defined?(name,false)
    cls = Class.new(ProviderLM)
    cls.define_method(:initialize) { |**opts| super(provider:id,**opts) }
    const_set(name,cls)
  end
end
