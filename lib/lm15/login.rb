# frozen_string_literal: true
module LM15
  module Auth
    PKCEPair = Struct.new(:verifier,:challenge,keyword_init:true) do
      def method = 'S256'
      def inspect = '#<LM15::Auth::PKCEPair [REDACTED]>'
      alias to_s inspect
    end
    def self.pkce_challenge(verifier)
      raise ValueError,'PKCE verifier must be 43–128 unreserved ASCII characters' unless verifier.is_a?(String) && verifier.match?(/\A[A-Za-z0-9._~-]{43,128}\z/)
      Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier),padding:false)
    end
    def self.generate_pkce
      verifier = Base64.urlsafe_encode64(SecureRandom.random_bytes(64),padding:false)
      PKCEPair.new(verifier:verifier,challenge:pkce_challenge(verifier)).freeze
    end
    class DeviceAuthorization
      attr_reader :user_code,:verification_uri,:verification_uri_complete,:interval_s,:expires_in_s,:device_code
      def initialize(data)
        @device_code,@user_code = data.values_at('device_code','user_code')
        raise AuthError,'device authorization lacks required codes' unless [@device_code,@user_code].all? { |v| v.is_a?(String) && !v.empty? }
        @expires_in_s = data['expires_in']; raise AuthError,'device authorization lacks expiry' unless @expires_in_s.is_a?(Numeric) && @expires_in_s.finite? && @expires_in_s > 0
        interval = data['interval']; @interval_s = interval.is_a?(Numeric) && interval.finite? && interval > 0 ? interval : 5
        @verification_uri = checked_url(data['verification_uri']); @verification_uri_complete = data['verification_uri_complete'] && checked_url(data['verification_uri_complete']); freeze
      end
      def checked_url(s)
        uri = URI.parse(s.to_s); raise AuthError,'untrusted device verification URL' unless uri.scheme == 'https' && uri.host && !uri.userinfo
        s
      rescue URI::InvalidURIError
        raise AuthError,'untrusted device verification URL'
      end
      def inspect = '#<LM15::Auth::DeviceAuthorization [REDACTED]>'
      alias to_s inspect
    end
    def self.device_post(url,payload,transport)
      res = transport.call(TransportRequest.new(method:'POST',url:url,headers:{'content-type'=>'application/x-www-form-urlencoded'},body:URI.encode_www_form(payload)))
      data = res.json; raise AuthError,'invalid device authorization response' unless data.is_a?(Hash)
      [res.status,data]
    rescue JSON::ParserError
      raise AuthError,'invalid device authorization JSON',cause:nil
    end
    def self.start_xai_device_login(transport:NetHTTPTransport.new)
      status,data = device_post('https://auth.x.ai/oauth2/device/code',{'client_id'=>TOKEN_ENDPOINTS['xai'][1],'scope'=>'openid profile email offline_access grok-cli:access api:access','referrer'=>'lm15'},transport)
      raise AuthError,'xAI device authorization failed' unless (200...300).cover?(status)
      DeviceAuthorization.new(data)
    end
    def self.poll_xai_device_login(device,transport:NetHTTPTransport.new,sleep_fn: ->(n) { sleep n },clock: -> { Time.now.utc },monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      deadline = monotonic.call + device.expires_in_s; interval = device.interval_s; elapsed = 0
      loop do
        raise AuthError,'xAI device code expired' if monotonic.call + interval >= deadline || elapsed + interval >= device.expires_in_s
        sleep_fn.call(interval); elapsed += interval
        status,d = device_post(TOKEN_ENDPOINTS['xai'][0],{'grant_type'=>'urn:ietf:params:oauth:grant-type:device_code','client_id'=>TOKEN_ENDPOINTS['xai'][1],'device_code'=>device.device_code},transport)
        if (200...300).cover?(status)
          token = d['access_token']; raise AuthError,'device token response lacks access token' unless token.is_a?(String) && !token.empty?
          lifetime = d['expires_in']; raise AuthError,'device token response lacks expiry' unless lifetime.is_a?(Numeric) && lifetime.finite? && lifetime > 0
          return LocalOAuthCredential.new(access_token:token,refresh_token:d['refresh_token'],expires_at:clock.call + lifetime - REFRESH_SKEW)
        end
        case d['error']
        when 'authorization_pending' then next
        when 'slow_down'
          reported = d['interval']; interval = reported.is_a?(Numeric) && reported.finite? && reported > interval ? reported : interval + 5
        when 'access_denied','authorization_denied' then raise AuthError,'xAI device authorization was denied'
        when 'expired_token' then raise AuthError,'xAI device code expired'
        else raise AuthError,'xAI device token polling failed' end
      end
    end
    def self.login(provider,path:nil,env:ENV,transport:NetHTTPTransport.new,echo: ->(s) { puts s },**opts)
      provider = provider.tr('_','-'); definition = PROVIDERS[provider]; raise NotConfiguredError,'unknown login provider' unless definition
      unless provider == 'xai'
        hint = definition.dig('access','login_hint') || definition['console_url'] || "configure #{definition.dig('access','env_keys')&.join(' or ')}"
        raise UnsupportedFeatureError.new("#{provider}: #{hint}",provider:provider)
      end
      device = start_xai_device_login(transport:transport)
      echo.call("Open #{device.verification_uri_complete || device.verification_uri} and enter code: #{device.user_code}")
      credential = poll_xai_device_login(device,transport:transport,**opts)
      store = CredentialFileStore.new(path,env:env)
      Auth.with_file_lock(store.path,env:env) do
        data = store.read_all; entry = data['xai'].is_a?(Hash) ? data['xai'].dup : {}
        entry.merge!('type'=>'oauth','access'=>credential.access_token,'refresh'=>credential.refresh_token,'expires'=>(credential.expires_at.to_f * 1000).to_i)
        data['xai'] = entry; write_private_json_atomic(store.path,data)
      end
      credential
    end
  end
  def self.login(provider,**opts) = Auth.login(provider,**opts)
  def self.generate_pkce = Auth.generate_pkce
end
