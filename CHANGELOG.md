# Changelog

## Unreleased

- Close response-stream resources on success, provider errors, malformed streams,
  consumer exceptions and interruption. Cleanup failures remain in
  `cleanup_errors` without replacing an existing error or completed answer.
  Closing from the wrong thread raises without poisoning the owning thread.
- Parse LF, CRLF and CR server-sent events across arbitrary byte boundaries,
  including split UTF-8, an initial byte-order mark, empty data fields and
  multiple records per chunk. Live HTTP reads and recorded replay share one
  bounded parser. The existing line-oriented parser remains available;
  `parse_sse_chunks` accepts raw transport chunks.
- Preserve assistant images/files using the Responses input-message format;
  explicitly refuse unsupported assistant media instead of silently dropping
  it. Preserve citation title, URL and quote during replay in all four dialects.
- Preserve image detail when an image is addressed by an uploaded-file ID.
- Point package metadata to the standalone Ruby repository. Add installed-gem,
  macOS and pinned-reference comparison checks to CI.

The contract pin is unchanged. Real provider calls, chat-style completion over
realtime sockets, and unsupported cloud features are not newly certified by these fixes.
