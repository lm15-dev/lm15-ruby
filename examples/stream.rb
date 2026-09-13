# frozen_string_literal: true
require 'lm15'
request = LM15::Request.new(model: ENV.fetch('LM15_MODEL', 'openai:gpt-4.1'), messages: [LM15::Message.user('Write a haiku about a river.')])
stream = LM15::LMRouter.new.response_stream(request)
begin
  stream.each { |text| print text }
  puts "\nFinished: #{stream.response.finish_reason}"
ensure
  stream.close
end
