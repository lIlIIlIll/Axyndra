package agent_tui

// A terminal card deliberately retains only a small prefix of streamed or
// completed output. sourceBytes/omittedBytes describe the original String,
// while text is always valid UTF-8 and bounded independently per logical line.
public class TuiBoundedText {
    public let text: String
    public let sourceBytes: Int64
    public let omittedBytes: Int64
    public let truncated: Bool

    public init(text: String, sourceBytes: Int64, omittedBytes: Int64, truncated: Bool) {
        this.text = text
        this.sourceBytes = sourceBytes
        this.omittedBytes = omittedBytes
        this.truncated = truncated
    }
}

public func boundedTerminalPreview(
    value: String,
    maximumBytes!: Int64 = 4096,
    maximumLineBytes!: Int64 = 1024
): TuiBoundedText {
    let sourceBytes = value.size
    if (sourceBytes == 0) {
        return TuiBoundedText("", 0, 0, false)
    }
    let totalLimit = max(1, maximumBytes)
    let lineLimit = max(1, min(maximumLineBytes, totalLimit))
    var end = min(sourceBytes, totalLimit)

    // Stop at the first oversized logical line. Continuing after a discarded
    // middle would make the preview misleading and can join two halves of a
    // sensitive token across the truncation marker.
    let bytes = unsafe { value.rawData() }
    var index: Int64 = 0
    var lineStart: Int64 = 0
    while (index < end) {
        if (bytes[index] == b'\n') {
            lineStart = index + 1
        } else if (index - lineStart + 1 > lineLimit) {
            end = lineStart + lineLimit
            break
        }
        index++
    }

    let (prefix, consumed) = validUtf8Prefix(value, end)
    if (consumed >= sourceBytes) {
        return TuiBoundedText(prefix, sourceBytes, 0, false)
    }
    let omitted = sourceBytes - consumed
    let separator = if (prefix == "" || prefix.endsWith("\n")) { "" } else { "\n" }
    TuiBoundedText(
        prefix + separator + "… " + omitted.toString() + " bytes omitted …",
        sourceBytes,
        omitted,
        true
    )
}

private func validUtf8Prefix(value: String, maximum: Int64): (String, Int64) {
    let bytes = unsafe { value.rawData() }
    var end = min(maximum, bytes.size)
    while (end > 0) {
        try {
            return (String.fromUtf8(bytes[..end]), end)
        } catch (_: Exception) {
            end--
        }
    }
    ("", 0)
}
