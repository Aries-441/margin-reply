import json
import logging
import logging.handlers
import os
import queue
import re
import shlex
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import lark_oapi as lark
from dotenv import load_dotenv

BASE = "https://open.feishu.cn/open-apis"
ROOT = Path(__file__).resolve().parent
SEEN = ROOT / ".seen_events.json"
LOCK = threading.Lock()

SUPPORTED_DOC_TYPES = {"docx"}
UNSUPPORTED_DOC_REPLY = (
    "当前仅支持新版文档（docx）的评论问答，这份文档类型暂未接入。"
    " Only new-format docs (docx) are supported for now."
)
MAX_DOC_CHARS = 30_000
MAX_COMMAND_DOC_CHARS = 12_000
MAX_REPLY_CHARS = 4_000
MAX_PROMPT_CHARS = 20_000
WORKER_COUNT = 2
TOKEN_REFRESH_MARGIN_SECONDS = 300
SEEN_LIMIT = 2_000
SEEN_TTL_SECONDS = 7 * 24 * 60 * 60
TOKEN_ERROR_CODES = {99991661, 99991663, 99991668}

log = logging.getLogger("feishu-comment-bot")
load_dotenv(ROOT / ".env")


def setup_logging():
    # 只在真正运行时配置：测试导入本模块不应该写 logs/。
    log_dir = ROOT / "logs"
    log_dir.mkdir(exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            # 常驻运行时没有可见窗口，日志落盘用于排查。
            logging.handlers.RotatingFileHandler(
                log_dir / "bot.log", maxBytes=5_000_000, backupCount=3, encoding="utf-8"
            ),
            logging.StreamHandler(),
        ],
    )


class ApiError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(f"API failed: code={code} msg={message}")
        self.code = code


def http_json(url, method="GET", body=None, headers=None):
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    request_headers = {"Content-Type": "application/json; charset=utf-8"}
    request_headers.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=request_headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise ApiError(exc.code, detail[:500]) from exc
    if result.get("code", 0) != 0:
        raise ApiError(result.get("code"), result.get("msg", ""))
    return result


def required_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required environment variable: {name}")
    return value


