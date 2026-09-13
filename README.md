# LM15 Ruby

A native Ruby implementation of LM15: one `Request`, one `Response`, and the same canonical types across model providers. This directory is a complete gem project. It can be copied to a new `lm15-ruby` repository without depending on its parent directory.

The implementation follows the pinned [LM15 contract](https://github.com/lm15-dev/lm15-contract), with the [Python](https://github.com/lm15-dev/lm15-python) and [TypeScript](https://github.com/lm15-dev/lm15-ts) SDKs as implementation references. No Python or TypeScript code runs in the Ruby SDK. Python is used only by development tools to run the shared harness and compare independent requests.

## Install

Ruby **3.2 or newer** is required. This port has not been published to RubyGems. From this directory:

```sh
bundle install
bundle exec rake test
gem build lm15.gemspec
gem install ./lm15-0.1.0.gem
```

For local development in another application's Gemfile:

```ruby
gem 'lm15', path: '/absolute/path/to/lm15-ruby'
```

Dependencies are Ruby standard-library gems: `json`, `base64`, `net-http`, `openssl`, and `rexml`. HTTP, SSE, WebSocket framing, credential resolution, JWT signing, and SigV4 signing are implemented in Ruby. There are no vendor SDK dependencies.

## Quick start

Set the provider's credential environment variable, such as `OPENAI_API_KEY`, then:

```ruby
require 'lm15'

router = LM15::LMRouter.new
request = LM15::Request.new(
  model: 'openai:gpt-4.1',
  messages: [LM15::Message.user('Explain how a rainbow forms.')],
  config: LM15::Config.new(temperature: 0.2, max_tokens: 300)
)
response = router.complete(request)
puts response.text
puts response.usage.input_tokens
```

Explicit prefixes select a provider. Bare model names use the shared routing rules. `router.resolve(model)` describes the decision without contacting a provider or invoking a credential callback.

```ruby
router = LM15::LMRouter.new(
  api_keys: { 'openai' => -> { ENV.fetch('OPENAI_API_KEY') } },
  base_urls: {},
  settings: {}
)
puts router.resolve('groq:llama-3.3-70b-versatile').describe
```

Direct clients use the same `complete`, `stream`, and `response_stream` methods:

```ruby
lm = LM15::AnthropicLM.new(api_key: ENV.fetch('ANTHROPIC_API_KEY'))
lm = LM15::OpenAIChatLM.new(compat: 'lmstudio', api_key: 'local')
# lmstudio selects http://localhost:1234/v1; explicit base_url takes precedence.
```

See [providers](docs/providers.md) for every registered route, credential variable, and supported endpoint family.

## Streaming and tool calls

`stream` yields canonical events. `response_stream` yields text and assembles the complete response. Close a stream when abandoning it; block form closes it automatically. A partial or prematurely closed stream cannot become a successful completed response.

```ruby
lm = LM15::OpenAILM.new
lm.response_stream(request) do |stream|
  stream.each { |text| print text }
  puts stream.response.finish_reason
end

# Raw events, with explicit cleanup:
events = router.stream(request)
begin
  events.each { |event| p event.type }
ensure
  events.close
end
```

Tools use explicit JSON schemas. Execution remains in your application:

```ruby
weather = LM15.tool(
  'weather',
  description: 'Look up the weather in a city',
  parameters: {
    'type' => 'object',
    'properties' => { 'city' => { 'type' => 'string' } },
    'required' => ['city']
  }
)
req = request.with(tools: [weather])
answer = router.complete(req)
if (call = answer.tool_calls.first)
  # Your application executes the tool using call.name and call.input.
  result = 'Sunny, 18 C'
  followup = req.with(messages: req.messages + [answer.message, LM15::Message.tool(call.id, result)])
  puts router.complete(followup).text
end
```

## Canonical values and migration

Values are validated on construction and frozen. Arrays of typed values are copied and frozen. Opaque JSON objects are validated but remain caller-owned; avoid mutating them after construction. `.with(...)` creates an updated value. JSON object keys are strings.

```ruby
copy = LM15::Request.from_json(LM15.to_json(request))
copy = LM15.from_dict('request', request.to_h)
image = LM15.image(data: Base64.strict_encode64(File.binread('picture.png')))
# Each media part has exactly one of data (base64), path, url, or file_id.
```

The migration entry point reads an existing OpenAI SDK or LiteLLM call:

```ruby
response = router.complete_from_openai_chat(
  'openai/gpt-4.1',
  [{ 'role' => 'user', 'content' => 'Hello' }],
  temperature: 0.2
)
puts response.text

canonical = LM15.request_from_openai_chat({
  'model' => 'gpt-4.1',
  'messages' => [{ 'role' => 'user', 'content' => 'Hello' }]
})
```

Fields either map to canonical values, pass through `Config.extensions`, or raise with the field named. Client configuration belongs in `RouterConfig`. `stream: true` on `complete_from_openai_chat` returns a lazy `ResponseStream`.

## Files, caches, jobs, and media

These methods are available where the provider's access policy supports them. Unsupported combinations raise `UnsupportedFeatureError`.

```ruby
models = lm.list_models
file = lm.file_upload(LM15::FileUploadRequest.new(
  filename: 'notes.txt', media_type: 'text/plain', bytes_data: "Research notes\n"
))
bytes = lm.file_download(file.id)
lm.file_delete(file.id)

# The prefix's config must be default; generation config belongs to the suffix.
prefix = LM15::Request.new(model: request.model, messages: [LM15::Message.user('Reusable context')])
cached = lm.cache(prefix)
answer = lm.complete(cached.request('A question about that context', config: LM15::Config.new(max_tokens: 100)))

batch = lm.batch([request, request])
batch.wait(poll_every: 5, timeout: 600)
entries = batch.results
# Reattach with lm.batch_job(id); list with lm.batches; cancel with batch.cancel.

picture = lm.image_generate(LM15::ImageGenerationRequest.new(model: 'gpt-image-1', prompt: 'A paper crane'))
speech = lm.speech_generate(LM15::SpeechGenerationRequest.new(model: 'gpt-4o-mini-tts', prompt: 'Hello', voice: 'alloy'))
video = lm.video_generate(LM15::VideoGenerationRequest.new(model: 'sora-2', prompt: 'A kite over a field'))
video.wait(poll_every: 5, timeout: 600)
part = video.result
```

A handle's properties never perform network IO. `refresh` fetches status, and `wait` is the method that polls. Video results retain the provider's delivery mode: a URL or inline bytes. Cache and file listing return canonical page values with cursors.

## Realtime

OpenAI and Gemini live sessions share canonical events and turn collectors. Use a block to guarantee socket closure:

```ruby
LM15::OpenAILM.new.live(LM15::LiveConfig.new(model: 'gpt-realtime')) do |session|
  session.send_text('Hello')
  turn = session.turn.result
  puts turn.text
  puts turn.ended_by
end
```

`send_audio` and `send_image` accept byte strings; pass `base64: true` for already encoded data. `send_turn`, `send_tool_result`, `interrupt`, and `end_audio` are also available. `session.each` exposes the full event stream. A turn result stops at a tool call so your application can answer it. Usage sums preserve unknown counters.

## Authentication and errors

Credential inputs are a string, `ApiKey`, `BearerToken`, `AwsCredentials`, or a zero-argument callable returning one of them. Credential callbacks are invoked when building a wire request. Router configuration selects accounts explicitly; ambiguous or empty entries fail.

- API key discovery follows each provider's ordered environment variables.
- Claude Code and Codex use their existing CLI login files, including locked refresh and atomic persistence.
- xAI supports a stored OAuth login, explicit API keys, and `LM15.login('xai')` device authorization.
- Bedrock, Azure, and Vertex use native credential chains. See [authentication](docs/authentication.md) for supported sources and limits.
- `LM15.explain_auth(provider)` reports credential sources without network calls or secret values. It also accepts a `Resolution` and `config: router.config`.

```ruby
begin
  response = router.complete(request)
rescue LM15::RateLimitError => error
  warn "Retry after: #{error.retry_after.inspect}; request: #{error.request_id}"
rescue LM15::LM15Error => error
  warn "#{error.code}: #{error.message}"
end
```

The SDK does not retry inference requests automatically. Decide retry policy in the application. HTTP and WebSocket transports verify TLS certificates.

## Development and conformance

```sh
bundle exec rake test
# Use a separate clean checkout at the exact CONTRACT_PIN revision:
git clone https://github.com/lm15-dev/lm15-contract.git /tmp/lm15-contract-oracle
git -C /tmp/lm15-contract-oracle checkout "$(cat CONTRACT_PIN)"
python tools/check_contract.py --contract /tmp/lm15-contract-oracle --direction all
# Optional, against a local Python reference checkout:
python tools/differential.py --python-repo /path/to/lm15-python
```

The checked-in schema, provider manifests, and compatibility tables are declarations exported from the reference SDK, not fixture answers. `tools/export_reference_data.py` regenerates them. The NDJSON shim delegates to the same public implementation as application code. See [CONFORMANCE.md](CONFORMANCE.md) for the exact validation record and [API.md](docs/API.md) for the Ruby API mapping.

## Stated deviations and limits

- Ruby uses synchronous methods, `Enumerable`, and pull-based fibers. There is no separate `Async*` API or event-loop integration guarantee. Consume and close a stream on its owning thread.
- Tools take explicit schemas; Ruby parameter names do not provide enough type information to derive a JSON schema.
- Compatibility policies and access manifests are Ruby hashes, not extra canonical classes. Pass `compat: 'preset'` or a hash of policy fields. The Responses request-level compat hatch is supported. Deprecated Python profiles and deprecated base-URL-based compat guessing are omitted.
- Media constructor `data:` means base64 text; use `.bytes` for local content. MIME types default by part kind; specify `media_type:` when a path's format differs. Live send helpers encode bytes by default.
- Realtime models use `.live(LiveConfig)`. This port does not redirect `.complete(Request)` to a realtime socket automatically.
- WebSocket compression, proxy tunneling, automatic reconnect, and background receive workers are not implemented. Plain `ws` and TLS `wss`, authenticated setup, control frames, and fragmentation are implemented.
- Bedrock's AWS event-stream response framing is outside this pinned contract's completed phase. Its request signing works; the host adapter refuses unsupported streaming.
- No live provider request, paid generation, or interactive login was performed for this port. The offline contract suite, injected transports, loopback socket tests, and gem installation tests are the validation evidence.

MIT licensed; see [LICENSE](LICENSE).
