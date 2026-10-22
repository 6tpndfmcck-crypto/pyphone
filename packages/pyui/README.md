# pyUI

**pyUI** is a lightweight, pure-Python widget toolkit. It is designed as a separate package: it does not require PyPhone or HeliOS.

The distribution name is `pyui-toolkit`; the import name is `pyui`.

## Install from source

From this folder:

```bash
python -m pip install .
```

The project is not yet published to PyPI. A pure-Python wheel can be built with `python -m pip install build && python -m build`.

## Example

```python
import pyui

pyui.label("Hello from pyUI")
name = pyui.entry("Your name")
pyui.button("Say hello", lambda: print("Hello", name.get()))
pyui.show("My app")
```

On desktop Python, `show()` uses Tkinter. When PyPhone's native `ui` module is already loaded, pyUI uses that renderer instead. The widgets API is the same in either case.

## Images

```python
import pyui
import helios  # optional; HeliOS is not a pyUI dependency

art = helios.new("RGB", (100, 100), (255, 0, 0))
pyui.image(art)
pyui.show("Image preview")
```

HeliOS is optional. Any image object with a compatible `save(..., format="PNG")` method can be passed to `pyui.image()`; a PNG file path also works.

## Backends and limitations

- **Desktop:** Tkinter, when available.
- **PyPhone:** native Window-tab renderer, when PyPhone's `ui` module is loaded.
- **Other runtimes:** need a supported backend adapter. pyUI cannot guarantee a desktop window in every browser-hosted Python environment, because those environments expose different APIs.

This is an early release. The initial API includes labels, buttons, entries, images, clearing widgets, and simple `get()` / `set()` methods. It is not a drop-in replacement for every UI toolkit.
