# Contributing

Thanks for taking a look. This is a small, single-file bot; keep changes small and boring.

## Before you open a PR

1. Create the environment and run the tests:

   ```powershell
   python -m venv .venv
   .\.venv\Scripts\pip install -r requirements.txt
   .\.venv\Scripts\python -m unittest -v test_bot
   ```

   All tests must pass. New behaviour needs a test in `test_bot.py`; the suite uses fakes and never calls the real Feishu API.

2. Do not commit secrets, `logs/`, `.venv/`, `.env` or `.seen_events.json`.

3. If you change a Feishu API call, note it in `docs/architecture.md` — that page exists so the next person does not rediscover the same traps.

## Scope

The bot intentionally stays:

- Windows-first (the autostart scripts target Task Scheduler);
- docx-only (other file types get a short "not supported" reply);
- single-process (two workers, no database, no admin UI).

Features outside that scope are better as a fork.

## Reporting bugs

Include: what you did, what the bot logged (`logs\bot.log`, redact tokens), and the error code if the Feishu API returned one. Feishu error codes are the fastest way to tell a permission problem from a code problem.
