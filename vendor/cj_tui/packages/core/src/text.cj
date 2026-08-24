package core

import std.collection.*

const ESC: String = "\u{1B}"

public enum AmbiguousWidth {
    | Narrow
    | Wide
}

public struct TextWidthOptions {
    public let ambiguousWidth: AmbiguousWidth

    public init(ambiguousWidth!: AmbiguousWidth = AmbiguousWidth.Narrow) {
        this.ambiguousWidth = ambiguousWidth
    }
}

public struct GraphemeCluster {
    public let text: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let width: Int64

    public init(text: String, startOffset: Int64, endOffset: Int64, width: Int64) {
        this.text = text
        this.startOffset = startOffset
        this.endOffset = endOffset
        this.width = width
    }
}

public func displayWidth(text: String): Int64 {
    displayWidth(text, options: TextWidthOptions())
}

public func displayWidth(text: String, options!: TextWidthOptions): Int64 {
    let bytes = unsafe { text.rawData() }
    if (isPrintableAscii(bytes)) { return bytes.size }
    var width: Int64 = 0
    var offset: Int64 = 0
    while (offset < bytes.size) {
        let next = nextGraphemeOffset(text, offset)
        width += graphemeDisplayWidth(text[offset..next], options: options)
        offset = next
    }
    width
}

func displayWidthFast(text: String): Int64 {
    let bytes = unsafe { text.rawData() }
    if (isPrintableAscii(bytes)) { return bytes.size }
    displayWidth(text)
}

public func displayWidth(r: Rune): Int64 {
    displayWidth(r, options: TextWidthOptions())
}

public func displayWidth(r: Rune, options!: TextWidthOptions): Int64 {
    let code = UInt32(r)
    if (code == 0 || code < 32 || (code >= 0x7Fu32 && code < 0xA0u32)) {
        return 0
    }
    if ((code >= 0x0300u32 && code <= 0x036Fu32) ||
        (code >= 0x1AB0u32 && code <= 0x1AFFu32) ||
        (code >= 0x1DC0u32 && code <= 0x1DFFu32) ||
        (code >= 0x20D0u32 && code <= 0x20FFu32) ||
        (code >= 0xFE00u32 && code <= 0xFE0Fu32) ||
        (code >= 0xE0100u32 && code <= 0xE01EFu32) ||
        (code >= 0x1F3FBu32 && code <= 0x1F3FFu32)) {
        return 0
    }
    if (isEastAsianAmbiguous(code)) {
        match (options.ambiguousWidth) {
            case AmbiguousWidth.Wide => return 2
            case AmbiguousWidth.Narrow => ()
        }
    }
    if ((code >= 0x1100u32 && code <= 0x115Fu32) ||
        (code >= 0x2329u32 && code <= 0x232Au32) ||
        (code >= 0x2E80u32 && code <= 0xA4CFu32) ||
        (code >= 0xAC00u32 && code <= 0xD7A3u32) ||
        (code >= 0xF900u32 && code <= 0xFAFFu32) ||
        (code >= 0xFE10u32 && code <= 0xFE19u32) ||
        (code >= 0xFE30u32 && code <= 0xFE6Fu32) ||
        (code >= 0xFF00u32 && code <= 0xFF60u32) ||
        (code >= 0xFFE0u32 && code <= 0xFFE6u32) ||
        (code >= 0x1F300u32 && code <= 0x1FAFFu32)) {
        return 2
    }
    1
}

public func graphemeClusters(text: String): Array<GraphemeCluster> {
    let clusters = ArrayList<GraphemeCluster>()
    var offset: Int64 = 0
    while (offset < text.size) {
        let next = nextGraphemeOffset(text, offset)
        let cluster = text[offset..next]
        clusters.add(GraphemeCluster(cluster, offset, next, graphemeDisplayWidth(cluster)))
        offset = next
    }
    clusters.toArray()
}

public func graphemeDisplayWidth(text: String): Int64 {
    graphemeDisplayWidth(text, options: TextWidthOptions())
}

// Truncate to a display width budget with a trailing ellipsis. Grapheme-safe
// (never splits a cluster). Moved down from product code (was agent_tui's
// local cut/graphemePrefix): generic UI capability.
public func cut(text: String, width: Int64): String {
    if (width <= 0) {
        ""
    } else {
        if (displayWidth(text) <= width) {
            text
        } else {
            graphemePrefix(text, max(0, width - 3)) + "..."
        }
    }
}

