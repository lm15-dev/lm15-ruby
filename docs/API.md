# Ruby API mapping

Canonical JSON uses the same snake_case keys and omission rules as the contract. All names live under `LM15`.

| Concept | Ruby |
|---|---|
| Router | `LMRouter.new(config)` or `LMRouter.new(api_keys: ..., settings: ...)` |
| Resolve without IO | `router.resolve(model)`, `router.resolve_openai_chat(model)` |
| Provider | `OpenAILM.new`, `OpenAIChatLM.new`, `AnthropicLM.new`, `GeminiLM.new`, `XaiLM.new`, `ClaudeCodeLM.new`, `OpenAICodexLM.new`; `LM15.adapter_for(provider)` for any binding |
| Complete | `lm.complete(request)`, `router.complete(request)`, `LM15.complete(request)` |
| Raw stream | `lm.stream(request)` → closeable `Enumerable<StreamEvent>` |
| Assembled stream | `lm.response_stream(request)` → `ResponseStream`; `.each` text, `.events` events, `.response` result, `.close` cleanup, `.cleanup_errors` diagnostics |
| SSE decoding | `LM15.parse_sse(lines)` for lines; `LM15.parse_sse_chunks(chunks)` for raw byte chunks |
| Request | `Request.new(model:, messages:, system: nil, tools: [], config: Config.new)` |
| Message | `Message.user`, `.developer`, `.assistant`, `.tool(id, content)` |
| Response | `.message`, `.text`, `.tool_calls`, `.citations`, `.usage`, `.finish_reason`, `.json`, `.parse_json(default:)` |
| Parts | `TextPart`, `ThinkingPart`, `RefusalPart`, `CitationPart`, `ToolCallPart`, `ToolResultPart`, `ImagePart`, `AudioPart`, `VideoPart`, `DocumentPart`, `BinaryPart` |
| Part factories | `LM15.text`, `.thinking`, `.refusal`, `.citation`, `.tool_call`, `.tool_result`, `.image`, `.audio`, `.video`, `.document`, `.binary` |
| Tool schema | `LM15.tool(name, description:, parameters:)`; `BuiltinTool.new(name:, config:)` |
| Configuration | `Config`, `Reasoning`, `ToolChoice`, `CacheConfig`; constructors use keyword arguments |
| Continuation | `ContinuationState`, `ContinuationDelta#to_state`, `LM15.continuation_data` |
| Serialization | `value.to_h`, `value.to_json`, `LM15.to_dict(value)`, `LM15.to_json(value)` |
| Deserialization | `Request.from_dict(hash)`, `Request.from_json(json)`, `LM15.from_dict('request', hash)` |
| Immutable update | `value.with(field: replacement)` |
| Model catalog | `ModelRegistry.new(models)`, `.add`, `.get`, `.list`, `.each`; `lm.list_models` |
| Request ingestion | `LM15.request_from_openai_chat(body, compat:)`, `lm.request_from_openai_chat(body)` on Chat adapters |
| Response ingestion | `LM15.response_from_openai_chat(body, model:, choice:)`, corresponding adapter method |
| Migration call | `router.complete_from_openai_chat(model, messages, **options)`; `stream: true` returns `ResponseStream` |
| Files | `file_upload`, `file_get`, `file_list(limit:, cursor:)`, `file_delete`, `file_download` |
| Caches | `cache_create`, `cache_get`, `cache_list`, `cache_update`, `cache_delete`; `cache(prefix)` → `CachedPrefix` |
| Prefix composition | `cached.request(suffix, config:)` or `cached + suffix` |
| Batch pure operations | `batch_submit`, `batch_status`, `batch_cancel`, `batch_list`, `batch_results` |
| Batch handle | `batch(requests)` → `BatchJob`; `batch_job(id)`, `batches(limit:)` |
| Image and speech | `image_generate(ImageGenerationRequest)`, `speech_generate(SpeechGenerationRequest)` |
| Video pure operations | `video_submit`, `video_status`, `video_list`, `video_result` |
| Video handle | `video_generate(VideoGenerationRequest)` → `VideoJob`; `video_job(id)`, `video_jobs(limit:, model:)` |
| Job state | `.info`, `.id`, `.status`, `.done?`, `.refresh`, `.wait(poll_every:, timeout:)`; `.results` or `.result` |
| Realtime | `lm.live(LiveConfig.new(...))`, optionally with a block |
| Live IO | `session.send(event)`, `.send_text`, `.send_turn`, `.send_audio`, `.send_image`, `.send_tool_result`, `.interrupt`, `.end_audio`, `.recv`, `.each`, `.close` |
| Live turn | `session.turn` → `TurnView`; `.each`, `.result`, `.snapshot`, `.close` |
| Turn result | `.ended_by`, `.ok?`, `.text`, `.audio`, `.audio_media_type`, `.tool_calls`, `.usage`, `.error`, `.events` |
| Credentials | `ApiKey.new(value:)`, `BearerToken.new(value:, expires_at:)`, `AwsCredentials.new(access_key_id:, secret_access_key:, session_token:, expires_at:)` |
| Auth diagnosis and login | `LM15.explain_auth`, `LM15.login`, `LM15.generate_pkce` |
| Errors | `LM15Error` subclasses; `.code`, `.provider`, `.provider_code`, `.status`, `.request_id`, `.retry_after`, `.retryable?` |

