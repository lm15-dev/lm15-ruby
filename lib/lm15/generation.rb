# frozen_string_literal: true
module LM15
  class ProviderLM
    def image_chat_request(request)
      ext = (request.extensions || {}).dup
      if request.size
        gen = hash_or(ext['generationConfig']).dup; config = hash_or(gen['imageConfig']).dup
        config['aspectRatio'] ||= request.size; gen['imageConfig'] = config; ext['generationConfig'] = gen
      end
      Request.new(model:request.model,messages:[Message.user([TextPart.new(text:request.prompt),*request.images])],config:Config.new(extensions:ext))
    end
    def speech_chat_request(request)
      unsupported('speech output format') if request.format
      gen = {'responseModalities'=>['AUDIO']}
      gen['speechConfig'] = {'voiceConfig'=>{'prebuiltVoiceConfig'=>{'voiceName'=>request.voice}}} if request.voice
      Request.new(model:request.model,messages:[Message.user(request.prompt)],config:Config.new(extensions:{'generationConfig'=>gen}.merge(request.extensions || {})))
    end
    def image_generate_request(request)
      support!('images'); return build_request(image_chat_request(request),false) if dialect == 'gemini'
      payload = {'model'=>request.model,'prompt'=>request.prompt}
      if provider == 'xai'
        unsupported('image size') if request.size
        unsupported('multiple input images') if request.images.length > 1
        path = request.images.empty? ? 'images/generations' : 'images/edits'
        unless request.images.empty?
          p = request.images.first; payload['image'] = p.file_id ? {'file_id'=>p.file_id} : {'url'=>p.url || LM15.media_uri(p)}
        end
        return emit('POST',path,payload:payload.merge(request.extensions || {}),headers:endpoint_headers)
      end
      payload['size'] = request.size if request.size; payload.merge!(request.extensions || {}); payload.compact!
      return emit('POST','images/generations',payload:payload,headers:endpoint_headers) if request.images.empty?
      files = request.images.each_with_index.map do |p,i|
        unsupported('image edit URL/file_id inputs') if p.url || p.file_id
        field = compatible(request.model)['edit_image_field'] == 'indexed' ? "image[#{i}]" : 'image[]'
        [field,"image-#{i}",p.media_type,p.bytes]
      end
      type,body = LM15.multipart_form(fields:payload.map { |k,v| [k,LM15.py_string(v)] },files:files)
      emit('POST','images/edits',headers:endpoint_headers.merge('content-type'=>type),body:body)
    end
    def image_generate_from_response(request,response)
      support!('images')
      if dialect == 'gemini'
        r = parse_response(image_chat_request(request),response); images = r.message.parts.grep(ImagePart)
        raise ProviderError,'image generation returned no images' if images.empty?
        text = r.message.parts.grep(TextPart).map(&:text).join
        return ImageGenerationResponse.new(images:images,text:present(text),id:r.id,model:r.model,usage:r.usage,provider_data:r.provider_data)
      end
      d = response.json; type = d['output_format'] ? "image/#{d['output_format']}" : 'application/octet-stream'
      images = array_or(d['data']).filter_map do |item|
        next unless item.is_a?(Hash)
        mime = provider == 'xai' ? item['mime_type'] || 'application/octet-stream' : type
        if item['b64_json'].is_a?(String) then ImagePart.new(data:item['b64_json'],media_type:mime)
        elsif item['url'].is_a?(String) then ImagePart.new(url:item['url'],media_type:mime) end
      end
      raise ProviderError,'image generation returned no images' if images.empty? && provider == 'xai'
      u = provider == 'xai' ? {} : hash_or(d['usage']).slice('input_tokens','output_tokens','total_tokens')
      ImageGenerationResponse.new(images:images,usage:Usage.from_dict(u),provider_data:d)
    end
    def speech_generate_request(request)
      support!('speech'); return build_request(speech_chat_request(request),false) if dialect == 'gemini'
      payload = {'model'=>request.model,'input'=>request.prompt}.merge(request.extensions || {})
      payload['voice'] = request.voice if request.voice; payload['response_format'] = request.format if request.format
      emit('POST','audio/speech',payload:payload,headers:endpoint_headers)
    end
    def speech_generate_from_response(request,response)
      support!('speech')
      if dialect == 'gemini'
        r = parse_response(speech_chat_request(request),response); audio = r.message.parts.find { |p| p.is_a?(AudioPart) }
        raise ProviderError,'speech generation returned no audio' unless audio
        return SpeechGenerationResponse.new(audio:audio,id:r.id,model:r.model,usage:r.usage,provider_data:r.provider_data)
      end
      type = content_media_type(response)
      SpeechGenerationResponse.new(audio:AudioPart.new(data:Base64.strict_encode64(response.body),media_type:type),provider_data:{'content_type'=>type})
    end
    def content_media_type(response)
      type = response.headers['content-type'].to_s.split(';').first.to_s.strip
      raise ProviderError,'media response has no content-type' if type.empty?
      type
    end
    def generate_image(request)
      request = ImageGenerationRequest.from_dict(request) if request.is_a?(Hash)
      image_generate_from_response(request,send_request(image_generate_request(request)))
    end
    def generate_speech(request)
      request = SpeechGenerationRequest.from_dict(request) if request.is_a?(Hash)
      speech_generate_from_response(request,send_request(speech_generate_request(request)))
    end
    def video_submit_request(request)
      support!('video'); unsupported('video input images') unless request.images.empty?
      if dialect == 'gemini'
        payload = {'instances'=>[{'prompt'=>request.prompt}]}.merge(request.extensions || {})
        payload['parameters'] ||= {'durationSeconds'=>request.seconds} if request.seconds
        path = LM15.path_id(request.model.start_with?('models/') ? request.model : "models/#{request.model}",resource_name:true) + ':predictLongRunning'
      else
        unsupported('video duration') if provider == 'xai' && request.seconds
        payload = {'model'=>request.model,'prompt'=>request.prompt}.merge(request.extensions || {})
        payload['seconds'] = request.seconds.to_s if request.seconds
        path = provider == 'xai' ? 'videos/generations' : 'videos'
      end
      emit('POST',path,payload:payload,headers:endpoint_headers)
    end
    def video_job_info(d,video_id = nil)
      if dialect == 'gemini'
        id = d['name']; status = d['done'] == true ? (d['error'].is_a?(Hash) ? 'failed' : 'completed') : 'running'
        return VideoJobInfo.new(id:id,status:status,provider_data:d) if id.is_a?(String) && !id.empty?
      else
        id = provider == 'xai' ? d['request_id'] || video_id : d['id']
        status = if provider == 'xai'
          d['request_id'] ? 'queued' : {'pending'=>'running','done'=>'completed','failed'=>'failed'}[d['status']]
        else {'queued'=>'queued','in_progress'=>'running','completed'=>'completed','failed'=>'failed','cancelled'=>'cancelled'}[d['status']] end
        raise ProviderError,'unknown video status' unless status
        if id.is_a?(String) && !id.empty?
          return VideoJobInfo.new(id:id,status:status,progress:d['progress'].is_a?(Numeric) ? d['progress'].to_i : nil,created_at:LM15.iso_utc(d['created_at']),model:d['model'],provider_data:d)
        end
      end
      raise ProviderError,'video object carries no id'
    end
    def video_job_from_body(body,video_id = nil)
      support!('video'); video_job_info(JSON.parse(body),video_id)
    end
    def video_status_request(id)
      support!('video'); path = dialect == 'gemini' ? LM15.path_id(id,resource_name:true) : "videos/#{LM15.path_id(id)}"
      emit('GET',path,headers:endpoint_headers)
    end
    def video_result_fetch(status_body)
      support!('video'); return nil if provider == 'xai'
      path = if dialect == 'gemini'
        status_body.dig('response','generateVideoResponse','generatedSamples',0,'video','uri')
      else
        id = status_body['id']; "videos/#{LM15.path_id(id)}/content" if id.is_a?(String) && !id.empty?
      end
      raise ProviderError,'finished video carries no download location' unless path.is_a?(String) && !path.empty?
      emit('GET',path,headers:endpoint_headers)
    end
    def video_part(status_body,fetched = nil)
      support!('video')
      if provider == 'xai'
        url = status_body.dig('video','url'); raise ProviderError,'finished video carries no URL' unless url.is_a?(String) && !url.empty?
        return VideoPart.new(url:url,media_type:'video/mp4')
      end
      raise ProviderError,'video bytes were not fetched' unless fetched
      VideoPart.new(data:Base64.strict_encode64(fetched.body),media_type:content_media_type(fetched))
    end
    def video_list_request(limit = 20,model = nil)
      support!('video'); unsupported('listing video jobs') if provider == 'xai'
      if dialect == 'gemini'
        unsupported('video listing without a model') unless model
        path = LM15.path_id(model.start_with?('models/') ? model : "models/#{model}",resource_name:true) + '/operations'
      else path = 'videos' end
      emit('GET',path,params:{dialect == 'gemini' ? 'pageSize' : 'limit'=>limit},headers:endpoint_headers)
    end
    def video_jobs_from_list_body(body)
      support!('video'); unsupported('listing video jobs') if provider == 'xai'
      d = JSON.parse(body); array_or(d[dialect == 'gemini' ? 'operations' : 'data']).map { |x| video_job_info(x) }
    end
    def submit_video(request)
      request = VideoGenerationRequest.from_dict(request) if request.is_a?(Hash)
      video_job_from_body(send_request(video_submit_request(request)).body)
    end
    def video_status(id) = video_job_from_body(send_request(video_status_request(id)).body,id)
    def list_videos(limit:20,model:nil) = video_jobs_from_list_body(send_request(video_list_request(limit,model)).body)
    def video_result(id)
      info = video_status(id)
      raise ProviderError,'video has not completed successfully' unless info.status == 'completed'
      wire = video_result_fetch(info.provider_data); video_part(info.provider_data,wire ? send_request(wire) : nil)
    end
  end
end
