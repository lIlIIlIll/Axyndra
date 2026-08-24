package core

import std.collection.*

public interface Widget {
    func render(area: Rect, buffer: Buffer): Unit
}

public enum WrapMode {
    | NoWrap
    | Word
    | Character
}

public enum TextAlign {
    | Left
    | Center
    | Right
}

func resolvedStateStyle(
    style: Style,
    focusedStyle: Style,
    disabledStyle: Style,
    focused: Bool,
    disabled: Bool,
    theme: ?Theme
): Style {
    if (disabled) { return themedDisabled(disabledStyle, theme) }
    if (focused) { return themedFocused(focusedStyle, theme) }
    themedNormal(style, theme)
}

func themedNormal(style: Style, theme: ?Theme): Style {
    match (theme) {
        case Some(t) => t.normal.patch(style)
        case None => style
    }
}

func themedFocused(style: Style, theme: ?Theme): Style {
    match (theme) {
        case Some(t) => t.focused.patch(style)
        case None => style
    }
}

func themedSelected(style: Style, theme: ?Theme): Style {
    match (theme) {
        case Some(t) => t.selected.patch(style)
        case None => style
    }
}

func themedDisabled(style: Style, theme: ?Theme): Style {
    match (theme) {
        case Some(t) => t.disabled.patch(style)
        case None => style
    }
}

func themedError(style: Style, theme: ?Theme): Style {
    match (theme) {
        case Some(t) => t.error.patch(style)
        case None => style
    }
}

func themedAccent(style: Style, theme: ?Theme): Style {
    match (theme) {
        case Some(t) => t.accent.patch(style)
        case None => style
    }
}

func decimalDigits(value: Int64): Int64 {
    var v = max(0, value)
    var digits: Int64 = 1
    while (v >= 10) {
        v /= 10
        digits++
    }
    digits
}

func maxArray(values: Array<Int64>): Int64 {
    var out: Int64 = 0
    for (value in values) {
        if (value > out) { out = value }
    }
    out
}

func containsIndex(items: ArrayList<Int64>, value: Int64): Bool {
    for (item in items) {
        if (item == value) { return true }
    }
    false
}

func pad2(value: Int64): String {
    if (value < 10) { "0${value}" } else { "${value}" }
}

func isBorderNone(kind: BorderKind): Bool {
    match (kind) {
        case BorderKind.NoBorder => true
        case _ => false
    }
}
