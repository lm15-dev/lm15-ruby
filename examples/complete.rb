# frozen_string_literal: true
require 'lm15'
request = LM15::Request.new(model: ENV.fetch('LM15_MODEL', 'openai:gpt-4.1'), messages: [LM15::Message.user('What makes Ruby blocks useful?')])
response = LM15::LMRouter.new.complete(request)
puts response.text
puts "Usage: #{response.usage.to_h}"