class FeishuClient:
    def __init__(self):
        self.app_id = required_env("FEISHU_COMMENT_BOT_APP_ID")
        self.app_secret = required_env("FEISHU_COMMENT_BOT_APP_SECRET")
        self._token = None
        self._token_expires_at = 0.0
        self._bot_open_id = None
        self._lock = threading.Lock()

    def _refresh_token(self, force=False):
        with self._lock:
            if not force and self._token and time.time() < self._token_expires_at:
                return self._token
            result = http_json(BASE + "/auth/v3/tenant_access_token/internal", "POST", {
                "app_id": self.app_id, "app_secret": self.app_secret
            })
            expire = int(result.get("expire", 7200))
            self._token = result["tenant_access_token"]
            self._token_expires_at = time.time() + max(
                60, expire - TOKEN_REFRESH_MARGIN_SECONDS
            )
            return self._token

    def token(self):
        if self._token and time.time() < self._token_expires_at:
            return self._token
        return self._refresh_token()

    def request(self, path, method="GET", body=None, query=None):
        url = BASE + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        for attempt in (1, 2):
            headers = {
                "Authorization": "Bearer " + self.token(),
                "Content-Type": "application/json; charset=utf-8",
            }
            try:
                return http_json(url, method, body, headers)
            except ApiError as exc:
                # 租户 token 失效时刷新一次再重试；其他错误直接抛出。
                if attempt == 1 and exc.code in TOKEN_ERROR_CODES:
                    self._refresh_token(force=True)
                    continue
                raise

    def call(self, path, method="GET", body=None, query=None):
        return self.request(path, method, body, query).get("data", {})

    def bot_open_id(self):
        if self._bot_open_id:
            return self._bot_open_id
        # 该接口把 bot 放在顶层，没有 data 包装。
        result = self.request("/bot/v3/info")
        bot = result.get("bot") or (result.get("data") or {}).get("bot") or {}
        self._bot_open_id = bot.get("open_id", "")
        return self._bot_open_id

    def document_text(self, file_token):
        data = self.call(f"/docx/v1/documents/{file_token}/raw_content")
        return data.get("content", "")

    def comment(self, file_token, comment_id, file_type):
        # 单条 GET 接口在部分租户返回 1069307，改用官方批量查询接口。
        data = self.call(
            f"/drive/v1/files/{file_token}/comments/batch_query",
            "POST",
            {"comment_ids": [comment_id]},
            query={"file_type": file_type, "user_id_type": "open_id"},
        )
        items = data.get("items") or []
        return items[0] if items else {}

    def list_replies(self, file_token, comment_id, file_type):
        replies = []
        page_token = None
        while True:
            query = {"file_type": file_type, "page_size": 100, "user_id_type": "open_id"}
            if page_token:
                query["page_token"] = page_token
            data = self.call(
                f"/drive/v1/files/{file_token}/comments/{comment_id}/replies",
                query=query,
            )
            replies.extend(data.get("items") or [])
            if not data.get("has_more") or not data.get("page_token"):
                return replies
            page_token = data["page_token"]

    def reply_comment(self, file_token, file_type, comment_id, text):
        self.call(
            f"/drive/v1/files/{file_token}/comments/{comment_id}/replies",
            "POST",
            {"content": {"elements": text_run_elements(text)}},
            query={"file_type": file_type},
        )

    def add_whole_comment(self, file_token, file_type, text):
        # 整篇评论不能用 replies 接口，只能新建一条全文评论。
        self.call(
            f"/drive/v1/files/{file_token}/new_comments",
            "POST",
            {"file_type": file_type, "reply_elements": whole_comment_elements(text)},
        )


_CLIENT = None
_CLIENT_LOCK = threading.Lock()


def get_client():
    global _CLIENT
    with _CLIENT_LOCK:
        if _CLIENT is None:
            _CLIENT = FeishuClient()
        return _CLIENT


def text_run_elements(text):
    # 单个 text_run 也按 1000 字符切分，避开元素长度上限。
    chunks = [text[i:i + 1000] for i in range(0, len(text), 1000)] or [""]
    return [{"type": "text_run", "text_run": {"text": chunk}} for chunk in chunks[:100]]


def whole_comment_elements(text):
    # new_comments 的单个 text 元素上限 1000 字符。
    chunks = [text[i:i + 1000] for i in range(0, len(text), 1000)] or [""]
    return [{"type": "text", "text": chunk} for chunk in chunks[:100]]


def extract_text(value):
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except (ValueError, TypeError):
            return value
        return extract_text(parsed) if isinstance(parsed, (dict, list)) else value
    if isinstance(value, list):
        return "".join(extract_text(item) for item in value)
    if not isinstance(value, dict):
        return ""
    text_run = value.get("text_run")
    if isinstance(text_run, dict):
        return extract_text(text_run)
    if isinstance(value.get("text"), str):
        return value["text"]
    # @人、@文档链接不是用户的问题正文，跳过。
    if value.get("type") in ("person", "mention_user", "docs_link", "link"):
        return ""
    for key in ("elements", "content", "replies", "reply_list", "quote"):
        if key in value:
            return extract_text(value[key])
    return ""


