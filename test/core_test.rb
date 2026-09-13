# frozen_string_literal: true
require_relative 'test_helper'
class CoreTest < Minitest::Test
  def test_real_client_and_router_use_selected_account_and_wire_model
    transport = FakeTransport.new(json_response(chat_response))
    calls = 0; router = LM15::LMRouter.new(api_keys:{'openai'=> -> { calls += 1; 'private-key' }},env:{},transport:transport)
    res = router.resolve('openai-chat:gpt-4.1'); assert_equal 'openai-chat',res.provider; assert_equal 0,calls
    answer = router.complete(request(model:'openai-chat:gpt-4.1'))
    assert_equal 'Hello',answer.text; assert_equal 1,calls
    wire = transport.requests.first; assert_equal 'gpt-4.1',JSON.parse(wire.body)['model']; assert_equal 'Bearer private-key',wire.headers['authorization']
    refute_includes router.config.inspect,'private-key'; refute_includes router.lm('openai:gpt-4.1').inspect,'private-key'
  end
  def test_migration_routes_openai_to_chat_and_rejects_unrepresentable_parameters
    router = LM15::LMRouter.new(env:{},api_keys:{'openai'=>'test'})
    req,lm = router.request_from_openai_chat('gpt-4.1',[{'role'=>'user','content'=>'Hi'}],seed:874,temperature:0.25)
    assert_equal 'openai-chat',lm.provider; assert_equal 874,req.config.extensions['seed']; assert_equal 0.25,req.config.temperature
    assert_raises(LM15::NotConfiguredError) { router.request_from_openai_chat('gpt-4.1',[],api_key:'wrong-place') }
    assert_raises(LM15::UnsupportedFeatureError) { LM15.request_from_openai_chat({'model'=>'a','messages'=>[],'n'=>2}) }
    assert_raises(LM15::UnknownModelError) { LM15.openai_chat_model_string('bedrock/ambiguous') }
    assert_equal 'groq:openai/gpt-oss-20b',LM15.openai_chat_model_string('groq/openai/gpt-oss-20b')
  end
  def test_named_presets_choose_their_server_and_ambiguous_hosts_fail_closed
    assert_equal 'http://localhost:1234/v1',LM15::OpenAIChatLM.new(compat:'lm-studio').base_url
    assert_equal 'http://localhost:11434/v1',LM15::OpenAILM.new(compat:'ollama').base_url
    assert_raises(LM15::NotConfiguredError) { LM15::OpenAIChatLM.new(compat:'qwen') }
    assert_equal 'https://example.invalid/v1',LM15::OpenAIChatLM.new(compat:'qwen',base_url:'https://example.invalid/v1').base_url
  end
  def test_opaque_json_is_validated_without_mutating_input
    params = {'type'=>'object','properties'=>{'x'=>{'type'=>'string'}}}; before = Marshal.dump(params)
    tool = LM15.tool('search',parameters:params)
    req = request(tools:[tool]); req.to_h
    assert_equal before,Marshal.dump(params); assert req.frozen?; assert req.messages.frozen?
    cyclic = {}; cyclic['self'] = cyclic
    assert_raises(LM15::ValueError) { LM15.tool('bad',parameters:cyclic) }
    assert_raises(LM15::ValueError) { LM15::Config.new(temperature:Float::NAN) }
    assert_raises(TypeError) { LM15::Config.new(extensions:{seed:4}) }
  end
  def test_usage_unknown_is_preserved_when_summing_turns
    a = LM15::Usage.new(input_tokens:2,output_tokens:3,cache_read_tokens:1)
    b = LM15::Usage.new(input_tokens:7,output_tokens:11)
    sum = LM15.sum_usage(a,b)
    assert_equal 23,sum.total_tokens; assert_nil sum.cache_read_tokens; assert_nil sum.reasoning_tokens
  end
  def test_media_sources_and_roundtrips
    data = Base64.strict_encode64("\x00\xff".b)
    part = LM15.image(data:data); assert_equal "\x00\xff".b,part.bytes
    assert_equal part,LM15.from_json('part',LM15.to_json(part))
    assert_raises(LM15::ValueError) { LM15.image(data:data,url:'https://example.invalid/a.png') }
    assert_raises(LM15::ValueError) { LM15.image(data:'bad!') }
  end
  def test_cached_prefix_owns_boundary_and_model
    prefix = request(model:'gemini:test'); cached = LM15::CachedPrefix.new(prefix:prefix)
    combined = cached + 'suffix'; assert_equal 2,combined.messages.length; assert_equal 0,combined.config.cache.prefix_until_index
    assert_raises(LM15::ValueError) { cached.request('suffix',config:LM15::Config.new(cache:LM15::CacheConfig.new)) }
    assert_raises(LM15::ValueError) { cached + request(model:'different') }
  end
  def test_http_errors_have_actionable_metadata
    lm = LM15::OpenAIChatLM.new(api_key:'test',transport:FakeTransport.new(json_response({'error'=>{'message'=>'slow down','code'=>'rate_limit_exceeded'}},status:429,headers:{'Retry-After'=>'7','X-Request-Id'=>'req-9'})))
    err = assert_raises(LM15::RateLimitError) { lm.complete(request) }
    assert err.retryable?; assert_equal 7,err.retry_after; assert_equal 'req-9',err.request_id
  end
  def test_wrong_credential_kind_fails_before_transport
    transport = FakeTransport.new
    lm = LM15::OpenAILM.new(credential:LM15::AwsCredentials.new(access_key_id:'A',secret_access_key:'B'),transport:transport)
    assert_raises(LM15::NotConfiguredError) { lm.complete(request) }; assert_empty transport.requests
  end
  def test_conflicting_credentials_and_catalog_ambiguity_are_explicit
    assert_raises(LM15::NotConfiguredError) { LM15::RouterConfig.new(api_keys:{'openai-chat'=>'a','openai_chat'=>'b'}) }
    reg = LM15::ModelRegistry.new([LM15::ModelInfo.new(id:'same',provider:'openai',api_family:'openai_responses'),LM15::ModelInfo.new(id:'same',provider:'groq',api_family:'openai_chat')])
    assert_raises(LM15::AmbiguousModelError) { LM15.resolve_model('same',registry:reg) }
    assert_equal 'groq',LM15.resolve_model('groq:same',registry:reg).provider
  end
