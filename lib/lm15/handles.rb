# frozen_string_literal: true
module LM15
  class JobHandle
    attr_reader :info
    def initialize(lm,info)
      @lm,@info = lm,info
    end
    def id = info.id
    def status = info.status
    def done = info.done
    alias done? done
    def wait(poll_every:2,timeout:nil)
      raise ValueError,'poll_every must be positive and finite' unless poll_every.is_a?(Numeric) && poll_every.finite? && poll_every > 0
      raise ValueError,'timeout must be nonnegative and finite' unless timeout.nil? || timeout.is_a?(Numeric) && timeout.finite? && timeout >= 0
      deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until done
        remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise ::Timeout::Error,'job wait timed out' if remaining && remaining <= 0
        sleep(remaining ? [poll_every,remaining].min : poll_every)
        raise ::Timeout::Error,'job wait timed out' if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        refresh
      end
      self
    end
  end
  class BatchJob < JobHandle
    def refresh = (@info = @lm.batch_status(id); self)
    def results = @lm.batch_results(id)
    def cancel = (@info = @lm.batch_cancel(id); self)
  end
  class VideoJob < JobHandle
    def refresh = (@info = @lm.video_status(id); self)
    def result = @lm.video_result(id)
  end
  class ProviderLM
    alias image_generate generate_image
    alias speech_generate generate_speech
    alias video_submit submit_video
    alias video_list list_videos
    def batch(requests,label:nil,extensions:nil)
      req = requests.is_a?(BatchRequest) ? requests : BatchRequest.new(requests:requests,label:label,extensions:extensions)
      BatchJob.new(self,batch_submit(req))
    end
    def batch_job(id) = BatchJob.new(self,batch_status(id))
    def batches(limit:20) = batch_list(limit:limit).map { |info| BatchJob.new(self,info) }
    def video_generate(request) = VideoJob.new(self,video_submit(request))
    def video_job(id) = VideoJob.new(self,video_status(id))
    def video_jobs(limit:20,model:nil) = video_list(limit:limit,model:model).map { |info| VideoJob.new(self,info) }
  end
  class CachedPrefix
    def id = resource&.id
    def expires_at = resource&.expires_at
    def cache_config = CacheConfig.new(prefix_until_index:prefix.messages.size - 1,resource:id)
    def request(messages,config:nil)
      if messages.is_a?(Request)
        raise ValueError,'suffix must use the prefix model and cannot redefine system or tools' unless messages.model == prefix.model && messages.system.nil? && messages.tools.empty?
        config ||= messages.config; suffix = messages.messages
      elsif messages.is_a?(String) then suffix = [Message.user(messages)]
      elsif messages.is_a?(Message) then suffix = [messages]
      else suffix = Array(messages) end
      raise TypeError,'suffix must contain messages' if suffix.empty? || !suffix.all? { |m| m.is_a?(Message) }
      config ||= Config.new; raise ValueError,'CachedPrefix decides config.cache' if config.cache
      prefix.with(messages:prefix.messages + suffix,config:config.with(cache:cache_config))
    end
    def +(messages) = request(messages)
  end
  def self.openai_chat_model_string(model)
    raise UnknownModelError.new('model must be a string',model:model.to_s) unless model.is_a?(String)
    return model if model.include?(':')
    head,rest = model.split('/',2); return model unless rest && !rest.empty?
    provider = TABLES['litellm_prefixes'][head]
    raise UnknownModelError.new("unknown migration provider #{head.inspect}; use provider:model",model:model) unless provider
    "#{provider}:#{rest}"
  end
  class LMRouter
    def resolve_openai_chat(model)
      res = resolve(LM15.openai_chat_model_string(model))
      res.source == 'rule' && res.provider == 'openai' ? resolve("openai-chat:#{res.model}") : res
    end
    def request_from_openai_chat(model,messages,**kwargs)
      client_keys = %i[api_key api_base base_url timeout num_retries max_retries headers extra_headers cache caching drop_params api_version organization client]
      bad = kwargs.keys & client_keys; raise NotConfiguredError,"#{bad.first} configures the client; use RouterConfig" unless bad.empty?
      res = resolve_openai_chat(model); adapter = lm("#{res.provider}:#{res.model}")
      body = {'model'=>res.model,'messages'=>messages}.merge(kwargs.transform_keys(&:to_s))
      req = adapter.dialect == 'openai-chat' ? adapter.request_from_openai_chat(body) : LM15.request_from_openai_chat(body)
      [req,adapter]
    end
    def complete_from_openai_chat(model,messages,stream:false,**kwargs)
      raise TypeError,'stream must be boolean' unless stream == true || stream == false
      req,adapter = request_from_openai_chat(model,messages,**kwargs)
      stream ? adapter.response_stream(req) : adapter.complete(req)
    end
    def stream_from_openai_chat(model,messages,**kwargs)
      req,adapter = request_from_openai_chat(model,messages,**kwargs); adapter.stream(req)
    end
    %i[image_generate speech_generate video_generate cache].each do |method|
      define_method(method) do |request,**kwargs|
        res = resolve(request.model); lm(request.model).public_send(method,request.with(model:res.model),**kwargs)
      end
    end
    def live(config,**kwargs,&block)
      res = resolve(config.model); lm(config.model).live(config.with(model:res.model),**kwargs,&block)
    end
    def batch(requests,**kwargs)
      req = requests.is_a?(BatchRequest) ? requests : BatchRequest.new(requests:requests,**kwargs)
      res = resolve(req.model || req.requests.first.model)
      routed = req.requests.map do |r|
        entry = resolve(r.model); raise ValueError,'one batch cannot span providers' unless entry.provider == res.provider
        r.with(model:entry.model)
      end
      lm("#{res.provider}:#{res.model}").batch(req.with(model:res.model,requests:routed))
    end
  end
end
