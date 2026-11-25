# Contributing

Thanks for taking a look. This is a small, single-file bot; keep changes small and boring.

## Before you open a PR

1. Create the environment and run the tests:

   ```powershell
   python -m venv .venv
   .\.venv\Scripts\pip install -r requirements.txt
   .\.venv\Scripts\python -m unittest discover -v
   ```

   Run the suite offline. Add bot tests to `test_bot.py` and Windows supervisor tests to `test_supervisor.py`.

2. Do not commit secrets, `logs/`, `.venv/`, `.env` or `.seen_events.json`.

3. If you change a Feishu API call, note it in `docs/architecture.md` — that page exists so the next person does not rediscover the same traps.

## The Windows installer

`build-installer.ps1` stages the project plus a Python 3.12 embeddable runtime into `installer\build\app`, then compiles `installer\MarginReply.iss` with Inno Setup 6:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-installer.ps1
```

- Downloads (`python-<ver>-embed-amd64.zip`, `get-pip.py`) are cached in `installer\build\downloads`; the runtime and pip dependencies are staged into `installer\build\runtime`. Reuse a staged runtime with `-SkipRuntime`.
- `installer\build\` and `installer\Output\` are gitignored; the compiled `.exe` is the release artifact.
- The wizard code lives in the `[Code]` section of the `.iss`. Silent-install parameters (`/APPID`, `/BACKEND`, …) are parsed there — keep them documented in both READMEs.
- After changing any `.ps1` that the package ships, keep the file **UTF-8 with BOM** (PowerShell 5.1 reads BOM-less files as ANSI and garbles Chinese).

## Scope

The bot intentionally stays:

- Windows-first (the autostart scripts target Task Scheduler);
- docx-only (other file types get a short "not supported" reply);
- single-process (two workers, no database, no admin UI).

Features outside that scope are better as a fork.

## Reporting bugs

Include: what you did, what the bot logged (`logs\bot.log`, redact tokens), and the error code if the Feishu API returned one. Feishu error codes are the fastest way to tell a permission problem from a code problem.