end
class CoreTest
  def test_responses_request_compat_override_is_not_sent_as_a_wire_field
    config = LM15::Config.new(extensions:{'openai_responses_compat'=>{'developer_role'=>'system','max_output_tokens_field'=>'max_tokens'},'metadata'=>{'test'=>'override'}},max_tokens:87)
    req = request(config:config,system:'custom instruction').with(messages:[LM15::Message.developer('developer instruction'),LM15::Message.user('question')])
    lm = LM15::OpenAILM.new(api_key:'test'); body = JSON.parse(lm.build_request(req).body)
    assert_equal 87,body['max_tokens']; refute body.key?('max_output_tokens'); refute body.key?('openai_responses_compat')
    assert_equal 'system',body['input'].first['role']; assert_equal({'test'=>'override'},body['metadata'])
    assert_raises(LM15::ValueError) { LM15::OpenAILM.new(api_key:'test',compat:{nonsense:'ignored'}).build_request(req) }
  end
  def test_xai_edit_retains_remote_input_url
    lm = LM15::XaiLM.new(api_key:'test'); req = LM15::ImageGenerationRequest.new(model:'image-test',prompt:'edit',images:[LM15.image(url:'https://example.invalid/source.png')])
    assert_equal({'url'=>'https://example.invalid/source.png'},JSON.parse(lm.image_generate_request(req).body)['image'])
  end
end