public func graphemePrefix(text: String, maxWidth: Int64): String {
    if (maxWidth <= 0) {
        return ""
    }
    var result = ""
    var width: Int64 = 0
    for (cluster in graphemeClusters(text)) {
        if (width + cluster.width > maxWidth) {
            break
        }
        result += cluster.text
        width += cluster.width
    }
    result
}

public func graphemeDisplayWidth(text: String, options!: TextWidthOptions): Int64 {
    if (text.isEmpty()) { return 0 }
    if (containsRune(text, r'\u{200D}')) {
        var hasWide = false
        var offset: Int64 = 0
        let bytes = unsafe { text.rawData() }
        while (offset < bytes.size) {
            let (r, len) = Rune.fromUtf8(bytes, offset)
            hasWide = hasWide || displayWidth(r, options: options) >= 2
            offset += len
        }
        return if (hasWide) { 2 } else { 1 }
    }
    var width: Int64 = 0
    var offset: Int64 = 0
    let bytes = unsafe { text.rawData() }
    while (offset < bytes.size) {
        let (r, len) = Rune.fromUtf8(bytes, offset)
        width += displayWidth(r, options: options)
        offset += len
    }
    width
}

public func wrapText(text: String, width: Int64, mode: WrapMode): Array<String> {
    let lines = ArrayList<String>()
    if (width <= 0) { return lines.toArray() }
    var start: Int64 = 0
    var offset: Int64 = 0
    let bytes = unsafe { text.rawData() }
    while (offset < bytes.size) {
        let (r, len) = Rune.fromUtf8(bytes, offset)
        if (r == r'\n') {
            appendWrappedLine(text[start..offset], width, mode, lines)
            start = offset + len
        }
        offset += len
    }
    appendWrappedLine(text[start..], width, mode, lines)
    lines.toArray()
}

func appendWrappedLine(text: String, width: Int64, mode: WrapMode, lines: ArrayList<String>): Unit {
    match (mode) {
        case NoWrap =>
            lines.add(text)
        case Character =>
            appendCharacterWrappedLine(text, width, lines)
        case Word =>
            appendWordWrappedLine(text, width, lines)
    }
}

func appendCharacterWrappedLine(text: String, width: Int64, lines: ArrayList<String>): Unit {
    if (text.isEmpty()) {
        lines.add("")
        return
    }
    var current = ""
    var currentWidth: Int64 = 0
    var offset: Int64 = 0
    while (offset < text.size) {
        let next = nextGraphemeOffset(text, offset)
        let part = text[offset..next]
        let partWidth = graphemeDisplayWidth(part)
        if (partWidth > 0 && currentWidth > 0 && currentWidth + partWidth > width) {
            lines.add(current)
            current = ""
            currentWidth = 0
        }
        current += part
        currentWidth += partWidth
        offset = next
    }
    lines.add(current)
}

func appendWordWrappedLine(text: String, width: Int64, lines: ArrayList<String>): Unit {
    let words = splitAsciiWords(text)
    if (words.size == 0) {
        lines.add("")
        return
    }
    var current = ""
    var currentWidth: Int64 = 0
    for (word in words) {
        let wordWidth = displayWidth(word)
        if (wordWidth > width) {
            if (!current.isEmpty()) {
                lines.add(current)
                current = ""
                currentWidth = 0
            }
            appendCharacterWrappedLine(word, width, lines)
        } else if (current.isEmpty()) {
            current = word
            currentWidth = wordWidth
        } else if (currentWidth + 1 + wordWidth <= width) {
            current += " " + word
            currentWidth += 1 + wordWidth
        } else {
            lines.add(current)
            current = word
            currentWidth = wordWidth
        }
    }
    if (!current.isEmpty()) {
        lines.add(current)
    }
}

func splitAsciiWords(text: String): Array<String> {
    let words = ArrayList<String>()
    var current = ""
    let bytes = unsafe { text.rawData() }
    var offset: Int64 = 0
    while (offset < bytes.size) {
        let (r, len) = Rune.fromUtf8(bytes, offset)
        if (r == r' ' || r == r'\t') {
            if (!current.isEmpty()) {
                words.add(current)
                current = ""
            }
        } else {
            current += runeToString(r)
        }
        offset += len
    }
    if (!current.isEmpty()) {
        words.add(current)
    }
    words.toArray()
}

func alignedX(area: Rect, lineWidth: Int64, align: TextAlign): Int64 {
    let extra = max(0, area.width - lineWidth)
    match (align) {
        case Left => area.x
        case Center => area.x + extra / 2
        case Right => area.x + extra
    }
}

