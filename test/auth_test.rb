# frozen_string_literal: true
require_relative 'test_helper'
class AuthTest < Minitest::Test
  def test_pkce_matches_rfc7636_vector_and_redacts_verifier
    verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
    assert_equal 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',LM15::Auth.pkce_challenge(verifier)
    pair = LM15.generate_pkce; assert_equal LM15::Auth.pkce_challenge(pair.verifier),pair.challenge; refute_includes pair.inspect,pair.verifier
  end
  def test_atomic_credential_store_preserves_other_providers_and_private_mode
    Dir.mktmpdir do |dir|
      env = {'HOME'=>dir,'LM15_LOCK_DIR'=>File.join(dir,'locks')}; store = LM15::CredentialFileStore.new(File.join(dir,'creds.json'),env:env)
      threads = 6.times.map { |i| Thread.new { store.write("provider-#{i}",{'value'=>i}) } }; threads.each(&:value)
      assert_equal 6,store.list.size; assert_equal 0o600,File.stat(store.path).mode & 0o777
      store.delete('provider-2'); assert_equal 5,store.list.size; assert_equal({'value'=>4},store.read('provider-4'))
      assert_equal 1,Dir.children(dir).count { |p| p.end_with?('.json') }
    end
  end
  def test_lock_timeout_never_runs_unlocked
    Dir.mktmpdir do |dir|
      env = {'HOME'=>dir,'LM15_LOCK_DIR'=>File.join(dir,'locks')}; target = File.join(dir,'creds.json'); ready = Queue.new; release = Queue.new
      owner = Thread.new { LM15::Auth.with_file_lock(target,env:env) { ready << true; release.pop } }; ready.pop
      begin
        called = false
        err = assert_raises(LM15::LockTimeoutError) { LM15::Auth.with_file_lock(target,env:env,timeout:0) { called = true } }
        refute called; assert_equal target,err.path; assert err.retryable?
      ensure release << true; owner.value end
    end
  end
  def test_oauth_refresh_rotates_once_under_lock_and_preserves_cli_fields
    Dir.mktmpdir do |dir|
      now = Time.utc(2026,1,1); path = File.join(dir,'credentials.json'); env = {'HOME'=>dir,'LM15_LOCK_DIR'=>File.join(dir,'locks')}
      LM15::Auth.write_private_json_atomic(path,{'untouched'=>[1,2],'claudeAiOauth'=>{'accessToken'=>'old','refreshToken'=>'rotate-me','expiresAt'=>0,'scopes'=>['cli']}})
      transport = FakeTransport.new(json_response({'access_token'=>'new','refresh_token'=>'rotated','expires_in'=>3600}))
      values = 4.times.map { Thread.new { LM15::Auth.get_oauth('claude-code',path,env:env,clock: -> { now },transport:transport) } }.map(&:value)
      assert_equal ['new'],values.map(&:access_token).uniq; assert_equal 1,transport.requests.size
      body = JSON.parse(File.read(path)); assert_equal [1,2],body['untouched']; assert_equal ['cli'],body['claudeAiOauth']['scopes']; assert_equal 'rotated',body['claudeAiOauth']['refreshToken']
      refute_includes values.first.inspect,'rotated'
    end
  end
  def test_refresh_failure_does_not_clobber_original_store_or_echo_tokens
    Dir.mktmpdir do |dir|
      path = File.join(dir,'credentials.json'); env = {'HOME'=>dir,'LM15_LOCK_DIR'=>File.join(dir,'locks')}
      original = {'claudeAiOauth'=>{'accessToken'=>'secret-old','refreshToken'=>'secret-refresh','expiresAt'=>0}}
      LM15::Auth.write_private_json_atomic(path,original)
      transport = FakeTransport.new(json_response({'error'=>'secret-refresh'},status:401))
      error = assert_raises(LM15::AuthError) { LM15::Auth.get_oauth('claude-code',path,env:env,transport:transport) }
      refute_includes error.message,'secret'; assert_equal original,JSON.parse(File.read(path))
    end
  end
  def test_azure_secret_exchange_is_cached_and_identity_change_invalidates_it
    now = Time.utc(2026,1,1); env = {'AZURE_TENANT_ID'=>'tenant','AZURE_CLIENT_ID'=>'client','AZURE_CLIENT_SECRET'=>'first','AZURE_TOKEN_CREDENTIALS'=>'EnvironmentCredential'}
    transport = FakeTransport.new(json_response({'access_token'=>'one','expires_in'=>3600}),json_response({'access_token'=>'two','expires_in'=>3600}))
    lm = LM15.adapter_for('azure',env:env,settings:{'resource'=>'resource'},clock: -> { now },transport:transport)
    a = lm.build_request(request); b = lm.build_request(request)
    assert_equal 'Bearer one',a.headers['authorization']; assert_equal a.headers['authorization'],b.headers['authorization']; assert_equal 1,transport.requests.size
    env['AZURE_CLIENT_SECRET'] = 'second'; c = lm.build_request(request); assert_equal 'Bearer two',c.headers['authorization']; assert_equal 2,transport.requests.size
    assert_equal 'second',URI.decode_www_form(transport.requests.last.body).to_h['client_secret']
  end
  def test_device_polling_observes_pending_and_slowdown_without_real_sleep
    device = LM15::Auth::DeviceAuthorization.new({'device_code'=>'secret-device','user_code'=>'ABCD','verification_uri'=>'https://auth.example/verify','expires_in'=>90,'interval'=>1})
    transport = FakeTransport.new(json_response({'error'=>'authorization_pending'},status:400),json_response({'error'=>'slow_down'},status:400),json_response({'access_token'=>'granted','refresh_token'=>'rotated','expires_in'=>3600}))
    waits = []; result = LM15::Auth.poll_xai_device_login(device,transport:transport,sleep_fn: ->(n) { waits << n })
    assert_equal [1,1,6],waits; assert_equal 'granted',result.access_token; refute_includes device.inspect,'secret-device'
    assert_raises(LM15::AuthError) { LM15::Auth::DeviceAuthorization.new({'device_code'=>'s','user_code'=>'u','verification_uri'=>'file:///tmp/a','expires_in'=>90}) }
  end
