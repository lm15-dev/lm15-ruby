# frozen_string_literal: true
require_relative 'test_helper'

class HistoryContentTest < Minitest::Test
  def history(*parts)
    request.with(messages: [LM15::Message.assistant(parts), LM15::Message.user('Describe that earlier output.')])
  end

  def test_chat_refuses_assistant_media_before_credentials_or_transport
    %w[Image Audio Video Document Binary].each do |kind|
      calls = 0
      transport = FakeTransport.new
      lm = LM15::OpenAIChatLM.new(api_key: -> { calls += 1; 'test' }, env: {}, transport: transport)
      part = LM15.const_get("#{kind}Part").new(url: 'https://example.invalid/original')
      [false, true].each do |stream|
        error = assert_raises(LM15::UnsupportedFeatureError) do
          lm.build_request(history(LM15::TextPart.new(text: 'keep both'), part), stream)
        end
        assert_includes error.message, part.type
        assert_includes error.message, 'assistant'
      end
      assert_equal 0, calls
      assert_empty transport.requests
    end
  end

  def test_responses_keeps_text_and_image_in_one_assistant_input_message
    lm = LM15::OpenAILM.new(api_key: 'test')
    req = history(LM15::TextPart.new(text: 'before'), LM15.image(url: 'https://example.invalid/image.png', detail: 'high'), LM15::TextPart.new(text: 'after'))
    before = req.to_h
    [false, true].each do |stream|
      message = JSON.parse(lm.build_request(req, stream).body)['input'].first
      assert_equal 'assistant', message['role']
      assert_equal [
        {'type' => 'input_text', 'text' => 'before'},
        {'type' => 'input_image', 'image_url' => 'https://example.invalid/image.png', 'detail' => 'high'},
        {'type' => 'input_text', 'text' => 'after'}
      ], message['content']
    end
    assert_equal before, req.to_h
  end

  def test_responses_supports_all_image_sources_without_turning_bytes_into_text
    data = Base64.strict_encode64('original image bytes')
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'image.png')
      File.binwrite(path, 'original image bytes')
      inputs = [
        [LM15.image(data: data), 'image_url', "data:image/png;base64,#{data}"],
        [LM15.image(path: path), 'image_url', "data:image/png;base64,#{data}"],
        [LM15.image(file_id: 'file-image', detail: 'high'), 'file_id', 'file-image']
      ]
      lm = LM15::OpenAILM.new(api_key: 'test')
      inputs.each do |part, key, value|
        block = JSON.parse(lm.build_request(history(part)).body)['input'].first['content'].first
        assert_equal 'input_image', block['type']
        assert_equal value, block[key]
        assert_equal part.detail, block['detail'] if part.detail
      end
    end
  end

  def test_responses_preserves_files_and_tool_association
    lm = LM15::OpenAILM.new(api_key: 'test')
    doc = LM15::DocumentPart.new(file_id: 'file-document')
    binary = LM15::BinaryPart.new(url: 'https://example.invalid/data.bin')
    call = LM15::ToolCallPart.new(id: 'call-original', name: 'inspect', input: {'page' => 2})
    items = JSON.parse(lm.build_request(history(doc, binary, call)).body)['input']
    assert_equal [
      {'type' => 'input_file', 'file_id' => 'file-document'},
      {'type' => 'input_file', 'file_url' => 'https://example.invalid/data.bin'}
    ], items.first['content']
    assert_equal 'function_call', items[1]['type']
    assert_equal 'call-original', items[1]['call_id']
    assert_equal({'page' => 2}, JSON.parse(items[1]['arguments']))
  end

  def test_responses_refuses_unsupported_assistant_audio_video_and_mixed_refusal
    lm = LM15::OpenAILM.new(api_key: -> { flunk 'must refuse before credentials' })
    [LM15::AudioPart.new(url: 'https://example.invalid/audio.wav'), LM15::VideoPart.new(url: 'https://example.invalid/video.mp4')].each do |part|
      error = assert_raises(LM15::UnsupportedFeatureError) { lm.build_request(history(part)) }
      assert_includes error.message, part.type
    end
    assert_raises(LM15::UnsupportedFeatureError) do
      lm.build_request(history(LM15::RefusalPart.new(text: 'No'), LM15.image(file_id: 'file-image')))
    end
  end

  def test_text_only_responses_history_keeps_existing_encoding
    lm = LM15::OpenAILM.new(api_key: 'test')
    message = JSON.parse(lm.build_request(history(LM15::TextPart.new(text: 'earlier answer'))).body)['input'].first
    assert_equal [{'type' => 'output_text', 'text' => 'earlier answer'}], message['content']
  end

  def test_citation_replay_preserves_title_url_and_text_in_every_dialect
    citation = LM15::CitationPart.new(title: 'Source title', url: 'https://example.invalid/citation', text: 'Quoted evidence')
    [LM15::OpenAILM, LM15::OpenAIChatLM, LM15::AnthropicLM, LM15::GeminiLM].each do |klass|
      body = klass.new(api_key: 'test').build_request(history(citation)).body
      [citation.title, citation.url, citation.text].each { |value| assert_includes body, value, klass.name }
    end
  end

  def test_supported_anthropic_and_gemini_history_still_carries_media
    [LM15::AnthropicLM, LM15::GeminiLM].each do |klass|
      req = history(LM15.image(url: 'https://example.invalid/kept-image'), LM15::DocumentPart.new(url: 'https://example.invalid/kept-document'))
      body = klass.new(api_key: 'test').build_request(req).body
      assert_includes body, 'https://example.invalid/kept-image'
      assert_includes body, 'https://example.invalid/kept-document'
    end
  end
end
