# frozen_string_literal: true
require 'lm15'
request = LM15::Request.new(
  model: 'groq:llama-3.3-70b-versatile',
  messages: [LM15::Message.user('Explain Ruby blocks in one sentence.')],
  config: LM15::Config.new(max_tokens: 80)
)
router = LM15::LMRouter.new(env: {})
puts router.resolve(request.model).describe
puts LM15.to_json(request)
# Build a wire request without network activity, using a placeholder key.
wire = LM15.adapter_for('groq', api_key: 'example-placeholder').build_request(request.with(model: 'llama-3.3-70b-versatile'))
puts "#{wire.method} #{wire.url}"
