"""iOS 运行时补丁（随 App 分发，安装 Python 运行时后写入 site-packages）。

这个 CPython 构建（python.org iOS 版）把进程创建整个禁掉了：
    subprocess.Popen(...) -> OSError(45, "ios does not support processes")
    os.fork()             -> 同
所以 pip 装包、调用外部命令、跑子进程构建全都不可用。

但 iOS 并不是不能起进程，只是不能 fork —— posix_spawn 是允许的（App 自己就是
这么起 codex / bash 的）。这里用 os.posix_spawn 顶上 subprocess.Popen，
支持 run/check_output/call/check_call 和 Popen 的常用参数。

另外补上 CA 证书：这个构建没有内置根证书，HTTPS 一律
CERTIFICATE_VERIFY_FAILED。默认指向同目录的 cacert.pem（安装器一起放进来），
用户已经设了 SSL_CERT_FILE 就不覆盖。
"""
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_ca = os.path.join(_here, "cacert.pem")
if os.path.exists(_ca) and not os.environ.get("SSL_CERT_FILE"):
    os.environ["SSL_CERT_FILE"] = _ca
    os.environ.setdefault("REQUESTS_CA_BUNDLE", _ca)
    os.environ.setdefault("CURL_CA_BUNDLE", _ca)

if sys.platform == "ios":
    import signal
    import subprocess
    import tempfile

    class Popen(subprocess.Popen):  # 只借用它的类型身份，__init__ 全接管
        def __init__(self, args, bufsize=-1, executable=None, stdin=None,
                     stdout=None, stderr=None, preexec_fn=None, close_fds=True,
                     shell=False, cwd=None, env=None, universal_newlines=None,
                     startupinfo=None, creationflags=0, restore_signals=True,
                     start_new_session=False, pass_fds=(), *, text=None,
                     encoding=None, errors=None, **rest):
            if isinstance(args, (str, bytes)):
                argv = [args.decode() if isinstance(args, bytes) else args]
                if shell:
                    argv = [_shell(), "-c", argv[0]]
            else:
                argv = [a.decode() if isinstance(a, bytes) else str(a) for a in args]
            if executable:
                argv = [executable] + argv[1:]

            if shell and not (isinstance(args, (str, bytes))):
                argv = [_shell(), "-c", " ".join(argv)]

            self._tmp = []
            self.args = argv
            self.text_mode = bool(text or encoding or errors or universal_newlines)
            self.encoding = encoding or "utf-8"
            self.errors = errors or "strict"

            def _fd(stream, mode):
                """把 stream 折成 posix_spawn 的 file_actions 三元组。"""
                if stream is None:
                    return None, None
                if hasattr(stream, "fileno"):
                    try:
                        return ("dup", stream.fileno()), None
                    except Exception:
                        pass
                f = tempfile.TemporaryFile(mode=mode)
                self._tmp.append(f)
                return ("dup", f.fileno()), f

            self._in, self._in_file = _fd(stdin if stdin is not None else None, "w+b")
            if stdin is not None and hasattr(stdin, "write") and not hasattr(stdin, "fileno"):
                pass
            self._out, self._out_file = _fd(stdout, "w+b")
            self._err, self._err_file = _fd(stderr, "w+b")
            # 只有"确实要捕获"（PIPE 之类没有真实 fd 的流）才读回临时文件；
            # stdout=None 表示继承父进程，绝不能被当成捕获。
            self._capture_out = stdout is not None and not hasattr(stdout, "fileno")
            self._capture_err = stderr is not None and not hasattr(stderr, "fileno")

            if isinstance(stdin, (bytes, str)):
                data = stdin.encode() if isinstance(stdin, str) else stdin
                f = tempfile.TemporaryFile()
                f.write(data)
                f.flush()
                f.seek(0)
                self._tmp.append(f)
                self._in = ("dup", f.fileno())

            if cwd:
                # posix_spawn 没有"先 chdir"的通道，用 sh 包一层
                argv = [_shell(), "-c", 'cd "$0" || exit 1; exec "$@"', cwd] + argv

            fa = []
            for tgt, spec in ((0, self._in), (1, self._out), (2, self._err)):
                if spec is None:
                    continue  # 不传 -> 继承父进程（和 subprocess 语义一致）
                fa.append((os.POSIX_SPAWN_DUP2, spec[1], tgt))

            kid_env = None if env is None else {k: v for k, v in env.items()
                                               if v is not None}
            spawn = os.posix_spawnp if os.sep not in argv[0] else os.posix_spawn
            self.pid = spawn(argv[0], argv, kid_env, file_actions=fa)
            self.returncode = None
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
            self._closed = False

        # —— 流接口 ——
        def communicate(self, input=None, timeout=None):
            if input is not None and self._in_file is not None:
                data = input.encode() if isinstance(input, str) else input
                self._in_file.write(data)
                self._in_file.flush()
            try:
                self.wait(timeout)
            finally:
                out = self._read(self._out_file) if self._capture_out else b""
                err = self._read(self._err_file) if self._capture_err else b""
                self._cleanup()
            if self.text_mode:
                return out.decode(self.encoding, self.errors), err.decode(
                    self.encoding, self.errors)
            return out, err

        def _read(self, f):
            if f is None:
                return b""
            try:
                f.seek(0)
                return f.read()
            except Exception:
                return b""

        def _cleanup(self):
            for f in self._tmp:
                try:
                    f.close()
                except Exception:
                    pass
            self._tmp = []

        def wait(self, timeout=None):
            if self.returncode is not None:
                return self.returncode
            if timeout is None:
                _, status = os.waitpid(self.pid, 0)
            else:
                import time
                end = time.time() + timeout
                while True:
                    pid, status = os.waitpid(self.pid, os.WNOHANG)
                    if pid:
                        break
                    if time.time() > end:
                        raise subprocess.TimeoutExpired(self.args, timeout)
                    time.sleep(0.02)
            self.returncode = self._exit_code(status)
            return self.returncode

        @staticmethod
        def _exit_code(status):
            if os.WIFEXITED(status):
                return os.WEXITSTATUS(status)
            if os.WIFSIGNALED(status):
                return -os.WTERMSIG(status)
            return status

        def poll(self):
            if self.returncode is not None:
                return self.returncode
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if not pid:
                return None
            self.returncode = self._exit_code(status)
            return self.returncode

        def send_signal(self, sig):
            os.kill(self.pid, sig)

        def terminate(self):
            self.send_signal(signal.SIGTERM)

        def kill(self):
            self.send_signal(signal.SIGKILL)

        def __enter__(self):
            return self

        def __exit__(self, *a):
            self._cleanup()
            return False

    subprocess.Popen = Popen

# --- platform 兼容：iOS 版 CPython 的 platform.uname() 要走 objc 桥，
# 在非 pythonista 环境里 get_platform_ios() 会抛 AttributeError（systemName 为 None），
# pip / setuptools 一调用就崩。这里把 uname/system/machine 固定成 Darwin/arm64。
try:
    import platform as _platform

    def _fixed_uname(_cache={}):
        return _platform.uname_result("Darwin", "iPhone", "24.0.0", "Darwin Kernel", "arm64")

    _platform.uname = _fixed_uname
    _platform.system = lambda: "Darwin"
    _platform.machine = lambda: "arm64"
    try:
        _platform.ios_ver = lambda *a, **k: ("iOS", "18.0", "iPhone", True)
    except Exception:
        pass
except Exception:
    pass
