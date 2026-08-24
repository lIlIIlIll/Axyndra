package core

public enum Color {
    | Reset
    | Black
    | Red
    | Green
    | Yellow
    | Blue
    | Magenta
    | Cyan
    | White
    | Indexed(UInt8)
    | Rgb(UInt8, UInt8, UInt8)
}

public struct Modifier <: Equatable<Modifier> {
    public var bold: Bool = false
    public var italic: Bool = false
    public var underline: Bool = false
    public var reversed: Bool = false

    public init() {}

    public static func none(): Modifier { Modifier() }

    public static func strong(): Modifier {
        var m = Modifier()
        m.bold = true
        m
    }

    public operator func ==(other: Modifier): Bool {
        bold == other.bold && italic == other.italic && underline == other.underline && reversed == other.reversed
    }
}

public struct Style <: Equatable<Style> {
    public var fg: Color = Color.Reset
    public var bg: Color = Color.Reset
    public var modifier: Modifier = Modifier.none()

    public init(fg!: Color = Color.Reset, bg!: Color = Color.Reset, modifier!: Modifier = Modifier.none()) {
        this.fg = fg
        this.bg = bg
        this.modifier = modifier
    }

    public static func default(): Style { Style() }

    public func withFg(color: Color): Style {
        var s = this
        s.fg = color
        s
    }

    public func withBg(color: Color): Style {
        var s = this
        s.bg = color
        s
    }

    public func withModifier(modifier: Modifier): Style {
        var s = this
        s.modifier = modifier
        s
    }

    public func patch(other: Style): Style {
        var s = this
        if (!colorEquals(other.fg, Color.Reset)) {
            s.fg = other.fg
        }
        if (!colorEquals(other.bg, Color.Reset)) {
            s.bg = other.bg
        }
        if (other.modifier != Modifier.none()) {
            s.modifier = other.modifier
        }
        s
    }

    public operator func ==(other: Style): Bool {
        colorEquals(fg, other.fg) && colorEquals(bg, other.bg) && modifier == other.modifier
    }
}

public struct Theme {
    public let normal: Style
    public let focused: Style
    public let selected: Style
    public let disabled: Style
    public let error: Style
    public let accent: Style
    public let success: Style
    public let warning: Style
    public let info: Style

    public init(
        normal!: Style = Style.default(),
        focused!: Style = Style(fg: Color.Black, bg: Color.White),
        selected!: Style = Style(fg: Color.Black, bg: Color.White),
        disabled!: Style = Style(fg: Color.Indexed(8)),
        error!: Style = Style(fg: Color.Red),
        accent!: Style = Style(fg: Color.Cyan),
        success!: Style = Style(fg: Color.Green),
        warning!: Style = Style(fg: Color.Yellow),
        info!: Style = Style(fg: Color.Cyan)
    ) {
        this.normal = normal
        this.focused = focused
        this.selected = selected
        this.disabled = disabled
        this.error = error
        this.accent = accent
        this.success = success
        this.warning = warning
        this.info = info
    }

    public static func default(): Theme {
        Theme()
    }

    public func serialize(): String {
        "normal=${styleName(normal)}\nfocused=${styleName(focused)}\nselected=${styleName(selected)}\ndisabled=${styleName(disabled)}\nerror=${styleName(error)}\naccent=${styleName(accent)}\nsuccess=${styleName(success)}\nwarning=${styleName(warning)}\ninfo=${styleName(info)}"
    }
}

// Shared state value used by immediate experimental widgets.
public enum StyleState {
    | Normal
    | Focused
    | Selected
    | Disabled
    | Error
    | Accent
}

func styleName(style: Style): String {
    if (style == Style.default()) { return "default" }
    "style"
}
