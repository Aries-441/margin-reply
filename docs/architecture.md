# Architecture and API notes

One Python process, two worker threads, no database. This page exists so the next person does not have to rediscover the Feishu comment API by trial and error.

## Flow

```
Feishu long connection (lark-oapi ws.Client)
  │  drive.notice.comment_add_v1
  ▼
on_comment()            read header.event_id, put (event_id, event) on a queue
  ▼
worker()  ×2            process_comment()
  ├─ already_seen(event_id)?                  → drop
  ├─ from_user == bot? / not @bot?            → drop
  ├─ POST comments/batch_query                → comment, is_solved, is_whole
  ├─ pick text: reply_id (add_reply) or first reply
  ├─ GET docx raw_content                     → 30k chars, head + tail
  ├─ answer(): DeepSeek or local CLI
  ├─ plain_text() + truncate(4000)
  └─ POST replies  |  POST new_comments (whole-doc comment)
       ▼
     mark_seen(event_id) — only after a successful reply
```

A failed event is deliberately **not** marked seen, so Feishu's redelivery retries it.

## Event payload

```
header.event_id                          # the event ID lives here, not in event
event.notice_meta.file_token
event.notice_meta.file_type              # docx / sheet / bitable / slides / file / doc
event.notice_meta.notice_type            # add_comment / add_reply
event.notice_meta.from_user_id.open_id
event.notice_meta.to_user_id.open_id     # the notification target; equals the bot when @-mentioned
event.comment_id
event.reply_id
event.is_mentioned
```

There is no `event.event_id` and no `mentions` array. @-detection uses `to_user_id == bot open_id`, falling back to `is_mentioned` when `to_user_id` is absent.

## Endpoints used

| Purpose | Call |
|---|---|
| Tenant token | `POST /auth/v3/tenant_access_token/internal` |
| Bot identity | `GET /bot/v3/info` |
| Fetch one comment | `POST /drive/v1/files/{token}/comments/batch_query?file_type=…&user_id_type=open_id` with `{"comment_ids":[id]}` |
| List replies | `GET /drive/v1/files/{token}/comments/{comment_id}/replies?file_type=…&page_size=100` |
| Reply in thread | `POST /drive/v1/files/{token}/comments/{comment_id}/replies?file_type=…` |
| Whole-document comment | `POST /drive/v1/files/{token}/new_comments` with `{"file_type":"docx","reply_elements":[…]}` |
| Document text | `GET /docx/v1/documents/{token}/raw_content` |

## Traps (all of these were hit in practice)

1. **`event_id` is in `header`.** Reading `event["event_id"]` silently returns `None`, and deduplication silently stops working.
2. **`file_type` is required on comment endpoints.** Omit it and the call returns 400 — including the reply call, which means answers are never posted.
3. **Single-comment GET can return `1069307` ("comment not exist")** even with a valid token and an existing comment. `batch_query` with the same ID works. Use `batch_query`.
4. **`add_reply` events point at the parent comment.** The actual question is the reply whose `reply_id` matches `event.reply_id`; it may be beyond the first page of `reply_list`, so paginate.
5. **Whole-document comments cannot be replied to via `replies`.** They need `new_comments`, and that endpoint takes `reply_elements` (`{"type":"text","text":…}`), not `content.elements`.
6. **Text elements are capped at 1,000 characters.** Both element builders chunk the answer.
7. **Tenant tokens expire (2 h).** The client refreshes 5 minutes early and retries once on token error codes.
8. **Feishu comments do not render Markdown.** `plain_text()` strips `**`, `#`, `>`, backticks and link syntax before sending, and the prompt asks the model for plain text.
9. **`/bot/v3/info` has no `data` wrapper.** The bot object is at the top level.
10. **JSON bodies need `Content-Type: application/json`.** Without it the token endpoint answers `10003 invalid param`.

## Sizing limits

| Limit | Value | Where |
|---|---|---|
| Document text sent to the model | 30,000 chars (head + tail) | `MAX_DOC_CHARS` |
| Command backend document text | 12,000 chars | `MAX_COMMAND_DOC_CHARS` |
| Command line prompt cap | 20,000 chars | `MAX_PROMPT_CHARS` |
| Reply length | 4,000 chars | `MAX_REPLY_CHARS` |
| Dedupe store | 2,000 entries / 7 days | `SEEN_LIMIT`, `SEEN_TTL_SECONDS` |
| Workers | 2 | `WORKER_COUNT` |

## Backends

`FEISHU_COMMENT_BOT_AGENT_BACKEND`:

- `deepseek` — HTTPS call to `api.deepseek.com`, model from `FEISHU_COMMENT_BOT_DEEPSEEK_MODEL`.
- anything else (`claude`, `codex`, …) — runs `FEISHU_COMMENT_BOT_AGENT_COMMAND` with `-p <prompt>`, 180 s timeout, and uses stdout as the answer.

Both are single-shot: no conversation history between comments.