func styleToAnsi(style: Style): String {
    let parts = ArrayList<String>()
    parts.add("0")
    match (style.fg) {
        case Reset => ()
        case Black => parts.add("30")
        case Red => parts.add("31")
        case Green => parts.add("32")
        case Yellow => parts.add("33")
        case Blue => parts.add("34")
        case Magenta => parts.add("35")
        case Cyan => parts.add("36")
        case White => parts.add("37")
        case Indexed(v) => parts.add("38;5;${v}")
        case Rgb(r, g, b) => parts.add("38;2;${r};${g};${b}")
    }
    match (style.bg) {
        case Reset => ()
        case Black => parts.add("40")
        case Red => parts.add("41")
        case Green => parts.add("42")
        case Yellow => parts.add("43")
        case Blue => parts.add("44")
        case Magenta => parts.add("45")
        case Cyan => parts.add("46")
        case White => parts.add("47")
        case Indexed(v) => parts.add("48;5;${v}")
        case Rgb(r, g, b) => parts.add("48;2;${r};${g};${b}")
    }
    if (style.modifier.bold) { parts.add("1") }
    if (style.modifier.italic) { parts.add("3") }
    if (style.modifier.underline) { parts.add("4") }
    if (style.modifier.reversed) { parts.add("7") }
    "${ESC}[" + join(parts.toArray(), ";") + "m"
}

func colorEquals(a: Color, b: Color): Bool {
    match ((a, b)) {
        case (Reset, Reset) => true
        case (Black, Black) => true
        case (Red, Red) => true
        case (Green, Green) => true
        case (Yellow, Yellow) => true
        case (Blue, Blue) => true
        case (Magenta, Magenta) => true
        case (Cyan, Cyan) => true
        case (White, White) => true
        case (Indexed(x), Indexed(y)) => x == y
        case (Rgb(ar, ag, ab), Rgb(br, bg, bb)) => ar == br && ag == bg && ab == bb
        case _ => false
    }
}

func truncate(text: String, maxWidth: Int64): String {
    if (maxWidth <= 0) { return "" }
    let bytes = unsafe { text.rawData() }
    if (isPrintableAscii(bytes)) {
        if (bytes.size <= maxWidth) { return text }
        return text[0..maxWidth]
    }
    let out = StringBuilder()
    var width: Int64 = 0
    var offset: Int64 = 0
    while (offset < bytes.size) {
        let next = nextGraphemeOffset(text, offset)
        let part = text[offset..next]
        let w = graphemeDisplayWidth(part)
        if (width + w > maxWidth) { break }
        out.append(part)
        width += w
        offset = next
    }
    out.toString()
}

public func clampToRuneBoundary(text: String, offset: Int64): Int64 {
    let target = clamp(offset, 0, text.size)
    let bytes = unsafe { text.rawData() }
    var pos: Int64 = 0
    var last: Int64 = 0
    while (pos < bytes.size && pos <= target) {
        last = pos
        let (_, len) = Rune.fromUtf8(bytes, pos)
        pos += len
    }
    if (target == text.size) { text.size } else { last }
}

func previousRuneOffset(text: String, offset: Int64): Int64 {
    previousGraphemeOffset(text, offset)
}

public func previousGraphemeOffset(text: String, offset: Int64): Int64 {
    let target = clampToRuneBoundary(text, offset)
    if (target <= 0) { return 0 }
    var pos: Int64 = 0
    var prev: Int64 = 0
    while (pos < target) {
        prev = pos
        pos = nextGraphemeOffset(text, pos)
    }
    prev
}

func nextRuneOffset(text: String, offset: Int64): Int64 {
    nextGraphemeOffset(text, offset)
}

