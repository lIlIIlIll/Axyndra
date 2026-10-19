package agent_app

import agent_domain.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation
import agent_runtime.*
import agent_tui.*
import yjson.*
import yjson_support.*

// All scalar/name copies are actual UTF8 copies, including an untruncated
// preview. No accepted field can keep a large source String backing alive.
func copyTuiDisplayText(value: String): String { String.fromUtf8(value.toArray()) }

// Immutable captures with mutable cells are accepted by the actual SDK;
// their complete small control metadata is prepaid before construction.
class OwnedTuiCursorDecision { var accepted = false }
private class OwnedTuiProjectionHolder { var value: ?OwnedTuiToolDisplay = None }

private class TuiProjectionInvoice {
    var remaining: Int64 = 12288
    var raw: Int64 = 0
    var encoded: Int64 = 0
    var nodes: Int64 = 0
    func add(bytes: Int64, encodedBytes: Int64): Unit {
        if (bytes < 0 || encodedBytes < 0 || raw > Int64.Max - bytes || encoded > Int64.Max - encodedBytes) {
            throw IllegalArgumentException("display invoice overflow") }
        raw += bytes; encoded += encodedBytes
    }
    func consume(bytes: Int64): Unit { remaining = max(0, remaining - max(0, bytes)) }
    func visit(value: AgentValue, depth: Int64): Unit {
        nodes++
        if (remaining <= 0 || depth >= 5) { add("… nested value omitted …".size, "… nested value omitted …".size * 6 + 2); return }
        match (value.unifiedKind) {
            case ValueKind.Null => add(0, 4)
            case ValueKind.Boolean => add(0, 5)
            // Preserve the original complete Number behavior. An unusually
            // large number is prepaid in full, or rejected before copying.
            case ValueKind.Number => add(value.asNumberText().size, value.asNumberText().size)
            case ValueKind.Text =>
                let maximum = max(1, min(2048, remaining))
                let bytes = tuiPreviewExactSize(value.text, maximum, min(1024, maximum))
                add(bytes, bytes * 6 + 2); consume(bytes)
            case ValueKind.List =>
                add(0, 2)
                for (index in 0..value.asArray().size()) {
                    if (index >= 24 || remaining <= 16) { break }
                    consume(4); add(0, 1); visit(value.asArray().get(index).getOrThrow(), depth + 1)
                }
            case ValueKind.Object =>
                add(0, 2)
                for (index in 0..value.asObject().size()) {
                    let name = value.asObject().nameAt(index)
                    if (index >= 24 || remaining <= name.size + 8) { break }
                    consume(name.size + 8); add(name.size, name.size * 6 + 4)
                    visit(value.asObject().valueAt(index), depth + 1)
                }
        }
    }
    func total(metadataBytes: Int64): Int64 {
        if (metadataBytes < 0 || raw > Int64.Max / 16 || encoded > Int64.Max / 32 || nodes > Int64.Max / 512) {
            throw IllegalArgumentException("display invoice overflow") }
        let scalar = raw * 16; let serialized = encoded * 32; let cells = nodes * 512
        if (scalar > Int64.Max - serialized || scalar + serialized > Int64.Max - cells - 65536 ||
            metadataBytes > (Int64.Max - scalar - serialized - cells - 65536) / 32) {
            throw IllegalArgumentException("display invoice overflow") }
        65536 + scalar + serialized + cells + metadataBytes * 32
    }
}

// Count the original preview algorithm without creating a prefix, marker or
// byte array. Strings are valid UTF8; backing bytes are read only in this loan.
private func tuiPreviewExactSize(value: String, maximum: Int64, lineMaximum: Int64): Int64 {
    if (value.size == 0) { return 0 }
    let total = max(1, maximum); let line = max(1, min(lineMaximum, total))
    var end = min(value.size, total); var index: Int64 = 0; var start: Int64 = 0
    while (index < end) {
        if (value[index] == b'\n') { start = index + 1 }
        else if (index - start + 1 > line) { end = start + line; break }
        index++
    }
    if (end < value.size) {
        while (end > 0 && (value[end] & 0xc0) == 0x80) { end-- }
    }
    if (end == value.size) { return end }
    var omitted = value.size - end; var digits: Int64 = 1
    while (omitted >= 10) { omitted /= 10; digits++ }
    end + (if (end == 0 || value[end - 1] == b'\n') { 0 } else { 1 }) + "… ".size + digits + " bytes omitted …".size
}

