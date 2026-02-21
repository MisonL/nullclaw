# Changelog

All notable changes to this project are documented in this file.

## v0.1.1 - 2026-02-21

### Highlights
- Completed Chinese UI localization in onboarding and setup summaries.
- Improved OpenAI-compatible provider support for custom base URLs and custom models.
- Fixed multiple Windows-specific CLI/runtime issues in interactive agent mode.

### Added
- Interactive onboarding now supports per-provider `base_url` override (optional).
- Interactive and non-interactive onboarding support custom model selection.
- Streaming parser fallback for gateways that return one-shot JSON instead of SSE.
- Additional compatibility parsing for OpenAI-style response variants:
  - `message.content` as string/object/array
  - `delta.content`
  - `text`
  - `output_text`

### Fixed
- `error.InvalidWtf8` on Windows when sending request bodies through `curl -d`.
  - Switched POST body transport to stdin (`--data-binary @-`) for curl calls.
- Empty response behavior in streaming mode with some OpenAI-compatible gateways.
  - Added automatic non-stream fallback when stream content is empty.
- `error.NoResponseContent` with non-UTF8 terminal input under Git Bash/IME on Windows.
  - Added Windows input normalization/transcoding before agent requests.

### Compatibility
- Better cross-platform behavior with a focus on Windows + Git Bash scenarios.
- No config schema breakage; existing configs remain valid.