end
class AuthTest
  def test_explicit_empty_callback_does_not_fall_back_to_another_account
    lm = LM15::OpenAILM.new(api_key: -> { nil },env:{'OPENAI_API_KEY'=>'another-account'})
    assert_raises(LM15::NotConfiguredError) { lm.build_request(request) }
    lm = LM15::OpenAILM.new(api_key:'',env:{'OPENAI_API_KEY'=>'another-account'})
    assert_raises(LM15::NotConfiguredError) { lm.build_request(request) }
  end
  def test_aws_profile_assume_role_signs_exchange_and_parses_namespaced_xml
    files = {'/home/test/.aws/config'=>"[profile target]\nregion=us-east-2\nrole_arn=arn:aws:iam::123456789012:role/Test\nsource_profile=source\nrole_session_name=unit-test\n",'/home/test/.aws/credentials'=>"[source]\naws_access_key_id=source-id\naws_secret_access_key=source-secret\n"}
    xml = '<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleResult><Credentials><AccessKeyId>assumed-id</AccessKeyId><SecretAccessKey>assumed-secret</SecretAccessKey><SessionToken>session</SessionToken><Expiration>2026-01-01T01:00:00Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>'
    transport = FakeTransport.new(LM15::HttpResponse.new(body:xml))
    chain = LM15::CloudChain.new('bedrock-chat',env:{'HOME'=>'/home/test','AWS_PROFILE'=>'target','AWS_EC2_METADATA_DISABLED'=>'true'},files:files,transport:transport,clock: -> { Time.utc(2026,1,1) })
    credential = chain.acquire
    assert_equal 'assumed-id',credential.access_key_id; assert_equal 'session',credential.session_token
    wire = transport.requests.first; assert_includes wire.headers['authorization'],'Credential=source-id/'; assert_equal 'us-east-2',chain.settings['region']
    assert_equal 'AssumeRole',URI.decode_www_form(wire.body).to_h['Action']; refute_includes chain.inspect,'source-secret'
  end
  def test_gcp_adc_authorized_user_exchange_discovers_project
    data = {'type'=>'authorized_user','client_id'=>'client','client_secret'=>'secret','refresh_token'=>'refresh','quota_project_id'=>'adc-project'}
    transport = FakeTransport.new(json_response({'access_token'=>'gcp-access','expires_in'=>3600}))
    chain = LM15::CloudChain.new('vertex',env:{'GOOGLE_APPLICATION_CREDENTIALS'=>'/test/adc.json','NO_GCE_CHECK'=>'true'},files:{'/test/adc.json'=>JSON.generate(data)},settings:{'location'=>'us-central1'},transport:transport)
    result = chain.acquire; assert_equal 'gcp-access',result.value; assert_equal 'adc-project',chain.settings['project']
    assert_equal 'refresh_token',URI.decode_www_form(transport.requests.first.body).to_h['grant_type']; assert_equal 1,transport.requests.size
  end
end