public func nextGraphemeOffset(text: String, offset: Int64): Int64 {
    let target = clampToRuneBoundary(text, offset)
    if (target >= text.size) { return text.size }
    let bytes = unsafe { text.rawData() }
    // Two adjacent printable ASCII code points are always separated by the
    // default grapheme-break rule.  Mixed terminal strings commonly contain
    // long ASCII spans beside one border glyph, emoji, or CJK rune; sending
    // every byte in those spans through the generated Unicode 17 property
    // tables dominates header and transcript rendering.  Keep the full path
    // when the following code point is non-ASCII so sequences such as
    // `e\u{301}` remain one grapheme cluster.
    let firstByte = bytes[target]
    if (firstByte >= 0x20 && firstByte <= 0x7E) {
        let next = target + 1
        if (next >= bytes.size ||
            (bytes[next] >= 0x20 && bytes[next] <= 0x7E)) {
            return next
        }
    }
    let (first, firstLen) = Rune.fromUtf8(bytes, target)
    var prevClass = graphemeBreakClass(UInt32(first))
    let firstInCB = indicConjunctBreakClass(UInt32(first))
    var pos = min(text.size, target + firstLen)
    var regionalCount: Int64 = if (sameGraphemeBreakClass(prevClass, GraphemeBreakClass.RegionalIndicator)) { 1 } else { 0 }
    var extPictSequence = isExtendedPictographic(UInt32(first))
    var zwjAfterExtPict = false
    var indicConsonantSeen = sameIndicConjunctBreakClass(firstInCB, IndicConjunctBreakClass.Consonant)
    var indicLinkerSeen = false
    while (pos < text.size) {
        let r = runeAt(text, pos)
        let code = UInt32(r)
        let currentClass = graphemeBreakClass(code)
        let currentInCB = indicConjunctBreakClass(code)
        if (shouldBreakGrapheme(
            prevClass,
            currentClass,
            isExtendedPictographic(code),
            regionalCount,
            zwjAfterExtPict,
            indicConsonantSeen && indicLinkerSeen,
            currentInCB
        )) {
            break
        }
        let previousClass = prevClass
        pos = nextRuneBoundary(text, pos)
        if (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.RegionalIndicator)) {
            regionalCount++
        } else {
            regionalCount = 0
        }
        let currentIsExtendedPictographic = isExtendedPictographic(code)
        if (currentIsExtendedPictographic) {
            extPictSequence = true
            zwjAfterExtPict = false
        } else if (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.Extend) &&
            !sameGraphemeBreakClass(previousClass, GraphemeBreakClass.ZWJ)) {
            zwjAfterExtPict = false
        } else if (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.ZWJ) && extPictSequence) {
            extPictSequence = false
            zwjAfterExtPict = true
        } else {
            extPictSequence = false
            zwjAfterExtPict = false
        }
        match (currentInCB) {
            case IndicConjunctBreakClass.Consonant =>
                indicConsonantSeen = true
                indicLinkerSeen = false
            case IndicConjunctBreakClass.Extend =>
                ()
            case IndicConjunctBreakClass.Linker =>
                if (indicConsonantSeen) { indicLinkerSeen = true }
            case IndicConjunctBreakClass.InCBNone =>
                indicConsonantSeen = false
                indicLinkerSeen = false
        }
        prevClass = currentClass
    }
    pos
}

func shouldBreakGrapheme(
    prevClass: GraphemeBreakClass,
    currentClass: GraphemeBreakClass,
    currentIsExtendedPictographic: Bool,
    regionalCount: Int64,
    zwjAfterExtPict: Bool,
    indicLinkerActive: Bool,
    currentInCB: IndicConjunctBreakClass
): Bool {
    if (sameGraphemeBreakClass(prevClass, GraphemeBreakClass.CR) &&
        sameGraphemeBreakClass(currentClass, GraphemeBreakClass.LF)) {
        return false
    }
    if (isGraphemeControl(prevClass)) { return true }
    if (isGraphemeControl(currentClass)) { return true }
    if (sameGraphemeBreakClass(prevClass, GraphemeBreakClass.L) &&
        (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.L) ||
            sameGraphemeBreakClass(currentClass, GraphemeBreakClass.V) ||
            sameGraphemeBreakClass(currentClass, GraphemeBreakClass.LV) ||
            sameGraphemeBreakClass(currentClass, GraphemeBreakClass.LVT))) {
        return false
    }
    if ((sameGraphemeBreakClass(prevClass, GraphemeBreakClass.LV) ||
            sameGraphemeBreakClass(prevClass, GraphemeBreakClass.V)) &&
        (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.V) ||
            sameGraphemeBreakClass(currentClass, GraphemeBreakClass.T))) {
        return false
    }
    if ((sameGraphemeBreakClass(prevClass, GraphemeBreakClass.LVT) ||
            sameGraphemeBreakClass(prevClass, GraphemeBreakClass.T)) &&
        sameGraphemeBreakClass(currentClass, GraphemeBreakClass.T)) {
        return false
    }
    if (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.Extend) ||
        sameGraphemeBreakClass(currentClass, GraphemeBreakClass.ZWJ)) {
        return false
    }
    if (sameGraphemeBreakClass(currentClass, GraphemeBreakClass.SpacingMark)) { return false }
    if (sameGraphemeBreakClass(prevClass, GraphemeBreakClass.Prepend)) { return false }
    if (sameGraphemeBreakClass(prevClass, GraphemeBreakClass.ZWJ) &&
        zwjAfterExtPict &&
        currentIsExtendedPictographic) {
        return false
    }
    if (indicLinkerActive && sameIndicConjunctBreakClass(currentInCB, IndicConjunctBreakClass.Consonant)) {
        return false
    }
    if (sameGraphemeBreakClass(prevClass, GraphemeBreakClass.RegionalIndicator) &&
        sameGraphemeBreakClass(currentClass, GraphemeBreakClass.RegionalIndicator) &&
        regionalCount % 2 == 1) {
        return false
    }
    true
}

