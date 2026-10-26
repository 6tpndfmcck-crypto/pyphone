import sys, json, traceback, threading, builtins, os, shutil, tempfile, zipfile, urllib.request, urllib.parse, shlex, ssl, difflib
from pathlib import Path
import importlib
import linecache
from collections import deque

# Load datetime on the interpreter's main thread before user code or native
# packages (such as NumPy) request its C API from a worker thread.
import datetime
try:
    import certifi
except ImportError:
    # Host-side smoke tests run before bundled iOS packages are on sys.path.
    certifi = None

_PYPI_SSL_CONTEXT = (
    ssl.create_default_context(cafile=certifi.where())
    if certifi is not None else ssl.create_default_context()
)


class _Out:
    MAX_PENDING = 200_000

    def __init__(self):
        self.buf = deque()
        self.size = 0
        self.trimmed = False
        self.lock = threading.Lock()

    def write(self, s):
        original_length = len(s)
        if not s:
            return 0
        with self.lock:
            if len(s) > self.MAX_PENDING:
                s = s[-self.MAX_PENDING:]
                self.trimmed = True
            self.buf.append(s)
            self.size += len(s)
            while self.size > self.MAX_PENDING:
                removed = self.buf.popleft()
                self.size -= len(removed)
                self.trimmed = True
        return original_length

    def flush(self):
        pass


_out = _Out()
sys.stdout = _out
sys.stderr = _out


# User files and pure-Python wheels live in the app's shared Documents folder.
# Binary/native wheels are rejected because iOS needs their extensions built
# and packaged as frameworks; ordinary PyPI wheels cannot safely do that here.
def _documents_root():
    documents = os.environ.get("PYPHONE_DOCUMENTS")
    if not documents:
        documents = os.path.join(os.path.expanduser("~"), "Documents")
    return Path(documents)


def _files_folder():
    folder = _documents_root() / "Files"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _package_folders():
    root = _documents_root()
    incoming = root / "Packages"
    archived = root / "Installed"
    installed = root / "InstalledPackages"
    for folder in (incoming, archived, installed):
        folder.mkdir(parents=True, exist_ok=True)
    _files_folder()
    return incoming, archived, installed


def _wheel_install_target(filename):
    if not filename.lower().endswith(".whl"):
        raise ValueError("Only .whl package files are supported.")
    fields = filename[:-4].split("-")
    if len(fields) < 5:
        raise ValueError("This doesn't look like a valid wheel filename.")
    python_tags, abi_tags, platform_tags = fields[-3:]
    supported_python = {"py3", "py" + str(sys.version_info.major) + str(sys.version_info.minor)}
    if not (set(python_tags.split(".")) & supported_python):
        raise ValueError("Wheel is for a different Python version.")
    if abi_tags != "none" or platform_tags != "any":
        raise ValueError("Only pure-Python wheels (none-any) are supported.")
    target_name = "-".join(fields[:-3])
    safe_name = "".join(c if c.isalnum() or c in "._-" else "_" for c in target_name)
    return safe_name or "package"


