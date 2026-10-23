# Deploy with an AI agent

This page is written **for an AI coding agent** (Claude Code, Codex, ChatGPT with file access). It is not a human tutorial — a human can follow [README.md](../README.md) or [README.zh-CN.md](../README.zh-CN.md).

Target environment: Windows 10/11, PowerShell 5.1, Python 3.12.

> Deploying from a release build? The `FeishuDocClarifier-Setup-*.exe` installer does Phases 1 and 5 itself and needs no Python on the target machine — see [README.zh-CN.md](../README.zh-CN.md#安装包推荐无需-python). The phases below are the source-based path; do not mix the two on one machine.

## Ground rules

1. **Never print secrets.** Do not `Get-Content .env`, do not `echo` the app secret or API key, do not put them in a command line, a git commit, or your reply. If you must check that a value exists, check its length only.
2. **The human does the console steps.** You cannot click in the Feishu developer console. Ask for them in Phase 2 and wait.
3. **Verify every phase before moving on.** Each phase ends with an acceptance check; if it fails, stop and report, do not continue.
4. **One bot process at a time.** If a bot is already running, stop it before starting another (see Phase 5).
5. Do not modify `bot.py` to make a phase pass. If the code does not match this document, report the mismatch.

## Phase 0 — preflight

Run, from the project root:

```powershell
git --version
python --version
```

Accepted: Python 3.10 or newer (tested on 3.12 and 3.14). If `python` opens the Microsoft Store or exits silently, install Python from python.org or use `uv python install 3.12`.

Check that TLS to Feishu works (any HTTP status is fine, `404` is expected):

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" https://open.feishu.cn/open-apis/
```

**Acceptance:** Python version is acceptable and the curl command prints an HTTP status. If it times out, the machine needs a proxy or outbound access to `open.feishu.cn` and `*.feishu.cn` on 443 — stop and tell the human.

## Phase 1 — code, environment, tests

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m unittest -v test_bot
```

**Acceptance:** `Ran 27 tests ... OK`. If tests fail, the environment is wrong or the repository is dirty — do not proceed.

## Phase 2 — Feishu app (human)

Give the human this checklist, pointing at [feishu-setup.md](feishu-setup.md) for the details:

1. Create a **self-built app** with bot capability enabled.
2. Add the event `drive.notice.comment_add_v1`.
3. Set **both** event subscription and callback configuration to **long connection** (HTTP callback is not supported for this event).
4. Import the 10 tenant scopes listed in `feishu-setup.md`.
5. **Create a version and publish it** — scope and event changes only take effect after a release.
6. Copy the app ID and app secret.

Then ask the human to add the bot as a **collaborator on the test document** (document owner → Share → add the bot).

**Acceptance:** the human confirms the app is published and has the app ID. Do not proceed on "I think I did".

## Phase 3 — credentials

```powershell
Copy-Item .env.example .env
```

Ask the human to open `.env` and fill in `FEISHU_COMMENT_BOT_APP_ID`, `FEISHU_COMMENT_BOT_APP_SECRET`, and one backend:

- `FEISHU_COMMENT_BOT_AGENT_BACKEND=deepseek` + `FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY=...`, or
- `FEISHU_COMMENT_BOT_AGENT_BACKEND=claude` (or `codex`) and make sure that CLI is on `PATH`.

**Acceptance:** the bot starts without a `missing required environment variable` error (the next phase proves it). Never validate by printing the file.

## Phase 4 — first live answer

```powershell
.\.venv\Scripts\python.exe -u bot.py
```

**Acceptance (two steps):**

1. Within ~30 seconds the log contains `connected to wss://msg-frontier.feishu.cn/...`.
   A single `SSL: UNEXPECTED_EOF_WHILE_READING` before that is a transient network error — the SDK retries by itself; only investigate if retries keep failing.
2. Ask the human to post a **new** comment on the test doc mentioning the bot, then check `logs\bot.log` for `Replied to comment ...`. The reply should appear in the thread within a few seconds.

If the comment produces nothing, go to [troubleshooting.md](troubleshooting.md) before touching code.

Stop the foreground process (`Ctrl+C` or kill the `python.exe` running `bot.py`) before Phase 5.

## Phase 5 — run it in the background

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1
Start-Sleep -Seconds 40
Get-ScheduledTask -TaskName FeishuDocClarifier | Select-Object State
Get-Content logs\runner.log -Tail 3
```

**Acceptance:**

- task `State` is `Running`;
- `logs\bot.log` gets a new `connected to wss://` line after the task starts;
- optional resilience check: kill the `python.exe` running `bot.py`; within ~1 minute `runner.log` shows `starting bot` again and the bot reconnects.

Operational commands:

```powershell
Stop-ScheduledTask -TaskName FeishuDocClarifier
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.CommandLine -like '*bot.py*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Start-ScheduledTask -TaskName FeishuDocClarifier
Unregister-ScheduledTask -TaskName FeishuDocClarifier -Confirm:$false
```

## Final checklist

Report each line as pass/fail:

- [ ] Python environment created, dependencies installed
- [ ] `unittest` — 27 tests OK
- [ ] `.env` filled (values not printed anywhere)
- [ ] Foreground run reached `connected to wss://`
- [ ] A real @-mention got a correct reply in the thread
- [ ] Scheduled task `FeishuDocClarifier` is `Running`
- [ ] Bot process restarts after being killed
- [ ] No secret, `.env`, `.seen_events.json`, `.venv/` or `logs/` staged in git

## Things that will confuse you

- The bot only answers **@-mentions**; a plain comment gets nothing.
- Solved comments are skipped by design.
- Already-answered events are remembered in `.seen_events.json`; a redelivery will not answer twice. To re-test the same comment, resolve/reopen or delete the entry.
- A document the bot was not added to returns permission errors (`codes` in the 106xxxx range) — that is a sharing problem, not a code problem.
- Chinese in the console may look garbled on a GBK code page. The log files are UTF-8; read them, not the console.
