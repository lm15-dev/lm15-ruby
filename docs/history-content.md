# Replaying conversation history without losing content

The contract's MAP-10 rule requires every message part to reach its native
wire block or raise `UnsupportedFeatureError` before the request is sent.
A passing comparison against Python is not enough: the pinned Python source
silently omits some assistant media and citations.

## Assistant messages

| Content | Chat Completions | Responses | Anthropic | Gemini |
|---|---|---|---|---|
| Text | Existing text encoding | Existing `output_text` encoding | Text block | Text part |
| Citation | Title, URL and quote as text | Title, URL and quote as text | Title, URL and quote as text | Title, URL and quote as text |
| Image | Raise | `input_image` | Image block | Inline/file data |
| Document | Raise | `input_file` | Document block | Inline/file data |
| Binary file | Raise | `input_file` | Raise | Inline/file data |
| Audio/video | Raise | Raise | Raise | Inline/file data |

These are format mappings, not promises that every provider/model accepts
every format. Existing provider capability and compatibility checks still
apply. Nothing changes the assistant role to user, replaces media with its
caption, or sends base64 bytes as ordinary prose.

Responses has two message shapes. Ordinary assistant text retains its old
output-message encoding. An assistant message containing images/files uses
`EasyInputMessage`: text becomes `input_text`, media uses `input_image` or
`input_file`, and the parts remain in one assistant message in their original
order. URLs, uploaded-file IDs, inline bytes and local file paths retain
native media delivery. Image detail also survives an uploaded-file ID.

A refusal block cannot be mixed into that input-content list, so a single
assistant message combining refusal and media raises rather than changing
the refusal into ordinary text. Assistant audio/video also raises: the
snapshot's concrete Responses input-content variants are text, image and
file. Chat's optional assistant `audio.id` is a provider response identifier,
not an arbitrary URL/file ID or audio byte string, so it is not fabricated
from a canonical media part.

Reasoning continuation state and tool-call IDs keep their existing paths.
Citations are text-bearing parts: replay includes all their title, URL and
quote information without inventing native annotation offsets or IDs.

## Evidence

- Contract `cfed00771dffef2a218b5549151950bf5060ca06`,
  `docs/mapping-rules.md`, MAP-10 rules 1–5; `playbooks/port.md` rule 4.
- [OpenAI Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create):
  `input` → `EasyInputMessage` permits `role: assistant`; its content list
  declares `input_text`, `input_image`, and `input_file`.
- [OpenAI Chat create reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create):
  `ChatCompletionAssistantMessageParam.content` declares text/refusal, with
  previous audio represented separately by a response ID.
- Frozen local documentation: `curl-fixtures` commit
  `35fa9a71a6f0beddd1236c4ccdb54d42f26d588b`,
  `api-references/openai/pages/responses--create.md` (EasyInputMessage) and
  `api-references/openai/pages/chat--create.md` (assistant message).

`test/history_content_test.rb` exercises the public request builder,
including failure before credential callbacks or transport, supported media
sources, mixed text/media ordering, citations and unmodified caller input.
No contract fixture was changed. These new mappings are checked against the
documentation and offline expected bytes; no live provider receipt is claimed.
