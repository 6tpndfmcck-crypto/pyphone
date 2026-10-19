import sys, json, traceback, threading, builtins

# Load datetime on the interpreter's main thread before user code or native
# packages (such as NumPy) request its C API from a worker thread.
import datetime


class _Out:
    def __init__(self):
        self.buf = []
        self.lock = threading.Lock()

    def write(self, s):
        with self.lock:
            self.buf.append(s)
        return len(s)

    def flush(self):
        pass


_out = _Out()
sys.stdout = _out
sys.stderr = _out

import ui

_run_tid = [0]
_cb_tid = [0]
_prompt = [None]
_reply = [""]
_got = threading.Event()


def _input(prompt=""):
    prompt = str(prompt)
    _reply[0] = ""
    _got.clear()
    _prompt[0] = prompt
    ui._seq[0] += 1
    try:
        while not _got.wait(0.1):
            pass
        text = _reply[0]
    finally:
        _prompt[0] = None
    print(prompt + text)
    return text


builtins.input = _input


def _worker(code, started):
    _run_tid[0] = threading.get_ident()
    started.set()
    try:
        exec(compile(code, "<code>", "exec"), {"__name__": "__main__"})
    except KeyboardInterrupt:
        print("Stopped.")
    except BaseException:
        traceback.print_exc()
    finally:
        _run_tid[0] = 0


def run_code(code):
    if _run_tid[0]:
        print("Already running. Stop it first.")
        return ""
    ui._reset()
    started = threading.Event()
    threading.Thread(target=_worker, args=(code, started), daemon=True).start()
    started.wait(2)
    return ""


def input_reply(text):
    _reply[0] = text
    _got.set()
    return ""


def get_state(_=""):
    tid = _run_tid[0] or _cb_tid[0]
    return json.dumps({
        "widgets": ui._state(),
        "running": bool(tid),
        "prompt": _prompt[0],
        "tid": tid,
        "seq": ui._seq[0],
    })


def send_event(arg):
    d = json.loads(arg)
    if d["kind"] == "tap":
        _cb_tid[0] = threading.get_ident()
    try:
        ui._event(d["id"], d["kind"], d.get("value", ""))
    except KeyboardInterrupt:
        print("Stopped.")
    except BaseException:
        traceback.print_exc()
    finally:
        _cb_tid[0] = 0
    ui._seq[0] += 1
    return ""


def take_output(_=""):
    with _out.lock:
        s = "".join(_out.buf)
        _out.buf.clear()
    return s
