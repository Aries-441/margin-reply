"""常驻守护进程，负责拉起 bot.py 并在异常退出后重试。

由计划任务通过 runtime\\pythonw.exe 启动：pythonw 是 GUI 子系统程序，
不会创建控制台窗口，因此登录/启动时不会再弹出 PowerShell 或终端窗口。
手动排查时可以用 python.exe 前台运行本文件，日志会同时打印到控制台。

守护进程负责以下操作：
- 命名互斥体保证单实例，避免计划任务重复触发时抢同一个飞书长连接；
- 机器人稳定运行 10 分钟后再挂掉，重试间隔回到 15 秒，否则指数退避到 5 分钟；
- `.stop-runner` 标记用于卸载/升级前优雅停止；
- 机器人自己的日志在 logs\\bot.log，本进程写 logs\\runner.log。
"""

from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import os
import subprocess
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOG_DIR = ROOT / "logs"
RUNNER_LOG = LOG_DIR / "runner.log"
STARTUP_LOG = LOG_DIR / "bot.startup.log"
STOP_FLAG = ROOT / ".stop-runner"
MUTEX_NAME = "Local\\margin-reply"

RESTART_DELAY_SECONDS = 15
MAX_RESTART_DELAY_SECONDS = 300
STABLE_RUN_SECONDS = 600

CREATE_NO_WINDOW = 0x08000000

# 让机器人随守护进程一起结束：即使守护进程被任务计划程序强杀，
# 子进程也会在 job 句柄关闭时被系统回收，不会留下孤儿 bot 抢长连接。
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9


class _JobBasicLimits(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", wt.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wt.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wt.DWORD),
        ("SchedulingClass", wt.DWORD),
    ]


class _IoCounters(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_uint64),
        ("WriteOperationCount", ctypes.c_uint64),
        ("OtherOperationCount", ctypes.c_uint64),
        ("ReadTransferCount", ctypes.c_uint64),
        ("WriteTransferCount", ctypes.c_uint64),
        ("OtherTransferCount", ctypes.c_uint64),
    ]


class _JobExtendedLimits(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _JobBasicLimits),
        ("IoInfo", _IoCounters),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


_kernel32 = ctypes.windll.kernel32
_kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wt.BOOL, wt.LPCWSTR]
_kernel32.CreateMutexW.restype = wt.HANDLE
_kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wt.LPCWSTR]
_kernel32.CreateJobObjectW.restype = wt.HANDLE
_kernel32.SetInformationJobObject.argtypes = [
    wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD
]
_kernel32.SetInformationJobObject.restype = wt.BOOL
_kernel32.AssignProcessToJobObject.argtypes = [wt.HANDLE, wt.HANDLE]
_kernel32.AssignProcessToJobObject.restype = wt.BOOL
_kernel32.CloseHandle.argtypes = [wt.HANDLE]

ERROR_ALREADY_EXISTS = 183

# 句柄必须一直存在，回收就意味着互斥体/Job 失效。
_mutex_handle = None
_job_handle = None


def log(message: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + message
    try:
        with open(RUNNER_LOG, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass
    # pythonw 下 sys.stdout 是 None；前台手动运行时顺便打印一份。
    if sys.stdout is not None:
        try:
            print(line, flush=True)
        except (OSError, ValueError):
            pass


def acquire_single_instance() -> bool:
    global _mutex_handle
    _mutex_handle = _kernel32.CreateMutexW(None, False, MUTEX_NAME)
    if not _mutex_handle:
        return True  # 创建互斥体失败时宁可继续跑，也不要静默不启动。
    if _kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
        _kernel32.CloseHandle(_mutex_handle)
        _mutex_handle = None
        return False
    return True


def create_job_object():
    global _job_handle
    _job_handle = _kernel32.CreateJobObjectW(None, None)
    if not _job_handle:
        return None
    info = _JobExtendedLimits()
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    ok = _kernel32.SetInformationJobObject(
        _job_handle,
        JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if not ok:
        _kernel32.CloseHandle(_job_handle)
        _job_handle = None
        return None
    return _job_handle


def python_for_bot() -> Path:
    exe = Path(sys.executable)
    # 运行时和 .venv 都同时提供 python.exe / pythonw.exe。优先 pythonw：
    # 子进程也不需要控制台；没有就退回当前解释器并用 CREATE_NO_WINDOW。
    pythonw = exe.with_name("pythonw.exe")
    return pythonw if pythonw.exists() else exe


def start_bot():
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    stderr_file = open(STARTUP_LOG, "w", encoding="utf-8", errors="replace")
    try:
        process = subprocess.Popen(
            [str(python_for_bot()), "-u", "bot.py"],
            cwd=str(ROOT),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=stderr_file,
            creationflags=CREATE_NO_WINDOW,
        )
    except BaseException:
        stderr_file.close()
        raise
    if _job_handle:
        try:
            _kernel32.AssignProcessToJobObject(_job_handle, process._handle)
        except (OSError, OverflowError):
            pass
    return process, stderr_file


def stop_flag_set() -> bool:
    return STOP_FLAG.exists()


def clear_stop_flag() -> None:
    try:
        STOP_FLAG.unlink()
    except FileNotFoundError:
        pass


def wait_for_bot(process) -> bool:
    """等机器人退出；期间看到停止标记就优雅结束它。返回是否因停止而退出。"""
    while process.poll() is None:
        if stop_flag_set():
            log("[run] stop requested, stopping bot")
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            return True
        time.sleep(0.5)
    return False


def sleep_unless_stopped(seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if stop_flag_set():
            return True
        time.sleep(min(0.25, max(0.0, deadline - time.monotonic())))
    return False


def run() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    if not acquire_single_instance():
        return 0

    # 拿到互斥体后才清理上一次停止留下的标记；重复启动不能吞掉当前实例的停止请求。
    clear_stop_flag()

    create_job_object()

    delay = RESTART_DELAY_SECONDS
    while True:
        if stop_flag_set():
            clear_stop_flag()
            log("[run] stop requested, exiting")
            return 0

        started = time.monotonic()
        log("[run] starting bot")
        process, stderr_file = start_bot()
        try:
            stopped = wait_for_bot(process)
        finally:
            stderr_file.close()

        if stopped:
            clear_stop_flag()
            log("[run] stop requested, exiting")
            return 0

        ran = time.monotonic() - started
        log(f"[run] bot exited code={process.returncode} after {ran:,.0f}s")

        if ran > STABLE_RUN_SECONDS:
            delay = RESTART_DELAY_SECONDS
        if sleep_unless_stopped(delay):
            clear_stop_flag()
            log("[run] stop requested, exiting")
            return 0
        delay = min(delay * 2, MAX_RESTART_DELAY_SECONDS)


def main() -> int:
    try:
        return run()
    except KeyboardInterrupt:
        clear_stop_flag()
        return 0
    except Exception:
        log("[run] supervisor crashed:\n" + traceback.format_exc())
        return 1


if __name__ == "__main__":
    sys.exit(main())