def _install_wheel(wheel_path, installed_root):
    target_name = _wheel_install_target(wheel_path.name)
    target = installed_root / target_name
    if target.exists():
        print("Package already installed; not reinstalling:", wheel_path.name)
        return False

    with zipfile.ZipFile(wheel_path, "r") as archive:
        entries = archive.infolist()
        if sum(entry.file_size for entry in entries) > 50 * 1024 * 1024:
            raise ValueError("Package expands beyond the 50 MB safety limit.")
        # Reject native extensions and unsafe paths before writing anything.
        for entry in entries:
            path = Path(entry.filename)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Package contains an unsafe file path.")
            suffix = path.suffix.lower()
            if suffix in {".so", ".dylib", ".dll", ".pyd", ".fwork"} or suffix == ".framework":
                raise ValueError("This wheel contains native code and isn't installable on iOS this way.")
        if not any(name.endswith(".dist-info/WHEEL") for name in archive.namelist()):
            raise ValueError("The ZIP doesn't contain wheel metadata.")

        # Check limits and paths before decompressing the archive for CRC checks.
        if archive.testzip():
            raise ValueError("The wheel archive is damaged.")
        installed_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="pyphone-wheel-", dir=str(installed_root)) as temp:
            staging = Path(temp) / "package"
            staging.mkdir()
            for entry in entries:
                if entry.is_dir():
                    continue
                parts = Path(entry.filename).parts
                # Wheel data files are placed according to the wheel spec.
                # purelib/platlib/data are importable or runtime data; scripts
                # are intentionally skipped because PyPhone has no shell.
                if parts and parts[0].endswith(".data"):
                    if len(parts) < 3:
                        continue
                    category = parts[1]
                    if category == "scripts":
                        continue
                    if category not in {"purelib", "platlib", "data"}:
                        continue
                    relative = Path(*parts[2:])
                else:
                    relative = Path(*parts)
                destination = staging / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry, "r") as src, open(destination, "wb") as dst:
                    shutil.copyfileobj(src, dst)
            os.replace(str(staging), str(target))
    return True


def _pip_install_command(code):
    """Handle a standalone 'pip install ...' line in the editor without a shell."""
    stripped = code.strip()
    if "\n" in stripped or "\r" in stripped or not stripped.startswith("pip install "):
        return False

    try:
        parts = shlex.split(stripped)
        if len(parts) != 3 or parts[0:2] != ["pip", "install"]:
            print("Usage: pip install package==version")
            return True

        spec = parts[2]
        if "==" in spec:
            package_name, version = spec.split("==", 1)
            if not package_name or not version:
                raise ValueError("Use package==version, for example pyui-toolkit==0.1.0")
            endpoint = "https://pypi.org/pypi/" + urllib.parse.quote(package_name, safe="") + "/" + urllib.parse.quote(version, safe="") + "/json"
        else:
            package_name = spec
            endpoint = "https://pypi.org/pypi/" + urllib.parse.quote(package_name, safe="") + "/json"

        print("Looking up", spec, "on PyPI...")
        request = urllib.request.Request(endpoint, headers={"User-Agent": "PyPhone-package-installer/1.0"})
        with urllib.request.urlopen(request, timeout=20, context=_PYPI_SSL_CONTEXT) as response:
            metadata = json.loads(response.read().decode("utf-8"))

        files = metadata.get("urls", [])
        wheel = next((item for item in files
                      if item.get("filename", "").endswith(".whl")
                      and item.get("filename", "").endswith("none-any.whl")
                      and item.get("filename", "").split("-")[-3] in ("py3", "py2.py3", "py2.py3.py3")), None)
        if wheel is None:
            raise ValueError("PyPI has no compatible pure-Python wheel for this package. Native-code wheels and source builds aren't supported.")

        incoming, archived, installed = _package_folders()
        wheel_path = incoming / wheel["filename"]
        print("Downloading", wheel["filename"], "...")
        request = urllib.request.Request(wheel["url"], headers={"User-Agent": "PyPhone-package-installer/1.0"})
        with urllib.request.urlopen(request, timeout=45, context=_PYPI_SSL_CONTEXT) as response, open(wheel_path, "wb") as output:
            shutil.copyfileobj(response, output)

        did_install = _install_wheel(wheel_path, installed)
        archive_path = archived / wheel_path.name
        if archive_path.exists():
            archive_path = archived / (wheel_path.stem + "-copy" + wheel_path.suffix)
        shutil.move(str(wheel_path), str(archive_path))
        if did_install:
            install_folder = installed / _wheel_install_target(wheel_path.name)
            sys.path.insert(0, str(install_folder))
            importlib.invalidate_caches()
            print("Successfully installed", metadata.get("info", {}).get("name", package_name), metadata.get("info", {}).get("version", version if "version" in locals() else ""))
        else:
            print("Package is already installed.")
        print("Note: this installs one pure-Python package only; dependencies must be installed separately.")
    except Exception as exc:
        print("pip install failed:", str(exc))
    return True


