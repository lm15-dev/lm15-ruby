# frozen_string_literal: true
module LM15
  module CloudTokens
    JWT_BEARER = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
    ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
    GCP_SCOPE = 'https://www.googleapis.com/auth/cloud-platform'
    def self.jwt(header,payload,pem)
      raise NotConfiguredError,'encrypted private keys are unsupported; decrypt with openssl pkey' if pem.include?('ENCRYPTED')
      block = pem[/-----BEGIN (?:RSA )?PRIVATE KEY-----.*?-----END (?:RSA )?PRIVATE KEY-----/m]
      raise NotConfiguredError,'RS256 requires a PEM RSA private key' unless block
      key = OpenSSL::PKey.read(block)
      raise NotConfiguredError,'RS256 requires an RSA private key' unless key.is_a?(OpenSSL::PKey::RSA) && key.private?
      input = [header,payload].map { |d| Base64.urlsafe_encode64(JSON.generate(d),padding:false) }.join('.')
      input + '.' + Base64.urlsafe_encode64(key.sign('SHA256',input),padding:false)
    rescue OpenSSL::PKey::PKeyError
      raise NotConfiguredError,'invalid RSA private key',cause:nil
    end
    def self.build(provider,rung,input,now: Time.now.utc,settings: {},env: {},files: nil)
      if %w[adc-env adc-file service-account].include?(rung)
        info = input['credential_file']; raise ValueError,'credential_file must be an object' unless info.is_a?(Hash)
        url = info['token_uri'] || 'https://oauth2.googleapis.com/token'
        header = {'alg'=>'RS256','typ'=>'JWT'}; header['kid'] = info['private_key_id'] if info['private_key_id']
        payload = {'iat'=>now.to_i,'exp'=>now.to_i + 3600,'iss'=>info['client_email'].to_s,'aud'=>url,'scope'=>input['scope'] || GCP_SCOPE}
        body = {'grant_type'=>JWT_BEARER,'assertion'=>jwt(header,payload,info['private_key'].to_s)}
      elsif rung == 'environment'
        env = input['env'] || env; settings = input['settings'] || settings
        tenant,client = env.values_at('AZURE_TENANT_ID','AZURE_CLIENT_ID')
        raise NotConfiguredError,'Azure environment requires tenant and client IDs' unless tenant && client
        authority = (settings['authority_host'] || env['AZURE_AUTHORITY_HOST'] || 'https://login.microsoftonline.com').sub(%r{/+$},'')
        url = "#{authority}/#{tenant}/oauth2/v2.0/token"
        body = {'client_id'=>client,'scope'=>settings['scope'] || 'https://ai.azure.com/.default'}
        if env['AZURE_CLIENT_SECRET']
          body['client_secret'] = env['AZURE_CLIENT_SECRET']
        elsif env['AZURE_CLIENT_CERTIFICATE_PATH']
          raise NotConfiguredError,'password-protected certificates are unsupported' if env['AZURE_CLIENT_CERTIFICATE_PASSWORD']
          path = env['AZURE_CLIENT_CERTIFICATE_PATH']
          pem = input['certificate_pem'] ? input['certificate_pem'] + "\n" + input['private_key_pem'].to_s : files ? files[path] : File.read(path)
          raise NotConfiguredError,'certificate is unreadable' unless pem
          der = OpenSSL::X509::Certificate.new(pem).to_der
          header = {'alg'=>'RS256','typ'=>'JWT','x5t'=>Base64.urlsafe_encode64(OpenSSL::Digest::SHA1.digest(der),padding:false)}
          header['x5c'] = [Base64.strict_encode64(der)] if %w[true 1].include?(env['AZURE_CLIENT_SEND_CERTIFICATE_CHAIN'].to_s.downcase)
          payload = {'aud'=>url,'iss'=>client,'sub'=>client,'exp'=>now.to_i + 600,'iat'=>now.to_i,'jti'=>input['jti'] || SecureRandom.uuid}
          body['client_assertion_type'] = ASSERTION_TYPE
          body['client_assertion'] = jwt(header,payload,pem)
        else
          raise NotConfiguredError,'Azure environment needs a secret or certificate'
        end
        body['grant_type'] = 'client_credentials'
      else
        raise ValueError,"no deterministic token request for #{rung}"
      end
      {'method'=>'POST','url'=>url,'headers'=>{'content-type'=>'application/x-www-form-urlencoded'},'body_encoding'=>'form','body'=>body}
    rescue SystemCallError,OpenSSL::X509::CertificateError
      raise NotConfiguredError,'certificate could not be loaded',cause:nil
    end
    def self.parse(provider,rung,status,body,now: Time.now.utc)
      aws = %w[credential_process imds container].include?(rung)
      ok = rung == 'credential_process' ? status == 0 && body['Version'] == 1 : (200...300).cover?(status)
      raise AuthError.new("#{rung}: token request failed",provider:provider) unless ok
      if aws
        raise AuthError,'AWS credential response is missing keys' unless body['AccessKeyId'].is_a?(String) && body['SecretAccessKey'].is_a?(String)
        expires = begin Time.iso8601(body['Expiration']).utc if body['Expiration']; rescue ArgumentError; nil end
        AwsCredentials.new(access_key_id:body['AccessKeyId'],secret_access_key:body['SecretAccessKey'],session_token:body['Token'] || body['SessionToken'],expires_at:expires)
      else
        token = body['access_token']; raise AuthError,'token response is missing access_token' unless token.is_a?(String) && !token.empty?
        expires = begin
          body['expires_on'] && body['expires_on'] != '' ? Time.at(Float(body['expires_on']).to_i).utc : nil
        rescue ArgumentError,TypeError,RangeError
          nil
        end
        unless expires
          expires = begin now + Float(body['expires_in']).to_i if body['expires_in']; rescue ArgumentError,TypeError,RangeError; nil end
        end
        BearerToken.new(value:token,expires_at:expires)
      end
    end
  end
end
