# frozen_string_literal: true
module LM15
  module SigV4
    def self.sign(method:, url:, headers:, body:, credential:, region:, service:, now: Time.now.utc)
      m = %r{\A[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)([^?#]*)(?:\?([^#]*))?}.match(url)
      raise ValueError,'invalid signing URL' unless m
      host,path,query = m.captures
      kept = []
      path.to_s.split('/').each { |s| s == '..' ? kept.pop : kept << s unless s.empty? || s == '.' }
      normalized = (path.start_with?('/') ? '/' : '') + kept.join('/') + (path.end_with?('/') && !kept.empty? ? '/' : '')
      normalized = '/' if normalized.empty?
      canonical_path = normalized.split('/',-1).map { |s| LM15.path_id(URI::RFC2396_PARSER.unescape(s)) }.join('/')
      canonical_query = (query || '').split('&').reject(&:empty?).map { |pair| k,v = pair.split('=',2); [k,v || ''].map { |x| URI::RFC2396_PARSER.unescape(x.tr('+',' ')) } }.map { |k,v| [LM15.path_id(k),LM15.path_id(v)] }.sort.map { |k,v| "#{k}=#{v}" }.join('&')
      h = headers.to_h.reject { |k,_| %w[authorization host x-amz-date x-amz-security-token].include?(k.downcase) }.transform_keys(&:downcase).transform_values { |v| (v.is_a?(Array) ? v.join(',') : v.to_s).split.join(' ') }
      date = now.utc.strftime('%Y%m%d'); stamp = now.utc.strftime('%Y%m%dT%H%M%SZ')
      h['host'] = host; h['x-amz-date'] = stamp
      h['x-amz-security-token'] = credential.session_token if credential.session_token
      signed = h.keys.sort.join(';')
      canonical = [method.upcase,canonical_path,canonical_query,h.keys.sort.map { |k| "#{k}:#{h[k]}\n" }.join,signed,OpenSSL::Digest::SHA256.hexdigest(body)].join("\n")
      scope = "#{date}/#{region}/#{service}/aws4_request"
      to_sign = ['AWS4-HMAC-SHA256',stamp,scope,OpenSSL::Digest::SHA256.hexdigest(canonical)].join("\n")
      key = "AWS4#{credential.secret_access_key}"
      [date,region,service,'aws4_request'].each { |s| key = OpenSSL::HMAC.digest('SHA256',key,s) }
      signature = OpenSSL::HMAC.hexdigest('SHA256',key,to_sign)
      authorization = "AWS4-HMAC-SHA256 Credential=#{credential.access_key_id}/#{scope}, SignedHeaders=#{signed}, Signature=#{signature}"
      {'canonical_request'=>canonical,'string_to_sign'=>to_sign,'authorization'=>authorization,'headers'=>h.merge('authorization'=>authorization)}
    end
  end
  class ProviderLM
    def resolve_host(explicit_url)
      host = access['host']; return unless host
      known = host['settings'].map { |s| s['name'] }
      raise ValueError,"unknown host settings: #{(settings.keys - known).join(', ')}" unless (settings.keys - known).empty?
      host['settings'].each do |s|
        value = settings[s['name']] || s['default']
        raise NotConfiguredError.new("#{provider}: setting #{s['name']} is required",provider:provider) unless value && !value.empty?
        @settings[s['name']] = value
      end
      %w[region resource location].each { |k| raise NotConfiguredError,"#{k} must be a DNS label" if settings[k] && !settings[k].match?(/\A[A-Za-z0-9-]+\z/) }
      v = settings.dup
      v['project'] = LM15.path_id(v['project']) if v['project']
      l = v['location']
      v['location_host'] = l == 'global' ? 'aiplatform.googleapis.com' : %w[us eu].include?(l) ? "aiplatform.#{l}.rep.googleapis.com" : "#{l}-aiplatform.googleapis.com" if l
      @base_url = explicit_url || host['base_url'].gsub(/\{(\w+)\}/) { v.fetch(Regexp.last_match(1)) }
    end
    def finish_host_request(url,payload,headers,request)
      h = access['host']; return [url,payload,headers] unless h
      endpoint = dialect == 'anthropic' ? 'messages' : dialect == 'gemini' ? 'generateContent' : dialect == 'openai-chat' ? 'chat/completions' : 'responses'
      streaming = payload.is_a?(Hash) && payload['stream'] || url.include?(':streamGenerateContent')
      unsupported("#{h['stream_framing']} framing") if streaming && h['stream_framing'] != 'sse'
      key = streaming && h['paths'].key?("#{endpoint}/stream") ? "#{endpoint}/stream" : endpoint
      if h['paths'][key] && request
        model = LM15.path_id(request.model).gsub('%3A',':').gsub('%40','@')
        url = base_url + h['paths'][key].gsub('{model}',model)
      end
      if payload.is_a?(Hash)
        payload = payload.dup
        payload.delete('model') if h['model_in'] == 'path'
        if h['anthropic_version_in'].start_with?('body:')
          payload['anthropic_version'] = h['anthropic_version_in'].delete_prefix('body:')
          headers.delete('anthropic-version')
        end
      end
      h['required_headers'].each { |name,setting| headers[name.downcase] = settings.fetch(setting) }
      [url,payload,headers]
    end
    def sign_request(wire,c)
      host = access['host']
      raise NotConfiguredError,'AWS credentials need a SigV4 host' unless host && host['sigv4_service']
      signed = SigV4.sign(method:wire.method,url:wire.url,headers:wire.headers,body:wire.body,credential:c,region:settings.fetch('region'),service:host['sigv4_service'],now:@clock.call)
      TransportRequest.new(method:wire.method,url:wire.url,headers:signed['headers'],body:wire.body)
    end
  end
end
