_widgets = []
_next = [0]
_seq = [0]


class Widget:
    def __init__(self, kind, text="", placeholder="", on_click=None):
        self.id = _next[0]
        _next[0] += 1
        self.kind = kind
        self._text = str(text)
        self.placeholder = placeholder
        self._on_click = on_click
        _widgets.append(self)
        _seq[0] += 1

    def set(self, text):
        self._text = str(text)
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


def _state():
    return [
        {"id": w.id, "kind": w.kind, "text": w._text, "placeholder": w.placeholder}
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
