# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path('../lib',__dir__))
require 'lm15'
require 'minitest/autorun'
require 'tmpdir'
class FakeTransport
  attr_reader :requests
  def initialize(*responses,&handler)
    @responses,@handler,@requests = responses,handler,[]
  end
  def call(request,&block)
    @requests << request
    response = @handler ? @handler.call(request) : @responses.shift
    raise 'unexpected network request' unless response
    raise response if response.is_a?(Exception)
    if block
      body = response.body
      source = Object.new
      source.define_singleton_method(:read_body) { |&consume| body.bytes.each_slice(7) { |bytes| consume.call(bytes.pack('C*')) } }
      block.call(response,source)
    else response end
  end
end
module TestHelpers
  def request(model:'gpt-4.1',**kw) = LM15::Request.new(model:model,messages:[LM15::Message.user('A novel test prompt: café 🦀')],**kw)
  def json_response(data,status:200,headers:{}) = LM15::HttpResponse.new(status:status,headers:headers,body:JSON.generate(data))
  def chat_response(text:'Hello',usage:nil)
    {'id'=>'answer-42','model'=>'gpt-4.1','choices'=>[{'message'=>{'role'=>'assistant','content'=>text},'finish_reason'=>'stop'}]}.tap { |d| d['usage'] = usage if usage }
  end
end
class Minitest::Test
  include TestHelpers
end
