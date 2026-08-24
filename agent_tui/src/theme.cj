package agent_tui

import core.*
import std.convert.*
import std.env.*

public class TuiThemeDefinition {
    public let name: String
    public let raised: String
    public let userMessageBg: String
    public let text: String
    public let muted: String
    public let accent: String
    public let secondary: String
    public let success: String
    public let warning: String
    public let danger: String
    public let userMessageText: String
    public let reasoning: String
    public let tool: String

    public init(
        name: String,
        raised: String,
        userMessageBg: String,
        text: String,
        muted: String,
        accent: String,
        secondary: String,
        success: String,
        warning: String,
        danger: String,
        userMessageText: String,
        reasoning: String,
        tool: String
    ) {
        this.name = name
        this.raised = raised
        this.userMessageBg = userMessageBg
        this.text = text
        this.muted = muted
        this.accent = accent
        this.secondary = secondary
        this.success = success
        this.warning = warning
        this.danger = danger
        this.userMessageText = userMessageText
        this.reasoning = reasoning
        this.tool = tool
    }
}

class ProductTheme {
    let background: Color
    let panel: Color
    let raised: Color
    let userMessageBg: Color
    let text: Color
    let muted: Color
    let accent: Color
    let secondary: Color
    let success: Color
    let warning: Color
    let danger: Color
    let userMessageText: Color
    let reasoning: Color
    let tool: Color
    let toolBorder: Color
    let toolPrompt: Color
    let toolExecutable: Color
    let toolPath: Color
    let toolOutput: Color
    let toolMetadata: Color

    init(
        background: Color,
        panel: Color,
        raised: Color,
        userMessageBg: Color,
        text: Color,
        muted: Color,
        accent: Color,
        secondary: Color,
        success: Color,
        warning: Color,
        danger: Color,
        userMessageText: Color,
        reasoning: Color,
        tool: Color,
        toolBorder: Color,
        toolPrompt: Color,
        toolExecutable: Color,
        toolPath: Color,
        toolOutput: Color,
        toolMetadata: Color
    ) {
        this.background = background
        this.panel = panel
        this.raised = raised
        this.userMessageBg = userMessageBg
        this.text = text
        this.muted = muted
        this.accent = accent
        this.secondary = secondary
        this.success = success
        this.warning = warning
        this.danger = danger
        this.userMessageText = userMessageText
        this.reasoning = reasoning
        this.tool = tool
        this.toolBorder = toolBorder
        this.toolPrompt = toolPrompt
        this.toolExecutable = toolExecutable
        this.toolPath = toolPath
        this.toolOutput = toolOutput
        this.toolMetadata = toolMetadata
    }
}

func activeProductTheme(
    overrideName!: String = "",
    customThemes!: Array<TuiThemeDefinition> = []
): ProductTheme {
    let name = if (overrideName.trimAscii() != "") {
        overrideName.trimAscii().toAsciiLower()
    } else {
        match (getVariable("AXYNDRA_THEME")) {
            case Some(value) => value.toAsciiLower()
            case None => "axyndra"
        }
    }
    let noColor = match (getVariable("NO_COLOR")) {
        case Some(_) => true
        case None => false
    }
    if (noColor) { return terminalProductTheme(noColorTheme()) }
    if (name == "mono") { return terminalProductTheme(monoTheme()) }
    if (name == "light") { return terminalProductTheme(lightTheme()) }
    if (name == "dark") { return terminalProductTheme(darkTheme()) }
    for (theme in customThemes where theme.name == name) {
        return terminalProductTheme(configuredProductTheme(theme))
    }
    terminalProductTheme(axyndraTheme())
}

func configuredProductTheme(theme: TuiThemeDefinition): ProductTheme {
    ProductTheme(
        Color.Reset,
        Color.Reset,
        themeColor(theme.raised),
        themeColor(theme.userMessageBg),
        themeColor(theme.text),
        themeColor(theme.muted),
        themeColor(theme.accent),
        themeColor(theme.secondary),
        themeColor(theme.success),
        themeColor(theme.warning),
        themeColor(theme.danger),
        themeColor(theme.userMessageText),
        themeColor(theme.reasoning),
        themeColor(theme.tool),
        themeColor(theme.muted),
        themeColor(theme.muted),
        themeColor(theme.secondary),
        themeColor(theme.success),
        themeColor(theme.secondary),
        themeColor(theme.muted)
    )
}

