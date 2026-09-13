# frozen_string_literal: true
require 'fileutils'
require 'securerandom'
require 'shellwords'
module LM15
  module Auth
    REFRESH_SKEW = 300
    TOKEN_ENDPOINTS = {
      'claude-code'=>['https://platform.claude.com/v1/oauth/token','9d1c250a-e61b-44d5-88ed-5944d1962f5e'],
      'openai-codex'=>['https://auth.openai.com/oauth/token','app_EMoamEEZ73f0CkXaXp7hrann'],
      'xai'=>['https://auth.x.ai/oauth2/token','b1a00492-073a-47ea-816f-4c329264a828']
    }.freeze
    def self.expand(path,env = ENV)
      path = path.to_s
      path.start_with?('~/') ? File.join(env['HOME'] || Dir.home,path.delete_prefix('~/')) : path
    end
    def self.default_credentials_path(env = ENV)
      expand(env['LM15_CREDENTIALS_PATH'] || File.join(env['XDG_CONFIG_HOME'] || '~/\.config'.delete('\\'),'lm15/credentials.json'),env)
    end
    def self.lock_path_for(target,env = ENV)
      canonical = File.expand_path(expand(target,env)); missing = []
      until File.exist?(canonical)
        missing.unshift(File.basename(canonical)); parent = File.dirname(canonical); break if parent == canonical
        canonical = parent
      end
      canonical = File.join(File.realpath(canonical),*missing)
      dir = expand(env['LM15_LOCK_DIR'] || File.join(env['XDG_CACHE_HOME'] || '~/.cache','lm15/locks'),env)
      File.join(dir,"#{OpenSSL::Digest::SHA256.hexdigest(canonical)[0,32]}.lock")
    end
    def self.with_file_lock(target,timeout: 60,env: ENV)
      raise ValueError,'lock timeout must be nonnegative and finite' unless timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0
      path = lock_path_for(target,env); FileUtils.mkdir_p(File.dirname(path),mode:0o700)
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path,flags,0o600) do |f|
        raise NotConfiguredError,'credential lock must be a regular file' unless f.stat.file?
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until f.flock(File::LOCK_EX | File::LOCK_NB)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise LockTimeoutError.new('credential file lock timed out; do not delete the lock file',path:target,lock_path:path) if remaining <= 0
          sleep [0.05,remaining].min
        end
        begin
          yield
        ensure
          f.flock(File::LOCK_UN)
        end
      end
    end
    def self.write_private_json_atomic(target,data)
      dir = File.dirname(target); FileUtils.mkdir_p(dir,mode:0o700)
      temp = File.join(dir,".#{File.basename(target)}.#{SecureRandom.hex(12)}.tmp")
      begin
        File.open(temp,File::WRONLY | File::CREAT | File::EXCL,0o600) { |f| f.write(JSON.pretty_generate(data) + "\n"); f.flush; f.fsync }
        File.rename(temp,target)
        File.open(dir,File::RDONLY) { |f| f.fsync }
      ensure
        File.unlink(temp) if File.exist?(temp)
      end
    end
    def self.read_json(path,env: ENV,files: nil)
      p = expand(path,env)
      text = files ? files[p] || files[path] || files.find { |k,_| expand(k,env) == p }&.last : File.read(p)
      value = JSON.parse(text || '')
      value.is_a?(Hash) ? value : nil
    rescue SystemCallError, IOError, JSON::ParserError
      nil
    end
    def self.jwt_payload(token)
      middle = token.to_s.split('.')[1]; return {} unless middle
      JSON.parse(Base64.urlsafe_decode64(middle))
    rescue ArgumentError,JSON::ParserError
      {}
    end
    def self.account_id(token)
      claims = jwt_payload(token); auth = claims['https://api.openai.com/auth']
      auth.is_a?(Hash) ? auth['chatgpt_account_id'] : nil
    end
    class LocalOAuthCredential
      attr_reader :access_token,:refresh_token,:expires_at,:account_id,:path
      def initialize(access_token:,refresh_token: nil,expires_at: nil,account_id: nil,path: nil)
        @access_token,@refresh_token,@expires_at,@account_id,@path = access_token,refresh_token,expires_at,account_id,path
        freeze
      end
      def expired?(now = Time.now.utc) = expires_at && now >= expires_at
      def usable?(now = Time.now.utc) = !expired?(now) || !!refresh_token
      def inspect = '#<LM15::Auth::LocalOAuthCredential [REDACTED]>'
      alias to_s inspect
      def to_json(*) = JSON.generate(inspect)
    end
    def self.store_paths(provider,path = nil,env: ENV)
      return [expand(path,env)] if path
      paths = case provider
      when 'claude-code' then ['~/.claude/.credentials.json']
      when 'openai-codex' then ['~/.codex/auth.json']
      when 'xai' then [default_credentials_path(env),'~/.pi/agent/auth.json']
      else [] end
      paths.map { |p| expand(p,env) }
    end
    def self.load_oauth(provider,path = nil,env: ENV,files: nil)
      store_paths(provider,path,env:env).each do |file|
        data = read_json(file,env:env,files:files); next unless data
        raw = data[{'claude-code'=>'claudeAiOauth','openai-codex'=>'tokens','xai'=>'xai'}[provider]]; next unless raw.is_a?(Hash)
        token,refresh,expiry,account = case provider
        when 'claude-code' then [raw['accessToken'],raw['refreshToken'],raw['expiresAt'].is_a?(Numeric) ? Time.at(raw['expiresAt'] / 1000.0) : nil,nil]
        when 'openai-codex'
          access = raw['access_token']; exp = jwt_payload(access)['exp']
          [access,raw['refresh_token'],exp.is_a?(Numeric) ? Time.at(exp - REFRESH_SKEW) : nil,raw['account_id'] || account_id(access)]
        when 'xai' then [raw['access'],raw['refresh'],raw['expires'].is_a?(Numeric) ? Time.at(raw['expires'] / 1000.0) : nil,nil]
        end
        next unless token.is_a?(String) && !token.empty?
        refresh = nil unless refresh.is_a?(String) && !refresh.empty?
        return LocalOAuthCredential.new(access_token:token,refresh_token:refresh,expires_at:expiry,account_id:account,path:file)
      end
      hint = PROVIDERS.dig(provider,'access','login_hint')
      raise NotConfiguredError.new("#{provider}: no usable local credential file. #{hint}",provider:provider)
    end
    def self.get_oauth(provider,path = nil,env: ENV,clock: -> { Time.now.utc },transport: NetHTTPTransport.new,refresh: true)
      initial = load_oauth(provider,path,env:env)
      return initial unless initial.expired?(clock.call)
      hint = PROVIDERS.dig(provider,'access','login_hint')
      raise AuthError.new("#{provider}: OAuth token expired. #{hint}",provider:provider) unless refresh && initial.refresh_token
      with_file_lock(initial.path,env:env) do
        current = load_oauth(provider,initial.path,env:env)
        next current unless current.expired?(clock.call)
        raise AuthError.new("#{provider}: expired credential has no refresh token. #{hint}",provider:provider) unless current.refresh_token
        endpoint,client = TOKEN_ENDPOINTS.fetch(provider)
        payload = {'grant_type'=>'refresh_token','client_id'=>client,'refresh_token'=>current.refresh_token}
        json = provider == 'claude-code'
        wire = TransportRequest.new(method:'POST',url:endpoint,headers:{'content-type'=>json ? 'application/json' : 'application/x-www-form-urlencoded','accept'=>'application/json'},body:json ? JSON.generate(payload) : URI.encode_www_form(payload))
        begin
          res = transport.call(wire); d = res.json
          raise AuthError unless (200...300).cover?(res.status) && d.is_a?(Hash) && d['access_token'].is_a?(String) && !d['access_token'].empty?
          raise AuthError if json && (!d['refresh_token'].is_a?(String) || !d['expires_in'].is_a?(Numeric))
        rescue StandardError
          raise AuthError.new("#{provider}: OAuth refresh failed. #{hint}",provider:provider),cause:nil
        end
        data = read_json(current.path) || {}; section = {'claude-code'=>'claudeAiOauth','openai-codex'=>'tokens','xai'=>'xai'}[provider]
        raw = data[section].is_a?(Hash) ? data[section].dup : {}
        token = d['access_token']; refresh_token = d['refresh_token'] || current.refresh_token
        expiry = ((clock.call.to_f + (d['expires_in'] || 3600) - REFRESH_SKEW) * 1000).to_i
        case provider
        when 'claude-code' then raw.merge!('accessToken'=>token,'refreshToken'=>refresh_token,'expiresAt'=>expiry)
        when 'openai-codex'
          raw.merge!('access_token'=>token,'refresh_token'=>refresh_token)
          raw['account_id'] = account_id(token) if account_id(token)
          data['auth_mode'] ||= 'chatgpt'; data['last_refresh'] = clock.call.utc.iso8601
        when 'xai' then raw.merge!('type'=>'oauth','access'=>token,'refresh'=>refresh_token,'expires'=>expiry)
        end
        data[section] = raw; write_private_json_atomic(current.path,data)
        load_oauth(provider,current.path,env:env)
      end
    end
  end
  CredentialFileStore = Class.new do
    attr_reader :path
    def initialize(path = nil,env: ENV)
      @path = Auth.expand(path || Auth.default_credentials_path(env),env); @env = env
    end
    def read_all = Auth.read_json(path) || {}
    def read(provider) = read_all[provider]
    def list = read_all.keys.sort
    def write(provider,credential)
      Auth.with_file_lock(path,env:@env) { data = read_all; data[provider] = credential; Auth.write_private_json_atomic(path,data) }
    end
    def delete(provider)
      Auth.with_file_lock(path,env:@env) { data = read_all; data.delete(provider); Auth.write_private_json_atomic(path,data) }
    end
  end
  class ProviderLM
    def resolve_credential
      policy = access['credential_policy']
      if %w[oauth oauth-unless-explicit].include?(policy)
        begin
          local = Auth.load_oauth(provider,@credentials_path,env:@env)
          if policy == 'oauth' || local.usable?(@clock.call)
            local = Auth.get_oauth(provider,@credentials_path,env:@env,clock:@clock,transport:transport)
            @account_id = local.account_id if local.account_id
            return BearerToken.new(value:local.access_token)
          end
        rescue NotConfiguredError
          raise if policy == 'oauth'
        end
      end
      if policy.end_with?('-chain')
        return cloud_credential if respond_to?(:cloud_credential)
        raise NotConfiguredError,"#{provider}: provide an explicit credential"
      end
      access['env_keys'].each { |key| return ApiKey.new(value:@env[key]) if @env[key] && !@env[key].empty? }
      return ApiKey.new(value:@definition['placeholder_key']) if @definition['placeholder_key']
      raise NotConfiguredError.new("#{provider}: no credentials; set #{access['env_keys'].join(' or ')} or pass api_key. #{access['login_hint']}",provider:provider)
    end
    def inspect = "#<#{self.class} provider=#{provider.inspect}>"
  end
end
