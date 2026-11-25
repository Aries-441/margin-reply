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
| Trust | Document owner by default, open_id allowlist for strict use | Comment text drives the prompt; owner-only works out of the box, allowlist is the only true single-user control |
| Packaging | Inno Setup + Python embeddable runtime | One double-clickable `.exe`, no Python on the target machine, a real uninstaller |

## Installer

The package is built by `build-installer.ps1` (staging into `installer\build\app`, compiling `installer\MarginReply.iss`) and installs per-user into `%LocalAppData%\MarginReply` with no admin rights.

- **Why the embeddable runtime, not PyInstaller.** The bot is a plain script plus a scheduler wrapper. Shipping the official embeddable Python keeps `bot.py`, the `.ps1` files and the docs readable and editable after install, and the same `supervisor.py` works from a source checkout (it falls back to `.venv`).
- **Background startup.** The scheduled task runs `pythonw.exe` without a console window. The supervisor acquires the session mutex `Local\margin-reply` to prevent duplicate instances, restarts the bot with backoff, and uses a Windows job object to stop its child when the supervisor exits.
- **Why the wizard writes `.env` itself.** The app secret should not be typed into a terminal (where it lands in shell history). The wizard collects the app ID and a masked app secret and writes them straight to the file; a second UTF-8 encoder keeps it independent of console code pages.
- **Why silent mode skips validation.** A silent install has nobody to dismiss a dialog; `/APPID` etc. can be passed instead, and a missing value surfaces as the bot's own `missing required environment variable` log line.
- **Reinstalling.** The installer runs `uninstall-task.ps1 -StopOnly` to release the runtime files and pre-fills the wizard from the existing `.env`.
- **Why bytecode caching is off.** Python would otherwise drop untracked `__pycache__` files into the install directory on every start. The uninstaller deletes them too, but never writing them keeps the install tree equal to what the package shipped, which makes leftover files easier to identify. `supervisor.py` sets `PYTHONDONTWRITEBYTECODE=1` for the bot.
- **Why batch files are refused.** The prompt contains comment and document text. A `.cmd`/`.bat` target is run by `cmd.exe`, which re-parses `&`, `|` and `%VAR%` in the argument — the text would become shell syntax. `resolve_command()` accepts only real executables.

## Known boundaries

- **Prompt injection is unmitigated.** Comment text and the document body go into the same prompt with no instruction/data separation and no output filtering. Anyone who can comment can try to steer the answer or make the model quote the document into the thread. Treat it as a personal / trusted-team tool, not a public bot.
- **Local CLI permissions matter.** The bot launches the executable directly. Codex reads the prompt from stdin in its read-only sandbox. Claude and custom commands use their configured permissions.
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
