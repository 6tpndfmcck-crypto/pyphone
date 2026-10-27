import base64
import io
import sys
from pathlib import Path


_widgets = []
_next = [0]
_seq = [0]


def _emit_image(widget_id):
    """Mark the image position in stdout without moving image bytes through text."""
    sys.stdout.write(f"\x1fPYPHONE_IMAGE:{widget_id}\x1e\n")


def _image_bytes(source):
    """Read a path or a HeliOS Image object and return PNG/image bytes."""
    if hasattr(source, "save") and hasattr(source, "size"):
        buffer = io.BytesIO()
        source.save(buffer, format="PNG")
        data = buffer.getvalue()
    else:
        p = Path(source).expanduser()
        if not p.is_absolute():
            p = Path.cwd() / p
        data = p.read_bytes()
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("UI images must be 8 MB or smaller.")
    return data


def _read_image(source):
    """Read an image path or HeliOS Image and return base64 data."""
    return base64.b64encode(_image_bytes(source)).decode("ascii")


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

    def set(self, value):
        if self.kind == "image":
            self.image_data = _read_image(value)
            self._text = str(value) if isinstance(value, (str, Path)) else "<HeliOS Image>"
            _emit_image(self.id)
        else:
            self._text = str(value)
        _seq[0] += 1

    def get(self):
        return self._text


def _reset():
    _widgets.clear()
    # IDs stay unique so queued events cannot target a replacement widget.
    _seq[0] += 1


def clear():
    """Remove all widgets from the current UI."""
    _reset()


def label(text=""):
    return Widget("label", text)


def button(text, on_click):
    if not callable(on_click):
        raise TypeError("on_click must be callable")
    return Widget("button", text, on_click=on_click)


def entry(placeholder="", text=""):
    return Widget("entry", text, placeholder)


def image(source):
    """Display an image file or HeliOS Image in the console output."""
    data = _read_image(source)
    text = str(source) if isinstance(source, (str, Path)) else "<HeliOS Image>"
    widget = Widget("image", text, image_data=data)
    _emit_image(widget.id)
    return widget


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

