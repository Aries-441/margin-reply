# feishu-comment-bot

A small bot that answers questions in **Feishu (Lark) document comments**. Mention it in a comment, it reads the docx body and replies in the same thread — using DeepSeek or your local Claude Code / Codex.

No public HTTPS endpoint, no webhook: it receives the `drive.notice.comment_add_v1` event over Feishu's long connection.

> 中文说明见 [README.zh-CN.md](README.zh-CN.md)

## How it works

1. A user posts a comment or reply and @-mentions the bot.
2. Feishu pushes `drive.notice.comment_add_v1` over the WebSocket long connection.
3. The bot fetches the comment, the docx raw text, asks the configured backend, and replies in the same comment thread (whole-document comments get a new whole-document comment).

Only explicit @-mentions are answered, the bot ignores its own replies, and solved comments are skipped. Duplicate events are remembered in `.seen_events.json` so an event redelivery does not produce a second answer.

## Limitations

- **docx only.** Sheets, bitables, slides and old docs get a short "not supported" reply.
- **Windows-first.** The autostart scripts use Task Scheduler; the bot itself is plain Python.
- **Per-document permission.** The bot must be added as a collaborator to every document it should read. Feishu has no tenant-wide doc access for bots.
- Replies are plain text (Feishu comments do not render Markdown). Answers are truncated at 4,000 characters; very long docs are truncated to ~30,000 characters with head and tail kept.

## Quick start (Windows)

**1. Create the Feishu app** — follow [docs/feishu-setup.md](docs/feishu-setup.md). You need the app ID and app secret at the end, plus a published version with the comment event and long-connection mode enabled.

**2. Get the code and dependencies**

```powershell
git clone https://github.com/<you>/feishu-comment-bot.git
cd feishu-comment-bot
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Tested on Python 3.12 and 3.14. (`uv venv --python 3.12 .venv` + `uv pip install --python .venv\Scripts\python.exe -r requirements.txt` works too.)

**3. Configure**

```powershell
Copy-Item .env.example .env
notepad .env
```

Fill in `FEISHU_COMMENT_BOT_APP_ID`, `FEISHU_COMMENT_BOT_APP_SECRET`, and one answer backend — either a DeepSeek key or a local CLI.

**4. Run in the foreground**

```powershell
.\.venv\Scripts\python.exe -u bot.py
```

You should see a line ending with `connected to wss://msg-frontier.feishu.cn/...`. Then open a docx, add the bot as a collaborator, and @-mention it in a comment.

**5. Run it all the time (optional)**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1
```

Registers the scheduled task `FeishuDocClarifier` (starts at logon, single instance, automatic restart with backoff). See [docs/deploy-with-ai.md](docs/deploy-with-ai.md) (Phase 5) for stop/uninstall commands.

## Let an AI agent deploy it

This repo ships a deployment manual written **for an AI coding agent**, with a verification step after every phase: [docs/deploy-with-ai.md](docs/deploy-with-ai.md).

Paste this into Claude Code, Codex or ChatGPT with file access:

```text
Deploy https://github.com/<you>/feishu-comment-bot on this Windows machine.
Read docs/deploy-with-ai.md and follow it phase by phase.
Do the terminal work yourself, but let me handle the Feishu console steps and
let me put the app secret into .env myself — never print secrets.
Stop after each phase and show me the verification output.
```

## Configuration

Everything is read from `.env` (or the environment, which wins):

| Variable | Default | Meaning |
|---|---|---|
| `FEISHU_COMMENT_BOT_APP_ID` | — | Feishu app ID (`cli_...`) |
| `FEISHU_COMMENT_BOT_APP_SECRET` | — | Feishu app secret |
| `FEISHU_COMMENT_BOT_AGENT_BACKEND` | `deepseek` | `deepseek`, or `claude` / `codex` / any command |
| `FEISHU_COMMENT_BOT_AGENT_COMMAND` | `claude` | Command used when the backend is a local CLI |
| `FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY` | — | Required when backend is `deepseek` |
| `FEISHU_COMMENT_BOT_DEEPSEEK_MODEL` | `deepseek-chat` | DeepSeek model name |

Switching to a local CLI:

```powershell
$env:FEISHU_COMMENT_BOT_AGENT_BACKEND='claude'
$env:FEISHU_COMMENT_BOT_AGENT_COMMAND='claude'
.\.venv\Scripts\python.exe -u bot.py
```

## Logs and tests

- `logs\bot.log` — bot log (UTF-8, 5 MB × 3 rotation). Crashes and Feishu API errors land here.
- `logs\runner.log` — start / exit / retry records written by `run.ps1`.
- Tests: `.\.venv\Scripts\python.exe -m unittest -v test_bot` (15 tests, no network).

## Docs

| Page | What it covers |
|---|---|
| [docs/deploy-with-ai.md](docs/deploy-with-ai.md) | Deployment manual for an AI agent, phase by phase |
| [docs/feishu-setup.md](docs/feishu-setup.md) | App creation, event subscription, scopes, publishing, collaborators |
| [docs/architecture.md](docs/architecture.md) | Event payload, API endpoints, and the traps behind them |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Error codes and "no reply" checklists |
| [docs/internals.md](docs/internals.md) | Design decisions and known boundaries |
| [examples/prompts.md](examples/prompts.md) | Questions worth trying |

## Privacy

The bot reads the full text of documents it is added to. With the default backend that text is sent to the DeepSeek API; with `claude` / `codex` it goes to whatever that CLI sends it to. Do not add the bot to documents you would not share with that provider.

## License

[MIT](LICENSE)
