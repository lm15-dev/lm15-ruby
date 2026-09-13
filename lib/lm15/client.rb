# frozen_string_literal: true
module LM15
  class ProviderLM
    def send_request(wire)
      response = transport.call(wire)
      raise normalize_error(response.status,response.body,headers:response.headers) if response.status >= 400
      response
    end
    def complete(request)
      request = Request.from_dict(request) if request.is_a?(Hash)
      return LM15.materialize_response(stream(request),request) if provider == 'openai-codex'
      parse_response(request,send_request(build_request(request,false)))
    end
    def stream(request)
      request = Request.from_dict(request) if request.is_a?(Hash)
      raw = Enumerator.new do |out|
        wire = build_request(request,true)
        transport.call(wire) do |response,source|
          if response.status >= 400
            body = ''.b; source.read_body { |chunk| body << chunk }
            raise normalize_error(response.status,body,headers:response.headers)
          end
          chunks = Enumerator.new do |chunk_out|
            source.read_body { |chunk| chunk_out << chunk }
          end
          LM15.parse_sse_chunks(chunks).each { |event| parse_stream_events(request,event).each { |e| out << e } }
        end
      end
      PullStream.new(LM15.coalesce_stream(raw,model:request.model))
    end
    def response_stream(request)
      result = ResponseStream.new(stream(request),request)
      return result unless block_given?
      begin yield result; ensure result.close end
    end
  end
  class << self
    def default_router = (@default_router ||= LMRouter.new)
    def complete(request) = default_router.complete(request)
    def stream(request) = default_router.stream(request)
    def response_stream(request) = default_router.response_stream(request)
  end
end