func isGraphemeControl(kind: GraphemeBreakClass): Bool {
    sameGraphemeBreakClass(kind, GraphemeBreakClass.Control) ||
        sameGraphemeBreakClass(kind, GraphemeBreakClass.CR) ||
        sameGraphemeBreakClass(kind, GraphemeBreakClass.LF)
}

func splitLines(text: String): Array<String> {
    let lines = ArrayList<String>()
    var start: Int64 = 0
    var offset: Int64 = 0
    let bytes = unsafe { text.rawData() }
    while (offset < bytes.size) {
        let (r, len) = Rune.fromUtf8(bytes, offset)
        if (r == r'\n') {
            lines.add(text[start..offset])
            start = offset + len
        }
        offset += len
    }
    lines.add(text[start..])
    lines.toArray()
}

func lineStart(text: String, offset: Int64): Int64 {
    let target = clampToRuneBoundary(text, offset)
    var start: Int64 = 0
    let bytes = unsafe { text.rawData() }
    var pos: Int64 = 0
    while (pos < target) {
        let (r, len) = Rune.fromUtf8(bytes, pos)
        if (r == r'\n') { start = pos + len }
        pos += len
    }
    start
}

func lineEnd(text: String, offset: Int64): Int64 {
    let target = clampToRuneBoundary(text, offset)
    let bytes = unsafe { text.rawData() }
    var pos = target
    while (pos < bytes.size) {
        let (r, len) = Rune.fromUtf8(bytes, pos)
        if (r == r'\n') { return pos }
        pos += len
    }
    text.size
}

func offsetAtLineColumn(text: String, line: Int64, column: Int64): Int64 {
    let bytes = unsafe { text.rawData() }
    var pos: Int64 = 0
    var currentLine: Int64 = 0
    while (pos < bytes.size && currentLine < line) {
        let (r, len) = Rune.fromUtf8(bytes, pos)
        pos += len
        if (r == r'\n') { currentLine++ }
    }
    var width: Int64 = 0
    while (pos < bytes.size) {
        let (r, _) = Rune.fromUtf8(bytes, pos)
        if (r == r'\n') { return pos }
        let next = nextGraphemeOffset(text, pos)
        let w = graphemeDisplayWidth(text[pos..next])
        if (width + w > column) { return pos }
        width += w
        pos = next
    }
    pos
}

func nextRuneBoundary(text: String, offset: Int64): Int64 {
    let target = clampToRuneBoundary(text, offset)
    if (target >= text.size) { return text.size }
    let bytes = unsafe { text.rawData() }
    let (_, len) = Rune.fromUtf8(bytes, target)
    min(text.size, target + len)
}

func containsRune(text: String, needle: Rune): Bool {
    let bytes = unsafe { text.rawData() }
    var offset: Int64 = 0
    while (offset < bytes.size) {
        let (r, len) = Rune.fromUtf8(bytes, offset)
        if (r == needle) { return true }
        offset += len
    }
    false
}

