# 页边答

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

## 安全提醒（请先读）

**这个机器人适合自己用，或给一小群可信的同事用。不要把它加进公开的、谁都能评论的文档。**

默认只有**文档所有者**的 @ 会得到回答（见下面[「谁能使用」](#谁能使用)）。这挡住了普通协作者，但不等于「只有你本人」——如果别人把自己拥有的文档加进机器人，那位所有者同样可以用。要严格限定为只有你自己，请改用白名单模式。

它没有针对提示词注入做防护：评论正文和文档全文会原样拼进模型提示词，中间没有"以下是指令、以下是资料"的隔离。任何能给这篇文档写评论（或有编辑权限）的人，都可以尝试让它无视原始要求——比如把文档后半部分复述到评论区，或者输出误导性结论。机器人对回答也没有做审核。

用本机 CLI 后端（Claude Code / Codex）时后果更重：这类 CLI 能读写文件、执行命令，被注入后会不会真的动手，取决于你给它的权限配置。DeepSeek 后端只是一次 API 调用，不会在你机器上执行任何东西。

机器人直接调用可执行文件，并拒绝执行 `.cmd` 和 `.bat`。Codex 在只读沙箱中从标准输入读取问题，Claude 和自定义命令通过 `-p` 接收问题。请只授权可信的评论者使用。

## 安装包（推荐，无需 Python）

双击 `MarginReply-Setup-0.1.0.exe` 即可安装页边答。安装包自带 Python 3.12 和运行依赖。

向导会：

1. 展示飞书应用的创建步骤（约 5 分钟，在飞书开放平台完成）；
2. 让你填入 App ID 和 App Secret；
3. 让你选择回答后端：DeepSeek（默认）或本机 Claude / Codex CLI；
4. 按当前用户安装到 `%LocalAppData%\MarginReply`，不需要管理员权限；
5. 默认勾选登录自启，安装完成后立即启动机器人，并注册计划任务 `MarginReply` 供以后登录时启动。取消勾选后，可以在完成页直接启动，也可以稍后从开始菜单启动。

打开「开始 → 页边答」，可选择「启动页边答」「查看页边答日志」「飞书应用配置指南」或「卸载 页边答」。卸载会停止机器人、删除计划任务和安装目录（包括 `.env`）。

安装后，在飞书文档里把机器人加为协作者，然后在评论里 @ 它。

> 安装包没有代码签名，首次运行可能出现 Windows SmartScreen 提示；选择「更多信息」→「仍要运行」即可。

### 静默安装

```powershell
.\MarginReply-Setup-0.1.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART `
  /APPID=cli_xxx /APPSECRET=xxx /BACKEND=deepseek /DEEPSEEKKEY=sk-xxx
```

| 参数 | 含义 |
|---|---|
| `/APPID`、`/APPSECRET` | 飞书应用凭证 |
| `/BACKEND=deepseek\|claude\|codex` | 回答后端，默认 `deepseek` |
| `/CLICOMMAND` | 本机 CLI 命令，默认随后端取 `claude` / `codex` |
| `/DEEPSEEKKEY`、`/DEEPSEEKMODEL` | DeepSeek Key 与模型，默认 `deepseek-chat` |
| `/TRUSTMODE`、`/ALLOWEDUSERS` | 信任策略（`owner`/`allowlist`/`any`）与白名单 open_id |
| `/TASKS=""` | 静默安装后，通过「开始 → 页边答 → 启动页边答」手动启动 |

安装器将这些配置写入本机 `.env`。机器人运行时使用 App ID 和 App Secret 向飞书认证。静默安装的参数可能出现在进程命令行和 PowerShell 历史里，共享电脑上建议双击使用安装向导。

### 自己打包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-installer.ps1
```

脚本会下载 Python 3.12 嵌入式运行时、安装依赖，再调用 Inno Setup 6 编译，产物在 `installer\Output\`。首次构建需要联网；找不到 Inno Setup 时会尝试用 winget 安装。改版本号：`-AppVersion 0.2.0`。

## 从源码运行（Windows）

**1. 创建飞书应用** —— 按 [docs/feishu-setup.md](docs/feishu-setup.md) 配置。最后需要 app ID 和 app secret，并且要发布一个启用了评论事件、长连接模式的版本。

**2. 拉代码、装依赖**

```powershell
git clone https://github.com/Aries-441/margin-reply.git
cd margin-reply
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

注册计划任务 `MarginReply`：登录自启、单实例、异常退出后自动重试。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall-task.ps1   # 停止并删除任务
```

更多操作见 [docs/deploy-with-ai.md](docs/deploy-with-ai.md) 的 Phase 5。

## 让 AI 帮你部署

仓库里有一份**写给 AI 助手看的**部署手册，每一阶段都有验收判据：[docs/deploy-with-ai.md](docs/deploy-with-ai.md)。

把下面这段丢给 Claude Code、Codex 或带文件访问能力的 ChatGPT：

```text
在这台 Windows 机器上部署 https://github.com/Aries-441/margin-reply 。
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
| `FEISHU_COMMENT_BOT_AGENT_COMMAND` | 所选后端名称 | 可选，用于指定本机 CLI 可执行命令（只支持 `.exe`） |
| `FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY` | — | 后端为 `deepseek` 时必填 |
| `FEISHU_COMMENT_BOT_DEEPSEEK_MODEL` | `deepseek-chat` | DeepSeek 模型名 |
| `FEISHU_COMMENT_BOT_TRUST_MODE` | `owner` | `owner` 只回答文档所有者；`allowlist` 只回答白名单；`any` 任何人 |
| `FEISHU_COMMENT_BOT_ALLOWED_USERS` | 空 | `allowlist` 模式下的 open_id，逗号分隔 |

### 谁能使用

- **`owner`（默认）** —— 只回答文档所有者的 @。直接安装就能用，适合「机器人只加进我自己的文档」的场景。
- **`allowlist`** —— 只回答 `FEISHU_COMMENT_BOT_ALLOWED_USERS` 里的 open_id。名单为空时**全部拒绝**；模式值拼错也全部拒绝。
- **`any`** —— 任何能 @ 机器人的人都回答。只有在你完全信任文档评论者时再用。

想限定为只有你本人：

1. 让机器人正常回答你一次（或你被忽略时），在 `logs\bot.log` 里找你的 open_id（`ou_` 开头；回复日志是 `(by ou_...)`，忽略日志是 `is not allowed ...`）。
2. 在 `.env` 里写：

```dotenv
FEISHU_COMMENT_BOT_TRUST_MODE=allowlist
FEISHU_COMMENT_BOT_ALLOWED_USERS=ou_你的open_id
```

3. 重启机器人（或重启计划任务）。被忽略的评论已经记为处理过，改完配置后需要重新发一条评论。

所有者信息会缓存 10 分钟；`owner` 模式下查询失败会直接拒绝回答，不会退化成放行。

切换到本机 CLI：

```powershell
$env:FEISHU_COMMENT_BOT_AGENT_BACKEND='claude'
$env:FEISHU_COMMENT_BOT_AGENT_COMMAND='claude'
.\.venv\Scripts\python.exe -u bot.py
```

**只支持 `.exe`。** npm 在 Windows 上装出来的 `claude.cmd` / `codex.cmd` 是批处理脚本，命令行会重新解析参数——评论正文里一个 `&` 就可能变成一条命令，`%VAR%` 会被展开。机器人检测到批处理会直接报错，请改为指向 CLI 的原生 `.exe`（Claude Code 的原生安装就是 `claude.exe`），或用一个 `.exe` 包装器。

## 日志与测试

- `logs\bot.log` —— 机器人日志（UTF-8，5 MB × 3 轮转），崩溃和飞书接口错误都在这里。
- `logs\runner.log` —— `supervisor.py` 写的启动 / 退出 / 重试记录。
- 使用安装包时，打开「开始 → 页边答 → 查看页边答日志」即可查看 `%LocalAppData%\MarginReply\logs`。
- 运行离线测试：`.\.venv\Scripts\python.exe -m unittest discover -v`。

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

它同样挡不住提示词注入：见上面的[安全提醒](#安全提醒请先读)。

## 许可证

[MIT](LICENSE)
