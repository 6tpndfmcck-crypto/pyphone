"""An in-process command shell for iOS, which cannot spawn system executables."""
import code
import os
from pathlib import Path
import runpy
import shlex
import shutil
import sys

_directory = None


class _Console(code.InteractiveConsole):
    def runcode(self, source):
        try:
            exec(source, self.locals)
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException:
            self.showtraceback()



def execute(command, files, install):
    global _directory
    args = shlex.split(command)
    if not args:
        return
    if _directory is None:
        _directory = Path(files).resolve()
    os.chdir(_directory)
    name, *values = args
    try:
        if name == "help":
            print("Commands: help, pwd, cd [path], ls [path], cat file, echo [text],")
            print("mkdir path, touch file, cp source target, mv source target, rm file,")
            print("python [script.py | -c code], pip install package, clear")
            print("Quote paths containing spaces. Python without arguments opens a REPL.")
            print("This iOS shell runs built-in commands and Python; system executables,")
            print("pipes, redirection, and shell scripts are not supported.")
        elif name == "pwd" and not values:
            print(Path.cwd())
        elif name == "cd" and len(values) <= 1:
            os.chdir(Path(values[0]).expanduser() if values else files)
        elif name == "ls" and len(values) <= 1:
            target = Path(values[0]).expanduser() if values else Path.cwd()
            if target.is_dir():
                for item in sorted(target.iterdir(), key=lambda p: p.name):
                    print(item.name + ("/" if item.is_dir() else ""))
            else:
                target.stat()
                print(target.name)
        elif name == "echo":
            print(" ".join(values))
        elif name == "cat" and values:
            for value in values:
                print(Path(value).expanduser().read_text(), end="")
        elif name in ("mkdir", "touch", "rm") and values:
            for value in values:
                path = Path(value).expanduser()
                if name == "mkdir":
                    path.mkdir()
                elif name == "touch":
                    path.touch()
                else:
                    path.unlink()
        elif name in ("cp", "mv") and len(values) == 2:
            source, target = (str(Path(v).expanduser()) for v in values)
            (shutil.copy2 if name == "cp" else shutil.move)(source, target)
        elif name == "pip" and len(values) == 2 and values[0] == "install":
            install(shlex.join(args))
        elif name in ("python", "python3"):
            previous_argv, previous_path = sys.argv[:], sys.path[:]
            try:
                sys.path.insert(0, str(Path.cwd()))
                if not values:
                    print("Python terminal — exit() to return to the shell.")
                    console = _Console()
                    more = False
                    while True:
                        more = console.push(input("... " if more else ">>> "))
                elif values[0] == "-c" and len(values) >= 2:
                    sys.argv = ["-c"] + values[2:]
                    exec(compile(values[1], "<terminal>", "exec"), {"__name__": "__main__"})
                elif not values[0].startswith("-"):
                    path = Path(values[0]).expanduser().resolve()
                    sys.argv = [str(path)] + values[1:]
                    sys.path[0] = str(path.parent)
                    runpy.run_path(str(path), run_name="__main__")
                else:
                    raise ValueError("Usage: python [script.py | -c code]")
            except SystemExit as exc:
                if exc.code:
                    print("Python exited:", exc.code)
            finally:
                sys.argv, sys.path[:] = previous_argv, previous_path
        else:
            print(f"Unknown command or invalid arguments: {name}. Type help.")
    finally:
        _directory = Path.cwd()