private func tuiDisplayProjectionInvoice(detail: AgentValue, code: String): Int64 {
    let name = valueText(detail, "name"); let callId = valueText(detail, "call_id")
    let invoice = TuiProjectionInvoice()
    if (code == "tool.execution_started") {
        match (detail.field("arguments")) { case Some(value) => invoice.visit(value, 0); case None => invoice.add(0, 4) }
    } else {
        let output = match (detail.field("output")) { case Some(value) => value; case None => nullValue() }
        if (name == "bash" || name == "bash_readonly") {
            let stdout = if (output.unifiedKind == ValueKind.Text) { output.text } else { valueText(output, "stdout") }
            let stderr = if (output.unifiedKind == ValueKind.Object) { valueText(output, "stderr") } else { "" }
            let copied = tuiPreviewExactSize(stdout, 4096, 1024) + tuiPreviewExactSize(stderr, 4096, 1024) +
                valueText(output, "exit_code").size + firstArtifactId(output).size
            invoice.nodes = 17; invoice.add(copied + 512, copied * 6 + 2048)
        } else { invoice.visit(output, 0) }
    }
    invoice.total(name.size + callId.size)
}

// The actual App adopts the empty token before any fallible projection. Its
// fixed copied-data payment comes from the original real row's opaque bank.
func copyOwnedTuiToolEvent(event: OwnedAgentEvent,
    register: (OwnedTuiToolDisplay) -> Unit): Result<OwnedTuiToolDisplay> {
    match (event.ensureAdditionalRetainedPeak(4096)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let copy = OwnedTuiProjectionHolder()
    let result = event.withEvent(1048576, { actual =>
        match (actual.payload) {
            case AgentEventPayload.Extension(kind, detail) =>
                let code = valueText(detail, "code")
                if (kind != AgentEventKind.Tool || (code != "tool.execution_started" && code != "tool.execution_completed")) {
                    return ownedTuiDisplayError("display.unexpected_event") }
                let invoice = tuiDisplayProjectionInvoice(detail, code)
                let paid = match (event.acquireCopiedDisplayAllocation(invoice)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                try { copy.value = Some(OwnedTuiToolDisplay(paid, invoice)); register(copy.value.getOrThrow()) }
                catch (error: Exception) { let _ = paid.closeAfterCopiedDisplayRetirement(); throw error }
                let name = copyTuiDisplayText(valueText(detail, "name"))
                let callId = copyTuiDisplayText(valueText(detail, "call_id"))
                let mapped = if (code == "tool.execution_started") {
                    let argumentBudget = TuiProjectionBudget(12288)
                    let arguments = match (detail.field("arguments")) {
                        case Some(value) => encodeAgentValue(projectTuiValue(value, argumentBudget, 0))
                        case None => "null" }
                    if (callId == "") { TuiAgentEvent.ToolStarted(name, arguments) }
                    else { TuiAgentEvent.ToolStartedWithId(name, callId, arguments) }
                } else {
                    let output = match (detail.field("output")) { case Some(value) => value; case None => nullValue() }
                    let completion = projectTuiToolCompletion(output, name)
                    let failed = valueBoolean(detail, "is_error")
                    if (callId == "") { TuiAgentEvent.ToolCompleted(name, failed, completion) }
                    else { TuiAgentEvent.ToolCompletedWithId(name, callId, failed, completion) }
                }
                copy.value.getOrThrow().installCopiedEvent(mapped)
            case _ => ownedTuiDisplayError("display.unexpected_event") }
    })
    match (result) {
        case Result.Err(error) =>
            // No copied event escaped to a consumer on this builder failure.
            // The original alias remains paid; only empty/cleared copy data
            // may close, after the complete original borrow has ended.
            match (copy.value) { case Some(value) => let _ = value.closeAfterCopiedDisplayRetirement(); case None => () }
            Result.Err(error)
        case Result.Ok(_) => Result.Ok(copy.value.getOrThrow()) }
}
