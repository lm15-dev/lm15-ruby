# frozen_string_literal: true
require 'open3'
require 'timeout'
require 'rexml/document'
module LM15
  class CloudChain
    def http(method,url,headers: {},body: '',params: {},timeout: 30)
      transport.call(TransportRequest.new(method:method,url:url,headers:headers,body:body,params:params,connect_timeout:timeout,read_timeout:timeout,write_timeout:timeout))
    end
    def exchange(method,url,headers: {},body: '',params: {},form: nil,json: nil,timeout: 30)
      if form
        headers = headers.merge('content-type'=>'application/x-www-form-urlencoded'); body = URI.encode_www_form(form)
      elsif json
        headers = headers.merge('content-type'=>'application/json'); body = JSON.generate(json)
      end
      res = http(method,url,headers:headers,body:body,params:params,timeout:timeout)
      raise AuthError.new("#{provider}: credential exchange failed (HTTP #{res.status})",provider:provider) unless (200...300).cover?(res.status)
      data = JSON.parse(res.body)
      raise AuthError,'credential exchange returned an invalid body' unless data.is_a?(Hash)
      data
    rescue JSON::ParserError
      raise AuthError,'credential exchange returned invalid JSON',cause:nil
    end
    def run(argv,timeout: 30)
      executable = on_path(argv.first)
      raise NotConfiguredError,'credential command was not found on PATH' unless executable
      out = nil
      Open3.popen3(env.to_h,Auth.expand(executable,env),*argv.drop(1),unsetenv_others:true,pgroup:true) do |stdin,stdout,stderr,wait|
        stdin.close
        err_reader = Thread.new { stderr.read }
        begin
          Timeout.timeout(timeout) do
            out = stdout.read
            raise AuthError,'credential command failed' unless wait.value.success?
          end
        rescue Timeout::Error
          Process.kill('TERM',-wait.pid) rescue nil
          Process.kill('KILL',-wait.pid) rescue nil
          raise AuthError,'credential command timed out',cause:nil
        ensure
          err_reader.join
        end
      end
      out
    rescue SystemCallError
      raise AuthError,'credential command could not run',cause:nil
    end
    def run_json(argv,timeout: 30)
      d = JSON.parse(run(argv,timeout:timeout)); raise AuthError,'credential command did not return an object' unless d.is_a?(Hash)
      d
    rescue JSON::ParserError
      raise AuthError,'credential command returned invalid JSON',cause:nil
    end
    def bearer(data) = CloudTokens.parse(provider,'metadata',200,data,now:clock.call)
    def aws_response(data)
      expiry = data['Expiration'] || data['expiration'] || data['expiresAt']
      expiry = expiry.is_a?(Numeric) ? Time.at(expiry > 1e11 ? expiry / 1000.0 : expiry).utc.iso8601 : expiry
      CloudTokens.parse(provider,'imds',200,{'AccessKeyId'=>data['AccessKeyId'] || data['accessKeyId'],'SecretAccessKey'=>data['SecretAccessKey'] || data['secretAccessKey'],'SessionToken'=>data['SessionToken'] || data['Token'] || data['sessionToken'],'Expiration'=>expiry},now:clock.call)
    end
    def sts_credentials(text)
      doc = REXML::Document.new(text)
      d = {}
      REXML::XPath.each(doc,'//*[local-name()="Credentials"]/*') { |e| d[e.name] = e.text.to_s.strip }
      aws_response(d)
    rescue REXML::ParseException
      raise AuthError,'STS returned invalid XML',cause:nil
    end
    def region = settings['region'] || env['AWS_REGION'] || env['AWS_DEFAULT_REGION'] || profile_section['region'] || 'us-east-1'
    def aws_env
      static_aws({'aws_access_key_id'=>env['AWS_ACCESS_KEY_ID'],'aws_secret_access_key'=>env['AWS_SECRET_ACCESS_KEY'],'aws_session_token'=>env['AWS_SESSION_TOKEN']})
    end
    def assume_role(sec,depth = 0)
      raise AuthError,'assume-role source profile chain is too deep' if depth > 5
      source = if sec['source_profile']
        creds,conf,_ = aws_config; name = sec['source_profile']
        sub = (conf[name == 'default' ? name : "profile #{name}"] || conf[name] || {}).merge(creds[name] || {})
        sub['role_arn'] ? assume_role(sub,depth + 1) : static_aws(sub)
      else
        case sec['credential_source']
        when 'Environment' then aws_env
        when 'EcsContainer' then acquire_rung('container')
        when 'Ec2InstanceMetadata' then acquire_rung('imds')
        end
      end
      raise NotConfiguredError,'assume-role source credentials are missing' unless source
      params = {'Action'=>'AssumeRole','Version'=>'2011-06-15','RoleArn'=>sec['role_arn'],'RoleSessionName'=>sec['role_session_name'] || "lm15-#{SecureRandom.hex(6)}"}
      params['ExternalId'] = sec['external_id'] if sec['external_id']; params['DurationSeconds'] = sec['duration_seconds'] if sec['duration_seconds']
      url = "https://sts.#{region}.amazonaws.com/"; body = URI.encode_www_form(params)
      signed = SigV4.sign(method:'POST',url:url,headers:{'content-type'=>'application/x-www-form-urlencoded'},body:body,credential:source,region:region,service:'sts',now:clock.call)
      res = http('POST',url,headers:signed['headers'],body:body)
      raise AuthError,'STS AssumeRole failed' unless (200...300).cover?(res.status)
      sts_credentials(res.body)
    end
    def aws_sso
      _,conf,_ = aws_config; sec = profile_section
      session = sec['sso_session']; merged = session ? (conf["sso-session #{session}"] || {}).merge(sec) : sec
      key = OpenSSL::Digest::SHA1.hexdigest(session || sec['sso_start_url'])
      path = "~/.aws/sso/cache/#{key}.json"; token = json(path)
      raise NotConfiguredError,'no cached SSO token; run aws sso login' unless token
      sso_region = merged['sso_region'] || 'us-east-1'
      access = token['accessToken']; expires = Time.parse(token['expiresAt']) if token['expiresAt']
      if !access || (expires && expires <= clock.call + Auth::REFRESH_SKEW)
        raise NotConfiguredError,'SSO token expired; run aws sso login' unless %w[refreshToken clientId clientSecret].all? { |k| token[k] }
        # Rotated refresh tokens are stored while holding the same file lock.
        Auth.with_file_lock(Auth.expand(path,env),env:env) do
          fresh = json(path) || token
          fresh_expiry = Time.parse(fresh['expiresAt']) if fresh['expiresAt']
          if fresh['accessToken'] && fresh_expiry && fresh_expiry > clock.call + Auth::REFRESH_SKEW
            access = fresh['accessToken']
          else
            d = exchange('POST',"https://oidc.#{sso_region}.amazonaws.com/token",json:{'clientId'=>fresh['clientId'],'clientSecret'=>fresh['clientSecret'],'grantType'=>'refresh_token','refreshToken'=>fresh['refreshToken']})
            access = d['accessToken']; raise AuthError,'SSO refresh returned no token' unless access
            fresh['accessToken'] = access; fresh['refreshToken'] = d['refreshToken'] if d['refreshToken']; fresh['expiresAt'] = (clock.call + d.fetch('expiresIn',3600)).utc.iso8601
            Auth.write_private_json_atomic(Auth.expand(path,env),fresh)
          end
        end
      end
      raise NotConfiguredError,'SSO profile needs account and role' unless merged['sso_account_id'] && merged['sso_role_name']
      d = exchange('GET',"https://portal.sso.#{sso_region}.amazonaws.com/federation/credentials",params:{'role_name'=>merged['sso_role_name'],'account_id'=>merged['sso_account_id']},headers:{'x-amz-sso_bearer_token'=>access})
      aws_response(d['roleCredentials'] || {})
    end
    def aws_login_cached
      sec = profile_section; return nil unless sec['login_session']
      path = File.join(env['AWS_LOGIN_CACHE_DIRECTORY'] || '~/.aws/login/cache',OpenSSL::Digest::SHA256.hexdigest(sec['login_session']) + '.json')
      d = json(path); d && d['accessToken'].is_a?(Hash) ? aws_response(d['accessToken']) : nil
    end
    def azure_scope = settings['scope'] || 'https://ai.azure.com/.default'
    def azure_token_url = "#{(settings['authority_host'] || env['AZURE_AUTHORITY_HOST'] || 'https://login.microsoftonline.com').sub(%r{/+$},'')}/#{env['AZURE_TENANT_ID']}/oauth2/v2.0/token"
    def managed_identity
      resource = azure_scope.delete_suffix('/.default'); params = {'resource'=>resource}; params['client_id'] = env['AZURE_CLIENT_ID'] if env['AZURE_CLIENT_ID']
      if env['IDENTITY_ENDPOINT'] && env['IDENTITY_HEADER']
        raise NotConfiguredError,'Service Fabric TLS pinning is unsupported; pass a credential' if env['IDENTITY_SERVER_THUMBPRINT']
        bearer(exchange('GET',env['IDENTITY_ENDPOINT'],params:params.merge('api-version'=>'2019-08-01'),headers:{'X-IDENTITY-HEADER'=>env['IDENTITY_HEADER']}))
      elsif env['MSI_ENDPOINT']
        if env['MSI_SECRET']
          params['clientid'] = params.delete('client_id') if params['client_id']
          bearer(exchange('GET',env['MSI_ENDPOINT'],params:params.merge('api-version'=>'2017-09-01'),headers:{'secret'=>env['MSI_SECRET']}))
        else
          bearer(exchange('POST',env['MSI_ENDPOINT'],form:{'resource'=>resource},headers:{'Metadata'=>'true'}))
        end
      elsif env['IDENTITY_ENDPOINT'] && env['IMDS_ENDPOINT']
        query = {'api-version'=>'2019-11-01','resource'=>resource}; url = env['IDENTITY_ENDPOINT']
        res = http('GET',url,params:query,headers:{'Metadata'=>'true'},timeout:5)
        challenge = res.headers['www-authenticate'].to_s
        raise AuthError,'Azure Arc expected a 401 challenge' unless res.status == 401 && challenge.include?('realm=')
        path = challenge.split('realm=',2).last.strip.delete_prefix('"').delete_suffix('"')
        raise AuthError,'invalid Azure Arc challenge path' unless File.dirname(path) == '/var/opt/azcmagent/tokens' && File.extname(path) == '.key'
        secret = read(path); raise AuthError,'Azure Arc challenge key is missing or too large' unless secret && secret.bytesize <= 4096
        bearer(exchange('GET',url,params:query,headers:{'Metadata'=>'true','Authorization'=>"Basic #{secret.strip}"}))
      else
        begin
          res = http('GET','http://169.254.169.254/metadata/identity/oauth2/token',params:params.merge('api-version'=>'2018-02-01'),headers:{'Metadata'=>'true'},timeout:1)
          res.status == 200 ? bearer(res.json) : nil
        rescue TransportError,TimeoutError
          nil
        end
      end
    end
    def gcp_from_info(info,depth = 0)
      raise NotConfiguredError,'Google credential nesting is too deep' if depth > 5
      case info['type']
      when 'authorized_user'
        raise NotConfiguredError,'authorized_user credentials are incomplete' unless %w[refresh_token client_id client_secret].all? { |k| info[k] }
        bearer(exchange('POST',info['token_uri'] || 'https://oauth2.googleapis.com/token',form:{'grant_type'=>'refresh_token','client_id'=>info['client_id'],'client_secret'=>info['client_secret'],'refresh_token'=>info['refresh_token']}))
      when 'service_account'
        req = CloudTokens.build(provider,'service-account',{'credential_file'=>info},now:clock.call)
        bearer(exchange('POST',req['url'],form:req['body']))
      when 'impersonated_service_account'
        raise NotConfiguredError,'impersonation requires source_credentials' unless info['source_credentials'].is_a?(Hash)
        gcp_impersonate(gcp_from_info(info['source_credentials'],depth + 1),info['service_account_impersonation_url'],info['delegates'] || [])
      when 'external_account'
        source = info['credential_source'] || {}; format = source['format'] || {}
        raise NotConfiguredError,'Google external_account with AWS credential_source is unsupported; use a file, URL, or executable' if source.key?('environment_id')
        subject = if source['file']
          read(source['file'])&.strip
        elsif source['url']
          res = http('GET',source['url'],headers:source['headers'] || {})
          raise AuthError,'subject token URL request failed' unless (200...300).cover?(res.status)
          res.body.strip
        elsif source['executable'].is_a?(Hash)
          raise NotConfiguredError,'executable source requires GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1' unless env['GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES'] == '1'
          exe = source['executable']; d = run_json(Shellwords.split(exe['command']),timeout:(exe['timeout_millis'] || 30_000) / 1000.0)
          raise AuthError,'external account executable reported failure' if d['success'] == false
          format = {'type'=>'text'}; d['id_token'] || d['saml_response']
        end
        raise NotConfiguredError,'external account needs a readable subject token source' unless subject
        subject = JSON.parse(subject)[format['subject_token_field_name']].to_s if format['type'] == 'json'
        payload = {'grantType'=>'urn:ietf:params:oauth:grant-type:token-exchange','audience'=>info['audience'].to_s,'scope'=>CloudTokens::GCP_SCOPE,'requestedTokenType'=>'urn:ietf:params:oauth:token-type:access_token','subjectToken'=>subject,'subjectTokenType'=>info['subject_token_type'].to_s}
        token = bearer(exchange('POST',info['token_url'] || 'https://sts.googleapis.com/v1/token',json:payload))
        info['service_account_impersonation_url'] ? gcp_impersonate(token,info['service_account_impersonation_url'],[]) : token
      else
        raise NotConfiguredError,'unsupported Google credential type; provide an explicit credential'
      end
    rescue JSON::ParserError
      raise AuthError,'subject token source returned invalid JSON',cause:nil
    end
    def gcp_impersonate(source,url,delegates)
      d = exchange('POST',url,headers:{'authorization'=>"Bearer #{source.value}"},json:{'delegates'=>delegates,'scope'=>[CloudTokens::GCP_SCOPE],'lifetime'=>'3600s'})
      raise AuthError,'Google impersonation returned no token' unless d['accessToken']
      BearerToken.new(value:d['accessToken'],expires_at:d['expireTime'] && Time.iso8601(d['expireTime']))
    end
    def acquire_rung(name)
      if name.start_with?('env:')
        return aws_env if name == 'env:AWS_ACCESS_KEY_ID'
        key = name.delete_prefix('env:'); return nil unless env[key] && !env[key].empty?
        return (key == 'AWS_BEARER_TOKEN_BEDROCK' ? BearerToken : ApiKey).new(value:env[key])
      end
      case name
      when 'shared-credentials-file'
        creds,_,profile = aws_config; static_aws(creds[profile] || {})
      when 'config-file' then static_aws(profile_section)
      when 'assume-role' then assume_role(profile_section)
      when 'web-identity'
        sec = profile_section
        file = env['AWS_WEB_IDENTITY_TOKEN_FILE'] || sec['web_identity_token_file']; role = env['AWS_ROLE_ARN'] || sec['role_arn']
        token = read(file); raise NotConfiguredError,'web identity token file is unreadable' unless token
        payload = {'Action'=>'AssumeRoleWithWebIdentity','Version'=>'2011-06-15','RoleArn'=>role,'RoleSessionName'=>env['AWS_ROLE_SESSION_NAME'] || sec['role_session_name'] || "lm15-#{SecureRandom.hex(6)}",'WebIdentityToken'=>token.strip}
        res = http('POST',"https://sts.#{region}.amazonaws.com/",headers:{'content-type'=>'application/x-www-form-urlencoded'},body:URI.encode_www_form(payload))
        raise AuthError,'STS web identity request failed' unless (200...300).cover?(res.status)
        sts_credentials(res.body)
      when 'sso' then aws_sso
      when 'login'
        cached = aws_login_cached
        raise NotConfiguredError,'AWS login session missing or expired; run aws login' unless cached && (!cached.expires_at || cached.expires_at > clock.call + Auth::REFRESH_SKEW)
        cached
      when 'credential_process'
        d = run_json(Shellwords.split(profile_section.fetch('credential_process')),timeout:60)
        raise AuthError,'credential_process Version must be 1' unless d['Version'] == 1
        aws_response(d)
      when 'container'
        url = container_url; return nil unless url
        token = env['AWS_CONTAINER_AUTHORIZATION_TOKEN'] || read(env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'])&.strip
        aws_response(exchange('GET',url,headers:token ? {'authorization'=>token} : {},timeout:5))
      when 'imds'
        return nil if env['AWS_EC2_METADATA_DISABLED'].to_s.downcase == 'true'
        base = (env['AWS_EC2_METADATA_SERVICE_ENDPOINT'] || (env['AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE'].to_s.downcase == 'ipv6' ? 'http://[fd00:ec2::254]' : 'http://169.254.169.254')).sub(%r{/+$},'')
        begin
          res = http('PUT',"#{base}/latest/api/token",headers:{'X-aws-ec2-metadata-token-ttl-seconds'=>'21600'},timeout:1)
        rescue TransportError,TimeoutError
          return nil
        end
        return nil unless res.status == 200
        headers = {'X-aws-ec2-metadata-token'=>res.body}
        role = http('GET',"#{base}/latest/meta-data/iam/security-credentials/",headers:headers,timeout:1)
        return nil unless role.status == 200 && !role.body.strip.empty?
        res = http('GET',"#{base}/latest/meta-data/iam/security-credentials/#{LM15.path_id(role.body.lines.first.strip)}",headers:headers,timeout:1)
        return nil unless res.status == 200
        data = res.json; raise AuthError,'IMDS rejected the credential request' if data['Code'] && data['Code'] != 'Success'
        aws_response(data)
      when 'environment'
        request = CloudTokens.build(provider,'environment',{'env'=>env.to_h,'settings'=>settings},env:env,settings:settings,files:files,now:clock.call)
        bearer(exchange('POST',request['url'],form:request['body']))
      when 'workload-identity'
        token = read(env['AZURE_FEDERATED_TOKEN_FILE']); raise NotConfiguredError,'Azure federated token file is unreadable' unless token
        bearer(exchange('POST',azure_token_url,form:{'client_id'=>env['AZURE_CLIENT_ID'],'scope'=>azure_scope,'client_assertion_type'=>CloudTokens::ASSERTION_TYPE,'client_assertion'=>token.strip,'grant_type'=>'client_credentials'}))
      when 'managed-identity' then managed_identity
      when 'az'
        argv = ['az','account','get-access-token','--output','json','--scope',azure_scope]
        argv += ['--tenant',env['AZURE_TENANT_ID']] if env['AZURE_TENANT_ID']
        d = run_json(argv); return nil unless d['accessToken']
        c = bearer({'access_token'=>d['accessToken'],'expires_on'=>d['expires_on']})
        c = c.with(expires_at:Time.parse(d['expiresOn'])) if !c.expires_at && d['expiresOn']; c
      when 'pwsh'
        resource = azure_scope.delete_suffix('/.default').gsub("'","''")
        d = run_json(['pwsh','-NoProfile','-NonInteractive','-Command',"Get-AzAccessToken -ResourceUrl '#{resource}' -AsSecureString:$false | ConvertTo-Json -Compress"])
        d['Token'] && bearer({'access_token'=>d['Token']})
      when 'azd'
        d = run_json(['azd','auth','token','--output','json','--scope',azure_scope])
        d['token'] && BearerToken.new(value:d['token'],expires_at:d['expiresOn'] && Time.iso8601(d['expiresOn']))
      when 'adc-env','adc-file'
        d = json(name == 'adc-env' ? env['GOOGLE_APPLICATION_CREDENTIALS'] : adc_path)
        d && gcp_from_info(d)
      when 'metadata'
        return nil if %w[1 true].include?(env['NO_GCE_CHECK'].to_s.downcase)
        host = env['GCE_METADATA_HOST'] || env['GCE_METADATA_ROOT'] || 'metadata.google.internal'
        begin
          res = http('GET',"http://#{host}/computeMetadata/v1/instance/service-accounts/default/token",headers:{'Metadata-Flavor'=>'Google'},timeout:1)
        rescue TransportError,TimeoutError
          return nil
        end
        res.status == 200 ? bearer(res.json) : nil
      when 'gcloud'
        token = run(['gcloud','auth','print-access-token']).strip; token.empty? ? nil : BearerToken.new(value:token)
      else raise NotConfiguredError,"unknown credential rung #{name}" end
    end
    def acquire
      resolve_settings
      rungs.each do |name,verdict|
        next if verdict == :absent
        begin
          value = acquire_rung(name); return value if value
        rescue AuthError
          next if policy['credential_policy'] == 'azure-chain' && %w[az pwsh azd].include?(name)
          raise
        end
      end
      raise NotConfiguredError.new("#{provider}: no cloud credentials resolved; configure a credential source or pass an explicit credential",provider:provider)
    end
  end
  class ProviderLM
    def cloud_credential
      # Include identity-selecting environment and settings; never print the digest inputs.
      identity = OpenSSL::Digest::SHA256.hexdigest(JSON.generate([provider,settings,@env.to_h.sort]))
      @cloud_mutex ||= Mutex.new
      @cloud_mutex.synchronize do
        cached = @cloud_cache && @cloud_cache[identity]
        return cached if cached && cached.expires_at && cached.expires_at > @clock.call + Auth::REFRESH_SKEW
        chain = CloudChain.new(provider,env:@env,settings:settings.dup,clock:@clock,transport:transport)
        value = chain.acquire
        @settings.merge!(chain.settings)
        @cloud_cache = {identity=>value}
        value
      end
    end
  end
end
