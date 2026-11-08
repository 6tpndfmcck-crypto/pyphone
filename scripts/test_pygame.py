#!/usr/bin/env python3
"""Exercise the iOS adapter with real native Pygame on a host SDL driver.

The dispatcher models UIKit's serial main queue; only window/scene attachment
needs device validation. Requires pygame==2.6.1; uses dummy audio and video.
"""
import ctypes
import io
import os
from pathlib import Path
import queue
import sys
import tempfile
import threading
import time
import types

os.environ.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy",
                  SDL_RENDER_DRIVER="software", PYGAME_HIDE_SUPPORT_PROMPT="1")
os.environ["PYPHONE_DOCUMENTS"] = tempfile.mkdtemp(prefix="pyphone-pygame-")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))
REAL_STDOUT = sys.stdout
import pygame
import pygame_ios


class NativeDispatcher(types.ModuleType):
    """A serial UI executor with exception propagation and observable teardown."""
    def __init__(self):
        super().__init__("_pyphone_pygame")
        self.tasks = queue.Queue()
        self.calls = []
        self.visible = False
        self.owner = 0
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self):
        while True:
            function, args, kwargs, done, result = self.tasks.get()
            try:
                result.append((True, function(*args, **kwargs)))
            except BaseException as exc:
                result.append((False, exc))
            finally:
                done.set()

    def call_main(self, function, args, kwargs):
        self.calls.append((getattr(function, "__name__", ""), threading.get_ident()))
        if threading.get_ident() == self.thread.ident:
            return function(*args, **kwargs)
        done = threading.Event()
        result = []
        self.tasks.put((function, args, kwargs, done, result))
        if not done.wait(5):
            raise AssertionError("SDL call blocked the UI dispatcher")
        success, value = result[0]
        if not success:
            raise value
        return value

    def prepare(self):
        assert threading.get_ident() == self.thread.ident

    def set_thread(self, ident):
        assert threading.get_ident() == self.thread.ident
        self.owner = ident

    def show(self):
        assert threading.get_ident() == self.thread.ident
        assert pygame.display.get_surface() is not None
        self.visible = True

    def restore(self):
        assert threading.get_ident() == self.thread.ident
        self.visible = False
        self.owner = 0


native = NativeDispatcher()
sys.modules[native.__name__] = native
platform = sys.platform
try:
    sys.platform = "ios"
    pygame_ios.install()
finally:
    sys.platform = platform
pygame_ios.install()  # Idempotent and harmless on non-iOS hosts.

import runner
sys.excepthook = lambda kind, exc, tb: __import__("traceback").print_exception(kind, exc, tb, file=sys.__stderr__)


def wait_done():
    deadline = time.monotonic() + 5
    while runner._running[0] and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not runner._running[0], "Pygame runner did not finish"
    assert not native.visible, "SDL window was not closed"
    assert not pygame.display.get_init(), "SDL display survived cleanup"
    assert native.owner == 0, "Stop still targets the finished worker"
    return runner.take_output()


game = '''
import pygame, io
pygame.init()
screen = pygame.display.set_mode((96, 64))
assert screen.get_size() == (96, 64)
screen.fill((12, 34, 56))
pygame.draw.rect(screen, "red", (4, 4, 16, 16))
assert screen.get_at((5, 5))[:3] == (255, 0, 0)
assert pygame.transform.scale(screen, (48, 32)).get_size() == (48, 32)
image = io.BytesIO()
pygame.image.save(screen, image, "frame.png")
image.seek(0)
assert pygame.image.load(image).get_at((5, 5))[:3] == (255, 0, 0)
label = pygame.font.Font(None, 16).render("PyPhone", True, "white")
assert pygame.font.SysFont("sans", 16).render("iOS font", True, "white").get_width() > 0
screen.blit(label, (24, 24))
pygame.display.flip()
pygame.display.update((0, 0, 32, 32))
pygame.event.clear()
pygame.event.post(pygame.event.Event(pygame.MOUSEBUTTONDOWN, pos=(20, 30), button=1))
touch = pygame.event.wait(100)
assert touch.type == pygame.MOUSEBUTTONDOWN and touch.pos == (20, 30)
assert isinstance(touch, pygame.event.EventType)
assert pygame.event.wait(15).type == pygame.NOEVENT
pygame.mixer.Sound(buffer=b"\\x00" * 4096).play()
# SDL's dummy driver cannot resize a fullscreen SCALED renderer in place.
# Recreate the display to exercise scene restoration and a second set_mode.
pygame.display.quit()
pygame.display.set_mode((80, 60))
assert pygame.display.get_surface().get_size() == (80, 60)
print("pygame-ok")
'''

# Normal completion must clean up even when a game omits pygame.quit().
for _ in range(2):
    runner.run_code(game)
    output = wait_done()
    assert "pygame-ok" in output and "ERROR" not in output, output

# A failed SDL call must propagate through the UI queue into friendly errors.
runner.run_code('import pygame\npygame.display.set_mode((-1, 64))\n')
assert "ERROR" in wait_done()

runner.run_code('import pygame\npygame.display.set_mode((96, 64), pygame.OPENGL)\n')
assert "OpenGL is unavailable" in wait_done()

# Exercise Stop during a blocking event wait. The UI executor must stay usable
# and a subsequent ordinary script must still run.
runner.run_code('import pygame\npygame.init()\npygame.display.set_mode((96, 64))\n'
                'pygame.event.clear()\nwhile True: pygame.event.wait()\n')
deadline = time.monotonic() + 5
while not native.visible and time.monotonic() < deadline:
    time.sleep(0.01)
assert native.visible and native.owner == runner._run_tid[0]
interrupt = ctypes.pythonapi.PyThreadState_SetAsyncExc
interrupt.argtypes = (ctypes.c_ulong, ctypes.py_object)
interrupt.restype = ctypes.c_int
assert interrupt(native.owner, KeyboardInterrupt) == 1
assert "Stopped." in wait_done()
runner.run_code('print("after-pygame")\n')
assert "after-pygame" in wait_done()

# Direct submodule import keeps the same adapter and standard Pygame classes.
assert __import__("pygame.display", fromlist=["set_mode"]).set_mode is pygame.display.set_mode
assert pygame.Rect(1, 2, 3, 4).size == (3, 4)
REAL_STDOUT.write("PyPhone native Pygame adapter/render/input/Stop tests passed.\n")
REAL_STDOUT.flush()