def _process_dropped_packages():
    incoming, archived, installed = _package_folders()
    # Existing installs must be on sys.path before user code is executed.
    for folder in sorted(installed.iterdir()):
        if folder.is_dir() and not folder.name.startswith("."):
            sys.path.insert(0, str(folder))

    try:
        dropped = sorted(p for p in incoming.iterdir() if p.is_file() and p.suffix.lower() == ".whl")
    except OSError as exc:
        print("Package folder couldn't be read:", exc)
        return
    for wheel in dropped:
        try:
            did_install = _install_wheel(wheel, installed)
            # Archive successful installs and duplicates so they aren't retried
            # on every launch. Failed wheels remain in Packages for inspection.
            destination = archived / wheel.name
            if destination.exists():
                destination = archived / (wheel.stem + "-copy" + wheel.suffix)
            shutil.move(str(wheel), str(destination))
            if did_install:
                install_folder = installed / _wheel_install_target(wheel.name)
                if install_folder.is_dir():
                    sys.path.insert(0, str(install_folder))
                    importlib.invalidate_caches()
                print("Installed package:", destination.name)
        except Exception as exc:
            print("Couldn't install", wheel.name + ":", str(exc))
            print("The file was left in Packages so you can fix or remove it.")


_process_dropped_packages()


def _patch_pysdl2_ios_framework_lookup():
    """Teach pure-Python PySDL2 to search Apple frameworks on iOS."""
    if sys.platform != "ios":
        return
    for entry in sys.path:
        if not entry:
            continue
        dll_file = Path(entry) / "sdl2" / "dll.py"
        if not dll_file.is_file():
            continue
        try:
            source = dll_file.read_text(encoding="utf-8")
            patched = source.replace(
                'elif platform == "darwin":',
                'elif platform in ("darwin", "ios"):',
            ).replace(
                "elif platform == 'darwin':",
                "elif platform in ('darwin', 'ios'):",
            )
            if patched != source:
                dll_file.write_text(patched, encoding="utf-8")
                print("Enabled iOS SDL2.framework lookup for PySDL2.")
            return
        except OSError as exc:
            print("Could not apply PySDL2 iOS compatibility fix:", exc)
            return


_patch_pysdl2_ios_framework_lookup()

import ui

_run_tid = [0]
_run_lock = threading.RLock()
_running = [False]
_cb_tid = [0]
_callback_running = [False]
_input_lock = threading.Lock()
_prompt_id = [0]
_error_line = [None]
_prompt = [None]
_reply = [""]
_got = threading.Event()


def _input(prompt=""):
    prompt = str(prompt)
    with _input_lock:
        _reply[0] = ""
        _got.clear()
        _prompt_id[0] += 1
        _prompt[0] = prompt
        ui._seq[0] += 1
    try:
        while not _got.wait(0.1):
            pass
        text = _reply[0]
    finally:
        with _input_lock:
            _prompt[0] = None
    print(prompt + text)
    return text


builtins.input = _input


def check_runtime(_=""):
    """Import the core modules users need before enabling the Run button."""
    import math
    import numpy

    # Use each import in a small real operation, not merely an import statement.
    if math.sqrt(81) != 9.0:
        raise RuntimeError("math module failed its smoke test")
    probe = numpy.array([1, 2, 3])
    if int(probe.sum()) != 6:
        raise RuntimeError("NumPy failed its smoke test")
    return "Python ready · NumPy " + str(numpy.__version__)


def list_packages(_=""):
    """Report installed distributions without importing or running packages."""
    from importlib.metadata import distributions
    packages = {}
    for distribution in distributions():
        name = distribution.metadata.get("Name")
        if name:
            key = name.lower().replace("_", "-")
            packages.setdefault(key, {"name": name, "version": distribution.version})
    return json.dumps([packages[key] for key in sorted(packages)])



