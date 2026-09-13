# frozen_string_literal: true
module LM15
  AuthStep = Struct.new(:kind,:source,:detail,:state,keyword_init:true) do
    def to_h = {kind:kind,source:source,detail:detail,state:state}
  end
  AuthReport = Struct.new(:provider,:steps,:configured,:settings,keyword_init:true) do
    def describe
      (["auth for #{provider}:"] + steps.map { |s| "  #{s.state}: #{s.source} — #{s.detail}" } + ["configured: #{configured ? 'yes' : 'no'}"] + settings.map { |k,v| "setting #{k}: #{v}" }).join("\n")
    end
    def inspect = describe
  end
  class CloudChain
    attr_reader :provider,:policy,:env,:files,:clock,:transport
    attr_accessor :settings
    def initialize(provider,env: ENV,files: nil,settings: {},clock: -> { Time.now.utc },transport: NetHTTPTransport.new)
      @provider,@env,@files,@settings,@clock,@transport = provider,env,files,settings,clock,transport
      @policy = PROVIDERS.fetch(provider)['access']
    end
    def inspect = "#<LM15::CloudChain provider=#{provider}>"
    def read(path)
      return nil unless path
      p = Auth.expand(path,env)
      files ? files[p] || files[path] || files.find { |k,_| Auth.expand(k,env) == p }&.last : File.read(p)
    rescue SystemCallError,IOError
      nil
    end
    def json(path)
      data = JSON.parse(read(path) || ''); data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end
    def on_path(command)
      return nil if command.nil? || command.empty?
      paths = command.include?('/') ? [command] : env.fetch('PATH','').split(File::PATH_SEPARATOR).map { |p| File.join(p,command) }
      paths.find { |p| files ? !read(p).nil? : File.executable?(Auth.expand(p,env)) && File.file?(Auth.expand(p,env)) }
    end
    def ini(path)
      out = {}; current = nil
      (read(path) || '').each_line do |raw|
        line = raw.strip; next if line.empty? || line.start_with?('#',';')
        if (m = /\A\[(.+)\]\z/.match(line))
          current = (out[m[1].strip] ||= {})
        elsif current && (m = /\A([^=:]+?)\s*[=:]\s*(.*)\z/.match(line))
          current[m[1].strip.downcase] = m[2].strip
        elsif !raw.start_with?(' ',"\t")
          raise NotConfiguredError,'malformed AWS profile configuration'
        end
      end
      out
    end
    def aws_config
      credentials = ini(env['AWS_SHARED_CREDENTIALS_FILE'] || '~/.aws/credentials')
      config = ini(env['AWS_CONFIG_FILE'] || '~/.aws/config')
      profile = env['AWS_PROFILE'] || env['AWS_DEFAULT_PROFILE'] || 'default'
      [credentials,config,profile]
    end
    def profile_section
      _,config,name = aws_config; config[name == 'default' ? name : "profile #{name}"] || config[name] || {}
    end
    def static_aws(section)
      return nil unless section['aws_access_key_id'] && section['aws_secret_access_key']
      AwsCredentials.new(access_key_id:section['aws_access_key_id'],secret_access_key:section['aws_secret_access_key'],session_token:section['aws_session_token'])
    end
    def adc_path = File.join(env['CLOUDSDK_CONFIG'] || '~/.config/gcloud','application_default_credentials.json')
    def profile_setting(name)
      return profile_section['region'] if policy['credential_policy'] == 'aws-chain' && name == 'region'
      if policy['credential_policy'] == 'gcp-chain' && name == 'project'
        d = json(env['GOOGLE_APPLICATION_CREDENTIALS']) || json(adc_path) || {}
        d['quota_project_id'] || d['project_id']
      end
    end
    def resolve_settings
      host = policy['host']; return settings unless host
      known = host['settings'].map { |s| s['name'] }
      raise ValueError,'unknown host setting' unless (settings.keys - known).empty?
      host['settings'].each do |s|
        settings[s['name']] ||= s['env'].filter_map { |k| env[k] }.find { |v| !v.empty? } || profile_setting(s['name']) || s['default']
        raise NotConfiguredError,"#{provider}: required host setting #{s['name']} is missing" unless settings[s['name']]
      end
      settings
    end
    def narrowed?(name,developer = false)
      selection = env['AZURE_TOKEN_CREDENTIALS'].to_s.downcase
      return false if selection.empty?
      return developer if selection == 'prod'
      return !developer if selection == 'dev'
      selection != name.downcase
    end
    def container_url
      relative = env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI']
      if relative
        raise NotConfiguredError,'invalid container credential relative URI' unless relative.start_with?('/') && !relative.start_with?('//') && !relative.match?(/[\\\r\n\t#]/)
        return "http://169.254.170.2#{relative}"
      end
      full = env['AWS_CONTAINER_CREDENTIALS_FULL_URI']; return nil unless full
      uri = URI.parse(full)
      raise NotConfiguredError,'container credential URL must not include userinfo or fragments' if uri.userinfo || uri.fragment
      allowed = uri.scheme == 'https' || (uri.scheme == 'http' && ['localhost','127.0.0.1','::1','169.254.170.2','169.254.170.23','fd00:ec2::23'].include?(uri.hostname))
      raise NotConfiguredError,'untrusted container credential URL' unless allowed
      full
    rescue URI::InvalidURIError
      raise NotConfiguredError,'invalid container credential URL'
    end
    # The offline probes and online resolver share these ordered rungs.
    def rungs
      out = policy['env_keys'].map { |k| ["env:#{k}",env[k] && !env[k].empty? ? :usable : :absent] }
      case policy['credential_policy']
      when 'aws-chain'
        creds,_,profile = aws_config; sec = profile_section
        out += [
          ['env:AWS_ACCESS_KEY_ID',env['AWS_ACCESS_KEY_ID'] && env['AWS_SECRET_ACCESS_KEY'] ? :usable : :absent],
          ['assume-role',sec['role_arn'] && (sec['source_profile'] || sec['credential_source']) ? :configured : :absent],
          ['web-identity',(env['AWS_WEB_IDENTITY_TOKEN_FILE'] || sec['web_identity_token_file']) && (env['AWS_ROLE_ARN'] || sec['role_arn']) ? :configured : :absent],
          ['sso',sec['sso_session'] || sec['sso_start_url'] ? :configured : :absent],
          ['shared-credentials-file',static_aws(creds[profile] || {}) ? :usable : :absent],
          ['login',sec['login_session'] ? :configured : :absent],
          ['credential_process',sec['credential_process'] && on_path(Shellwords.split(sec['credential_process']).first) ? :configured : :absent],
          ['config-file',static_aws(sec) ? :usable : :absent],
          ['container',container_url ? :configured : :absent],
          ['imds',env['AWS_EC2_METADATA_DISABLED'].to_s.downcase == 'true' ? :absent : :configured]
        ]
      when 'azure-chain'
        identity = env['AZURE_TENANT_ID'] && env['AZURE_CLIENT_ID']
        out += [
          ['environment',!narrowed?('EnvironmentCredential') && identity && (env['AZURE_CLIENT_SECRET'] || env['AZURE_CLIENT_CERTIFICATE_PATH']) ? :configured : :absent],
          ['workload-identity',!narrowed?('WorkloadIdentityCredential') && identity && env['AZURE_FEDERATED_TOKEN_FILE'] ? :configured : :absent],
          ['managed-identity',narrowed?('ManagedIdentityCredential') ? :absent : :configured]
        ]
        {'az'=>'AzureCliCredential','pwsh'=>'AzurePowerShellCredential','azd'=>'AzureDeveloperCliCredential'}.each { |cmd,type| out << [cmd,!narrowed?(type,true) && on_path(cmd) ? :configured : :absent] }
      when 'gcp-chain'
        out += [
          ['adc-env',json(env['GOOGLE_APPLICATION_CREDENTIALS']) ? :configured : :absent],
          ['adc-file',json(adc_path) ? :configured : :absent],
          ['metadata',%w[1 true].include?(env['NO_GCE_CHECK'].to_s.downcase) ? :absent : :configured],
          ['gcloud',on_path('gcloud') ? :configured : :absent]
        ]
      end
      out
    end
    def explain(explicit = false)
      selected = explicit
      steps = [AuthStep.new(kind:'api_keys',source:'explicit api_keys entry',detail:explicit ? 'provided (value never shown)' : 'not provided',state:explicit ? 'selected' : 'absent')]
      rungs.each do |name,verdict|
        state = verdict == :absent ? 'absent' : selected ? 'shadowed' : verdict == :configured ? 'unprobed' : 'selected'
        selected = true if state == 'selected'
        steps << AuthStep.new(kind:name,source:name,detail:verdict == :configured ? 'checked at request time' : verdict == :usable ? 'provided (value never shown)' : 'not configured',state:state)
      end
      shown = begin resolve_settings.dup; rescue NotConfiguredError => e; {'error'=>e.message} end
      AuthReport.new(provider:provider,steps:steps,configured:selected || steps.any? { |s| s.state == 'unprobed' },settings:shown)
    end
  end
  def self.explain_auth(provider,env: ENV,api_keys: {},credentials_path: nil,files: nil,settings: {},clock: -> { Time.now.utc },config:nil)
    provider = provider.provider if provider.is_a?(Resolution)
    if config
      env,api_keys = config.env,config.api_keys
      settings = config.settings.find { |k,_| k.to_s.tr('_','-') == provider.tr('_','-') }&.last || {}
    end
    provider = provider.tr('_','-'); definition = PROVIDERS[provider]
    raise ValueError,"unknown provider #{provider}" unless definition
    policy = definition['access']; source = policy['credential_policy'] == 'oauth' ? nil : api_keys_source(api_keys,provider)
    if policy['host'] || policy['credential_policy'].end_with?('-chain')
      return CloudChain.new(provider,env:env,files:files,settings:settings.dup,clock:clock).explain(!source.nil?)
    end
    steps = []; selected = false
    unless policy['credential_policy'] == 'oauth'
      steps << AuthStep.new(kind:'api_keys',source:source ? "explicit api_keys entry via #{source}" : 'explicit api_keys entry',detail:source ? 'provided (value never shown)' : 'not provided',state:source ? 'selected' : 'absent')
      selected = !source.nil?
    end
    if %w[oauth oauth-unless-explicit].include?(policy['credential_policy'])
      usable = begin Auth.load_oauth(provider,credentials_path,env:env,files:files).usable?(clock.call); rescue NotConfiguredError; false end
      state = usable ? (selected ? 'shadowed' : 'selected') : 'absent'
      steps << AuthStep.new(kind:'oauth-file',source:'stored OAuth login',detail:usable ? 'usable (value never shown)' : "not usable; #{policy['login_hint']}",state:state)
      selected ||= !!usable
    end
    unless policy['credential_policy'] == 'oauth'
      policy['env_keys'].each do |key|
        present = env[key] && !env[key].empty?
        steps << AuthStep.new(kind:"env:#{key}",source:"env $#{key}",detail:present ? 'set (value never shown)' : 'not set',state:present ? (selected ? 'shadowed' : 'selected') : 'absent')
        selected ||= !!present
      end
      if definition['placeholder_key']
        steps << AuthStep.new(kind:'placeholder',source:'local-server placeholder key',detail:'preset default',state:selected ? 'shadowed' : 'selected'); selected = true
      end
    end
    AuthReport.new(provider:provider,steps:steps,configured:selected,settings:{})
  end
end
