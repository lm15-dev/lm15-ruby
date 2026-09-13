# Registered providers

The manifest is pinned to `CONTRACT_PIN`. Model names and provider product availability may evolve independently.

| Route prefix | Wire dialect | Credential variables | Endpoint families |
|---|---|---|---|
| `openai:` | openai-responses | `OPENAI_API_KEY` | complete, stream, live, models, files, batches, images, speech, video |
| `openai-chat:` | openai-chat | `OPENAI_API_KEY` | complete, stream, models |
| `anthropic:` | anthropic | `ANTHROPIC_API_KEY` | complete, stream, models, files, batches |
| `gemini:` | gemini | `GEMINI_API_KEY`, `GOOGLE_API_KEY` | complete, stream, live, models, files, caches, batches, images, speech, video |
| `xai:` | openai-chat | `XAI_API_KEY` | complete, stream, models, images, video |
| `claude-code:` | anthropic | oauth | complete, stream, models |
| `openai-codex:` | openai-responses | oauth | complete, stream, models |
| `groq:` | openai-chat | `GROQ_API_KEY` | complete, stream, models |
| `openrouter:` | openai-chat | `OPENROUTER_API_KEY` | complete, stream, models |
| `deepseek:` | openai-chat | `DEEPSEEK_API_KEY` | complete, stream, models |
| `deepseek-anthropic:` | anthropic | `DEEPSEEK_API_KEY` | complete, stream |
| `zai:` | openai-chat | `ZAI_API_KEY` | complete, stream, models |
| `moonshotai:` | openai-chat | `MOONSHOTAI_API_KEY`, `MOONSHOT_API_KEY` | complete, stream, models |
| `moonshotai-responses:` | openai-responses | `MOONSHOTAI_API_KEY`, `MOONSHOT_API_KEY` | complete, stream, models |
| `moonshotai-anthropic:` | anthropic | `MOONSHOTAI_API_KEY`, `MOONSHOT_API_KEY` | complete, stream |
| `meta:` | openai-responses | `META_API_KEY` | complete, stream, models, files, images |
| `meta-chat:` | openai-chat | `META_API_KEY` | complete, stream, models |
| `meta-anthropic:` | anthropic | `META_API_KEY` | complete, stream, models |
| `azure:` | openai-responses | `AZURE_OPENAI_API_KEY` | complete, stream, live, models, files, batches, speech |
| `azure-chat:` | openai-chat | `AZURE_OPENAI_API_KEY` | complete, stream, models |
| `azure-anthropic:` | anthropic | `ANTHROPIC_FOUNDRY_API_KEY` | complete, stream |
| `aws-anthropic:` | anthropic | `ANTHROPIC_AWS_API_KEY` | complete, stream |
| `bedrock-anthropic:` | anthropic | `AWS_BEARER_TOKEN_BEDROCK` | complete, stream |
| `bedrock-chat:` | openai-chat | `AWS_BEARER_TOKEN_BEDROCK` | complete, stream |
| `bedrock-mantle-chat:` | openai-chat | `AWS_BEARER_TOKEN_BEDROCK` | complete, stream, models |
| `vertex:` | gemini | gcp-chain | complete, stream |
| `vertex-express:` | gemini | `GOOGLE_API_KEY` | complete, stream |
| `vertex-anthropic:` | anthropic | gcp-chain | complete, stream |
| `ollama:` | openai-chat | key | complete, stream, models |
| `vllm:` | openai-chat | key | complete, stream, models |
| `sglang:` | openai-chat | key | complete, stream, models |

Support flags describe the shared access manifest. Bedrock hosts whose streaming framing is AWS event-stream fail explicitly at request construction in this port; see the README limits. Exact model capabilities still depend on the selected model.

Explicit `base_url:` wins over a compat preset address. Host settings come from the access manifest: AWS `region`; Azure `resource`; Vertex `project` and `location`. Missing required settings raise `NotConfiguredError`.