_ERROR_HELP = {
    "ModuleNotFoundError": (
        "Python couldn't find a package you're importing.",
        "Install the missing package with `pip install package-name` if it supports PyPhone, or check the import name."
    ),
    "ImportError": (
        "Python found a package, but couldn't import something from it.",
        "Check the package's documentation and make sure the name you're importing exists."
    ),
    "NameError": (
        "Your code used a name Python doesn't recognize.",
        "Check for a typo, or make sure the variable or function is created before you use it."
    ),
    "TypeError": (
        "An operation received the wrong kind of value.",
        "Check the values you're passing in and whether the function expects different types or arguments."
    ),
    "ValueError": (
        "A value has the right general type, but isn't valid for this operation.",
        "Check the value and use one that the operation accepts."
    ),
    "IndexError": (
        "Your code tried to access a list position that doesn't exist.",
        "Check the list length and make sure the index is between 0 and len(list) - 1."
    ),
    "KeyError": (
        "Your code asked a dictionary for a key that isn't there.",
        "Check the spelling of the key, or use dict.get(key) if the key might be missing."
    ),
    "AttributeError": (
        "An object doesn't have the property or method your code tried to use.",
        "Check the spelling and make sure this object supports that method or property."
    ),
    "IndentationError": (
        "Python found indentation that doesn't fit the surrounding code.",
        "Align the line with the correct code block and use consistent spaces."
    ),
    "TabError": (
        "Your code mixes tabs and spaces for indentation.",
        "Replace the indentation with consistent spaces."
    ),
    "ZeroDivisionError": (
        "Your code tried to divide by zero.",
        "Check the divisor before dividing and handle the case where it is 0."
    ),
    "FileNotFoundError": (
        "Python couldn't find the file you asked it to open.",
        "Check the filename and put the file in PyPhone's Documents/Files folder, or use the correct path."
    ),
    "PermissionError": (
        "Python doesn't have permission to access that file or folder.",
        "Use a location inside PyPhone's Documents/Files folder and check the file's permissions."
    ),
    "SyntaxError": (
        "Python couldn't understand the code's grammar.",
        "Check the indicated line for a missing colon, unmatched quote or bracket, or a misspelled keyword."
    ),
}


def _show_friendly_error(exc, tb=None):
    """Show a concise, colorized explanation and a practical next step."""
    # Colorama is already bundled/installed in PyPhone. Keep a plain-text
    # fallback so error reporting still works if it ever becomes unavailable.
    try:
        from colorama import Fore, Style
        red = Fore.RED
        yellow = Fore.YELLOW
        green = Fore.GREEN
        cyan = Fore.CYAN
        reset = Style.RESET_ALL
        bright = Style.BRIGHT
    except Exception:
        red = yellow = green = cyan = reset = bright = ""

    kind = type(exc).__name__
    explanation, fix = _ERROR_HELP.get(
        kind,
        ("Your code stopped because Python raised an error.",
         "Check the error message and the line where it happened. If you're stuck, share this message for help.")
    )

    line = getattr(exc, "lineno", None) if isinstance(exc, SyntaxError) else None
    source = getattr(exc, "text", None) if isinstance(exc, SyntaxError) else None
    if tb is not None:
        try:
            frames = traceback.extract_tb(tb)
            user_frames = [frame for frame in frames if frame.filename == "<code>"]
            if user_frames:
                line = user_frames[-1].lineno
                source = user_frames[-1].line or source
        except Exception:
            pass

    _error_line[0] = line

    # Suggest names actually available in the failing frame, never the typo itself.
    if isinstance(exc, NameError) and getattr(exc, "name", None) and tb is not None:
        frame = tb
        while frame.tb_next is not None:
            frame = frame.tb_next
        missing = exc.name
        candidates = set(frame.tb_frame.f_locals) | set(frame.tb_frame.f_globals) | set(vars(builtins))
        close = difflib.get_close_matches(missing, candidates - {missing}, n=1, cutoff=0.65)
        if close:
            fix = "Did you mean '" + close[0] + "'? Check the spelling of that variable."

    print()
    print(red + bright + "ERROR" + reset + red + "  " + kind + reset)
    print(yellow + "WHAT HAPPENED" + reset)
    print(explanation)
    if line:
        print(cyan + "LINE " + str(line) + reset)
        if source:
            print(red + "  " + source.strip() + reset)
    detail = str(exc).strip()
    if detail and detail != kind:
        print(yellow + "DETAIL " + reset + detail)
    print(green + "HOW TO FIX IT" + reset)
    print(fix)
    print()

