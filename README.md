# lm15 for Ruby (early port)

lm15 is one request and response model for every major AI model provider:
write a request once and send it to OpenAI, Anthropic, Gemini, xAI, Groq,
DeepSeek, OpenRouter, a cloud or a local model, by changing the model
string. Each language implements it separately and is graded by one shared
[contract](https://github.com/lm15-dev/lm15-contract).

**Early port, not published** (not on RubyGems). Written against the lm15
contract of 2026-09-11 (`cfed007`, in `CONTRACT_PIN`), where it passed
every check: 1,380 of 1,380 in 16 directions. It has not been updated
since, and the contract has grown (sign-in, judgments, ordered JSON
checks, new providers).

lm15 is released in [Python](https://github.com/lm15-dev/lm15-python) (1.0.1, stable),
[TypeScript](https://github.com/lm15-dev/lm15-ts), [Rust](https://github.com/lm15-dev/lm15-rs)
and [Go](https://github.com/lm15-dev/lm15-go) (release candidates). Guides:
[lm15.dev](https://lm15.dev/docs/). For production, use one of those.

## What's here

Ruby 3.2 or newer, standard-library gems only (`json`, `net-http`,
`openssl`, ...): the router, the four provider dialects, streaming, tools,
errors, credentials and cloud credential chains, files, batches, caches,
media generation, video and realtime sessions.

## Try it

```sh
bundle install
bundle exec rake test
gem build lm15.gemspec && gem install ./lm15-0.1.0.gem
```

```ruby
require 'lm15'

router = LM15::LMRouter.new   # keys from the environment
response = router.complete(LM15::Request.new(
  model: 'anthropic:claude-haiku-4-5',
  messages: [LM15::Message.user('What eats acorns at night?')]
))
puts response.text
```

## Conformance

See [CONFORMANCE.md](CONFORMANCE.md) for the harness commands.

The full guide written with this port, with every API and its stated
differences from the Python reference: [docs/guide.md](docs/guide.md).

## License

See [LICENSE](LICENSE).
