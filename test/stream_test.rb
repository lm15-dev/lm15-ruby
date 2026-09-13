# frozen_string_literal: true
require_relative 'test_helper'
class StreamTest < Minitest::Test
  def events
    [LM15::StreamStartEvent.new(model:'test'),LM15::StreamDeltaEvent.new(delta:LM15::TextDelta.new(part_index:0,text:'Hello')),LM15::StreamDeltaEvent.new(delta:LM15::TextDelta.new(part_index:0,text:' 🌱')),LM15::StreamEndEvent.new(finish_reason:'stop',usage:LM15::Usage.new(input_tokens:9,output_tokens:2))]
  end
  def test_response_includes_already_yielded_chunks
    stream = LM15::ResponseStream.new(events,request)
    stream.each { |text| assert_equal 'Hello',text; break }
    assert_equal 'Hello 🌱',stream.response.text; assert_equal 11,stream.response.usage.total_tokens
    assert_equal 'Hello 🌱',stream.response.text
  end
  def test_missing_end_and_post_end_events_never_look_successful
    error = assert_raises(LM15::StreamAssemblyError) { LM15.materialize_response(events[0...-1],request) }
    assert_equal 'Hello 🌱',error.partial.text
    assert_raises(LM15::StreamAssemblyError) { LM15.materialize_response(events + [events[1]],request) }
  end
  def test_close_releases_pull_source_without_draining
    closed = false; reads = 0
    source = Enumerator.new do |out|
      begin
        events.each { |e| reads += 1; out << e }
      ensure closed = true end
    end
    stream = LM15::ResponseStream.new(LM15::PullStream.new(source),request)
    stream.each { |_| break }; assert_equal 2,reads; refute closed
    stream.close; assert closed; assert_equal 2,reads
    assert_raises(LM15::StreamAssemblyError) { stream.response }
  end
  def test_early_close_unwinds_injected_http_transport
    closed = false; calls = 0
    transport = Object.new
    transport.define_singleton_method(:call) do |_wire,&block|
      calls += 1
      reader = Object.new
      reader.define_singleton_method(:read_body) do |&consume|
        consume.call("data: #{JSON.generate({'choices'=>[{'delta'=>{'content'=>'first'}}]})}\n\n")
        raise 'must not read ahead after close'
      end
      begin block.call(LM15::HttpResponse.new,reader); ensure closed = true end
    end
    lm = LM15::OpenAIChatLM.new(api_key:'test',transport:transport)
    stream = lm.response_stream(request); assert_equal 0,calls
    stream.each { |s| assert_equal 'first',s; break }; refute closed
    stream.close; assert closed; assert_equal 1,calls
  end
  def test_chunked_utf8_sse_through_real_client_parser
    body = "data: #{JSON.generate({'id'=>'x','choices'=>[{'delta'=>{'content'=>'café 🌱'}}]})}\n\n" +
      "data: #{JSON.generate({'choices'=>[{'delta'=>{},'finish_reason'=>'stop'}],'usage'=>{'prompt_tokens'=>3,'completion_tokens'=>4,'total_tokens'=>7}})}\n\ndata: [DONE]\n\n"
    lm = LM15::OpenAIChatLM.new(api_key:'test',transport:FakeTransport.new(LM15::HttpResponse.new(body:body)))
    res = lm.response_stream(request).response
    assert_equal 'café 🌱',res.text; assert_equal 'stop',res.finish_reason; assert_equal 7,res.usage.total_tokens
  end
  def test_sse_limits_and_multiline_records
    records = LM15.parse_sse([": ping\n","event: message\n","data: one\n","data: two\n","\n"]).to_a
    assert_equal "one\ntwo",records.first.data; assert_equal 'message',records.first.event
    assert_raises(LM15::TransportError) { LM15.parse_sse(['x' * 20],max_line_bytes:10).to_a }
  end
  def test_tool_arguments_assemble_over_arbitrary_chunks
    source = [LM15::StreamStartEvent.new,LM15::StreamDeltaEvent.new(delta:LM15::ToolCallDelta.new(part_index:0,id:'call-unique',name:'lookup',input:'{"city":')),LM15::StreamDeltaEvent.new(delta:LM15::ToolCallDelta.new(part_index:0,input:'"東京"}')),LM15::StreamEndEvent.new(finish_reason:'tool_call')]
    call = LM15.materialize_response(source,request).tool_calls.first
    assert_equal 'lookup',call.name; assert_equal({'city'=>'東京'},call.input)
  end
end