def _seen_entries():
    try:
        raw = json.loads(SEEN.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(raw, dict):
        # 兼容旧版本写入的 list 格式。
        return {}
    cutoff = time.time() - SEEN_TTL_SECONDS
    return {
        key: float(timestamp)
        for key, timestamp in raw.items()
        if isinstance(timestamp, (int, float)) and timestamp >= cutoff
    }


def already_seen(key):
    if not key:
        return False
    with LOCK:
        return key in _seen_entries()


def mark_seen(key):
    if not key:
        return
    with LOCK:
        seen = _seen_entries()
        seen[key] = time.time()
        if len(seen) > SEEN_LIMIT:
            newest = sorted(seen.items(), key=lambda item: item[1])[-SEEN_LIMIT:]
            seen = dict(newest)
        SEEN.write_text(json.dumps(seen, ensure_ascii=False), encoding="utf-8")


def find_reply(replies, reply_id):
    for reply in replies:
        if reply.get("reply_id") == reply_id:
            return reply
    return None


def comment_text(client, file_token, file_type, comment_id, comment, reply_id, notice_type):
    reply_list = comment.get("reply_list") or {}
    replies = reply_list.get("replies") or []
    if notice_type == "add_reply" and reply_id:
        reply = find_reply(replies, reply_id)
        if reply is not None:
            return extract_text(reply.get("content"))
        if reply_list.get("has_more"):
            reply = find_reply(client.list_replies(file_token, comment_id, file_type), reply_id)
            if reply is not None:
                return extract_text(reply.get("content"))
        return ""
    # add_comment 的正文是 reply_list 的第一条。
    return extract_text(replies[0].get("content")) if replies else ""


def clip_document(text, limit):
    if len(text) <= limit:
        return text
    head = limit * 2 // 3
    tail = limit - head
    return text[:head] + "\n\n…（中间内容省略）…\n\n" + text[-tail:]


def truncate_reply(text, limit=MAX_REPLY_CHARS):
    if len(text) <= limit:
        return text
    return text[:limit].rstrip() + "\n\n…（回答过长，已截断）"


def build_prompt(question, document, document_limit):
    return f"""你是飞书文档阅读助手。只依据文档内容回答；不确定时明确说明。先给结论，再解释依据，必要时引用简短原文。
回答语言与用户提问语言一致：中文提问用中文，英文提问用英文。
输出纯文本，适合飞书评论框显示；不要使用 Markdown 标记（不要 **、#、>、反引号、表格）。分点用 1. 2. 3. 或 ·。

用户问题：{question}

文档全文：
{clip_document(document, document_limit)}"""


def plain_text(text):
    # 飞书评论的 text_run 不渲染 Markdown，这里做一次兜底清理。
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"__(.+?)__", r"\1", text)
    text = re.sub(r"`([^`\n]*)`", r"\1", text)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.MULTILINE)
    text = re.sub(r"^>\s?", "", text, flags=re.MULTILINE)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r"\1（\2）", text)
    return text


def answer(question, document):
    backend = os.getenv("FEISHU_COMMENT_BOT_AGENT_BACKEND", "deepseek").lower()
    if backend == "deepseek":
        return answer_with_deepseek(build_prompt(question, document, MAX_DOC_CHARS))
    return answer_with_command(backend, build_prompt(question, document, MAX_COMMAND_DOC_CHARS))


def answer_with_deepseek(prompt):
    result = http_json("https://api.deepseek.com/chat/completions", "POST", {
        "model": os.getenv("FEISHU_COMMENT_BOT_DEEPSEEK_MODEL", "deepseek-chat"),
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.2,
    }, {
        "Authorization": "Bearer " + required_env("FEISHU_COMMENT_BOT_DEEPSEEK_API_KEY"),
        "Content-Type": "application/json",
    })
    choices = result.get("choices") or []
    if not choices:
        raise RuntimeError("DeepSeek returned no choices")
    return (choices[0].get("message") or {}).get("content", "")


def answer_with_command(backend, prompt):
    # Windows 命令行长度有限，先把 prompt 截到安全范围。
    prompt = prompt[:MAX_PROMPT_CHARS]
    command = shlex.split(os.getenv("FEISHU_COMMENT_BOT_AGENT_COMMAND", backend))
    if not command:
        raise RuntimeError("FEISHU_COMMENT_BOT_AGENT_COMMAND is empty")
    process = subprocess.run(
        command + ["-p", prompt],
        capture_output=True, text=True, timeout=180,
    )
    if process.returncode != 0:
        raise RuntimeError(f"agent command failed: {process.stderr.strip()[:500]}")
    return process.stdout.strip()


