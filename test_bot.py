import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import bot


class StubClient:
    def __init__(self, replies=None):
        self.replies = replies or []

    def list_replies(self, file_token, comment_id, file_type):
        return self.replies


class FakeFeishuClient:
    def __init__(self, comment, owner="ou_user"):
        self.comment_data = comment
        self.owner = owner
        self.owner_calls = 0
        self.comments = []
        self.replied = []
        self.whole_comments = []

    def bot_open_id(self):
        return "ou_bot"

    def document_owner(self, file_token, file_type):
        self.owner_calls += 1
        if isinstance(self.owner, Exception):
            raise self.owner
        return self.owner

    def comment(self, file_token, comment_id, file_type):
        self.comments.append((file_token, comment_id, file_type))
        return self.comment_data

    def document_text(self, file_token):
        return "文档正文"

    def list_replies(self, file_token, comment_id, file_type):
        return []

    def reply_comment(self, file_token, file_type, comment_id, text):
        self.replied.append((file_token, file_type, comment_id, text))

    def add_whole_comment(self, file_token, file_type, text):
        self.whole_comments.append((file_token, file_type, text))


class BotTest(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self._old_seen = bot.SEEN
        bot.SEEN = Path(self._temp.name) / "seen.json"
        # 测试使用固定的信任策略，避免本机环境变量影响结果。
        env = patch.dict(os.environ, {
            "FEISHU_COMMENT_BOT_TRUST_MODE": "owner",
            "FEISHU_COMMENT_BOT_ALLOWED_USERS": "",
        })
        env.start()
        self.addCleanup(env.stop)

    def tearDown(self):
        bot.SEEN = self._old_seen
        self._temp.cleanup()

    def test_text_extraction(self):
        self.assertEqual(
            bot.extract_text({"elements": [{"text_run": {"text": "你好"}}]}), "你好"
        )
        self.assertEqual(bot.extract_text(json.dumps({"elements": [{"text_run": {"text": "问"}}]})), "问")

    def test_text_extraction_ignores_mentions(self):
        content = {
            "elements": [
                {"type": "person", "person": {"user_id": "ou_bot"}},
                {"type": "text_run", "text_run": {"text": "这段什么意思？"}},
            ]
        }
        self.assertEqual(bot.extract_text(content), "这段什么意思？")

    def test_dedupe_round_trip(self):
        self.assertFalse(bot.already_seen("event-1"))
        bot.mark_seen("event-1")
        self.assertTrue(bot.already_seen("event-1"))

    def test_dedupe_expires_old_entries(self):
        bot.SEEN.write_text(
            json.dumps({"old": time.time() - bot.SEEN_TTL_SECONDS - 1}), encoding="utf-8"
        )
        self.assertFalse(bot.already_seen("old"))

    def test_add_reply_uses_the_reply_not_the_parent_comment(self):
        comment = {
            "reply_list": {
                "replies": [
                    {"reply_id": "r0", "content": {"elements": [{"text_run": {"text": "原评论"}}]}},
                    {"reply_id": "r1", "content": {"elements": [{"text_run": {"text": "追问"}}]}},
                ]
            }
        }
        self.assertEqual(
            bot.comment_text(StubClient(), "file", "docx", "c1", comment, "r1", "add_reply"),
            "追问",
        )
        self.assertEqual(
            bot.comment_text(StubClient(), "file", "docx", "c1", comment, "", "add_comment"),
            "原评论",
        )

    def test_add_reply_falls_back_to_paginated_replies(self):
        comment = {"reply_list": {"has_more": True, "replies": []}}
        stub = StubClient([{"reply_id": "r9", "content": {"elements": [{"text_run": {"text": "后面的追问"}}]}}])
        self.assertEqual(
            bot.comment_text(stub, "file", "docx", "c1", comment, "r9", "add_reply"),
            "后面的追问",
        )

    def test_clip_document(self):
        self.assertEqual(bot.clip_document("abc", 10), "abc")
        clipped = bot.clip_document("a" * 100, 20)
        self.assertIn("中间内容省略", clipped)
        self.assertLess(len(clipped), 100)

    def test_truncate_reply(self):
        self.assertEqual(bot.truncate_reply("short", 10), "short")
        self.assertIn("已截断", bot.truncate_reply("x" * 20, 10))

    def test_plain_text_strips_markdown(self):
        text = "**结论**\n\n> 引用\n\n`code`\n\n## 标题\n\n[链接](https://example.com)"
        result = bot.plain_text(text)
        self.assertNotIn("**", result)
        self.assertNotIn("> ", result)
        self.assertNotIn("`", result)
        self.assertNotIn("##", result)
        self.assertIn("结论", result)
        self.assertIn("链接（https://example.com）", result)

    def test_whole_comment_chunks_at_1000_chars(self):
        elements = bot.whole_comment_elements("x" * 2500)
        self.assertEqual([len(item["text"]) for item in elements], [1000, 1000, 500])

    def test_text_run_elements_chunk(self):
        elements = bot.text_run_elements("x" * 1500)
        self.assertEqual([len(item["text_run"]["text"]) for item in elements], [1000, 500])

    @staticmethod
    def make_event(notice_meta=None):
        event = {
            "notice_meta": {
                "file_token": "file",
                "file_type": "docx",
                "notice_type": "add_comment",
                "from_user_id": {"open_id": "ou_user"},
                "to_user_id": {"open_id": "ou_bot"},
            },
            "comment_id": "c1",
            "is_mentioned": True,
        }
        event["notice_meta"].update(notice_meta or {})
        return event

    @staticmethod
    def make_comment(**overrides):
        comment = {
            "is_solved": False,
            "is_whole": False,
            "reply_list": {
                "replies": [
                    {
                        "reply_id": "r1",
                        "content": {"elements": [{"text_run": {"text": "这是什么？"}}]},
                    }
                ]
            },
        }
        comment.update(overrides)
        return comment

    def test_process_comment_replies_with_file_type(self):
        fake = FakeFeishuClient(self.make_comment())
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="这是答案"):
            bot.process_comment("evt-1", self.make_event())
        self.assertEqual(fake.replied, [("file", "docx", "c1", "这是答案")])
        self.assertTrue(bot.already_seen("evt-1"))

    def test_process_comment_skips_solved(self):
        fake = FakeFeishuClient(self.make_comment(is_solved=True))
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-2", self.make_event())
        self.assertEqual(fake.replied, [])
        self.assertTrue(bot.already_seen("evt-2"))

    def test_process_comment_skips_unmentioned(self):
        fake = FakeFeishuClient(self.make_comment())
        event = self.make_event({"to_user_id": {"open_id": "ou_other"}})
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-3", event)
        self.assertEqual(fake.replied, [])

    def test_stranger_is_ignored_in_owner_mode(self):
        fake = FakeFeishuClient(self.make_comment())
        event = self.make_event({"from_user_id": {"open_id": "ou_stranger"}})
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-stranger", event)
        self.assertEqual(fake.replied, [])
        self.assertEqual(fake.comments, [])  # 连评论内容都不去查
        self.assertTrue(bot.already_seen("evt-stranger"))

    def test_allowlist_overrides_owner(self):
        fake = FakeFeishuClient(self.make_comment())
        event = self.make_event({"from_user_id": {"open_id": "ou_colleague"}})
        with patch.dict(os.environ, {
            "FEISHU_COMMENT_BOT_TRUST_MODE": "allowlist",
            "FEISHU_COMMENT_BOT_ALLOWED_USERS": "ou_me, ou_colleague",
        }), patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="这是答案"):
            bot.process_comment("evt-allow", event)
        self.assertEqual(fake.replied, [("file", "docx", "c1", "这是答案")])
        self.assertEqual(fake.owner_calls, 0)  # 白名单命中就不查所有者

    def test_empty_allowlist_denies_everyone(self):
        fake = FakeFeishuClient(self.make_comment())
        with patch.dict(os.environ, {
            "FEISHU_COMMENT_BOT_TRUST_MODE": "allowlist",
            "FEISHU_COMMENT_BOT_ALLOWED_USERS": "",
        }), patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-empty", self.make_event())
        self.assertEqual(fake.replied, [])

    def test_unknown_trust_mode_denies_everyone(self):
        fake = FakeFeishuClient(self.make_comment())
        with patch.dict(os.environ, {"FEISHU_COMMENT_BOT_TRUST_MODE": "trusted"}), \
                patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-typo", self.make_event())
        self.assertEqual(fake.replied, [])

    def test_any_mode_allows_stranger(self):
        fake = FakeFeishuClient(self.make_comment())
        event = self.make_event({"from_user_id": {"open_id": "ou_stranger"}})
        with patch.dict(os.environ, {"FEISHU_COMMENT_BOT_TRUST_MODE": "any"}), \
                patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="这是答案"):
            bot.process_comment("evt-any", event)
        self.assertEqual(fake.replied, [("file", "docx", "c1", "这是答案")])

    def test_owner_lookup_failure_denies(self):
        fake = FakeFeishuClient(self.make_comment(), owner=RuntimeError("boom"))
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-owner-fail", self.make_event())
        self.assertEqual(fake.replied, [])

    def test_non_docx_keeps_unsupported_reply(self):
        # 非 docx 不调用模型，也不受信任策略影响。
        fake = FakeFeishuClient(self.make_comment())
        event = self.make_event({
            "file_type": "sheet",
            "from_user_id": {"open_id": "ou_stranger"},
        })
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-sheet", event)
        self.assertEqual(fake.replied, [("file", "sheet", "c1", bot.UNSUPPORTED_DOC_REPLY)])
        self.assertEqual(fake.owner_calls, 0)

    def test_whole_comment_is_gated_too(self):
        fake = FakeFeishuClient(self.make_comment(is_whole=True))
        event = self.make_event({"from_user_id": {"open_id": "ou_stranger"}})
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="不该出现"):
            bot.process_comment("evt-whole-stranger", event)
        self.assertEqual(fake.whole_comments, [])

    def test_command_backend_resolves_command_on_path(self):
        # 裸命令名 CreateProcess 找不到，必须先按 PATH 解析成完整路径。
        completed = type("R", (), {"returncode": 0, "stdout": "回答\n", "stderr": ""})()
        with patch.dict(os.environ, {
            "FEISHU_COMMENT_BOT_AGENT_BACKEND": "claude",
            "FEISHU_COMMENT_BOT_AGENT_COMMAND": "claude",
        }), patch.object(bot.shutil, "which", return_value=r"C:\tools\claude.exe") as which, \
                patch.object(bot.subprocess, "run", return_value=completed) as run:
            result = bot.answer("问题", "正文")
        which.assert_called_once_with("claude")
        self.assertEqual(result, "回答")
        self.assertEqual(run.call_args[0][0][0], r"C:\tools\claude.exe")
        self.assertEqual(run.call_args[0][0][1:], ["-p", bot.build_prompt("问题", "正文", bot.MAX_COMMAND_DOC_CHARS)])

    def test_codex_exec_reads_utf8_prompt_from_stdin(self):
        script = Path(self._temp.name) / "fake codex.py"
        script.write_text(
            'import sys\n'
            'assert sys.argv[1:] == ["--profile", "example", "exec", "--skip-git-repo-check", '
            '"--sandbox", "read-only", "-"]\n'
            'sys.stdout.buffer.write(sys.stdin.buffer.read())\n',
            encoding="utf-8",
        )
        question, document = "这段是什么意思？", "第一行\n第二行 🌱"
        with patch.dict(os.environ, {
            "FEISHU_COMMENT_BOT_AGENT_BACKEND": "codex",
            "FEISHU_COMMENT_BOT_AGENT_COMMAND": f'"{sys.executable}" "{script}" --profile example',
        }):
            self.assertEqual(bot.answer(question, document),
                             bot.build_prompt(question, document, bot.MAX_COMMAND_DOC_CHARS))

    def test_command_backend_reports_missing_command(self):
        # 报错里要带上命令名，否则 bot.log 只有 WinError 2。
        with patch.object(bot.shutil, "which", return_value=None):
            with self.assertRaises(RuntimeError) as raised:
                bot.resolve_command("clad")
        self.assertIn("clad", str(raised.exception))

    @unittest.skipUnless(os.name == "nt", "Windows 路径规则")
    def test_command_backend_rejects_batch_files(self):
        # .cmd/.bat 会由 cmd.exe 重新解析参数：正文里的 & 会变成命令。
        with patch.object(bot.shutil, "which", return_value=r"C:\npm\codex.cmd"):
            with self.assertRaises(RuntimeError) as raised:
                bot.resolve_command("codex")
        self.assertIn("batch file", str(raised.exception))

    @unittest.skipUnless(os.name == "nt", "Windows 路径规则")
    def test_windows_command_path_keeps_backslashes_and_spaces(self):
        executable = Path(self._temp.name) / "CLI tools" / "codex.exe"
        executable.parent.mkdir()
        executable.touch()
        self.assertEqual(bot.split_command(str(executable)), [str(executable)])
        self.assertEqual(
            bot.split_command(r'"C:\Program Files\Claude\claude.exe" -p'),
            [r"C:\Program Files\Claude\claude.exe", "-p"],
        )
        self.assertEqual(
            bot.split_command(r"C:\tools\claude.exe -p"),
            [r"C:\tools\claude.exe", "-p"],
        )

    def test_process_whole_comment_uses_new_comment(self):
        fake = FakeFeishuClient(self.make_comment(is_whole=True))
        with patch.object(bot, "get_client", return_value=fake), \
                patch.object(bot, "answer", return_value="整篇回答"):
            bot.process_comment("evt-4", self.make_event())
        self.assertEqual(fake.replied, [])
        self.assertEqual(fake.whole_comments, [("file", "docx", "整篇回答")])


if __name__ == "__main__":
    unittest.main()
