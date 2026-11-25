import io
import os
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

if os.name == "nt":
    import supervisor


@unittest.skipUnless(os.name == "nt", "The supervisor uses Windows process APIs")
class SupervisorTest(unittest.TestCase):
    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        root = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        self.stop_flag = root / ".stop-runner"
        self.stop_flag.touch()
        stack.enter_context(patch.multiple(supervisor, STOP_FLAG=self.stop_flag, LOG_DIR=root))
        stack.enter_context(patch.object(supervisor, "log"))
        stack.enter_context(patch.object(supervisor, "create_job_object"))
        self.start_bot = stack.enter_context(patch.object(supervisor, "start_bot"))

    def test_new_instance_starts_with_a_stale_stop_flag(self):
        self.start_bot.return_value = (object(), io.StringIO())
        with (
            patch.object(supervisor, "acquire_single_instance", return_value=True),
            patch.object(supervisor, "wait_for_bot", return_value=True),
        ):
            self.assertEqual(supervisor.run(), 0)
        self.start_bot.assert_called_once_with()
        self.assertFalse(self.stop_flag.exists())

    def test_duplicate_instance_preserves_the_pending_stop_flag(self):
        with patch.object(supervisor, "acquire_single_instance", return_value=False):
            self.assertEqual(supervisor.run(), 0)
        self.start_bot.assert_not_called()
        self.assertTrue(self.stop_flag.exists())
