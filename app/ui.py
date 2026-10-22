import base64
from pathlib import Path

_widgets = []
_next = [0]
_seq = [0]


def _read_image(path):
    """Read an image file and return its base64 data for the native UI."""
    p = Path(path).expanduser()
    if not p.is_absolute():
        p = Path.cwd() / p
    data = p.read_bytes()
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("UI images must be 8 MB or smaller.")
    return base64.b64encode(data).decode("ascii")


class Widget:
    def __init__(self, kind, text="", placeholder="", on_click=None, image_data=None):
        self.id = _next[0]
        _next[0] += 1
        self.kind = kind
        self._text = str(text)
        self.placeholder = placeholder
        self._on_click = on_click
        self.image_data = image_data
        _widgets.append(self)
        _seq[0] += 1

    def set(self, text):
        self._text = str(text)
        if self.kind == "image":
            self.image_data = _read_image(self._text)
        _seq[0] += 1

    def get(self):
        return self._text


def _reset():
    _widgets.clear()
    _next[0] = 0
    _seq[0] += 1


def clear():
    _reset()


def label(text=""):
    return Widget("label", text)


def button(text, on_click):
    return Widget("button", text, on_click=on_click)


def entry(placeholder="", text=""):
    return Widget("entry", text, placeholder)


def image(path):
    """Display an image file in the Window tab; path is relative to Documents/Files."""
    return Widget("image", str(path), image_data=_read_image(path))


def _state():
    return [
        {"id": w.id, "kind": w.kind, "text": w._text, "placeholder": w.placeholder,
         "image_data": w.image_data}
        for w in _widgets
    ]


def _event(id_, kind, value):
    for w in _widgets:
        if w.id == id_:
            if kind == "change":
                w._text = value
            elif kind == "tap" and w._on_click:
                w._on_click()
            return
