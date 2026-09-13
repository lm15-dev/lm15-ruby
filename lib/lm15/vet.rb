# frozen_string_literal: true
# The contract protocol adapter is deliberately thin: it calls public build/parse hooks.
module LM15
  module Vet
    HANDLERS = {}
    def self.adapter(m,parse_only: false)
      cred = parse_only ? 'vet-parse-only' : m['credential'] ? LM15.from_dict('credential',m['credential']) : m['api_key']
      opts = {credential:cred,base_url:m['base_url'],settings:m['settings'] || {},account_id:m['provider'].tr('_','-') == 'openai-codex' ? 'test-account' : nil}
      opts[:clock] = -> { Time.iso8601(m['now']) } if m['now']
      LM15.adapter_for(m['provider'],**opts)
    end
    def self.body(m) = Base64.strict_decode64(m['body_b64'])
    def self.http_response(m) = HttpResponse.new(status:m['status'] || 200,headers:m['headers'] || {},body:body(m))
    def self.checked_body(m,lm)
      bytes = body(m); raise lm.normalize_error(m['status'],bytes) if m['status'] && m['status'] >= 400
      bytes
    end
    HANDLERS['build_models_request'] = ->(m) { adapter(m).models_request.normalized }
    HANDLERS['parse_models_response'] = ->(m) { lm = adapter(m,parse_only:true); {'models'=>lm.models_from_body(checked_body(m,lm)).map(&:to_h)} }
    HANDLERS['file_op_build'] = lambda do |m|
      lm = adapter(m)
      wire = case m['file_op']
      when 'upload' then lm.file_upload_request(FileUploadRequest.from_dict(m['upload_request']))
      when 'get' then lm.file_get_request(m['file_id'])
      when 'delete' then lm.file_delete_request(m['file_id'])
      when 'download' then lm.file_download_request(m['file_id'])
      when 'list' then lm.file_list_request(m['limit'] || 20,m['cursor'])
      else raise ValueError,'unknown file_op' end
      wire.normalized
    end
    HANDLERS['file_op_parse'] = lambda do |m|
      lm = adapter(m,parse_only:true); bytes = checked_body(m,lm)
      m['kind'] == 'info' ? {'file'=>lm.file_info_from_body(bytes).to_h} : {'page'=>lm.file_page_from_list_body(bytes).to_h}
    end
    HANDLERS['cache_op_build'] = lambda do |m|
      lm = adapter(m)
      wire = case m['cache_op']
      when 'create' then lm.cache_create_request(Request.from_dict(m['prefix_request']),m['ttl_seconds'],m['label'])
      when 'get' then lm.cache_get_request(m['cache_id'])
      when 'delete' then lm.cache_delete_request(m['cache_id'])
      when 'update' then lm.cache_update_request(m['cache_id'],m['ttl_seconds'])
      when 'list' then lm.cache_list_request(m['limit'] || 20,m['cursor'])
      else raise ValueError,'unknown cache_op' end
      wire.normalized
    end
    HANDLERS['cache_op_parse'] = lambda do |m|
      lm = adapter(m,parse_only:true); bytes = checked_body(m,lm)
      m['kind'] == 'info' ? {'cache'=>lm.cache_info_from_body(bytes).to_h} : {'page'=>lm.cache_page_from_list_body(bytes).to_h}
    end
  end
end
module LM15::Vet
  HANDLERS['batch_op_build'] = lambda do |m|
    lm = adapter(m)
    requests = case m['action']
    when 'upload' then [lm.batch_upload_request(LM15::BatchRequest.from_dict(m['batch_request']))].compact
    when 'submit' then [lm.batch_submit_request(LM15::BatchRequest.from_dict(m['batch_request']),m['upload_body'])]
    when 'status' then [lm.batch_status_request(m['batch_id'])]
    when 'cancel' then [lm.batch_cancel_request(m['batch_id'])]
    when 'list' then [lm.batch_list_request(m['limit'] || 20)]
    when 'result_fetches' then lm.batch_result_fetches(m['status_body'] || {})
    else raise LM15::ValueError,'unknown batch action' end
    {'requests'=>requests.map(&:normalized)}
  end
  HANDLERS['batch_op_parse'] = lambda do |m|
    lm = adapter(m,parse_only:true)
    case m['kind']
    when 'job' then {'job'=>lm.batch_job_from_body(checked_body(m,lm)).to_h}
    when 'list' then {'jobs'=>lm.batch_jobs_from_list_body(checked_body(m,lm)).map(&:to_h)}
    when 'entries' then {'entries'=>lm.batch_entries(m['status_body'] || {},(m['fetched_b64'] || []).map { |s| Base64.strict_decode64(s) }).map(&:to_h)}
    else raise LM15::ValueError,'unknown batch parse kind' end
  end
end
module LM15::Vet
  HANDLERS['generation_build'] = ->(m) { lm = adapter(m); req = LM15.from_dict("#{m['kind'] == 'image' ? 'image' : 'speech'}_generation_request",m['generation_request']); lm.public_send("#{m['kind']}_generate_request",req).normalized }
  HANDLERS['generation_parse'] = lambda do |m|
    lm = adapter(m,parse_only:true); checked_body(m,lm); req = LM15.from_dict("#{m['kind']}_generation_request",m['generation_request'])
    lm.public_send("#{m['kind']}_generate_from_response",req,http_response(m)).to_h
  end
  HANDLERS['video_op_build'] = lambda do |m|
    lm = adapter(m)
    wire = case m['action']
    when 'submit' then lm.video_submit_request(LM15::VideoGenerationRequest.from_dict(m['video_request']))
    when 'status' then lm.video_status_request(m['video_id'])
    when 'result_fetch' then lm.video_result_fetch(m['status_body'])
    when 'list' then lm.video_list_request(m['limit'] || 20,m['model'])
    else raise LM15::ValueError,'unknown video action' end
    {'requests'=>[wire].compact.map(&:normalized)}
  end
  HANDLERS['video_op_parse'] = lambda do |m|
    lm = adapter(m,parse_only:true)
    case m['kind']
    when 'job' then {'job'=>lm.video_job_from_body(checked_body(m,lm),m['video_id']).to_h}
    when 'list' then {'jobs'=>lm.video_jobs_from_list_body(checked_body(m,lm)).map(&:to_h)}
    when 'part'
      fetched = m['fetched_b64'] ? LM15::HttpResponse.new(body:Base64.strict_decode64(m['fetched_b64']),headers:m['headers'] || {}) : nil
      {'part'=>lm.video_part(m['status_body'] || {},fetched).to_h}
    else raise LM15::ValueError,'unknown video parse kind' end
  end
end
module LM15::Vet
  HANDLERS['replay_live'] = lambda do |m|
    lm = adapter(m,parse_only:true); config = LM15::LiveConfig.from_dict(m['live_config'])
    {'setup_frames'=>lm.live_setup_frames(config),'client_frames'=>(m['client_events'] || []).map { |e| lm.encode_live_event(LM15.from_dict('live_client_event',e),config) },'events'=>(m['server_frames_b64'] || []).map { |f| lm.decode_live_event(Base64.strict_decode64(f)).map(&:to_h) }}
  end
end
module LM15::Vet
  HANDLERS['ingest_openai_chat'] = lambda do |m|
    lm = m['provider'] ? adapter(m,parse_only:true) : LM15::OpenAIChatLM.new(compat:m['compat'],base_url:'http://localhost/v1')
    {'canonical_request'=>lm.request_from_openai_chat(m['body']).to_h}
  end
end
