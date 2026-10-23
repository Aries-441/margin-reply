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

## Security notice (read this first)

**This bot is meant for your own use, or for a small group of trusted colleagues. Do not add it to a public document that anyone can comment on.**

By default only the **document owner** gets an answer (see [Who can use it](#who-can-use-it)). That filters out ordinary collaborators, but it is not "only me" — if someone else adds the bot to a document they own, that owner can use it too. For strict single-user use, switch to allowlist mode.

It has no prompt-injection defences: the comment text and the whole document are concatenated into one prompt, with no separation between "instructions" and "data". Anyone who can comment on (or edit) the document can try to make the model ignore its original instructions — for example, repeat the rest of the document into the comment thread, or produce a misleading answer. The bot does not review or filter the model's output.

With a local CLI backend (Claude Code / Codex) the stakes are higher: those CLIs can read files and run commands, and whether an injected instruction actually does something depends on the permissions you gave them. The DeepSeek backend is a single API call and executes nothing on your machine.

On command injection: the bot refuses `.cmd` / `.bat` commands (batch files re-parse their arguments) and passes the prompt as an argument to a `.exe` without a shell. That is not full isolation — the real defence is **only letting trusted people comment on these documents**.

## Installer (recommended, no Python needed)

Download `FeishuDocClarifier-Setup-<version>.exe` and double-click it. The package bundles a Python 3.12 runtime and the dependencies, so the target machine does not need Python installed.

The wizard will:

1. Show the Feishu app creation steps (~5 minutes, done in the developer console);
2. Ask for the App ID and App Secret;
3. Ask for an answer backend: DeepSeek (default) or a local Claude / Codex CLI;
4. Install per-user into `%LocalAppData%\FeishuDocClarifier` — no admin rights needed;
5. Register the scheduled task `FeishuDocClarifier` (starts at logon) and start the bot once at the end.

The Start menu has entries for starting the bot, opening the logs, reading the Feishu setup guide, and uninstalling. Uninstalling stops the bot, removes the task and deletes the install directory (including `.env`).

After installing, add the bot as a collaborator on each document and @-mention it in a comment.

> The installer is not code-signed, so Windows SmartScreen may warn on first run: **More info → Run anyway**.

### Silent install

```powershell
.\FeishuDocClarifier-Setup-1.0.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART `
  /APPID=cli_xxx /APPSECRET=xxx /BACKEND=deepseek /DEEPSEEKKEY=sk-xxx
```

| Parameter | Meaning |
|---|---|
| `/APPID`, `/APPSECRET` | Feishu app credentials |
| `/BACKEND=deepseek\|claude\|codex` | Answer backend, default `deepseek` |
| `/CLICOMMAND` | Command used for a local CLI; defaults to `claude` / `codex` |
| `/DEEPSEEKKEY`, `/DEEPSEEKMODEL` | DeepSeek key and model, model defaults to `deepseek-chat` |
| `/TRUSTMODE`, `/ALLOWEDUSERS` | Trust policy (`owner`/`allowlist`/`any`) and allowed open_ids |
| `/TASKS=""` | Do not register the logon task |

Parameters are written to the local `.env`; nothing is uploaded. They also appear on the process command line and in PowerShell history, so on a shared machine prefer the interactive wizard.

### Build it yourself

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-installer.ps1
```

The script downloads the Python 3.12 embeddable runtime, installs the dependencies, then compiles with Inno Setup 6. Output lands in `installer\Output\`. The first build needs network access; if Inno Setup is missing the script tries winget. Bump the version with `-AppVersion 1.2.0`.

## Quick start (Windows, from source)

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

Registers the scheduled task `FeishuDocClarifier` (starts at logon, single instance, automatic restart with backoff).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-task.ps1   # stop and delete the task
```

More commands in [docs/deploy-with-ai.md](docs/deploy-with-ai.md) (Phase 5).

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
| `FEISHU_COMMENT_BOT_AGENT_COMMAND` | `claude` | Command used when the backend is a local CLI (`.exe` only) |
| `FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY` | — | Required when backend is `deepseek` |
| `FEISHU_COMMENT_BOT_DEEPSEEK_MODEL` | `deepseek-chat` | DeepSeek model name |
| `FEISHU_COMMENT_BOT_TRUST_MODE` | `owner` | `owner` = document owner only; `allowlist` = listed open_ids only; `any` = anyone |
| `FEISHU_COMMENT_BOT_ALLOWED_USERS` | empty | Comma-separated open_ids for `allowlist` mode |

### Who can use it

- **`owner` (default)** — only the owner of the document being commented on. Works out of the box if the bot only sits on your own documents.
- **`allowlist`** — only the open_ids in `FEISHU_COMMENT_BOT_ALLOWED_USERS`. An empty list denies everyone; an unknown mode value also denies everyone.
- **`any`** — anyone who can @-mention the bot. Only use this when you trust every commenter.

To restrict it to just yourself:

1. Let the bot answer you once (or get ignored once) and copy your open_id (`ou_...`) from `logs\bot.log` — the reply line ends with `(by ou_...)`, the ignore line contains `is not allowed ...`.
2. In `.env`:

```dotenv
FEISHU_COMMENT_BOT_TRUST_MODE=allowlist
FEISHU_COMMENT_BOT_ALLOWED_USERS=ou_your_open_id
```

3. Restart the bot (or the scheduled task). Ignored comments were marked as seen, so comment again after changing the config.

Owner lookups are cached for 10 minutes; in `owner` mode a failed lookup denies the answer instead of letting it through.

Switching to a local CLI:

```powershell
$env:FEISHU_COMMENT_BOT_AGENT_BACKEND='claude'
$env:FEISHU_COMMENT_BOT_AGENT_COMMAND='claude'
.\.venv\Scripts\python.exe -u bot.py
```

**`.exe` only.** The `claude.cmd` / `codex.cmd` shims that npm installs are batch files, and the command line re-parses their arguments — a `&` in a comment could become a command, and `%VAR%` gets expanded. The bot refuses to run batch files; point the command at the CLI's native `.exe` (the native Claude Code install is `claude.exe`) or at an `.exe` wrapper.

## Logs and tests

- `logs\bot.log` — bot log (UTF-8, 5 MB × 3 rotation). Crashes and Feishu API errors land here.
- `logs\runner.log` — start / exit / retry records written by `run.ps1`.
- With the installer, logs live in `%LocalAppData%\FeishuDocClarifier\logs` (also reachable from the Start menu).
- Tests: `.\.venv\Scripts\python.exe -m unittest -v test_bot` (27 tests, no network).

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

The bot reads the full text of documents it is added to. With the default backend that text is sent to the DeepSeek API; with `claude` / `codex` it goes to whatever that CLI sends it to. Do not add the bot to documents you would not share with that provider. See also the [security notice](#security-notice-read-this-first) above.

## License

[MIT](LICENSE)
