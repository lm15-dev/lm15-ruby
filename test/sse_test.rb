# frozen_string_literal: true
require_relative 'test_helper'

class SSETest < Minitest::Test
  def test_all_line_endings_and_every_two_chunk_boundary
    ["\n", "\r\n", "\r"].each do |separator|
      wire = "\uFEFF: heartbeat#{separator}event: message#{separator}data: café#{separator}data: 🌱#{separator}#{separator}".b
      (0..wire.bytesize).each do |split|
        chunks = [wire.byteslice(0, split), wire.byteslice(split..)]
        events = LM15.parse_sse_chunks(chunks).to_a
        assert_equal [["café\n🌱", 'message']], events.map { |e| [e.data, e.event] }, "separator=#{separator.inspect}, split=#{split}"
      end
    end
  end

  def test_many_records_in_one_chunk_and_delimiters_split_into_single_bytes
    wire = "data: one\r\ndata: two\r\n\r\nevent: custom\rdata: three\r\rdata: four\n\n".b
    expected = [["one\ntwo", nil], ['three', 'custom'], ['four', nil]]
    [ [wire], wire.bytes.map { |b| b.chr.b } ].each do |chunks|
      assert_equal expected, LM15.parse_sse_chunks(chunks).map { |e| [e.data, e.event] }
    end
  end

  def test_fields_keep_whitespace_and_empty_data_is_an_event
    wire = "event:  padded \ndata:  content \n\ndata\n\n: ignored\nretry: 100\nid: 7\n\n"
    events = LM15.parse_sse_chunks([wire]).to_a
    assert_equal [[' content ', ' padded '], ['', nil]], events.map { |e| [e.data, e.event] }
  end

  def test_existing_line_api_and_unterminated_final_record_still_work
    events = LM15.parse_sse(['event: last', 'data: one', '', 'data: two']).to_a
    assert_equal [['one', 'last'], ['two', nil]], events.map { |e| [e.data, e.event] }
    assert_equal ['last'], LM15.parse_sse_chunks(['data: last']).map(&:data)
  end

  def test_limits_work_across_chunks_and_before_newline_arrives
    assert_raises(LM15::TransportError) do
      LM15.parse_sse_chunks(['12345', '67890', 'x'], max_line_bytes: 10).to_a
    end
    assert_raises(LM15::TransportError) do
      LM15.parse_sse_chunks(["data: 1234\n", "data: 5678\n\n"], max_event_bytes: 15).to_a
    end
    assert_raises(LM15::TransportError) do
      LM15.parse_sse_chunks([": ignored\n" * 20], max_event_bytes: 30).to_a
    end
    ["\n", "\r", "\r\n"].each do |ending|
      assert_equal ['x'], LM15.parse_sse_chunks(["data: x#{ending}#{ending}"], max_line_bytes: 7).map(&:data)
    end
  end

  def test_public_stream_and_replay_share_byte_framing
    ["\n", "\r\n", "\r"].each do |ending|
      body = [
        "\uFEFFdata: #{JSON.generate('choices' => [{'delta' => {'content' => 'café 🌱'}}])}", '',
        "data: #{JSON.generate('choices' => [{'delta' => {}, 'finish_reason' => 'stop'}])}", '',
        'data: [DONE]', '', ''
      ].join(ending)
      transport = FakeTransport.new(LM15::HttpResponse.new(body: body))
      lm = LM15::OpenAIChatLM.new(api_key: 'test', transport: transport)
      assert_equal 'café 🌱', lm.response_stream(request).response.text
      assert_equal 'café 🌱', LM15.materialize_response(lm.replay_stream(request, body), request).text
    end
  end
end