func isEastAsianAmbiguous(code: UInt32): Bool {
    if (code < 0x00A1u32) { return false }
    (code >= 0x00A1u32 && code <= 0x00A1u32) ||
        (code >= 0x00A4u32 && code <= 0x00A4u32) ||
        (code >= 0x00A7u32 && code <= 0x00A8u32) ||
        (code >= 0x00AAu32 && code <= 0x00AAu32) ||
        (code >= 0x00ADu32 && code <= 0x00AEu32) ||
        (code >= 0x00B0u32 && code <= 0x00B4u32) ||
        (code >= 0x00B6u32 && code <= 0x00BAu32) ||
        (code >= 0x00BCu32 && code <= 0x00BFu32) ||
        (code >= 0x00C6u32 && code <= 0x00C6u32) ||
        (code >= 0x00D0u32 && code <= 0x00D0u32) ||
        (code >= 0x00D7u32 && code <= 0x00D8u32) ||
        (code >= 0x00DEu32 && code <= 0x00E1u32) ||
        (code >= 0x00E6u32 && code <= 0x00E6u32) ||
        (code >= 0x00E8u32 && code <= 0x00EAu32) ||
        (code >= 0x00ECu32 && code <= 0x00EDu32) ||
        (code >= 0x00F0u32 && code <= 0x00F0u32) ||
        (code >= 0x00F2u32 && code <= 0x00F3u32) ||
        (code >= 0x00F7u32 && code <= 0x00FAu32) ||
        (code >= 0x00FCu32 && code <= 0x00FCu32) ||
        (code >= 0x00FEu32 && code <= 0x00FEu32) ||
        (code >= 0x0101u32 && code <= 0x0101u32) ||
        (code >= 0x0111u32 && code <= 0x0111u32) ||
        (code >= 0x0113u32 && code <= 0x0113u32) ||
        (code >= 0x011Bu32 && code <= 0x011Bu32) ||
        (code >= 0x0126u32 && code <= 0x0127u32) ||
        (code >= 0x012Bu32 && code <= 0x012Bu32) ||
        (code >= 0x0131u32 && code <= 0x0133u32) ||
        (code >= 0x0138u32 && code <= 0x0138u32) ||
        (code >= 0x013Fu32 && code <= 0x0142u32) ||
        (code >= 0x0144u32 && code <= 0x0144u32) ||
        (code >= 0x0148u32 && code <= 0x014Bu32) ||
        (code >= 0x014Du32 && code <= 0x014Du32) ||
        (code >= 0x0152u32 && code <= 0x0153u32) ||
        (code >= 0x0166u32 && code <= 0x0167u32) ||
        (code >= 0x016Bu32 && code <= 0x016Bu32) ||
        (code >= 0x01CEu32 && code <= 0x01CEu32) ||
        (code >= 0x01D0u32 && code <= 0x01D0u32) ||
        (code >= 0x01D2u32 && code <= 0x01D2u32) ||
        (code >= 0x01D4u32 && code <= 0x01D4u32) ||
        (code >= 0x01D6u32 && code <= 0x01D6u32) ||
        (code >= 0x01D8u32 && code <= 0x01D8u32) ||
        (code >= 0x01DAu32 && code <= 0x01DAu32) ||
        (code >= 0x01DCu32 && code <= 0x01DCu32) ||
        (code >= 0x0251u32 && code <= 0x0251u32) ||
        (code >= 0x0261u32 && code <= 0x0261u32) ||
        (code >= 0x02C4u32 && code <= 0x02C4u32) ||
        (code >= 0x02C7u32 && code <= 0x02C7u32) ||
        (code >= 0x02C9u32 && code <= 0x02CBu32) ||
        (code >= 0x02CDu32 && code <= 0x02CDu32) ||
        (code >= 0x02D0u32 && code <= 0x02D0u32) ||
        (code >= 0x02D8u32 && code <= 0x02DBu32) ||
        (code >= 0x02DDu32 && code <= 0x02DDu32) ||
        (code >= 0x02DFu32 && code <= 0x02DFu32) ||
        (code >= 0x0391u32 && code <= 0x03A9u32) ||
        (code >= 0x03B1u32 && code <= 0x03C9u32) ||
        (code >= 0x2010u32 && code <= 0x2010u32) ||
        (code >= 0x2013u32 && code <= 0x2016u32) ||
        (code >= 0x2018u32 && code <= 0x2019u32) ||
        (code >= 0x201Cu32 && code <= 0x201Du32) ||
        (code >= 0x2020u32 && code <= 0x2022u32) ||
        (code >= 0x2024u32 && code <= 0x2027u32) ||
        (code >= 0x2030u32 && code <= 0x2030u32) ||
        (code >= 0x2032u32 && code <= 0x2033u32) ||
        (code >= 0x2035u32 && code <= 0x2035u32) ||
        (code >= 0x203Bu32 && code <= 0x203Bu32) ||
        (code >= 0x203Eu32 && code <= 0x203Eu32) ||
        (code >= 0x2074u32 && code <= 0x2074u32) ||
        (code >= 0x207Fu32 && code <= 0x207Fu32) ||
        (code >= 0x2081u32 && code <= 0x2084u32) ||
        (code >= 0x20ACu32 && code <= 0x20ACu32) ||
        (code >= 0x2103u32 && code <= 0x2103u32) ||
        (code >= 0x2105u32 && code <= 0x2105u32) ||
        (code >= 0x2109u32 && code <= 0x2109u32) ||
        (code >= 0x2113u32 && code <= 0x2113u32) ||
        (code >= 0x2116u32 && code <= 0x2116u32) ||
        (code >= 0x2121u32 && code <= 0x2122u32) ||
        (code >= 0x2126u32 && code <= 0x2126u32) ||
        (code >= 0x212Bu32 && code <= 0x212Bu32) ||
        (code >= 0x2153u32 && code <= 0x2154u32) ||
        (code >= 0x215Bu32 && code <= 0x215Eu32) ||
        (code >= 0x2160u32 && code <= 0x216Bu32) ||
        (code >= 0x2170u32 && code <= 0x2179u32) ||
        (code >= 0x2189u32 && code <= 0x2189u32) ||
        (code >= 0x2190u32 && code <= 0x2199u32) ||
        (code >= 0x21B8u32 && code <= 0x21B9u32) ||
        (code >= 0x21D2u32 && code <= 0x21D2u32) ||
        (code >= 0x21D4u32 && code <= 0x21D4u32) ||
        (code >= 0x21E7u32 && code <= 0x21E7u32) ||
        (code >= 0x2200u32 && code <= 0x2200u32) ||
        (code >= 0x2202u32 && code <= 0x2203u32) ||
        (code >= 0x2207u32 && code <= 0x2208u32) ||
        (code >= 0x220Bu32 && code <= 0x220Bu32) ||
        (code >= 0x220Fu32 && code <= 0x220Fu32) ||
        (code >= 0x2211u32 && code <= 0x2211u32) ||
        (code >= 0x2215u32 && code <= 0x2215u32) ||
        (code >= 0x221Au32 && code <= 0x221Au32) ||
        (code >= 0x221Du32 && code <= 0x2220u32) ||
        (code >= 0x2223u32 && code <= 0x2223u32) ||
        (code >= 0x2225u32 && code <= 0x2225u32) ||
        (code >= 0x2227u32 && code <= 0x222Cu32) ||
        (code >= 0x222Eu32 && code <= 0x222Eu32) ||
        (code >= 0x2234u32 && code <= 0x2237u32) ||
        (code >= 0x223Cu32 && code <= 0x223Du32) ||
        (code >= 0x2248u32 && code <= 0x2248u32) ||
        (code >= 0x224Cu32 && code <= 0x224Cu32) ||
        (code >= 0x2252u32 && code <= 0x2252u32) ||
        (code >= 0x2260u32 && code <= 0x2261u32) ||
        (code >= 0x2264u32 && code <= 0x2267u32) ||
        (code >= 0x226Au32 && code <= 0x226Bu32) ||
        (code >= 0x226Eu32 && code <= 0x226Fu32) ||
        (code >= 0x2282u32 && code <= 0x2283u32) ||
        (code >= 0x2286u32 && code <= 0x2287u32) ||
        (code >= 0x2295u32 && code <= 0x2295u32) ||
        (code >= 0x2299u32 && code <= 0x2299u32) ||
        (code >= 0x22A5u32 && code <= 0x22A5u32) ||
        (code >= 0x22BFu32 && code <= 0x22BFu32) ||
        (code >= 0x2312u32 && code <= 0x2312u32) ||
        (code >= 0x2460u32 && code <= 0x24E9u32) ||
        (code >= 0x24EBu32 && code <= 0x254Bu32) ||
        (code >= 0x2550u32 && code <= 0x2573u32) ||
        (code >= 0x2580u32 && code <= 0x258Fu32) ||
        (code >= 0x2592u32 && code <= 0x2595u32) ||
        (code >= 0x25A0u32 && code <= 0x25A1u32) ||
        (code >= 0x25A3u32 && code <= 0x25A9u32) ||
        (code >= 0x25B2u32 && code <= 0x25B3u32) ||
        (code >= 0x25B6u32 && code <= 0x25B7u32) ||
        (code >= 0x25BCu32 && code <= 0x25BDu32) ||
        (code >= 0x25C0u32 && code <= 0x25C1u32) ||
        (code >= 0x25C6u32 && code <= 0x25C8u32) ||
        (code >= 0x25CBu32 && code <= 0x25CBu32) ||
        (code >= 0x25CEu32 && code <= 0x25D1u32) ||
        (code >= 0x25E2u32 && code <= 0x25E5u32) ||
        (code >= 0x25EFu32 && code <= 0x25EFu32) ||
        (code >= 0x2605u32 && code <= 0x2606u32) ||
        (code >= 0x2609u32 && code <= 0x2609u32) ||
        (code >= 0x260Eu32 && code <= 0x260Fu32) ||
        (code >= 0x261Cu32 && code <= 0x261Cu32) ||
        (code >= 0x261Eu32 && code <= 0x261Eu32) ||
        (code >= 0x2640u32 && code <= 0x2640u32) ||
        (code >= 0x2642u32 && code <= 0x2642u32) ||
        (code >= 0x2660u32 && code <= 0x2661u32) ||
        (code >= 0x2663u32 && code <= 0x2665u32) ||
        (code >= 0x2667u32 && code <= 0x266Au32) ||
        (code >= 0x266Cu32 && code <= 0x266Du32) ||
        (code >= 0x266Fu32 && code <= 0x266Fu32) ||
        (code >= 0x269Eu32 && code <= 0x269Fu32) ||
        (code >= 0x26BFu32 && code <= 0x26BFu32) ||
        (code >= 0x26C6u32 && code <= 0x26CDu32) ||
        (code >= 0x26CFu32 && code <= 0x26D3u32) ||
        (code >= 0x26D5u32 && code <= 0x26E1u32) ||
        (code >= 0x26E3u32 && code <= 0x26E3u32) ||
        (code >= 0x26E8u32 && code <= 0x26E9u32) ||
        (code >= 0x26EBu32 && code <= 0x26F1u32) ||
        (code >= 0x26F4u32 && code <= 0x26F4u32) ||
        (code >= 0x26F6u32 && code <= 0x26F9u32) ||
        (code >= 0x26FBu32 && code <= 0x26FCu32) ||
        (code >= 0x26FEu32 && code <= 0x26FFu32) ||
        (code >= 0x273Du32 && code <= 0x273Du32) ||
        (code >= 0x2776u32 && code <= 0x277Fu32) ||
        (code >= 0x2B56u32 && code <= 0x2B59u32) ||
        (code >= 0x3248u32 && code <= 0x324Fu32) ||
        (code >= 0xE000u32 && code <= 0xF8FFu32) ||
        (code >= 0xFE00u32 && code <= 0xFE0Fu32) ||
        (code >= 0xFFFDu32 && code <= 0xFFFDu32) ||
        (code >= 0x1F100u32 && code <= 0x1F10Au32) ||
        (code >= 0x1F110u32 && code <= 0x1F12Du32) ||
        (code >= 0x1F130u32 && code <= 0x1F169u32) ||
        (code >= 0x1F170u32 && code <= 0x1F18Du32) ||
        (code >= 0x1F18Fu32 && code <= 0x1F190u32) ||
        (code >= 0x1F19Bu32 && code <= 0x1F1ACu32)
}