def process_comment(event_id, event):
    meta = event.get("notice_meta") or {}
    file_token = meta.get("file_token") or ""
    file_type = meta.get("file_type") or ""
    notice_type = meta.get("notice_type") or ""
    comment_id = str(event.get("comment_id") or "")
    reply_id = str(event.get("reply_id") or "")
    if not file_token or not comment_id:
        return

    dedupe_key = event_id or f"{file_token}:{comment_id}:{reply_id}"
    if already_seen(dedupe_key):
        return
    if notice_type not in ("add_comment", "add_reply"):
        mark_seen(dedupe_key)
        return

    client = get_client()
    bot_id = client.bot_open_id()
    from_id = (meta.get("from_user_id") or {}).get("open_id")
    to_id = (meta.get("to_user_id") or {}).get("open_id")

    if from_id == bot_id:
        mark_seen(dedupe_key)
        return
    # bot 被 @ 时 to_user_id 就是 bot；极少数返回体没有 to_user_id 时退回 is_mentioned。
    if not (to_id == bot_id or (not to_id and event.get("is_mentioned"))):
        mark_seen(dedupe_key)
        return

    comment = client.comment(file_token, comment_id, file_type)
    if comment.get("is_solved"):
        log.info("Skip solved comment %s", comment_id)
        mark_seen(dedupe_key)
        return

    question = comment_text(
        client, file_token, file_type, comment_id, comment, reply_id, notice_type
    )
    if not question.strip():
        log.info("Skip comment %s: empty question", comment_id)
        mark_seen(dedupe_key)
        return

    if file_type in SUPPORTED_DOC_TYPES:
        reply = answer(question, client.document_text(file_token))
    else:
        reply = UNSUPPORTED_DOC_REPLY

    reply = truncate_reply(plain_text(reply.strip()))
    if not reply:
        log.info("Skip comment %s: empty answer", comment_id)
        mark_seen(dedupe_key)
        return

    if comment.get("is_whole"):
        client.add_whole_comment(file_token, file_type, reply)
    else:
        client.reply_comment(file_token, file_type, comment_id, reply)
    mark_seen(dedupe_key)
    log.info("Replied to comment %s in file %s", comment_id, file_token)


def on_comment(data):
    try:
        event_id = data.header.event_id if data.header else ""
        event = data.event if isinstance(data.event, dict) else json.loads(lark.JSON.marshal(data.event))
        WORK_QUEUE.put((event_id, event))
    except Exception:
        log.exception("Could not dispatch document comment event")


WORK_QUEUE = queue.Queue()


def worker():
    while True:
        event_id, event = WORK_QUEUE.get()
        try:
            process_comment(event_id, event)
        except Exception:
            # 不写去重记录，事件重投时可以再试一次。
            log.exception("Failed to process document comment")
        finally:
            WORK_QUEUE.task_done()


def main():
    setup_logging()
    load_dotenv(ROOT / ".env")
    app_id = required_env("FEISHU_COMMENT_BOT_APP_ID")
    app_secret = required_env("FEISHU_COMMENT_BOT_APP_SECRET")
    get_client()

    for index in range(WORKER_COUNT):
        threading.Thread(target=worker, name=f"comment-worker-{index}", daemon=True).start()

    handler = lark.EventDispatcherHandler.builder("", "").register_p2_customized_event(
        "drive.notice.comment_add_v1", on_comment
    ).build()
    client = lark.ws.Client(
        app_id, app_secret, event_handler=handler, log_level=lark.LogLevel.INFO
    )
    log.info("Starting Feishu comment bot long connection")
    client.start()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # 常驻模式下 stderr 不可见，崩溃原因必须写进日志文件。
        log.exception("Bot stopped unexpectedly")
        raise