## Transport injection

A transport responds to `call(TransportRequest)`, returning `HttpResponse`. For streaming it accepts a block and calls it with `(HttpResponse, body_source)`, where `body_source.read_body { |chunk| ... }` yields byte strings. The transport owns connection cleanup and must release it in `ensure`.

`TransportRequest` exposes `method`, `url`, lowercase `headers`, binary `body`, and connection/read/write timeouts. `HttpResponse.new(status:, headers:, body:)` lowercases response header names. Build/parse hooks are public for custom transports and contract testing; calls involving credential discovery can perform auth IO before a provider request exists.

A realtime connector can be supplied as `lm.live(config, connect: callable)`. It receives `(url, headers:)` and returns a socket supporting `send(text)`, `recv` (text/bytes or nil at close), and `close`.

## Stream lifecycle and SSE

`ResponseStream` closes its source after normal exhaustion or failed consumption,
including consumer exceptions and interruption. Breaking iteration alone keeps
it resumable; explicitly `close` to abandon it. Consume and close on the same
thread. A wrong-thread close raises `ThreadError` without marking the original
stream closed. Cleanup errors never replace an existing error or a completed
answer; they are recorded in `cleanup_errors` and reported through Ruby's warning
channel. Warnings name the error class, not its potentially sensitive message.

Both SSE entry points return an enumerator of `SSEEvent(data:, event:)` values.
`parse_sse` still accepts lines with or without their separators.
`parse_sse_chunks` accepts arbitrary byte strings whose boundaries have no
meaning. Both support LF, CRLF, CR, an initial UTF-8 BOM and split UTF-8 data.
Each data/event field removes at most one leading space, as SSE requires.

Both accept `max_line_bytes:` (default 65,536, excluding separators) and
`max_event_bytes:` (default 1,048,576, including one normalized separator per
line). Comments and ignored fields count toward the event limit too. A final
record without a trailing blank line is flushed for compatibility with the
existing API; this does not excuse a missing canonical stream end event.

## Canonical declarations

`lib/lm15/data/schema.json` declares all 75 canonical struct types. `Value` builds the named Ruby classes from those declarations and validates actual instances. `LM15::SCHEMA` and `LM15::VOCABULARIES` expose the metadata; the contract shim reports the classes' actual fields. `KINDS` covers all 36 serialization entry kinds. Additional helpers such as `Turn`, `BatchJob`, and `LiveSession` are runtime objects, not new canonical wire types.

Credentials are intentionally serialized by explicit canonical serialization calls; their `inspect` is redacted. `Response#to_h` omits `provider_data` by default; use `include_provider_data: true` to include it. Batch entry responses preserve it under the contract's nested-response rule. Usage fields remain `nil` when the provider did not report them.
