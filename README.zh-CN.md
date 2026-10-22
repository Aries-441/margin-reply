# feishu-comment-bot

在**飞书云文档评论区**答疑的小机器人。在评论里 @ 它，它会读 docx 正文，在原评论线程回复——后端可以是 DeepSeek，也可以是你本机的 Claude Code / Codex。

不需要公网 HTTPS，也不需要配置回调地址：它通过飞书长连接接收 `drive.notice.comment_add_v1` 事件。

> English: [README.md](README.md)

## 工作方式

1. 用户在评论或回复里 @ 机器人。
2. 飞书通过 WebSocket 长连接推送 `drive.notice.comment_add_v1`。
3. 机器人取回评论、读取 docx 正文、调用配置的模型，在原评论线程回复；整篇评论则新建一条全文评论。

只回答明确 @ 机器人的评论，忽略机器人自己的回复，跳过已解决的评论。事件 ID 记录在 `.seen_events.json`，飞书重投事件时不会重复回答。

## 限制

- **只支持 docx。** 表格、多维表格、幻灯片和旧版文档会收到一条"暂不支持"的回复。
- **以 Windows 为主。** 常驻脚本用的是任务计划程序；机器人本身是纯 Python。
- **逐文档授权。** 机器人需要被加为每篇文档的协作者才能读取；飞书没有租户级的文档访问权限。
- 回复是纯文本（飞书评论不渲染 Markdown），超过 4000 字截断；文档正文送到模型前截到约 3 万字，保留头尾。

## 快速开始（Windows）

**1. 创建飞书应用** —— 按 [docs/feishu-setup.md](docs/feishu-setup.md) 配置。最后需要 app ID 和 app secret，并且要发布一个启用了评论事件、长连接模式的版本。

**2. 拉代码、装依赖**

```powershell
git clone https://github.com/<you>/feishu-comment-bot.git
cd feishu-comment-bot
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

已在 Python 3.12 和 3.14 上验证。也可以用 uv：`uv venv --python 3.12 .venv` + `uv pip install --python .venv\Scripts\python.exe -r requirements.txt`。

**3. 配置**

```powershell
Copy-Item .env.example .env
notepad .env
```

填写 `FEISHU_COMMENT_BOT_APP_ID`、`FEISHU_COMMENT_BOT_APP_SECRET`，再选一种回答后端：DeepSeek key 或本机 CLI。

**4. 前台跑起来**

```powershell
.\.venv\Scripts\python.exe -u bot.py
```

看到 `connected to wss://msg-frontier.feishu.cn/...` 说明连上了。然后打开一篇 docx，把机器人加为协作者，在评论里 @ 它。

**5. 常驻（可选）**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install-task.ps1
```

注册计划任务 `FeishuDocClarifier`：登录自启、单实例、异常退出后自动重试。停止/卸载命令见 [docs/deploy-with-ai.md](docs/deploy-with-ai.md) 的 Phase 5。

## 让 AI 帮你部署

仓库里有一份**写给 AI 助手看的**部署手册，每一阶段都有验收判据：[docs/deploy-with-ai.md](docs/deploy-with-ai.md)。

把下面这段丢给 Claude Code、Codex 或带文件访问能力的 ChatGPT：

```text
在这台 Windows 机器上部署 https://github.com/<you>/feishu-comment-bot 。
读 docs/deploy-with-ai.md，按阶段执行。
终端操作你来做；飞书控制台的步骤留给我，app secret 也由我自己填进 .env —— 不要打印任何密钥。
每个阶段结束停下来，把验收输出给我看。
```

## 配置项

全部从 `.env` 读取（环境变量优先）：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `FEISHU_COMMENT_BOT_APP_ID` | — | 飞书 app ID（`cli_...`） |
| `FEISHU_COMMENT_BOT_APP_SECRET` | — | 飞书 app secret |
| `FEISHU_COMMENT_BOT_AGENT_BACKEND` | `deepseek` | `deepseek`，或 `claude` / `codex` / 任意命令 |
| `FEISHU_COMMENT_BOT_AGENT_COMMAND` | `claude` | 本机 CLI 后端时执行的命令 |
| `FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY` | — | 后端为 `deepseek` 时必填 |
| `FEISHU_COMMENT_BOT_DEEPSEEK_MODEL` | `deepseek-chat` | DeepSeek 模型名 |

切换到本机 CLI：

```powershell
$env:FEISHU_COMMENT_BOT_AGENT_BACKEND='claude'
$env:FEISHU_COMMENT_BOT_AGENT_COMMAND='claude'
.\.venv\Scripts\python.exe -u bot.py
```

## 日志与测试

- `logs\bot.log` —— 机器人日志（UTF-8，5 MB × 3 轮转），崩溃和飞书接口错误都在这里。
- `logs\runner.log` —— `run.ps1` 写的启动 / 退出 / 重试记录。
- 测试：`.\.venv\Scripts\python.exe -m unittest -v test_bot`（15 个用例，不联网）。

## 文档

| 页面 | 内容 |
|---|---|
| [docs/deploy-with-ai.md](docs/deploy-with-ai.md) | 写给 AI 的部署手册，按阶段验收 |
| [docs/feishu-setup.md](docs/feishu-setup.md) | 建应用、订阅事件、权限 scope、发布、加协作者 |
| [docs/architecture.md](docs/architecture.md) | 事件体、接口清单，以及每个接口背后的坑 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 错误码与"没回复"排查表 |
| [docs/internals.md](docs/internals.md) | 设计取舍与已知边界 |
| [examples/prompts.md](examples/prompts.md) | 可以直接抄的提问示例 |

## 隐私

机器人会读取它被加入的文档全文。默认后端会把正文发给 DeepSeek API；用 `claude` / `codex` 时，正文发给那个 CLI 背后对应的服务。不要把机器人加进你不能给这些服务看的文档。

## 许可证

[MIT](LICENSE)
