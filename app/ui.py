import base64
import io
import sys
import threading
from collections import OrderedDict
from pathlib import Path


_widgets = []
_next = [0]
_seq = [0]
_lock = threading.RLock()
_recent_images = OrderedDict()
_MAX_IMAGES = 16
_MAX_IMAGE_BYTES = 32 * 1024 * 1024


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


def _remember_image(widget):
    """Keep bounded latest snapshots, including images followed by ui.clear()."""
    _recent_images[widget.id] = widget
    _recent_images.move_to_end(widget.id)
    while (len(_recent_images) > _MAX_IMAGES or
           sum(len(w.image_data or "") for w in _recent_images.values()) > _MAX_IMAGE_BYTES):
        _, evicted = _recent_images.popitem(last=False)
        evicted.image_data = None
        # A null payload with a newer revision explicitly evicts the native
        # cached image; null with the same revision means it is unchanged.
        evicted.image_revision = _seq[0]


class Widget:
    def __init__(self, kind, text="", placeholder="", on_click=None, image_data=None):
        self.kind = kind
        self._text = str(text)
        self.placeholder = placeholder
        self._on_click = on_click
        self.image_data = image_data
        with _lock:
            self.id = _next[0]
            _next[0] += 1
            _seq[0] += 1
            self.image_revision = _seq[0] if kind == "image" else 0
            _widgets.append(self)
            if kind == "image":
                _remember_image(self)

    def set(self, value):
        if self.kind == "image":
            # Encode outside the state lock; a slow PNG encoder must not block
            # input, Stop, or a native frame poll. Retain only the newest frame.
            data = _read_image(value)
            text = str(value) if isinstance(value, (str, Path)) else "<HeliOS Image>"
            with _lock:
                changed = self.image_data != data
                if changed or self._text != text:
                    _seq[0] += 1
                    self._text = text
                if changed:
                    self.image_data = data
                    self.image_revision = _seq[0]
                    _remember_image(self)
        else:
            with _lock:
                self._text = str(value)
                _seq[0] += 1

    def get(self):
        return self._text


def _reset():
    with _lock:
        _widgets.clear()
        _recent_images.clear()
        # IDs stay unique so queued events cannot target a replacement widget.
        _seq[0] += 1


def _changed():
    with _lock:
        _seq[0] += 1


def clear():
    """Remove interactive widgets; already printed Console images stay visible."""
    with _lock:
        _widgets.clear()
        _seq[0] += 1


def label(text=""):
    return Widget("label", text)


def button(text, on_click):
    if not callable(on_click):
        raise TypeError("on_click must be callable")
    return Widget("button", text, on_click=on_click)


def entry(placeholder="", text=""):
    return Widget("entry", text, placeholder)


def image(source):
    """Display one image in the console; .set(frame) replaces it in place."""
    data = _read_image(source)
    text = str(source) if isinstance(source, (str, Path)) else "<HeliOS Image>"
    widget = Widget("image", text, image_data=data)
    _emit_image(widget.id)
    return widget


def _state(since=-1):
    with _lock:
        widgets = list(_widgets)
        active_ids = {widget.id for widget in widgets}
        widgets.extend(widget for id_, widget in _recent_images.items() if id_ not in active_ids)
        return [
            {"id": w.id, "kind": w.kind, "text": w._text, "placeholder": w.placeholder,
             "image_data": w.image_data if w.image_revision > since else None,
             "image_revision": w.image_revision}
            for w in widgets
        ]


def _snapshot(since=-1):
    # Return the cursor and its payload together. An image update arriving
    # during serialization will then be delivered on the next native poll.
    with _lock:
        return _seq[0], _state(since)


def _event(id_, kind, value):
    callback = None
    with _lock:
        for w in _widgets:
            if w.id == id_:
                if kind == "change":
                    w._text = value
                elif kind == "tap":
                    callback = w._on_click
                break
    # Never hold the snapshot lock while executing arbitrary user callbacks.
    if callback:
        callback()

