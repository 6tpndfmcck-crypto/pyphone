"""pyUI: a small, pure-Python UI toolkit.

The package is independent of HeliOS and PyPhone. It can use PyPhone's native
UI renderer when one is already loaded, or Tkinter on desktop Python. Additional
rendering backends can be added without changing the widget API.
"""
from __future__ import annotations

import base64
import io
import sys
from pathlib import Path

__version__ = "0.1.0"
__all__ = ["Widget", "label", "button", "entry", "image", "clear", "show", "__version__"]

_widgets: list[Widget] = []
_next_id = 0
_sequence = 0
_window = None


def _native_backend():
    """Return PyPhone's already-loaded renderer, if it has the expected API."""
    module = sys.modules.get("ui")
    if module is None or module is sys.modules.get(__name__):
        return None
    if all(callable(getattr(module, name, None)) for name in ("label", "button", "entry", "image", "clear")):
        return module
    return None


def _image_data(source) -> str:
    """Convert a path or any save()-compatible image object to base64 PNG/data."""
    if hasattr(source, "save") and hasattr(source, "size"):
        buffer = io.BytesIO()
        try:
            source.save(buffer, format="PNG")
        except TypeError:
            # A few lightweight image APIs accept only a filename.
            import tempfile
            with tempfile.NamedTemporaryFile(suffix=".png") as temp:
                source.save(temp.name)
                buffer.write(Path(temp.name).read_bytes())
        data = buffer.getvalue()
    else:
        data = Path(source).expanduser().read_bytes()
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("UI images must be 8 MB or smaller.")
    return base64.b64encode(data).decode("ascii")


class Widget:
    """A UI element. Use set() to change its value and get() to read it."""
    def __init__(self, kind, text="", placeholder="", on_click=None, image_data=None):
        global _next_id, _sequence
        self.id = _next_id
        _next_id += 1
        self.kind = kind
        self._text = str(text)
        self.placeholder = str(placeholder)
        self._on_click = on_click
        self.image_data = image_data
        self._native_widget = None
        _widgets.append(self)
        _sequence += 1

    def set(self, value):
        global _sequence
        if self.kind == "image":
            self.image_data = _image_data(value)
            self._text = str(value) if isinstance(value, (str, Path)) else "<image object>"
            if self._native_widget is not None:
                self._native_widget.set(value)
        else:
            self._text = str(value)
            if self._native_widget is not None:
                self._native_widget.set(value)
            if _window is not None and self._tk_widget is not None:
                if self.kind == "entry":
                    self._tk_widget.delete(0, "end")
                    self._tk_widget.insert(0, self._text)
                elif self.kind == "label":
                    self._tk_widget.configure(text=self._text)
                elif self.kind == "button":
                    self._tk_widget.configure(text=self._text)
        _sequence += 1

    def get(self):
        if self.kind == "entry" and self._native_widget is not None:
            return self._native_widget.get()
        if self.kind == "entry" and _window is not None and self._tk_widget is not None:
            return self._tk_widget.get()
        return self._text


def _make(kind, text="", placeholder="", on_click=None, image_data=None):
    return Widget(kind, text, placeholder, on_click, image_data)


def label(text=""):
    return _make("label", text)


def button(text, on_click):
    if not callable(on_click):
        raise TypeError("on_click must be callable")
    return _make("button", text, on_click=on_click)


def entry(placeholder="", text=""):
    return _make("entry", text, placeholder)


def image(source):
    """Create an image widget from a path or a save()-compatible image object."""
    data = _image_data(source)
    text = str(source) if isinstance(source, (str, Path)) else "<image object>"
    return _make("image", text, image_data=data)


def clear():
    """Remove all widgets from the current UI."""
    global _sequence, _next_id
    _widgets.clear()
    _next_id = 0
    _sequence += 1
    native = _native_backend()
    if native is not None:
        native.clear()


def _state():
    return [
        {"id": w.id, "kind": w.kind, "text": w._text, "placeholder": w.placeholder,
         "image_data": w.image_data}
        for w in _widgets
    ]


def _event(id_, kind, value=""):
    for widget in _widgets:
        if widget.id == id_:
            if kind == "change":
                widget._text = str(value)
            elif kind == "tap" and widget._on_click is not None:
                widget._on_click()
            return


def show(title="pyUI", backend="auto"):
    """Display widgets using PyPhone's native renderer or desktop Tkinter.

    backend may be 'auto', 'pyphone', or 'tkinter'. In auto mode, the native
    PyPhone renderer is preferred when available; otherwise Tkinter is used.
    A runtime without either supported backend raises a clear RuntimeError.
    """
    global _window
    if backend not in {"auto", "pyphone", "tkinter"}:
        raise ValueError("backend must be 'auto', 'pyphone', or 'tkinter'")

    native = _native_backend() if backend in {"auto", "pyphone"} else None
    if native is not None:
        for widget in _widgets:
            if widget.kind == "label":
                widget._native_widget = native.label(widget._text)
            elif widget.kind == "button":
                widget._native_widget = native.button(widget._text, widget._on_click)
            elif widget.kind == "entry":
                widget._native_widget = native.entry(widget.placeholder, widget._text)
            elif widget.kind == "image":
                # Pass the encoded PNG to native backends as a data URI when
                # the original source was an image object; paths are passed as-is.
                source = widget._text if not widget._text.startswith("<") else None
                if source is not None:
                    widget._native_widget = native.image(source)
                else:
                    widget._native_widget = native.image("data:image/png;base64," + widget.image_data)
        return None
    if backend == "pyphone":
        raise RuntimeError("PyPhone's native UI renderer is not available in this Python runtime.")

    try:
        import tkinter as tk
        from tkinter import ttk
    except ImportError as exc:
        raise RuntimeError("No supported UI backend is available. Tkinter is required outside PyPhone.") from exc

    root = tk.Tk()
    _window = root
    root.title(str(title))
    for widget in _widgets:
        widget._tk_widget = None
        if widget.kind == "label":
            control = ttk.Label(root, text=widget._text)
            control.pack(anchor="w", padx=8, pady=4)
            widget._tk_widget = control
        elif widget.kind == "button":
            control = ttk.Button(root, text=widget._text, command=widget._on_click)
            control.pack(anchor="w", padx=8, pady=4)
            widget._tk_widget = control
        elif widget.kind == "entry":
            control = ttk.Entry(root)
            control.insert(0, widget._text)
            if widget.placeholder:
                control.insert(0, "")
            control.pack(fill="x", padx=8, pady=4)
            widget._tk_widget = control
        elif widget.kind == "image":
            try:
                import tkinter as tk
                raw = base64.b64decode(widget.image_data)
                photo = tk.PhotoImage(data=base64.b64encode(raw))
                control = ttk.Label(root, image=photo)
                control.image = photo
                control.pack(anchor="w", padx=8, pady=4)
                widget._tk_widget = control
            except Exception as exc:
                ttk.Label(root, text="Could not display image: " + str(exc)).pack(anchor="w", padx=8, pady=4)
    root.mainloop()

