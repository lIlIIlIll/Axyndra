package core

import std.collection.*

public class KeyBinding {
    public let keys: Array<KeyEvent>
    public let action: String
    public let description: String

    public init(keys: Array<KeyEvent>, action: String, description!: String = "") {
        this.keys = keys
        this.action = action
        this.description = description
    }

    public func matches(key: KeyEvent): Bool {
        for (candidate in keys) {
            if (keyEventEquals(candidate, key)) { return true }
        }
        false
    }
}

public class KeyMap {
    private let bindings = ArrayList<KeyBinding>()

    public init(bindings!: Array<KeyBinding> = []) {
        for (binding in bindings) {
            this.bindings.add(binding)
        }
    }

    public func add(binding: KeyBinding): Unit {
        bindings.add(binding)
    }

    public func actionFor(key: KeyEvent): ?String {
        for (binding in bindings) {
            if (binding.matches(key)) { return Some(binding.action) }
        }
        None
    }

    public func all(): Array<KeyBinding> {
        bindings.toArray()
    }
}

public class HelpView <: Widget {
    private let keymap: KeyMap
    private let style: Style
    private let separator: String

    public init(keymap: KeyMap, style!: Style = Style(fg: Color.Indexed(8)), separator!: String = "  ") {
        this.keymap = keymap
        this.style = style
        this.separator = separator
    }

    public func render(area: Rect, buffer: Buffer): Unit {
        if (area.width <= 0 || area.height <= 0) { return }
        let parts = ArrayList<String>()
        for (binding in keymap.all()) {
            let desc = if (binding.description.isEmpty()) { binding.action } else { binding.description }
            parts.add(keyLabel(binding.keys) + ": " + desc)
        }
        let text = join(parts.toArray(), separator)
        buffer.setString(area.x, area.y, truncate(text, area.width), style: style)
    }
}

func keyEventEquals(a: KeyEvent, b: KeyEvent): Bool {
    a.modifiers == b.modifiers && keyCodeEquals(a.code, b.code)
}

func keyCodeEquals(a: KeyCode, b: KeyCode): Bool {
    match ((a, b)) {
        case (KeyCode.Char(x), KeyCode.Char(y)) => x == y
        case (KeyCode.CtrlC, KeyCode.CtrlC) => true
        case (KeyCode.Esc, KeyCode.Esc) => true
        case (KeyCode.Tab, KeyCode.Tab) => true
        case (KeyCode.BackTab, KeyCode.BackTab) => true
        case (KeyCode.Enter, KeyCode.Enter) => true
        case (KeyCode.Backspace, KeyCode.Backspace) => true
        case (KeyCode.Delete, KeyCode.Delete) => true
        case (KeyCode.Insert, KeyCode.Insert) => true
        case (KeyCode.Up, KeyCode.Up) => true
        case (KeyCode.Down, KeyCode.Down) => true
        case (KeyCode.Left, KeyCode.Left) => true
        case (KeyCode.Right, KeyCode.Right) => true
        case (KeyCode.Home, KeyCode.Home) => true
        case (KeyCode.End, KeyCode.End) => true
        case (KeyCode.PageUp, KeyCode.PageUp) => true
        case (KeyCode.PageDown, KeyCode.PageDown) => true
        case (KeyCode.F(x), KeyCode.F(y)) => x == y
        case _ => false
    }
}

func keyLabel(keys: Array<KeyEvent>): String {
    let labels = ArrayList<String>()
    for (key in keys) {
        labels.add(singleKeyLabel(key))
    }
    join(labels.toArray(), "/")
}

func singleKeyLabel(key: KeyEvent): String {
    let prefix = modifierLabel(key.modifiers)
    prefix + match (key.code) {
        case KeyCode.Char(r) => runeToString(r)
        case KeyCode.CtrlC => "ctrl+c"
        case KeyCode.Esc => "esc"
        case KeyCode.Tab => "tab"
        case KeyCode.BackTab => "shift+tab"
        case KeyCode.Enter => "enter"
        case KeyCode.Backspace => "backspace"
        case KeyCode.Delete => "delete"
        case KeyCode.Insert => "insert"
        case KeyCode.Up => "up"
        case KeyCode.Down => "down"
        case KeyCode.Left => "left"
        case KeyCode.Right => "right"
        case KeyCode.Home => "home"
        case KeyCode.End => "end"
        case KeyCode.PageUp => "pgup"
        case KeyCode.PageDown => "pgdn"
        case KeyCode.F(n) => "f${n}"
    }
}

func modifierLabel(modifiers: KeyModifier): String {
    var text = ""
    if (modifiers.ctrl) { text += "ctrl+" }
    if (modifiers.alt) { text += "alt+" }
    if (modifiers.shift) { text += "shift+" }
    text
}
