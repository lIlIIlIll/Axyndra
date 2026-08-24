package agent_tui

// Presentation helpers for the already-bounded completion contract. They do
// not parse the original tool result, so completion and every later frame are
// proportional to the terminal preview rather than provider output size.
func tuiToolCompletionOutput(
    name: String,
    payload: TuiToolCompletionPayload
): String {
    if (name != "bash" && name != "bash_readonly") {
        return ""
    }
    if (payload.stdoutPreview == "") {
        return payload.stderrPreview
    }
    if (payload.stderrPreview == "") {
        return payload.stdoutPreview
    }
    payload.stdoutPreview + if (payload.stdoutPreview.endsWith("\n")) {
        ""
    } else {
        "\n"
    } + payload.stderrPreview
}

func tuiToolCompletionFooter(
    name: String,
    payload: TuiToolCompletionPayload
): String {
    if (name != "bash" && name != "bash_readonly") {
        return toolFooter(name, payload.detailPreview)
    }
    var footer = ""
    func append(value: String): Unit {
        if (value == "") {
            return
        }
        if (footer != "") {
            footer += " · "
        }
        footer += value
    }
    if (payload.stdoutBytes >= 0) {
        append("stdout " + payload.stdoutBytes.toString() + " B")
    }
    if (payload.stderrBytes > 0) {
        append("stderr " + payload.stderrBytes.toString() + " B")
    }
    if (payload.sourceTruncated) {
        append("source truncated")
    }
    if (payload.previewTruncated) {
        append("preview truncated")
    }
    footer
}