func themeColor(value: String): Color {
    let token = value.trimAscii()
    if (token == "") { return Color.Reset }
    if (token.size == 7 && token.startsWith("#")) {
        let bytes = token.toArray()
        return Color.Rgb(
            UInt8(hexPair(bytes[1], bytes[2])),
            UInt8(hexPair(bytes[3], bytes[4])),
            UInt8(hexPair(bytes[5], bytes[6]))
        )
    }
    try {
        let index = Int64.parse(token)
        if (index >= 0 && index <= 255) {
            return Color.Indexed(UInt8(index))
        }
    } catch (_: Exception) {
        ()
    }
    Color.Reset
}

// Product themes are adapted before they reach cjtui's Buffer.  This keeps
// capability policy out of individual card renderers: RGB is preserved on
// true-color terminals, reduced to the xterm cube on 256-color terminals,
// and reduced to semantic ANSI colors on classic terminals.
func terminalProductTheme(theme: ProductTheme): ProductTheme {
    let level = productColorLevel()
    ProductTheme(
        productColor(theme.background, level),
        productColor(theme.panel, level),
        productColor(theme.raised, level),
        productColor(theme.userMessageBg, level),
        productColor(theme.text, level),
        productColor(theme.muted, level),
        productColor(theme.accent, level),
        productColor(theme.secondary, level),
        productColor(theme.success, level),
        productColor(theme.warning, level),
        productColor(theme.danger, level),
        productColor(theme.userMessageText, level),
        productColor(theme.reasoning, level),
        productColor(theme.tool, level),
        productColor(theme.toolBorder, level),
        productColor(theme.toolPrompt, level),
        productColor(theme.toolExecutable, level),
        productColor(theme.toolPath, level),
        productColor(theme.toolOutput, level),
        productColor(theme.toolMetadata, level)
    )
}

func productColorLevel(): Int64 {
    match (getVariable("NO_COLOR")) {
        case Some(_) => return 0
        case None => ()
    }
    let term = match (getVariable("TERM")) {
        case Some(value) => value.toAsciiLower()
        case None => ""
    }
    let colorTerm = match (getVariable("COLORTERM")) {
        case Some(value) => value.toAsciiLower()
        case None => ""
    }
    if (term == "dumb") { return 0 }
    if (colorTerm.contains("truecolor") || colorTerm.contains("24bit")) { return 24 }
    if (term.contains("256color")) { return 256 }
    if (term == "") { return 24 }
    16
}

func productColor(color: Color, level: Int64): Color {
    if (level <= 0) { return Color.Reset }
    match (color) {
        case Color.Rgb(red, green, blue) =>
            if (level >= 256) {
                Color.Indexed(productRgbTo256(red, green, blue))
            } else if (level >= 24) {
                color
            } else {
                productRgbToBasic(red, green, blue)
            }
        case Color.Indexed(value) =>
            if (level >= 256 || level >= 24) { color } else { productIndexToBasic(value) }
        case _ => color
    }
}

func productRgbTo256(red: UInt8, green: UInt8, blue: UInt8): UInt8 {
    let sourceRed = Int64(red)
    let sourceGreen = Int64(green)
    let sourceBlue = Int64(blue)
    let cubeLevels: Array<Int64> = [0, 95, 135, 175, 215, 255]
    var bestIndex: Int64 = 16
    var bestDistance: Int64 = Int64.Max

    // The xterm palette contains both a 6x6x6 cube and a 24-step grayscale
    // ramp.  Dark OMP surfaces are much closer to that ramp; quantizing only
    // through the cube collapses the transcript and user-message backgrounds
    // to the same blue-black entry.
    for (r in 0..6) {
        for (g in 0..6) {
            for (b in 0..6) {
                let dr = sourceRed - cubeLevels[r]
                let dg = sourceGreen - cubeLevels[g]
                let db = sourceBlue - cubeLevels[b]
                let distance = dr * dr + dg * dg + db * db
                if (distance < bestDistance) {
                    bestDistance = distance
                    bestIndex = 16 + r * 36 + g * 6 + b
                }
            }
        }
    }
    for (gray in 0..24) {
        let level = 8 + gray * 10
        let dr = sourceRed - level
        let dg = sourceGreen - level
        let db = sourceBlue - level
        let distance = dr * dr + dg * dg + db * db
        if (distance < bestDistance) {
            bestDistance = distance
            bestIndex = 232 + gray
        }
    }
    UInt8(bestIndex)
}

