# frozen_string_literal: true
module LM15
  def self.multipart_form(fields: [],files: [])
    boundary = "lm15-#{SecureRandom.hex(16)}"; body = ''.b
    quote = ->(s) { s.to_s.gsub(/\r|\n|"/) { |c| {'\r'=>'%0D','\n'=>'%0A','"'=>'%22'}[c] || '' } }
    fields.each { |name,value| body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{quote.call(name)}\"\r\n\r\n#{value}\r\n".b }
    files.each do |name,filename,type,data|
      raise ValueError,'invalid multipart media type' if type.match?(/[\r\n]/)
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{quote.call(name)}\"; filename=\"#{quote.call(filename)}\"\r\nContent-Type: #{type}\r\n\r\n".b << data.b << "\r\n".b
    end
    body << "--#{boundary}--\r\n".b
    ["multipart/form-data; boundary=#{boundary}",body]
  end
  def self.multipart_related(metadata:,media_type:,data:)
    raise ValueError,'invalid multipart media type' if media_type.match?(/[\r\n]/)
    boundary = "lm15-#{SecureRandom.hex(16)}"
    body = "--#{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n#{JSON.generate(metadata)}\r\n--#{boundary}\r\nContent-Type: #{media_type}\r\n\r\n".b + data.b + "\r\n--#{boundary}--\r\n".b
    ["multipart/related; boundary=#{boundary}",body]
  end
  class FileUploadRequest
    def bytes = bytes_data || File.binread(path)
  end
  MEDIA_KINDS.each do |kind|
    const_get("#{kind.capitalize}Part").class_eval do
      def bytes
        return Base64.strict_decode64(data) if data
        return File.binread(path) if path
        raise ValueError,'URL and file_id sources have no local bytes'
      end
    end
  end
  class ProviderLM
    def endpoint_headers
      return {} if dialect == 'gemini'
      h = {'content-type'=>'application/json'}
      h['anthropic-version'] = '2023-06-01' if dialect == 'anthropic'
      h
    end
    def models_request
      support!('models')
      params = dialect == 'gemini' ? {'pageSize'=>1000} : dialect == 'anthropic' ? {'limit'=>1000} : {}
      params['client_version'] = access['backend_options']['client_version'] if provider == 'openai-codex'
      emit('GET','models',headers:endpoint_headers,params:params)
    end
    def models_from_body(body)
      support!('models'); d = JSON.parse(body)
      key,id_key = if provider == 'openai-codex' then ['models','slug']
      elsif dialect == 'gemini' then ['models','name']
      else ['data','id'] end
      family = {'openai-chat'=>'openai_chat','openai-responses'=>'openai_responses','anthropic'=>'anthropic_messages','gemini'=>'gemini_generate_content'}[dialect]
      array_or(d[key]).filter_map do |entry|
        next unless entry.is_a?(Hash) && entry[id_key].is_a?(String) && !entry[id_key].empty?
        id = entry[id_key]; id = id.delete_prefix('models/') if dialect == 'gemini'
        ModelInfo.new(id:id,provider:provider,api_family:family,origin:ModelOrigin.new(type:'provider',provider_data:entry)) unless id.empty?
      end
    end
    def list_models = models_from_body(send_request(models_request).body)
    def file_resource(id)
      if id.include?('://') && id.sub(%r{/+$},'').include?('/files/')
        return 'files/' + id.sub(%r{/+$},'').split('/files/').last
      end
      id.start_with?('files/') ? id : "files/#{id}"
    end
    def file_path(id)
      dialect == 'gemini' ? LM15.path_id(file_resource(id),resource_name:true) : "files/#{LM15.path_id(id)}"
    end
    def file_upload_request(request)
      support!('files')
      if dialect == 'gemini'
        type,body = LM15.multipart_related(metadata:{'file'=>{'display_name'=>request.filename}},media_type:request.media_type,data:request.bytes)
        emit('POST','https://generativelanguage.googleapis.com/upload/v1beta/files',params:request.extensions || {},headers:{'X-Goog-Upload-Protocol'=>'multipart','content-type'=>type},body:body)
      else
        ext = (request.extensions || {}).dup
        fields = dialect == 'anthropic' ? [] : [['purpose',ext.delete('purpose') || 'user_data']]
        fields.concat(ext.map { |k,v| [k,LM15.py_string(v)] })
        type,body = LM15.multipart_form(fields:fields,files:[['file',request.filename,request.media_type,request.bytes]])
        emit('POST','files',headers:endpoint_headers.merge('content-type'=>type),body:body)
      end
    end
    def file_get_request(id)
      support!('files'); emit('GET',file_path(id),headers:endpoint_headers)
    end
    def file_delete_request(id)
      support!('files'); emit('DELETE',file_path(id),headers:endpoint_headers)
    end
    def file_download_request(id)
      support!('files'); suffix = dialect == 'gemini' ? ':download?alt=media' : '/content'
      emit('GET',file_path(id) + suffix,headers:endpoint_headers)
    end
    def file_list_request(limit = 20,cursor = nil)
      support!('files')
      p = dialect == 'gemini' ? {'pageSize'=>limit,'pageToken'=>cursor} : {'limit'=>limit,dialect == 'anthropic' ? 'page' : 'after'=>cursor}
      emit('GET','files',params:p,headers:endpoint_headers)
    end
    def file_info_from_body(body)
      support!('files'); d = JSON.parse(body); d = d['file'] if dialect == 'gemini' && d['file'].is_a?(Hash)
      file_info(d)
    end
    def file_info(d)
      case dialect
      when 'gemini'
        id = present(d['uri']) || present(d['name']); name,mime,created,expires = d.values_at('displayName','mimeType','createTime','expirationTime')
        size = begin Integer(d['sizeBytes']) if d['sizeBytes'].is_a?(Integer) || d['sizeBytes'].is_a?(String); rescue ArgumentError; nil end
        state = d['state'].to_s; ready = state.end_with?('PROCESSING') ? 'pending' : state.end_with?('FAILED') ? 'failed' : 'ready'
        download = present(d['downloadUri']) ? true : d['source'] == 'UPLOADED' ? false : nil
      when 'anthropic'
        id = d['id']; name,mime,size,created,expires,download = d.values_at('filename','mime_type','size_bytes','created_at','expires_at','downloadable'); ready = 'ready'
        download = nil unless download == true || download == false
      else
        id = d['id']; name,size,created,expires = d.values_at('filename','bytes','created_at','expires_at'); mime,download = nil,nil
        ready = {'uploaded'=>'pending','pending'=>'pending','error'=>'failed','failed'=>'failed','processed'=>'ready'}.fetch(d['status'],'ready')
      end
      raise ProviderError.new("#{provider}: file object carries no id",provider:provider) unless id.is_a?(String) && !id.empty?
      FileInfo.new(id:id,filename:name.is_a?(String) ? present(name) : nil,media_type:mime.is_a?(String) ? present(mime) : nil,size_bytes:size.is_a?(Integer) ? size : nil,created_at:LM15.iso_utc(created),expires_at:LM15.iso_utc(expires),readiness:ready,downloadable:download,provider_data:d)
    end
    def file_page_from_list_body(body)
      support!('files'); d = JSON.parse(body)
      items = array_or(d[dialect == 'gemini' ? 'files' : 'data']).select { |x| x.is_a?(Hash) }.map { |x| file_info(x) }
      cursor = dialect == 'gemini' ? d['nextPageToken'] : dialect == 'anthropic' ? d['next_page'] : d['has_more'] && !items.empty? ? d['last_id'] : nil
      FilePage.new(items:items,next_cursor:cursor.is_a?(String) ? present(cursor) : nil)
    end
    def file_upload(request) = file_info_from_body(send_request(file_upload_request(request)).body)
    def file_get(id) = file_info_from_body(send_request(file_get_request(id)).body)
    def file_list(limit: 20,cursor: nil) = file_page_from_list_body(send_request(file_list_request(limit,cursor)).body)
    def file_delete(id)
      send_request(file_delete_request(id)); nil
    end
    def file_download(id) = send_request(file_download_request(id)).body
    def self.check_cache_prefix(prefix,ttl = nil)
      raise ValueError,'cached prefix must carry a default Config' unless prefix.config == Config.new
      raise ValueError,'ttl_seconds must be a positive integer' if ttl && (!ttl.is_a?(Integer) || ttl <= 0)
    end
    def cache_create_request(prefix,ttl = nil,label = nil)
      support!('caches'); self.class.check_cache_prefix(prefix,ttl)
      p = gemini_payload(prefix).merge('model'=>prefix.model.start_with?('models/') ? prefix.model : "models/#{prefix.model}")
      p['ttl'] = "#{ttl}s" if ttl; p['displayName'] = label if label
      emit('POST','cachedContents',payload:p)
    end
    def cache_path(id) = LM15.path_id(id.start_with?('cachedContents/') ? id : "cachedContents/#{id}",resource_name:true)
    def cache_get_request(id)
      support!('caches'); emit('GET',cache_path(id))
    end
    def cache_delete_request(id)
      support!('caches'); emit('DELETE',cache_path(id))
    end
    def cache_update_request(id,ttl)
      support!('caches'); raise ValueError,'ttl_seconds must be a positive integer' unless ttl.is_a?(Integer) && ttl > 0
      emit('PATCH',cache_path(id),payload:{'ttl'=>"#{ttl}s"})
    end
    def cache_list_request(limit = 20,cursor = nil)
      support!('caches'); emit('GET','cachedContents',params:{'pageSize'=>limit,'pageToken'=>cursor})
    end
    def cache_info(d)
      id,model = d.values_at('name','model')
      raise ProviderError,'cache object carries no name or model' unless id.is_a?(String) && !id.empty? && model.is_a?(String) && !model.empty?
      count = hash_or(d['usageMetadata'])['totalTokenCount']
      CacheInfo.new(id:id,model:model.delete_prefix('models/'),tokens:count.to_s.match?(/\A\d+\z/) ? count.to_i : nil,created_at:LM15.iso_utc(d['createTime']),expires_at:LM15.iso_utc(d['expireTime']),label:present(d['displayName']),provider_data:d)
    end
    def cache_info_from_body(body)
      support!('caches'); cache_info(JSON.parse(body))
    end
    def cache_page_from_list_body(body)
      support!('caches'); d = JSON.parse(body)
      CachePage.new(items:array_or(d['cachedContents']).select { |x| x.is_a?(Hash) }.map { |x| cache_info(x) },next_cursor:present(d['nextPageToken']))
    end
    def cache_create(prefix,ttl_seconds: nil,label: nil) = cache_info_from_body(send_request(cache_create_request(prefix,ttl_seconds,label)).body)
    def cache_get(id) = cache_info_from_body(send_request(cache_get_request(id)).body)
    def cache_update(id,ttl_seconds:) = cache_info_from_body(send_request(cache_update_request(id,ttl_seconds)).body)
    def cache_list(limit: 20,cursor: nil) = cache_page_from_list_body(send_request(cache_list_request(limit,cursor)).body)
    def cache_delete(id)
      send_request(cache_delete_request(id)); nil
    end
    def cache(prefix,ttl_seconds: nil,label: nil)
      self.class.check_cache_prefix(prefix,ttl_seconds)
      resource = cache_create(prefix,ttl_seconds:ttl_seconds,label:label) if access.dig('supports','caches')
      CachedPrefix.new(prefix:prefix,resource:resource)
    end
  end
end