func runeToString(r: Rune): String {
    let builder = StringBuilder()
    builder.append(r)
    builder.toString()
}

func join(items: Array<String>, sep: String): String {
    let builder = StringBuilder()
    for (i in 0..items.size) {
        if (i > 0) { builder.append(sep) }
        builder.append(items[i])
    }
    builder.toString()
}

func repeat(text: String, count: Int64): String {
    let builder = StringBuilder()
    for (_ in 0..count) {
        builder.append(text)
    }
    builder.toString()
}

func splitInts(text: String): Array<Int64> {
    let result = ArrayList<Int64>()
    var current: Int64 = 0
    var hasDigits = false
    let bytes = unsafe { text.rawData() }
    for (b in bytes) {
        if (b >= b'0' && b <= b'9') {
            current = current * 10 + Int64(b - b'0')
            hasDigits = true
        } else if (b == b';') {
            if (hasDigits) { result.add(current) }
            current = 0
            hasDigits = false
        }
    }
    if (hasDigits) { result.add(current) }
    result.toArray()
}

func clamp(v: Int64, lo: Int64, hi: Int64): Int64 {
    min(max(v, lo), hi)
}

func min(a: Int64, b: Int64): Int64 { if (a < b) { a } else { b } }
func max(a: Int64, b: Int64): Int64 { if (a > b) { a } else { b } }

func readUInt16(bytes: Array<UInt8>, offset: Int64): UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

@When[os == "Linux"]
func readUInt32(bytes: Array<UInt8>, offset: Int64): UInt32 {
    UInt32(bytes[offset]) |
        (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) |
        (UInt32(bytes[offset + 3]) << 24)
}

@When[os == "Linux"]
func writeUInt32(bytes: Array<UInt8>, offset: Int64, value: UInt32): Unit {
    bytes[offset] = UInt8(value & 0xFFu32)
    bytes[offset + 1] = UInt8((value >> 8) & 0xFFu32)
    bytes[offset + 2] = UInt8((value >> 16) & 0xFFu32)
    bytes[offset + 3] = UInt8((value >> 24) & 0xFFu32)
}
