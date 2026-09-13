# frozen_string_literal: true
require_relative 'test_helper'
class LiveTest < Minitest::Test
  class FakeSocket
    attr_reader :sent,:closed
    def initialize(frames) = (@frames,@sent,@closed = frames,[],false)
    def send(frame) = @sent << JSON.parse(frame)
    def recv = @frames.shift&.then { |f| JSON.generate(f) }
    def close = @closed = true
  end
  def test_gemini_setup_and_turn_materialization_over_injected_connection
    ws = FakeSocket.new([{'setupComplete'=>{}},{'serverContent'=>{'modelTurn'=>{'parts'=>[{'text'=>'Hello'}]}}},{'serverContent'=>{'turnComplete'=>true},'usageMetadata'=>{'promptTokenCount'=>5,'responseTokenCount'=>6,'totalTokenCount'=>11}}])
    connector = lambda do |url,headers:|
      assert_equal 'wss',URI.parse(url).scheme; assert_equal 'test',URI.decode_www_form(URI.parse(url).query).to_h['key']; refute headers.key?('x-goog-api-key'); ws
    end
    lm = LM15::GeminiLM.new(api_key:'test')
    lm.live(LM15::LiveConfig.new(model:'gemini-live-preview'),connect:connector) do |session|
      session.send_text('Hi'); result = session.turn.result
      assert result.ok?; assert_equal 'Hello',result.text; assert_equal 11,result.usage.total_tokens
      assert_equal({'realtimeInput'=>{'text'=>'Hi'}},ws.sent[1])
    end
    assert ws.closed
  end
  def test_tool_call_ends_materialization_without_consuming_continuation_bill
    ws = FakeSocket.new([{'type'=>'response.output_item.done','item'=>{'type'=>'function_call','call_id'=>'call-1','name'=>'sum','arguments'=>'{"a":5}'}},{'type'=>'response.done','response'=>{'output'=>[{'type'=>'function_call'}],'usage'=>{'input_tokens'=>2,'output_tokens'=>3}}},{'type'=>'response.output_text.delta','delta'=>'Done'},{'type'=>'response.done','response'=>{'usage'=>{'input_tokens'=>7,'output_tokens'=>11}}}])
    lm = LM15::OpenAILM.new(api_key:'test')
    session = lm.live(LM15::LiveConfig.new(model:'gpt-realtime'),connect: ->(_url,headers:) { ws })
    first = session.turn.result; assert_equal 'tool_call',first.ended_by; assert_equal({'a'=>5},first.tool_calls.first.input)
    session.send_tool_result('call-1'=>'5'); second = session.turn.result
    assert_equal 'Done',second.text; assert_equal 23,second.usage.total_tokens; session.close
  end
  def test_closed_incomplete_turn_raises_with_snapshot_available
    ws = FakeSocket.new([{'type'=>'response.output_text.delta','delta'=>'partial'}])
    session = LM15::LiveSession.new(ws:ws,lm:LM15::OpenAILM.new,config:LM15::LiveConfig.new(model:'test'))
    turn = session.turn; assert_raises(LM15::TransportError) { turn.result }; assert_equal 'partial',turn.snapshot.text; refute turn.snapshot.ok?
  end
  def test_turn_rejects_concatenating_different_audio_formats
    events = [LM15::LiveServerAudioEvent.new(data:'AA==',media_type:'audio/pcm'),LM15::LiveServerAudioEvent.new(data:'AA==',media_type:'audio/mpeg')]
    assert_raises(LM15::ValueError) { LM15.materialize_turn(events) }
  end
  def with_websocket_server(&serve)
    server = TCPServer.new('127.0.0.1',0)
    worker = Thread.new do
      client = server.accept
      begin
        text = +''
        text << client.read(1) until text.end_with?("\r\n\r\n")
        key = text.lines.find { |s| s.downcase.start_with?('sec-websocket-key:') }.split(':',2).last.strip
        accept = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(key + LM15::WebSocket::GUID))
        client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n")
        serve.call(client)
      ensure client.close rescue nil end
    end
    yield_url = "ws://127.0.0.1:#{server.addr[1]}/realtime?model=test"
    [server,worker,yield_url]
  end
  def read_client_frame(socket)
    a,b = socket.read(2).unpack('CC'); size = b & 127; size = socket.read(2).unpack1('n') if size == 126
    mask = socket.read(4); data = socket.read(size)
    [a & 15,b & 128,data.bytes.each_with_index.map { |v,i| v ^ mask.getbyte(i % 4) }.pack('C*')]
  end
  def test_real_websocket_masking_ping_and_fragmented_unicode
    received = Queue.new
    server,worker,url = with_websocket_server do |socket|
      received << read_client_frame(socket)
      socket.write([0x01,3].pack('CC') + 'caf' + [0x89,1].pack('CC') + 'p')
      received << read_client_frame(socket)
      socket.write([0x80,2].pack('CC') + 'é'.b)
      received << read_client_frame(socket)
    end
    ws = LM15::WebSocket.new(url,read_timeout:3); ws.send('client-hello'); assert_equal 'café',ws.recv; ws.close
    worker.value
    assert_equal [1,128,'client-hello'],received.pop; assert_equal [10,128,'p'],received.pop; assert_equal 8,received.pop.first
  ensure
    ws&.close; worker&.kill; server&.close
  end
  def test_real_websocket_rejects_masked_server_frames
    server,worker,url = with_websocket_server { |socket| socket.write([0x81,0x80].pack('CC')) }
    ws = LM15::WebSocket.new(url,read_timeout:3)
    assert_raises(LM15::TransportError) { ws.recv }; worker.value
  ensure
    ws&.close; worker&.kill; server&.close
  end
end
