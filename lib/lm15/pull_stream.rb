# frozen_string_literal: true
module LM15
  # Pull-based IO stays on the caller's thread. Fiber#raise unwinds network
  # ensures immediately when a consumer closes a suspended stream.
  class PullStream
    include Enumerable
    class Cancelled < Exception; end
    def initialize(source)
      @source = source; @fiber = nil; @closed = false; @owner = nil
    end
    def next
      raise StopIteration if @closed
      @owner ||= Thread.current
      raise ThreadError,'consume and close a stream on its owning thread' unless @owner == Thread.current
      @fiber ||= Fiber.new do
        begin @source.each { |value| Fiber.yield(value) }
        ensure @closed = true end
      end
      value = @fiber.resume; raise StopIteration if @closed; value
    end
    def each
      return self unless block_given?
      loop { yield self.next }; self
    end
    def to_enum(*) = self
    def close
      return if @closed
      raise ThreadError,'close a stream on its owning thread' if @owner && @owner != Thread.current
      begin @fiber.raise(Cancelled) if @fiber&.alive?; rescue Cancelled; ensure @closed = true end
      @source.close if @source.respond_to?(:close)
      nil
    end
  end
end