def _worker(code, started):
    try:
        with _run_lock:
            _run_tid[0] = threading.get_ident()
        started.set()
        # Make relative file paths use Documents/Files, which is writable
        # inside PyPhone's iOS container.
        os.chdir(_files_folder())
        if not _pip_install_command(code):
            # Keep the source available for runtime tracebacks and callback errors.
            linecache.cache["<code>"] = (len(code), None, code.splitlines(keepends=True), "<code>")
            exec(compile(code, "<code>", "exec"), {"__name__": "__main__"})
    except KeyboardInterrupt:
        print("Stopped.")
    except BaseException as exc:
        _show_friendly_error(exc, exc.__traceback__)
    finally:
        with _run_lock:
            _run_tid[0] = 0
            _running[0] = False


def run_code(code):
    # Reserve the runner before starting the worker. Otherwise, two rapid Run
    # taps can both observe a zero thread ID before either worker starts.
    with _run_lock:
        if _running[0] or _callback_running[0]:
            print("Already running. Stop it first.")
            return ""
        _running[0] = True
        _error_line[0] = None

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


def input_reply(arg):
    reply = json.loads(arg)
    with _input_lock:
        # Polls and duplicate submissions can arrive after the next input().
        if (_prompt[0] is not None and not _got.is_set()
                and reply["prompt_id"] == _prompt_id[0]):
            _reply[0] = str(reply["text"])
            _got.set()
    return ""


def get_state(_=""):
    with _input_lock:
        prompt, prompt_id = _prompt[0], _prompt_id[0]
    tid = _run_tid[0] or _cb_tid[0]
    return json.dumps({
        "widgets": ui._state(),
        "running": bool(_running[0] or _callback_running[0]),
        "prompt": prompt,
        "prompt_id": prompt_id,
        "tid": tid,
        "seq": ui._seq[0],
        "error_line": _error_line[0],
    })


def _callback_worker(d):
    try:
        with _run_lock:
            _cb_tid[0] = threading.get_ident()
        ui._event(d["id"], d["kind"], d.get("value", ""))
    except KeyboardInterrupt:
        print("Stopped.")
    except BaseException as exc:
        _show_friendly_error(exc, exc.__traceback__)
    finally:
        with _run_lock:
            _cb_tid[0] = 0
            _callback_running[0] = False
        ui._seq[0] += 1


def send_event(arg):
    d = json.loads(arg)
    if d["kind"] == "tap":
        with _run_lock:
            if _running[0] or _callback_running[0]:
                print("Already running. Wait for it to finish or tap Stop.")
                return ""
            _callback_running[0] = True
            _error_line[0] = None
        try:
            threading.Thread(target=_callback_worker, args=(d,), daemon=True).start()
        except BaseException:
            with _run_lock:
                _callback_running[0] = False
            raise
    else:
        ui._event(d["id"], d["kind"], d.get("value", ""))
        ui._seq[0] += 1
    return ""


def take_output(_=""):
    with _out.lock:
        s = ("[Older output trimmed]\n" if _out.trimmed else "") + "".join(_out.buf)
        _out.buf.clear()
        _out.size = 0
        _out.trimmed = False
    return s


