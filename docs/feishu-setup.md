# Feishu app setup

Everything on this page happens in the [Feishu Developer Console](https://open.feishu.cn/app). You need to be an admin of the tenant, or have someone who is.

## 1. Create the app

1. Developer Console → **Create custom app** (企业自建应用).
2. Choose the name users will see when they @-mention the bot, for example **Margin Reply** or **页边答**.
3. **Add app capability → Bot** (机器人). Without the bot capability the comment event is never delivered.

## 2. Subscribe to the comment event

App → **Events and callbacks** (事件与回调):

1. Add event: `drive.notice.comment_add_v1`.
2. **Event configuration** → subscription mode: **long connection** (使用长连接接收事件).
3. **Callback configuration** → also **long connection**.

The HTTP callback mode is not supported for this event, and this bot has no HTTP server. If the console shows a request URL field, you are on the wrong mode.

The long connection is established by the bot process, not by the console. Until the bot runs, the console may show no connection — that is expected.

## 3. Permissions

App → **Permissions & scopes** (权限管理) → batch import (批量导入):

```json
{
  "scopes": {
    "tenant": [
      "drive:drive.metadata:readonly",
      "docs:document.comment:create",
      "docs:document.comment:delete",
      "docs:document.comment:read",
      "docs:document.comment:update",
      "docs:document.comment:write_only",
      "docx:document:create",
      "docx:document:readonly",
      "docx:document:write_only",
      "docx:document.block:convert"
    ],
    "user": []
  }
}
```

The comment scopes let it read and answer comments; `docx:document:readonly` lets it read the document body; the rest are required by the comment APIs and the bot-info endpoint.

## 4. Publish

App → **Version management & release** (版本管理与发布) → create a version → **publish**.

Scope and event changes do **not** take effect until a new version is published. For a custom app you may also need an admin to approve the release.

## 5. Credentials

App → **Credentials & Basic Info** (凭证与基础信息):

- App ID (`cli_...`) → `FEISHU_COMMENT_BOT_APP_ID`
- App Secret → `FEISHU_COMMENT_BOT_APP_SECRET`

With the installer, enter both in the setup wizard — it writes `.env` for you. From source, put them in `.env`. Do not paste them into a chat, a shell command, or a commit.

Changing the app later? Edit `.env` in the install directory (`%LocalAppData%\MarginReply`) and restart the task, or run the installer again — it pre-fills the previous values.

## 6. Give the bot access to documents

Feishu bots have no tenant-wide document access. For each document:

> Only add the bot to documents whose readers/commenters you trust. The bot has no prompt-injection protection — anyone who can comment can try to steer the model or make it quote the document into the thread. See the security notice in [README.md](../README.md#security-notice-read-this-first).

1. Open the docx.
2. **Share** → add collaborator → search the bot's name.
3. Give it at least **read** permission. The bot also writes comments, so write/comment permission is needed to answer.

If the bot is missing from a document, the API returns a permission error (`106xxxx` codes) and the bot logs it — see [troubleshooting.md](troubleshooting.md).

## 7. Verify the app from the CLI (optional)

If you have the Feishu `lark-cli` installed and bound to this app, these two commands confirm the credentials and the bot identity:

```powershell
lark-cli auth status
lark-cli api GET /open-apis/bot/v3/info
```

The second one returns the bot at the top level (`"bot": {...}`) — there is no `data` wrapper. If you are on Git Bash and the path gets mangled, prefix the command with `MSYS_NO_PATHCONV=1`.

## Checklist

- [ ] App is self-built, bot capability enabled
- [ ] `drive.notice.comment_add_v1` added
- [ ] Event subscription **and** callback both set to long connection
- [ ] 10 tenant scopes imported
- [ ] Version published (and approved, if the tenant requires it)
- [ ] Bot added as a collaborator on the test document
- [ ] App ID + secret entered (installer wizard, or `.env` when running from source)
