# frozen_string_literal: true
module LM15
  class ProviderLM
    def batch_upload_request(request)
      support!('batches'); return nil unless dialect == 'openai-responses'
      data = request.requests.each_with_index.map { |r,i| JSON.generate({'custom_id'=>i.to_s,'method'=>'POST','url'=>'/v1/responses','body'=>responses_payload(r,false)}) }.join("\n") + "\n"
      type,body = LM15.multipart_form(fields:[['purpose','batch']],files:[['file','lm15-batch.jsonl','application/jsonl',data]])
      emit('POST','files',headers:endpoint_headers.merge('content-type'=>type),body:body)
    end
    def batch_submit_request(request,upload_body = nil)
      support!('batches'); ext = (request.extensions || {}).dup
      case dialect
      when 'openai-responses'
        id = hash_or(upload_body)['id']; raise ProviderError,'batch upload returned no id' unless id.is_a?(String) && !id.empty?
        payload = {'input_file_id'=>id,'endpoint'=>ext.delete('endpoint') || '/v1/responses','completion_window'=>ext.delete('completion_window') || '24h'}
        payload['metadata'] = {'label'=>request.label} if request.label
        path = 'batches'
      when 'anthropic'
        unsupported('batch labels') if request.label
        payload = {'requests'=>request.requests.each_with_index.map { |r,i| {'custom_id'=>i.to_s,'params'=>anthropic_payload(r,false)} }}
        path = 'messages/batches'
      when 'gemini'
        batch = {'inputConfig'=>{'requests'=>{'requests'=>request.requests.each_with_index.map { |r,i| {'request'=>gemini_payload(r),'metadata'=>{'key'=>i.to_s}} }}}}
        batch['displayName'] = request.label if request.label
        payload = {'batch'=>batch}
        model = request.model || request.requests.first.model
        path = LM15.path_id(model.start_with?('models/') ? model : "models/#{model}",resource_name:true).gsub('%3A',':').gsub('%40','@') + ':batchGenerateContent'
      else unsupported('batches') end
      emit('POST',path,payload:payload.merge(ext),headers:endpoint_headers)
    end
    def batch_job_info(d)
      case dialect
      when 'anthropic'
        id,created = d.values_at('id','created_at'); label = nil
        status = case d['processing_status']
        when 'in_progress' then 'running'
        when 'canceling' then 'cancelling'
        when 'ended'
          counts = hash_or(d['request_counts']); n = ->(k) { counts[k].to_i }
          if n.call('canceled') > 0 && %w[succeeded errored expired].all? { |k| n.call(k).zero? } then 'cancelled'
          elsif n.call('expired') > 0 && %w[succeeded errored canceled].all? { |k| n.call(k).zero? } then 'expired'
          else 'completed' end
        else 'queued' end
      when 'gemini'
        meta = hash_or(d['metadata']); id = d['name']; label,created = meta.values_at('displayName','createTime')
        map = {'PENDING'=>'queued','RUNNING'=>'running','CANCELLING'=>'cancelling','SUCCEEDED'=>'completed','FAILED'=>'failed','CANCELLED'=>'cancelled','EXPIRED'=>'expired'}
        status = map.fetch(meta['state'].to_s.delete_prefix('BATCH_STATE_'),d['done'] ? 'completed' : 'queued')
      else
        id,created = d.values_at('id','created_at'); label = hash_or(d['metadata'])['label']
        status = case d['status'].to_s.downcase
        when 'completed','failed','cancelled','expired' then d['status'].downcase
        when 'cancelling','canceling' then 'cancelling'
        when 'in_progress','finalizing' then 'running'
        else 'queued' end
      end
      raise ProviderError,'batch object carries no id' unless id.is_a?(String) && !id.empty?
      BatchJobInfo.new(id:id,status:status,label:label.is_a?(String) ? present(label) : nil,created_at:LM15.iso_utc(created),provider_data:d)
    end
    def batch_job_from_body(body)
      support!('batches'); batch_job_info(JSON.parse(body))
    end
    def batch_path(id)
      return LM15.path_id(id,resource_name:true) if dialect == 'gemini'
      (dialect == 'anthropic' ? 'messages/batches/' : 'batches/') + LM15.path_id(id)
    end
    def batch_status_request(id)
      support!('batches'); emit('GET',batch_path(id),headers:endpoint_headers)
    end
    def batch_cancel_request(id)
      support!('batches'); path = batch_path(id) + (dialect == 'gemini' ? ':cancel' : '/cancel')
      emit('POST',path,payload:dialect == 'gemini' ? {} : nil,headers:endpoint_headers)
    end
    def batch_list_request(limit = 20)
      support!('batches'); path = dialect == 'anthropic' ? 'messages/batches' : 'batches'
      emit('GET',path,params:{dialect == 'gemini' ? 'pageSize' : 'limit'=>limit},headers:endpoint_headers)
    end
    def batch_jobs_from_list_body(body)
      support!('batches'); d = JSON.parse(body)
      array_or(d[dialect == 'gemini' ? 'operations' : 'data']).select { |x| x.is_a?(Hash) }.map { |x| batch_job_info(x) }
    end
    def batch_result_fetches(status_body)
      support!('batches')
      return [] if dialect == 'gemini'
      if dialect == 'anthropic'
        url = status_body['results_url']; raise ProviderError,'ended batch carries no results_url' unless url.is_a?(String) && !url.empty?
        return [emit('GET',url,headers:endpoint_headers)]
      end
      %w[output_file_id error_file_id].filter_map do |key|
        id = status_body[key]
        emit('GET',"files/#{LM15.path_id(id)}/content",headers:endpoint_headers) if id.is_a?(String) && !id.empty?
      end
    end
    def batch_entry_response(body,model = nil)
      req = Request.new(model:model || body['model'] || 'unknown',messages:[Message.user('')])
      parse_response(req,HttpResponse.new(body:JSON.generate(body)))
    end
    def batch_error(index,status,body)
      err = normalize_error(status,JSON.generate(body))
      BatchEntry.new(index:index,outcome:'errored',error:ErrorDetail.new(code:err.code,message:err.message.empty? ? 'batch entry errored' : err.message,provider_code:err.provider_code))
    end
    def batch_entries(status_body,fetched = [])
      support!('batches')
      if dialect == 'gemini'
        inlined = hash_or(status_body['response'])['inlinedResponses']; inlined = inlined['inlinedResponses'] if inlined.is_a?(Hash)
        return array_or(inlined).each_with_index.filter_map do |item,position|
          next unless item.is_a?(Hash)
          index = begin Integer(hash_or(item['metadata'])['key']); rescue TypeError,ArgumentError; position end
          if item['response'].is_a?(Hash)
            BatchEntry.new(index:index,outcome:'succeeded',response:batch_entry_response(item['response'],item['response']['modelVersion']))
          else
            err = hash_or(item['error']); pc = err['status'] || err['code']
            BatchEntry.new(index:index,outcome:'errored',error:ErrorDetail.new(code:'provider',message:(err['message'] || 'batch entry errored').to_s,provider_code:pc&.to_s))
          end
        end.sort_by(&:index)
      end
      found = {}
      fetched.each do |text|
        text.each_line do |line|
          next if line.strip.empty?
          item = JSON.parse(line); index = Integer(item['custom_id'])
          if dialect == 'anthropic'
            result = hash_or(item['result'])
            entry = case result['type']
            when 'succeeded' then BatchEntry.new(index:index,outcome:'succeeded',response:batch_entry_response(hash_or(result['message'])))
            when 'errored'
              raw = result['error'] || {}; batch_error(index,400,raw.is_a?(Hash) && raw.key?('error') ? raw : {'error'=>raw})
            when 'canceled' then BatchEntry.new(index:index,outcome:'cancelled')
            when 'expired' then BatchEntry.new(index:index,outcome:'expired')
            else BatchEntry.new(index:index,outcome:'errored',error:ErrorDetail.new(code:'provider',message:"unrecognized batch result type #{result['type'].inspect}")) end
          else
            response = hash_or(item['response']); status = response['status_code'] || 0; body = hash_or(response['body'])
            entry = status == 200 && !body.empty? ? BatchEntry.new(index:index,outcome:'succeeded',response:batch_entry_response(body)) : batch_error(index,status.zero? ? 400 : status,body.empty? ? item['error'] || {} : body)
          end
          found[index] = entry
        end
      end
      return found.values.sort_by(&:index) if dialect == 'anthropic'
      total = hash_or(status_body['request_counts'])['total'].to_i; total = (found.keys.max || -1) + 1 if total.zero?
      status = batch_job_info(status_body).status
      Array.new(total) do |i|
        found[i] || if %w[expired cancelled].include?(status)
          BatchEntry.new(index:i,outcome:status)
        else BatchEntry.new(index:i,outcome:'errored',error:ErrorDetail.new(code:'provider',message:'entry missing from batch output files')) end
      end
    end
    def batch_submit(request)
      upload = batch_upload_request(request); uploaded = upload && send_request(upload).json
      batch_job_from_body(send_request(batch_submit_request(request,uploaded)).body)
    end
    def batch_status(id) = batch_job_from_body(send_request(batch_status_request(id)).body)
    def batch_cancel(id) = batch_job_from_body(send_request(batch_cancel_request(id)).body)
    def batch_list(limit: 20) = batch_jobs_from_list_body(send_request(batch_list_request(limit)).body)
    def batch_results(id)
      res = send_request(batch_status_request(id)); info = batch_job_from_body(res.body)
      raise ValueError,'batch is not finished; poll status until done' unless info.done?
      status = res.json; batch_entries(status,batch_result_fetches(status).map { |wire| send_request(wire).body })
    end
  end
end
