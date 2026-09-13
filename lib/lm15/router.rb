# frozen_string_literal: true
module LM15
  RouteRule = Struct.new(:prefix,:provider,:note,keyword_init:true)
  DEFAULT_RULES = TABLES['rules'].map { |r| RouteRule.new(**r.transform_keys(&:to_sym)).freeze }.freeze
  Resolution = Struct.new(:requested,:model,:provider,:source,:rule,:env_key,:model_info,keyword_init:true) do
    def to_h = {'provider'=>provider,'model'=>model,'source'=>source}
    def describe = "#{requested.inspect} -> #{provider}:#{model} via #{source}"
  end
  class ModelRegistry
    include Enumerable
    def initialize(models = [])
      @models = []; models.each { |m| add(m,replace:false) }
    end
    def add(info,replace: true)
      info = ModelInfo.from_dict(info) if info.is_a?(Hash)
      raise TypeError,'expected ModelInfo' unless info.is_a?(ModelInfo)
      @models.reject! { |m| m.id == info.id && m.provider == info.provider } if replace
      @models << info; info
    end
    def each(&block) = @models.each(&block)
    def list(provider: nil) = provider ? @models.select { |m| m.provider == provider } : @models.dup
    def get(id,provider: nil) = @models.find { |m| m.id == id && (!provider || m.provider == provider) }
  end
  def self.resolve_model(model,registry: nil,rules: DEFAULT_RULES,env: ENV)
    raise UnknownModelError.new('model must be a non-empty string',model:model.to_s) unless model.is_a?(String) && !model.empty?
    requested = model
    head,rest = model.split(':',2)
    provider = head.tr('_','-')
    if rest && !rest.empty? && PROVIDERS[provider]
      return Resolution.new(requested:requested,model:rest,provider:provider,source:'prefix',env_key:PROVIDERS[provider]['access']['env_keys'].find { |k| env[k] && !env[k].empty? })
    end
    if registry
      matches = registry.select { |m| m.id == model || m.aliases.include?(model) }
      providers = matches.map(&:provider).uniq
      raise AmbiguousModelError.new("model #{model.inspect} is offered by multiple providers; use provider:model",model:model,providers:providers) if providers.length > 1
      unless matches.empty?
        exact = matches.select { |m| m.id == model }; matches = exact unless exact.empty?
        raise AmbiguousModelError.new("model #{model.inspect} matches multiple catalog entries",model:model,providers:providers) if matches.length > 1
        info = matches.first; provider = info.provider.tr('_','-')
        raise UnknownModelError.new("catalog provider #{provider.inspect} has no adapter",model:model) unless PROVIDERS[provider]
        return Resolution.new(requested:requested,model:info.id,provider:provider,source:'catalog',model_info:info)
      end
    end
    rules.each do |rule|
      rule = RouteRule.new(**rule.transform_keys(&:to_sym)) if rule.is_a?(Hash)
      next unless model.start_with?(rule.prefix)
      provider = rule.provider.tr('_','-')
      raise UnknownModelError.new("rule provider #{provider.inspect} has no adapter",model:model) unless PROVIDERS[provider]
      return Resolution.new(requested:requested,model:model,provider:provider,source:'rule',rule:rule,env_key:PROVIDERS[provider]['access']['env_keys'].find { |k| env[k] && !env[k].empty? })
    end
    raise UnknownModelError.new("could not route #{model.inspect}; use a known provider:model prefix",model:model)
  end
  def self.api_keys_source(keys,provider)
    keys ||= {}; provider = provider.tr('_','-')
    exact = keys.keys.select { |k| k.to_s.tr('_','-') == provider }
    candidates = exact
    if exact.empty? && PROVIDERS[provider]
      target = PROVIDERS[provider]['access']['env_keys']
      candidates = keys.keys.select { |k| PROVIDERS.dig(k.to_s.tr('_','-'),'access','env_keys') == target } unless target.empty?
    end
    raise NotConfiguredError,"ambiguous credentials for #{provider}; supply one exact api_keys entry" if candidates.length > 1
    source = candidates.first
    raise NotConfiguredError,'explicit credential is empty; no environment fallback' if source && (keys[source].nil? || keys[source] == '')
    source
  end
  class RouterConfig
    attr_reader :registry,:rules,:env,:api_keys,:base_urls,:settings,:transport
    def initialize(registry: nil,rules: DEFAULT_RULES,env: ENV,api_keys: {},base_urls: {},settings: {},transport: NetHTTPTransport.new)
      @registry,@rules,@env,@api_keys,@base_urls,@settings,@transport = registry,rules,env,api_keys,base_urls,settings,transport
      {api_keys:api_keys,base_urls:base_urls,settings:settings}.each do |field,mapping|
        seen = []
        mapping.each_key do |key|
          canonical = key.to_s.tr('_','-')
          raise NotConfiguredError,"#{field} contains unknown provider #{key.inspect}" unless PROVIDERS[canonical]
          raise NotConfiguredError,"duplicate provider spelling in api_keys: #{key}" if field == :api_keys && seen.include?(canonical)
          seen << canonical
        end
      end
      freeze
    end
    def inspect = "#<LM15::RouterConfig providers=#{api_keys.keys.inspect}>"
  end
  class LMRouter
    attr_reader :config
    def initialize(config = nil,**opts)
      @config = config || RouterConfig.new(**opts); @lms = {}; @mutex = Mutex.new
    end
    def resolve(model) = LM15.resolve_model(model,registry:config.registry,rules:config.rules,env:config.env)
    def lm(model)
      res = resolve(model)
      @mutex.synchronize do
        @lms[res.provider] ||= begin
          policy = PROVIDERS[res.provider]['access']
          source = policy['credential_policy'] == 'oauth' ? nil : LM15.api_keys_source(config.api_keys,res.provider)
          key = source && config.api_keys[source]
          base = config.base_urls.find { |k,_| k.to_s.tr('_','-') == res.provider }&.last
          settings = config.settings.find { |k,_| k.to_s.tr('_','-') == res.provider }&.last || {}
          if policy['host']
            settings = settings.dup
            policy['host']['settings'].each do |s|
              settings[s['name']] ||= s['env'].filter_map { |n| config.env[n] }.find { |v| !v.empty? }
              settings.delete(s['name']) if settings[s['name']].nil?
            end
          end
          LM15.adapter_for(res.provider,api_key:key,base_url:base,settings:settings,env:config.env,transport:config.transport)
        end
      end
    end
    def complete(request)
      request = Request.from_dict(request) if request.is_a?(Hash)
      res = resolve(request.model); lm(request.model).complete(request.with(model:res.model))
    end
    def stream(request)
      request = Request.from_dict(request) if request.is_a?(Hash)
      res = resolve(request.model); lm(request.model).stream(request.with(model:res.model))
    end
    def response_stream(request) = ResponseStream.new(stream(request),request)
  end
end
