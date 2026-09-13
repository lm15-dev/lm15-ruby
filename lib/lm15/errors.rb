# frozen_string_literal: true
module LM15
  class LM15Error < StandardError
    attr_reader :code, :provider, :provider_code, :status, :request_id, :retry_after, :partial, :part_index, :model, :providers, :path, :lock_path
    def initialize(message = nil, code: nil, provider: nil, provider_code: nil, status: nil, request_id: nil, retry_after: nil, partial: nil, part_index: nil, model: nil, providers: nil, path: nil, lock_path: nil)
      super(message)
      @code = code || self.class::CODE
      @provider,@provider_code,@status,@request_id = provider,provider_code,status,request_id
      @retry_after = retry_after.to_f if retry_after.is_a?(Numeric) && retry_after.finite? && retry_after >= 0
      @partial,@part_index,@model,@providers,@path,@lock_path = partial,part_index,model,providers,path,lock_path
    end
    CODE = 'provider'
    def retryable? = %w[rate_limit timeout server transport lock_timeout].include?(code)
  end
  {
    'TransportError'=>['LM15Error','transport'], 'LockTimeoutError'=>['LM15Error','lock_timeout'],
    'StreamAssemblyError'=>['LM15Error','stream_assembly'], 'ConfigurationError'=>['LM15Error','not_configured'],
    'NotConfiguredError'=>['ConfigurationError','not_configured'], 'UnknownModelError'=>['ConfigurationError','unknown_model'],
    'AmbiguousModelError'=>['ConfigurationError','ambiguous_model'], 'CapabilityError'=>['LM15Error','unsupported_feature'],
    'UnsupportedFeatureError'=>['CapabilityError','unsupported_feature'], 'ProviderError'=>['LM15Error','provider'],
    'AuthError'=>['ProviderError','auth'], 'BillingError'=>['ProviderError','billing'], 'RateLimitError'=>['ProviderError','rate_limit'],
    'InvalidRequestError'=>['ProviderError','invalid_request'], 'ContextLengthError'=>['InvalidRequestError','context_length'],
    'UnsupportedModelError'=>['InvalidRequestError','unsupported_model'], 'TimeoutError'=>['ProviderError','timeout'], 'ServerError'=>['ProviderError','server']
  }.each do |name,(parent,code)|
    cls = Class.new(const_get(parent)); cls.const_set(:CODE,code); const_set(name,cls)
  end
  RequestTimeoutError = TimeoutError
  def self.error_from_code(code, message = nil, **meta)
    name = %w[AuthError BillingError RateLimitError ContextLengthError UnsupportedModelError InvalidRequestError TimeoutError ServerError UnsupportedFeatureError NotConfiguredError UnknownModelError AmbiguousModelError TransportError LockTimeoutError StreamAssemblyError].find { |n| const_get(n)::CODE == code }
    const_get(name || 'ProviderError').new(message,**meta)
  end
end
