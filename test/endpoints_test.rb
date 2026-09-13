# frozen_string_literal: true
require_relative 'test_helper'
class EndpointsTest < Minitest::Test
  def test_batch_handle_runs_upload_submit_poll_and_ordered_results
    first = {'id'=>'batch-1','status'=>'in_progress','request_counts'=>{'total'=>2}}
    done = first.merge('status'=>'completed','output_file_id'=>'output-1')
    response = {'id'=>'answer','model'=>'gpt-4.1','status'=>'completed','output'=>[{'type'=>'message','role'=>'assistant','content'=>[{'type'=>'output_text','text'=>'ok'}]}]}
    lines = [1,0].map { |i| JSON.generate({'custom_id'=>i.to_s,'response'=>{'status_code'=>200,'body'=>response}}) }.join("\n")
    transport = FakeTransport.new(json_response({'id'=>'input-1'}),json_response(first),json_response(done),json_response(done),LM15::HttpResponse.new(body:lines))
    lm = LM15::OpenAILM.new(api_key:'test',transport:transport); job = lm.batch([request,request])
    assert_equal 'batch-1',job.id; assert_equal 'running',job.status; assert_equal 2,transport.requests.size
    assert_same job,job.refresh; assert job.done?; results = job.results
    assert_equal [0,1],results.map(&:index); assert_equal ['ok','ok'],results.map { |e| e.response.text }
    assert_equal 'input-1',JSON.parse(transport.requests[1].body)['input_file_id']
    assert_includes transport.requests.first.body,'"custom_id":"0"'
  end
  def test_job_wait_deadline_and_properties_do_not_issue_extra_requests
    transport = FakeTransport.new; lm = LM15::OpenAILM.new(api_key:'test',transport:transport)
    job = LM15::BatchJob.new(lm,LM15::BatchJobInfo.new(id:'pending',status:'queued'))
    assert_equal 'pending',job.id; refute job.done?; assert_raises(::Timeout::Error) { job.wait(timeout:0) }; assert_empty transport.requests
    assert_raises(LM15::ValueError) { job.wait(poll_every:0) }
  end
  def test_file_upload_preserves_binary_bytes_and_escapes_resource_ids
    bytes = "\x00\xff\r\n".b
    transport = FakeTransport.new(json_response({'id'=>'file weird/1','filename'=>'a.bin','bytes'=>4,'purpose'=>'user_data','created_at'=>1}),LM15::HttpResponse.new(body:bytes))
    lm = LM15::OpenAILM.new(api_key:'test',transport:transport)
    file = lm.file_upload(LM15::FileUploadRequest.new(filename:'a.bin',media_type:'application/octet-stream',bytes_data:bytes))
    assert_equal 'file weird/1',file.id; assert_includes transport.requests.first.body,bytes
    assert_equal bytes,lm.file_download(file.id); assert_includes transport.requests.last.url,'file%20weird%2F1'
  end
  def test_media_generation_and_video_result_preserve_delivery_modes
    speech = LM15::OpenAILM.new(api_key:'test',transport:FakeTransport.new(LM15::HttpResponse.new(headers:{'content-type'=>'audio/mpeg'},body:'audio-bytes')))
    audio = speech.speech_generate(LM15::SpeechGenerationRequest.new(model:'tts-test',prompt:'hello',voice:'voice-test')).audio
    assert_equal 'audio/mpeg',audio.media_type; assert_equal 'audio-bytes',audio.bytes
    xai = LM15::XaiLM.new(api_key:'test',transport:FakeTransport.new(json_response({'request_id'=>'v1'}),json_response({'status'=>'done','video'=>{'url'=>'https://example.invalid/movie.mp4'}})))
    job = xai.video_generate(LM15::VideoGenerationRequest.new(model:'video-test',prompt:'A kite'))
    assert_equal 'queued',job.status; result = job.result; assert_equal 'https://example.invalid/movie.mp4',result.url; assert_nil result.data
  end
  def test_models_and_cache_drivers_use_native_values
    transport = FakeTransport.new(json_response({'models'=>[{'name'=>'models/novel','displayName'=>'Novel'}]}),json_response({'name'=>'cachedContents/one','model'=>'models/novel','usageMetadata'=>{'totalTokenCount'=>41}}))
    lm = LM15::GeminiLM.new(api_key:'test',transport:transport)
    assert_equal 'novel',lm.list_models.first.id
    cached = lm.cache(request(model:'novel'),ttl_seconds:90)
    assert_equal 'cachedContents/one',cached.id; assert_equal 'cachedContents/one',(cached + 'ask').config.cache.resource
    assert_equal '90s',JSON.parse(transport.requests.last.body)['ttl']
  end
end
