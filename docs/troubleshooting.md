# Troubleshooting

Start with the two log files:

- `logs\bot.log` — what the bot did; API errors with Feishu codes land here.
- `logs\runner.log` — whether the autostart wrapper started the bot and how many times it restarted.

## The bot connects but never answers

| Check | How |
|---|---|
| Was the bot actually @-mentioned? | Only explicit mentions are answered. A plain comment produces nothing — by design. |
| Is the comment already solved? | Solved threads are skipped. Unresolve it or start a new comment. |
| Is it a docx? | Other file types get a one-line "not supported" reply, not an answer. |
| Did the bot already answer this event? | Events are remembered in `.seen_events.json` for 7 days. A redelivered event will not be answered twice. |
| Was the bot added to this document? | Share → collaborators. Without it, the API returns a permission error (`106xxxx`) in `bot.log`. |
| Is the event subscribed? | Console → Events and callbacks. Scope/event changes need a **new published version**. |
| Are you allowed to use it? | Default `TRUST_MODE=owner` answers only the document owner. Look for `is not allowed to use the bot (TRUST_MODE=…)` in `bot.log`, copy your open_id into `FEISHU_COMMENT_BOT_ALLOWED_USERS`, set `TRUST_MODE=allowlist`, restart the task, then comment again. |

## Connection problems

| Symptom in log | Meaning | Fix |
|---|---|---|
| `SSL: UNEXPECTED_EOF_WHILE_READING` once, then `connected to wss://…` | Transient TLS failure | Nothing — the SDK reconnects by itself. |
| `connect failed` repeating | No route to `open.feishu.cn` / `*.feishu.cn` on 443 | Check corporate proxy/firewall. `curl.exe -s -o NUL -w "%{http_code}" https://open.feishu.cn/open-apis/` should print a status. |
| `missing required environment variable: FEISHU_COMMENT_BOT_APP_ID` | `.env` not found or not filled | The bot reads `.env` from the project root. Check the file name is exactly `.env`. |
| `cannot find agent command 'x'` | `FEISHU_COMMENT_BOT_AGENT_COMMAND` is misspelled, or the scheduled task's PATH lacks the CLI | Use an absolute path to the `.exe`. |
| `resolves to a batch file (…cmd)` | The command resolved to an npm `.cmd` shim | Point the command at the CLI's native `.exe`; batch files are refused because they re-parse the comment text as command-line syntax. |
| `code=10003 … invalid param` | Request sent without a JSON `Content-Type` | A code problem, not configuration — report it with the log line. |
| `code=99991663` / `99991661` / `99991668` | Tenant token invalid/expired | The client refreshes and retries once. If it persists, the app secret is wrong or the app was not published. |

## API error codes

| Code | Meaning | Likely fix |
|---|---|---|
| `1069307` | Single-comment GET says the comment does not exist | Known Feishu quirk; the bot uses `batch_query` instead. If you see this, the code is outdated. |
| `106xxxx` (permission family) | The app/bot cannot read or write this file | Add the bot as a document collaborator; re-check the 10 scopes and republish. |
| `99991663` | Token invalid | Check app ID/secret; republish the app. |
| `10003` | Invalid parameter | Usually a missing `Content-Type` or `file_type`. |

## Installer problems

The installer stores logs in `%LocalAppData%\MarginReply\logs`. Open **Start → 页边答 → 查看页边答日志** to view them.

| Symptom | Cause | Fix |
|---|---|---|
| SmartScreen blocks the `.exe` | The installer is not code-signed | More info → Run anyway. Sign the build for wider distribution. |
| Wizard advanced but the bot never answers | Feishu credentials wrong, or the app version was never published | Check `bot.log` for `app_id is invalid` / `99991663`; fix the app in the console and republish. |
| Silent install produced an empty `.env` | No `/APPID` etc. were passed (silent mode skips the dialogs) | Re-run with the parameters, or edit `%LocalAppData%\MarginReply\.env` and restart the task. |
| **Start → 页边答 → 启动页边答** does nothing | Another instance already holds the single-instance mutex | Check `Get-ScheduledTask MarginReply`; the running task is enough. |
| Uninstall leaves the folder behind | The bot process was busy writing logs | Run `uninstall-task.ps1` first, then uninstall again. |
| Scheduled task still exists after uninstall | The uninstaller ran while the task was disabled/protected | `Unregister-ScheduledTask -TaskName MarginReply -Confirm:$false` |

To build or re-test the package, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Autostart problems

| Symptom | Cause | Fix |
|---|---|---|
| `runner.log` says `starting bot` but `bot.log` never grows | Python crashes before logging starts, or the path is wrong | Run `runtime\python.exe -u bot.py` (installer) or `.\.venv\Scripts\python.exe -u bot.py` (source) in the foreground to see the error. |
| `bot exited code=-1` right after start | The wrapper killed it, or it crashed | Check `bot.log`; re-run in the foreground. |
| `找不到 Python 运行时` thrown by `run.ps1` / `install-task.ps1` | Neither `runtime\python.exe` nor `.venv` exists | Reinstall the package, or create `.venv`: `python -m venv .venv` + install requirements. |
| `app_id is invalid` right after start | Wrong app ID, or the app was never published | Fix the credentials in `.env`, republish the app, restart the task. |
| Task exists but never runs | Trigger is "at logon" for a different user, or the project folder was moved | Re-run `install-task.ps1` from the current project root; it stores absolute paths. |
| Two bots fighting over the connection | Single-instance guard bypassed (e.g. launched manually plus the task) | Keep one: stop the manual process, or stop the task. |

## Console output looks like mojibake

Windows console code pages (GBK) can garble Chinese paths and log lines. The log files are UTF-8 — read them with `Get-Content logs\bot.log -Encoding utf8`. Functionality is unaffected.

## Editing the PowerShell scripts

PowerShell 5.1 reads `.ps1` files as ANSI unless they have a UTF-8 BOM. If you add Chinese text to `run.ps1` / `install-task.ps1` / `uninstall-task.ps1` and the script dies with `TerminatorExpectedAtEndOfString`, save it as **UTF-8 with BOM**. `supervisor.py` is plain Python and always read as UTF-8.

## Testing without spamming a real document

- Unit tests never touch the network: `.\.venv\Scripts\python.exe -m unittest -v test_bot`.
- For live tests create a throwaway docx, add the bot, and comment there. Delete the comment afterwards; the bot does not answer deleted or re-delivered events.
