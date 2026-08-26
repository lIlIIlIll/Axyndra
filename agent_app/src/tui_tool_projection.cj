package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_tui.*
import model_adapters.*
import std.collection.*
import std.convert.*

// Converts the provider/tool result to a terminal-sized value before JSON
// encoding. Persistence and model context keep the complete AgentValue; only
// this display projection is bounded.
func projectTuiToolCompletion(
    output: AgentValue,
    toolName: String
): TuiToolCompletionPayload {
    if (toolName == "bash" || toolName == "bash_readonly") {
        return projectShellCompletion(output)
    }
    let budget = TuiProjectionBudget(12288)
    let projected = projectTuiValue(output, budget, 0)
    TuiToolCompletionPayload(
        detailPreview: encodeAgentValue(projected),
        previewTruncated: budget.truncated
    )
}

func projectRestoredTuiToolCompletion(
    encoded: String,
    toolName: String
): TuiToolCompletionPayload {
    match (decodeAgentValue(encoded, maxBytes: 8388608)) {
        case Result.Ok(value) => projectTuiToolCompletion(value, toolName)
        case Result.Err(_) =>
            let preview = boundedTerminalPreview(encoded)
            if (toolName == "bash" || toolName == "bash_readonly") {
                TuiToolCompletionPayload(
                    detailPreview: preview.text,
                    stdoutPreview: preview.text,
                    stdoutBytes: preview.sourceBytes,
                    stderrBytes: 0,
                    previewTruncated: preview.truncated
                )
            } else {
                TuiToolCompletionPayload(
                    detailPreview: preview.text,
                    previewTruncated: preview.truncated
                )
            }
    }
}

private func projectShellCompletion(output: AgentValue): TuiToolCompletionPayload {
    let rawStdout = if (output.unifiedKind == ValueKind.Text) {
        output.text
    } else {
        valueText(output, "stdout")
    }
    let rawStderr = if (output.unifiedKind == ValueKind.Object) { valueText(output, "stderr") } else { "" }
    let stdout = boundedTerminalPreview(rawStdout)
    let stderr = boundedTerminalPreview(rawStderr)
    let exitCode = valueText(output, "exit_code")
    let stdoutBytes = valueInteger(output, "stdout_bytes", rawStdout.size)
    let stderrBytes = valueInteger(output, "stderr_bytes", rawStderr.size)
    let sourceTruncated = valueBoolean(output, "truncated")
    let artifactId = firstArtifactId(output)
    let previewTruncated = stdout.truncated || stderr.truncated
    let detail = objectValue([
        ValueField("stdout", textValue(stdout.text)),
        ValueField("stderr", textValue(stderr.text)),
        ValueField("exit_code", textValue(exitCode)),
        ValueField("stdout_bytes", integerValue(stdoutBytes)),
        ValueField("stderr_bytes", integerValue(stderrBytes)),
        ValueField("truncated", boolValue(sourceTruncated)),
        ValueField("preview_truncated", boolValue(previewTruncated)),
        ValueField("artifact_id", textValue(artifactId))
    ])
    TuiToolCompletionPayload(
        detailPreview: encodeAgentValue(detail),
        stdoutPreview: stdout.text,
        stderrPreview: stderr.text,
        exitCode: exitCode,
        stdoutBytes: stdoutBytes,
        stderrBytes: stderrBytes,
        sourceTruncated: sourceTruncated,
        previewTruncated: previewTruncated,
        artifactId: artifactId
    )
}

private class TuiProjectionBudget {
    var remaining: Int64
    var truncated = false

    init(remaining: Int64) {
        this.remaining = remaining
    }

    func consume(bytes: Int64): Unit {
        remaining = max(0, remaining - max(0, bytes))
    }
}

private func projectTuiValue(
    value: AgentValue,
    budget: TuiProjectionBudget,
    depth: Int64
): AgentValue {
    if (budget.remaining <= 0 || depth >= 5) {
        budget.truncated = true
        return textValue("… nested value omitted …")
    }
    match (value.unifiedKind) {
        case ValueKind.Null => nullValue()
        case ValueKind.Boolean => boolValue(value.boolean)
        case ValueKind.Number => numberValue(value.number)
        case ValueKind.Text =>
            let maximum = max(1, min(2048, budget.remaining))
            let preview = boundedTerminalPreview(value.text, maximumBytes: maximum,
                maximumLineBytes: min(1024, maximum))
            budget.consume(preview.text.size)
            if (preview.truncated) { budget.truncated = true }
            textValue(preview.text)
        case ValueKind.List =>
            let items = ArrayList<AgentValue>()
            for (index in 0..value.items.size) {
                if (index >= 24 || budget.remaining <= 16) {
                    budget.truncated = true
                    break
                }
                budget.consume(4)
                items.add(projectTuiValue(value.items[index], budget, depth + 1))
            }
            listValue(items.toArray())
        case ValueKind.Object =>
            let fields = ArrayList<ValueField>()
            for (index in 0..value.fields.size) {
                let field = value.fields[index]
                if (index >= 24 || budget.remaining <= field.name.size + 8) {
                    budget.truncated = true
                    break
                }
                budget.consume(field.name.size + 8)
                fields.add(ValueField(field.name, projectTuiValue(field.value, budget, depth + 1)))
            }
            objectValue(fields.toArray())
    }
}

private func valueText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => match (field.unifiedKind) {
            case ValueKind.Text => field.text
            case ValueKind.Number => field.number
            case ValueKind.Boolean => field.boolean.toString()
            case _ => ""
        }
        case None => ""
    }
}

private func valueInteger(value: AgentValue, name: String, fallback: Int64): Int64 {
    let text = valueText(value, name)
    if (text == "") { return fallback }
    try {
        Int64.parse(text)
    } catch (_: Exception) {
        fallback
    }
}

private func valueBoolean(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(field) => match (field.unifiedKind) {
            case ValueKind.Boolean => field.boolean
            case ValueKind.Text => field.text == "true"
            case _ => false
        }
        case None => false
    }
}

private func firstArtifactId(output: AgentValue): String {
    let direct = valueText(output, "artifact")
    if (direct != "") { return direct }
    let directId = valueText(output, "artifact_id")
    if (directId != "") { return directId }
    match (output.field("artifacts")) {
        case Some(artifacts) => if (artifacts.unifiedKind == ValueKind.List && !artifacts.items.isEmpty()) {
            let first = artifacts.items[0]
            let id = valueText(first, "id")
            if (id != "") { id } else { valueText(first, "path") }
        } else {
            ""
        }
        case None => ""
    }
}