func productIndexToBasic(value: UInt8): Color {
    match (Int64(value) % 8) {
        case 0 => Color.Black
        case 1 => Color.Red
        case 2 => Color.Green
        case 3 => Color.Yellow
        case 4 => Color.Blue
        case 5 => Color.Magenta
        case 6 => Color.Cyan
        case _ => Color.White
    }
}

func productRgbToBasic(red: UInt8, green: UInt8, blue: UInt8): Color {
    let r = Int64(red)
    let g = Int64(green)
    let b = Int64(blue)
    let maximum = max(r, max(g, b))
    let minimum = min(r, min(g, b))
    if (maximum < 48) { return Color.Black }
    if (maximum - minimum < 32) { return Color.White }
    let redDominant = r >= g + 30 && r >= b + 30
    let greenDominant = g >= r + 30 && g >= b + 30
    let blueDominant = b >= r + 30 && b >= g + 30
    if (redDominant && greenDominant) { return Color.Yellow }
    if (redDominant && blueDominant) { return Color.Magenta }
    if (greenDominant && blueDominant) { return Color.Cyan }
    if (redDominant) { return Color.Red }
    if (greenDominant) { return Color.Green }
    if (blueDominant) { return Color.Blue }
    Color.White
}

func hexPair(high: Byte, low: Byte): Int64 {
    hexDigit(high) * 16 + hexDigit(low)
}

func hexDigit(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value - b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value - b'A') + 10 }
    0
}

func axyndraTheme(): ProductTheme {
    ProductTheme(
        Color.Rgb(30, 30, 46),
        Color.Reset,
        Color.Rgb(30, 30, 46),
        Color.Rgb(24, 24, 37),
        Color.Rgb(205, 214, 244),
        Color.Rgb(108, 112, 134),
        Color.Rgb(137, 180, 250),
        Color.Rgb(127, 132, 156),
        Color.Rgb(166, 227, 161),
        Color.Rgb(249, 226, 175),
        Color.Rgb(243, 139, 168),
        Color.Rgb(205, 214, 244),
        Color.Rgb(127, 132, 156),
        Color.Rgb(166, 227, 161),
        Color.Rgb(69, 71, 90),
        Color.Rgb(108, 112, 134),
        Color.Rgb(137, 180, 250),
        Color.Rgb(166, 227, 161),
        Color.Rgb(127, 132, 156),
        Color.Rgb(88, 91, 112)
    )
}

func darkTheme(): ProductTheme {
    axyndraTheme()
}

func lightTheme(): ProductTheme {
    ProductTheme(
        Color.Reset,
        Color.Reset,
        Color.Rgb(232, 232, 240),
        Color.Rgb(232, 232, 232),
        Color.Reset,
        Color.Rgb(108, 108, 108),
        Color.Rgb(90, 128, 128),
        Color.Rgb(84, 125, 167),
        Color.Rgb(88, 132, 88),
        Color.Rgb(154, 115, 38),
        Color.Rgb(170, 85, 85),
        Color.Reset,
        Color.Rgb(108, 108, 108),
        Color.Reset,
        Color.Rgb(168, 168, 176),
        Color.Rgb(108, 108, 108),
        Color.Rgb(84, 125, 167),
        Color.Rgb(88, 132, 88),
        Color.Rgb(108, 108, 108),
        Color.Rgb(128, 128, 136)
    )
}

func monoTheme(): ProductTheme {
    ProductTheme(
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset,
        Color.Reset
    )
}

func noColorTheme(): ProductTheme {
    monoTheme()
}
