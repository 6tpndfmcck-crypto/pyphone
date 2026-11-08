"""Main-thread SDL/UIKit adapter for the bundled, native Pygame extensions.

Drawing and the game loop stay on the script thread. Only SDL video/input
operations cross to UIKit. Desktop Python never imports the native bridge.
"""
import functools
import sys
import time
import types
import threading
from pathlib import Path

_pygame = None
_native = None
_active = False


def install():
    global _pygame, _native
    if sys.platform != "ios" or _pygame is not None:
        return
    import _pyphone_pygame
    import pygame

    _native, _pygame = _pyphone_pygame, pygame

    # iOS cannot launch fontconfig's fc-list process. Let SysFont retain its
    # normal style handling and fallback using the bundled redistributable font.
    def bundled_fonts(path="fc-list"):
        font = str(Path(pygame.__file__).with_name(pygame.font.get_default_font()))
        return {"freesans": {(False, False): font}}

    pygame.sysfont.initsysfonts_unix = bundled_fonts

    def on_main(function, *, prepare=False, show=False, restore=False):
        @functools.wraps(function)
        def invoke(*args, **kwargs):
            global _active
            if prepare and not _active:
                _active = True
                _native.call_main(_native.prepare, (), {})
                _native.call_main(_native.set_thread, (threading.get_ident(),), {})
            try:
                result = _native.call_main(function, args, kwargs)
                if show:
                    _native.call_main(_native.show, (), {})
                return result
            finally:
                if restore:
                    try:
                        _native.call_main(_native.restore, (), {})
                    finally:
                        _active = False
        return invoke

    # Keep types (Event, Cursor, etc.) intact. Wrap only native functions.
    for module in (pygame.display, pygame.event, pygame.key, pygame.mouse):
        for name, function in list(vars(module).items()):
            if isinstance(function, types.BuiltinFunctionType):
                setattr(module, name, on_main(
                    function,
                    prepare=(module is pygame.display and name in {"init", "set_mode"}),
                    show=(module is pygame.display and name == "set_mode"),
                    restore=(module is pygame.display and name == "quit"),
                ))

    # SDL_WaitEvent must never block the UIKit run loop. Poll on main and wait
    # on the game thread, leaving Stop, input, timers, and rendering responsive.
    def wait(timeout=0):
        if not isinstance(timeout, int):
            raise TypeError("timeout must be an integer")
        deadline = time.monotonic() + timeout / 1000 if timeout > 0 else None
        while True:
            event = pygame.event.poll()
            if event.type != pygame.NOEVENT:
                return event
            if deadline is not None and time.monotonic() >= deadline:
                return event
            time.sleep(0.005)

    pygame.event.wait = wait
    # SCALED gives conventional software games their requested logical size,
    # letterboxing the fullscreen iOS window and mapping touch/mouse positions.
    original_set_mode = pygame.display.set_mode

    @functools.wraps(original_set_mode)
    def set_mode(size=(0, 0), flags=0, depth=0, display=0, vsync=0):
        if flags & pygame.OPENGL:
            raise pygame.error("PyPhone supports software/SCALED Pygame displays; OpenGL is unavailable.")
        if size[0] > 0 and size[1] > 0:
            flags |= pygame.SCALED | pygame.FULLSCREEN
        return original_set_mode(size, flags, depth, display, vsync)

    pygame.display.set_mode = set_mode
    pygame.init = on_main(pygame.init, prepare=True)
    pygame.quit = on_main(pygame.quit, restore=True)
    pygame.base.init = pygame.init
    pygame.base.quit = pygame.quit


def cleanup():
    """Release a game's SDL resources after completion, error, or Stop."""
    global _active
    if _active:
        try:
            _pygame.quit()
        finally:
            _active = False
