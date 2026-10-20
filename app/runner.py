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
_run_lock = threading.Lock()
_running = [False]
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
    with _run_lock:
        _run_tid[0] = threading.get_ident()
    started.set()
    try:
        exec(compile(code, "<code>", "exec"), {"__name__": "__main__"})
    except KeyboardInterrupt:
        print("Stopped.")
    except BaseException:
        traceback.print_exc()
    finally:
        with _run_lock:
            _run_tid[0] = 0
            _running[0] = False


def run_code(code):
    # Reserve the runner before starting the worker. Otherwise, two rapid Run
    # taps can both observe a zero thread ID before either worker starts.
    with _run_lock:
        if _running[0]:
            print("Already running. Stop it first.")
            return ""
        _running[0] = True

    ui._reset()
    started = threading.Event()
    worker = threading.Thread(target=_worker, args=(code, started), daemon=True)
    try:
        worker.start()
    except BaseException:
        with _run_lock:
            _running[0] = False
        raise

    if not started.wait(2):
        # A started thread may simply be waiting for a scheduling slot. Don't
        # clear the reservation while it could still begin executing.
        if not worker.is_alive():
            with _run_lock:
                _running[0] = False
            print("Could not start the Python worker.")
        else:
            print("Python worker startup is taking longer than expected.")
    return ""


def input_reply(text):
    _reply[0] = text
    _got.set()
    return ""


def get_state(_=""):
    tid = _run_tid[0] or _cb_tid[0]
    return json.dumps({
        "widgets": ui._state(),
        "running": bool(_running[0]),
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
