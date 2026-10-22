# Design notes

Why the bot is built this way, and where the edges are. For the API-level traps see [architecture.md](architecture.md).

## Constraints that shaped the code

- **No public endpoint.** The comment event is only delivered over Feishu's long connection, so the bot is an outbound WebSocket client. That also means it must run somewhere that can reach `*.feishu.cn` — fine for a laptop, no server or TLS certificate needed.
- **Comments must be answered in place.** The reply has to go into the same comment thread, and whole-document comments live on a different endpoint. Both paths exist.
- **Feishu renders no Markdown in comments.** The model is asked for plain text, and `plain_text()` cleans up if it ignores that.
- **One answer per event.** Feishu redelivers events; answering twice looks broken. Deduplication is a small JSON file rather than a database.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Transport | `lark-oapi` long connection | `lark-cli` (as of 1.0.98) cannot consume `drive.notice.comment_add_v1` |
| Concurrency | 1 queue + 2 daemon workers | Bounded; one slow model call cannot spawn unbounded threads |
| Dedupe | `event_id` in `.seen_events.json`, 2,000 entries / 7 days | No database, survives restarts |
| Dedupe timing | Mark **after** a successful reply | A transient failure stays retryable |
| Document scope | docx only, with an explicit "not supported" reply | Silent failure is worse than a one-line notice |
| Solved comments | Skipped | Replying into a resolved thread is noise |
| Reply format | Plain text, 4,000 chars | Feishu comment box, no Markdown |
| Config | `.env` via python-dotenv, env vars win | Works for both a laptop and a task runner |
| Autostart | Task Scheduler (Windows) | Login start, single instance, restart on crash |

## Known boundaries

- No conversation memory: every comment is answered with the document and that one question. Follow-ups require repeating context (the thread is not fed back in).
- The document is read as raw text, so tables lose their structure and images are invisible.
- Very long documents are cut in the middle (head + tail kept) to stay inside the model context.
- Replies are written by the bot account, so the document shows the bot as the comment author.
- Permission is per document; there is no tenant-wide grant for this event.

## Extending

- **Another document type** — branch in `process_comment()` on `file_type` and add a `document_text` implementation; keep the "not supported" fallback for unknown types.
- **Another model** — `FEISHU_COMMENT_BOT_AGENT_BACKEND` / `..._COMMAND` already accept any CLI that takes `-p <prompt>` and prints the answer.
- **Richer replies** — Feishu comments support richer elements than plain text, but the comment box renders a limited subset; anything fancy belongs in a card sent to a chat, not a comment.
- **Tests** — `test_bot.py` uses fakes for the Feishu client and the answer backend; keep new behaviour testable the same way (no network in tests).
