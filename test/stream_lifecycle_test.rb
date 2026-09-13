# frozen_string_literal: true
require_relative 'test_helper'

class StreamLifecycleTest < Minitest::Test
  class Source
    include Enumerable
    attr_reader :closes

    def initialize(events, tail_error: nil, close_error: nil)
      @events = events.each
      @tail_error = tail_error
      @close_error = close_error
      @closes = 0
    end

    def next
      @events.next
    rescue StopIteration
      raise @tail_error if @tail_error
      raise
    end

    def each
      return enum_for(:each) unless block_given?
      loop { yield self.next }
    end

    def close
      @closes += 1
      raise @close_error if @close_error
    end
  end

  def end_event
    LM15::StreamEndEvent.new(finish_reason: 'stop')
  end

  def error_event
    LM15::StreamErrorEvent.new(error: LM15::ErrorDetail.new(code: 'server', message: 'original failure'))
  end

  def test_provider_error_closes_suspended_http_source_without_reading_more
    closed = false
    transport = Object.new
    transport.define_singleton_method(:call) do |_request, &block|
      reader = Object.new
      reader.define_singleton_method(:read_body) do |&consume|
        consume.call("data: {\"error\":{\"code\":\"server_error\",\"message\":\"original failure\"}}\n\n")
        raise 'must not read beyond the error'
      end
      begin
        block.call(LM15::HttpResponse.new, reader)
      ensure
        closed = true
      end
    end
    lm = LM15::OpenAIChatLM.new(api_key: 'test', transport: transport)
    assert_raises(LM15::ServerError) { lm.response_stream(request).response }
    assert closed, 'error must release the HTTP response immediately'
  end

  def test_original_error_survives_cleanup_failure_and_repeated_reads
    cleanup = IOError.new('secret-cleanup-material')
    source = Source.new([error_event], close_error: cleanup)
    stream = LM15::ResponseStream.new(source, request)
    failure = nil
    _, warning = capture_io { failure = assert_raises(LM15::ServerError) { stream.response } }
    assert_includes warning, 'StreamCleanupWarning'
    refute_includes warning, 'secret-cleanup-material'
    assert_same failure, assert_raises(LM15::ServerError) { stream.response }
    stream.close
    assert_equal 1, source.closes
    assert_equal [cleanup], stream.cleanup_errors
  end

  def test_missing_end_and_assembly_failure_both_close_source
    unnamed = LM15::StreamDeltaEvent.new(delta: LM15::ToolCallDelta.new(input: '{}', part_index: 0))
    [[], [unnamed, end_event]].each do |events|
      source = Source.new(events)
      stream = LM15::ResponseStream.new(source, request)
      assert_raises(LM15::StreamAssemblyError) { stream.response }
      assert_equal 1, source.closes
    end
  end

  def test_event_after_end_closes_source_and_fails
    source = Source.new([end_event, error_event])
    assert_raises(LM15::StreamAssemblyError) { LM15.materialize_response(source, request) }
    assert_equal 1, source.closes
  end

  def test_completed_response_survives_tail_and_close_failures
    tail_error = IOError.new('tail failed')
    close_error = IOError.new('close failed')
    source = Source.new([end_event], tail_error: tail_error, close_error: close_error)
    stream = LM15::ResponseStream.new(source, request)
    _, warning = capture_io { assert_equal 'stop', stream.response.finish_reason }
    assert_equal 2, warning.scan('StreamCleanupWarning').size
    assert_equal [tail_error, close_error], stream.cleanup_errors
    assert_equal 1, source.closes
    stream.close
    assert_equal 1, source.closes
  end

  def test_broken_warning_channel_does_not_replace_a_completed_answer
    cleanup = IOError.new('cleanup failed')
    warning = IOError.new('warning destination failed')
    source = Source.new([end_event], close_error: cleanup)
    stream = LM15::ResponseStream.new(source, request)
    stream.define_singleton_method(:warn) { |*| raise warning }
    assert_equal 'stop', stream.response.finish_reason
    assert_equal [cleanup, warning], stream.cleanup_errors
    assert_equal 1, source.closes
  end

  def test_success_closes_the_original_enumerable_not_just_its_enumerator
    terminal = end_event
    closes = 0
    source = Object.new.extend(Enumerable)
    source.define_singleton_method(:each) { |&block| [terminal].each(&block) }
    source.define_singleton_method(:close) { closes += 1 }
    stream = LM15::ResponseStream.new(source, request)
    answer = stream.response
    assert_same answer, stream.response
    assert_equal 1, closes
  end

  def test_wrong_thread_close_does_not_poison_the_owning_thread
    closed = false
    terminal = end_event
    source = LM15::PullStream.new(Enumerator.new do |out|
      begin
        out << LM15::StreamStartEvent.new
        out << terminal
      ensure
        closed = true
      end
    end)
    stream = LM15::ResponseStream.new(source, request)
    stream.events { break }
    outcome = Thread.new do
      stream.close
    rescue ThreadError => error
      error
    end.value
    assert_instance_of ThreadError, outcome
    refute closed
    assert_equal 'stop', stream.response.finish_reason
    assert closed
  end

  def test_consumer_exception_and_interrupt_unwind_source
    [RuntimeError.new('consumer failed'), Interrupt.new('cancelled')].each do |failure|
      closed = false
      source = LM15::PullStream.new(Enumerator.new do |out|
        begin
          out << LM15::StreamStartEvent.new
          out << end_event
        ensure
          closed = true
        end
      end)
      stream = LM15::ResponseStream.new(source, request)
      assert_same failure, assert_raises(failure.class) { stream.events { raise failure } }
      assert closed
    end
  end

  def test_close_releases_source_even_if_partial_response_cannot_be_built
    bad_audio = LM15::StreamDeltaEvent.new(delta: LM15::AudioDelta.new(data: '!!!!', media_type: 'audio/wav'))
    source = Source.new([bad_audio])
    stream = LM15::ResponseStream.new(source, request)
    stream.events { break }
    failure = assert_raises(LM15::ValueError) { stream.close }
    assert_equal 1, source.closes
    assert_same failure, assert_raises(LM15::ValueError) { stream.response }
  end

  def test_closing_from_consumer_does_not_read_ahead
    source = Source.new([LM15::StreamStartEvent.new, end_event])
    stream = LM15::ResponseStream.new(source, request)
    seen = []
    stream.events do |event|
      seen << event.type
      stream.close
    end
    assert_equal ['start'], seen
    assert_equal 1, source.closes
    assert_raises(LM15::StreamAssemblyError) { stream.response }
  end
end
