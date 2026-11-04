package agent_product

import agent_domain.*
import agent_runtime.*
import std.collection.*
import stdx.crypto.digest.*
import tool_runtime.*
import yjson.*
import yjson_support.*

let PLAN_CONTRACT_OPEN = "\n\n<plan-contract>\n"
let PLAN_CONTRACT_CLOSE = "\n</plan-contract>"

func planReviewDocument(content: String, contract: AgentValue): String {
    content.trimAscii() + PLAN_CONTRACT_OPEN + contract.toJson() + PLAN_CONTRACT_CLOSE
}

func planReviewContract(document: String, requirePins!: Bool = true): Result<PlanContract> {
    let start = match (document.indexOf(PLAN_CONTRACT_OPEN)) {
        case Some(value) => value + PLAN_CONTRACT_OPEN.size
        case None => return planExecutionError("plan.contract_required",
            "Record a structured execution contract with plan_write before approving execution")
    }
    if (!document.endsWith(PLAN_CONTRACT_CLOSE)) {
        return planExecutionError("plan.contract_invalid", "The reviewed execution contract is incomplete")
    }
    try {
        parsePlanContract(parseUnifiedJson(document[start..document.size - PLAN_CONTRACT_CLOSE.size]),
            requireToolIdentities: requirePins)
    } catch (_: Exception) {
        planExecutionError("plan.contract_invalid", "The reviewed execution contract is not valid JSON")
    }
}

// The host supplies implementation pins before displaying/hash-binding the
// document. Existing pins are never silently changed after a reviewer saw them.
func pinPlanReviewDocument(document: String, catalog: ToolCatalog, workspace: LocalWorkspace,
    threadId!: ?ThreadId = None<ThreadId>): Result<String> {
    pinPlanReviewText204(document, catalog, workspace, threadId, false)
}
// Internal canonical identity only: all current tool/source/schema checks are
// identical to the public review; no complete Raw document is published.
func pinPlanReviewHash204(document: String, catalog: ToolCatalog, workspace: LocalWorkspace,
    threadId!: ?ThreadId = None<ThreadId>): Result<String> {
    pinPlanReviewText204(document, catalog, workspace, threadId, true)
}
private func pinPlanReviewText204(document: String, catalog: ToolCatalog, workspace: LocalWorkspace,
    threadId: ?ThreadId, hashOnly: Bool): Result<String> {
    let source = try { catalog.openPlanIdentityCopy204(threadId) }
        catch (_: LogicalJsonPayloadError) { return planExecutionError("plan.review_copy_capacity", "Plan review cannot fit its original Catalog DATA budget") }
    let owner = match (source) {
        case Some(value) => value
        case None => return planExecutionError("plan.review_copy_owner_required", "Plan review requires its original Catalog DATA owner")
    }
    let consumer = try { owner.beginConsumer204() }
        catch (_: LogicalJsonPayloadError) {
            owner.closeAfterCaller204()
            return planExecutionError("plan.review_copy_capacity", "Plan review cannot fit its original Catalog DATA budget")
        }
    let output = ProductPlanReviewOutput204(owner, hashOnly)
    let reviewed = consumer.withIdentities204<Result<String>>({ identities =>
        pinPlanReviewClosedFrame204(document, workspace, identities, output)
    })
    // The actual complete pin/copy helper has returned. No identity aliases
    // occur in its output; only independently prepaid String copies survive.
    output.returnBuilderFrame204()
    consumer.returnConsumerFrame204()
    owner.closeAfterCaller204()
    reviewed
}

// A builder has a real independent message lifetime in the SAME Catalog
// bank. A derived lease on the long-lived Catalog would retain its physical
// high-water until the last Catalog owner, even after this builder returned.
private func productPlanReviewTemporaryAllocation204(source: ToolCatalogIdentityOwner204,
    bytes: Int64): LogicalJsonOwnerReservation {
    let anchor = source.deriveRetainedAllocation204(4096)
    try { productPlanReviewTemporaryAllocationFrame204(anchor, bytes) }
    finally { anchor.close() }
}
private func productPlanReviewTemporaryAllocationFrame204(anchor: LogicalJsonOwnerReservation,
    bytes: Int64): LogicalJsonOwnerReservation {
    anchor.acquireIndependentDataFrame(bytes)
}

private class ProductPlanReviewOutput204 {
    private let source: ToolCatalogIdentityOwner204
    let hashOnly: Bool
    private var temporary: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retained: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    init(source: ToolCatalogIdentityOwner204, hashOnly: Bool) { this.source = source; this.hashOnly = hashOnly }
    func ensurePeak204(bytes: Int64): Unit {
        match (temporary) {
            case Some(value) => value.ensureRetainedPeak(bytes)
            case None => temporary = Some(productPlanReviewTemporaryAllocation204(source, bytes))
        }
    }
    private func fundReturned204(bytes: Int64): Unit {
        if (retained.isSome()) { throw IllegalStateException("plan review output was already copied") }
        retained = Some(source.deriveRetainedAllocation204(bytes))
    }
    func copyDocument204(document: String): String {
        if (document.size > 134217728 - 8192) {
            throw LogicalJsonPayloadError("plan review output exceeds its original DATA envelope") }
        // The temporary recipe already pays the draft and UTF-8 conversion
        // buffer. This separate lease pays only the final independent String,
        // which may outlive both the parsed contract and the identity loan.
        fundReturned204(document.size + 8192)
        String.fromUtf8(document.toArray())
    }
    // processToolCanonicalArguments -> LocalWorkspace.resolve ->
    // hostWorkspaceError has scalar fields, no attempt/observation attachment.
    // Its escaping copies keep their own payment, not the parsed-graph peak.
    func copyWorkspaceError204(error: AgentError): AgentError {
        if (error.attemptFailure.isSome() || error.observation.isSome()) {
            throw IllegalStateException("workspace canonicalization error acquired an unsupported diagnostic attachment") }
        var bytes = error.code.size + error.message.size
        for (field in error.fields) { bytes += field.name.size + field.value.size }
        if (error.fields.size > (134217728 - 8192) / 1024 ||
            bytes > (134217728 - 8192 - error.fields.size * 1024) / 64) {
            throw LogicalJsonPayloadError("plan review error copy exceeds its original DATA envelope") }
        let invoice = bytes * 64 + error.fields.size * 1024 + 8192
        fundReturned204(invoice)
        let fields = ArrayList<ErrorField>()
        for (field in error.fields) {
            fields.add(ErrorField(String.fromUtf8(field.name.toArray()), String.fromUtf8(field.value.toArray())))
        }
        AgentError(error.kind, String.fromUtf8(error.code.toArray()),
            String.fromUtf8(error.message.toArray()), retryable: error.retryable,
            fallbackAllowed: error.fallbackAllowed, fields: fields.toArray())
    }
    func returnBuilderFrame204(): Unit {
        // Called only after the entire concrete builder/loan callback returned.
        // Raw output/error copies retain their original compatibility lifetime;
        // no temporary graph or prose construction peak escapes with them.
        let copied = retained; retained = None<LogicalJsonOwnerReservation>
        match (copied) { case Some(value) => productRegistryEscapedCopies83.adopt(value); case None => () }
        let returned = temporary; temporary = None<LogicalJsonOwnerReservation>
        match (returned) { case Some(value) => value.close(); case None => () }
    }
}
private func pinPlanReviewClosedFrame204(document: String, workspace: LocalWorkspace,
    identities: Array<ToolCatalogIdentity204>, output: ProductPlanReviewOutput204): Result<String> {
    try { pinPlanReviewPaidCopyFrame204(document, workspace, identities, output) }
    catch (_: LogicalJsonPayloadError) {
        planExecutionError("plan.review_copy_capacity", "Plan review cannot fit its original Catalog DATA budget")
    }
    // Unexpected builder/copy failures propagate through withIdentities204:
    // its actual consumer remains Held rather than guessing a return witness.
}
private func pinPlanReviewPaidCopyFrame204(document: String, workspace: LocalWorkspace,
    identities: Array<ToolCatalogIdentity204>, output: ProductPlanReviewOutput204): Result<String> {
    output.ensurePeak204(131072)
    let contractStart = match (document.indexOf(PLAN_CONTRACT_OPEN)) {
        case Some(value) => value + PLAN_CONTRACT_OPEN.size
        case None => return planExecutionError("plan.contract_required",
            "Record a structured execution contract with plan_write before approving execution")
    }
    if (!document.endsWith(PLAN_CONTRACT_CLOSE)) {
        return planExecutionError("plan.contract_invalid", "The reviewed execution contract is incomplete") }
    let contractBytes = document.size - PLAN_CONTRACT_CLOSE.size - contractStart
    // Preserve parseUnifiedJson's original 1 MiB/depth-64 contract bounds.
    // Human prose belongs to the workflow source, not this JSON input graph.
    if (contractBytes < 0 || contractBytes > 1048576) {
        return planExecutionError("plan.contract_invalid", "The reviewed execution contract is not valid JSON") }
    // Public review keeps its original twelve-text construction envelope.
    // Internal hashing uses the bounded advisory filter: input-sized byte
    // array, possible prefix-array copy, validated String and construction
    // scratch (four extents), plus two conservative body/check slices. The
    // complete filter returns only small advisory values before leading trim
    // and segment hashing; no full reviewed/final-document concat overlaps it.
    let textCopies: Int64 = if (output.hashOnly) { 6 } else { 12 }
    if (document.size > (134217728 - 131072 - contractBytes * 64) / textCopies) {
        throw LogicalJsonPayloadError("plan review text exceeds its original temporary DATA envelope") }
    // The public path retains its original twelve-text recipe for native
    // advisory replace and concatenation/copy phases. The private hash path
    // uses the bounded filter/segment recipe above instead. Both retain the
    // full phase peak until the complete helper returns; prose is never
    // multiplied by JSON nodes or retained as the published output's invoice.
    let base = 131072 + document.size * textCopies + contractBytes * 64
    output.ensurePeak204(base)
    let bytes = document[contractStart..document.size - PLAN_CONTRACT_CLOSE.size].toArray()
    var nodes: Int64 = 0
    var quoted = false
    var escaped = false
    var primitive = false
    for (byte in bytes) {
        if (quoted) {
            if (escaped) { escaped = false } else if (byte == 92u8) { escaped = true }
            else if (byte == 34u8) { quoted = false }
            continue
        }
        if (byte == 34u8) { nodes++; quoted = true; primitive = false }
        else if (byte == 123u8 || byte == 91u8) { nodes++; primitive = false }
        else if (byte == 44u8 || byte == 58u8 || byte == 125u8 || byte == 93u8 || byte <= 32u8) { primitive = false }
        else if (!primitive) { nodes++; primitive = true }
    }
    if (nodes > (134217728 - base) / 1024) {
        throw LogicalJsonPayloadError("plan review graph exceeds the original copied DATA envelope") }
    let parsedPeak = base + nodes * 1024
    output.ensurePeak204(parsedPeak)
    let contract = match (planReviewContract(document, requirePins: false)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    var extra: Int64 = 0
    for (roots in [contract.targetRoots, contract.participatingRepositories]) {
        for (root in roots) {
            var components: Int64 = 1
            for (byte in root.toArray() where byte == 47u8) { components++ }
            extra += root.size * components * 32 + 4096
        }
    }
    for (step in contract.steps) {
        for (action in step.actions) {
            for (tool in action.toolNames) {
                for (entry in identities where entry.name == tool) {
                    extra += (entry.version.size + entry.fingerprint.size + entry.schemaDigest.size) * 256 + 12288
                }
            }
        }
    }
    if (extra > 134217728 - parsedPeak) {
        throw LogicalJsonPayloadError("plan review retained copies exceed their original DATA envelope") }
    output.ensurePeak204(parsedPeak + extra)
    let steps = ArrayList<PlanExecutionStep>()
    for (step in contract.steps) {
        let actions = ArrayList<PlanAction>()
        for (action in step.actions) {
            let arguments = if (action.exactArguments && action.toolNames.size == 1 &&
                (action.toolNames[0] == "bash" || action.toolNames[0] == "command_probe")) {
                match (processToolCanonicalArguments(
                    ToolCall("plan-review", action.toolNames[0], action.argumentConstraints), workspace
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(output.copyWorkspaceError204(error))
                }
            } else { action.argumentConstraints }
            let pins = ArrayList<ValueField>()
            for (tool in action.toolNames) {
                var identity: ?AgentValue = None
                for (entry in identities where entry.name == tool) {
                    identity = Some(objectValue([
                        ValueField("version", textValue(String.fromUtf8(entry.version.toArray()))),
                        ValueField("fingerprint", textValue(String.fromUtf8(entry.fingerprint.toArray()))),
                        ValueField("schema_digest", textValue(String.fromUtf8(entry.schemaDigest.toArray())))
                    ]))
                }
                let pin = match (identity) {
                    case Some(value) => value
                    case None => return planExecutionError("plan.tool_unavailable",
                        "An approved action references an unregistered tool")
                }
                match (action.toolIdentities.field(tool)) {
                    case Some(existing) => if (canonicalAgentValue(existing) != canonicalAgentValue(pin)) {
                        return planExecutionError("plan.tool_identity_changed",
                            "A reviewed tool implementation changed; regenerate and review the plan")
                    }
                    case None => ()
                }
                pins.add(ValueField(tool, pin))
            }
            actions.add(PlanAction(action.id, action.toolNames, action.networkModes,
                action.effectCeiling, arguments, action.maxAttempts,
                exactArguments: action.exactArguments, evidence: action.evidence,
                artifactDigest: action.artifactDigest, toolIdentities: objectValue(pins.toArray()),
                delegatedActionIds: action.delegatedActionIds))
        }
        steps.add(PlanExecutionStep(step.id, step.dependencies, step.required, actions.toArray(),
            fallbackStepId: step.fallbackStepId))
    }
    let roots = ArrayList<String>()
    for (root in contract.targetRoots) { roots.add(canonicalTaskPath(root)) }
    let repositories = ArrayList<String>()
    for (root in contract.participatingRepositories) { repositories.add(canonicalTaskPath(root)) }
    let pinned = PlanContract(roots.toArray(), steps.toArray(), participatingRepositories: repositories.toArray())
    match (parsePlanContract(planContractValue(pinned))) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let start = document.indexOf(PLAN_CONTRACT_OPEN).getOrThrow()
    let body = document[..start]
    let checksMarker = "\n\n<plan-review-checks>\n"
    let cleanBody = match (body.indexOf(checksMarker)) {
        case Some(index) => body[..index]
        case None => body
    }
    if (output.hashOnly) {
        return Result.Ok(output.copyDocument204(productPlanReviewCanonicalHash204(cleanBody, planContractValue(pinned))))
    }
    let reviewedBody = cleanBody + checksMarker +
        productPlanReviewAdvisoriesValue(cleanBody).toJson() + "\n</plan-review-checks>"
    Result.Ok(output.copyDocument204(planReviewDocument(reviewedBody, planContractValue(pinned))))
}
private func productPlanReviewAdvisoryJson204(body: String): String {
    productPlanReviewBoundedAdvisoriesValue204(body).toJson()
}
private func productPlanReviewCanonicalHash204(body: String, contract: AgentValue): String {
    // This whole helper returns before the large body-prefix allocation.
    let checks = productPlanReviewAdvisoryJson204(body)
    // Use the same ASCII trim implementation as the public concatenation.
    // If the body is all whitespace its leading trim also reaches the two
    // newlines before the check marker; body trailing whitespace otherwise
    // remains inside the full reviewed document.
    let leadingTrimmedBody = body.trimAsciiStart()
    let marker = if (leadingTrimmedBody == "") {
        "\n\n<plan-review-checks>\n".trimAsciiStart()
    } else { "\n\n<plan-review-checks>\n" }
    let contractJson = contract.toJson()
    let hash = SHA256()
    for (part in [leadingTrimmedBody, marker, checks,
        "\n</plan-review-checks>", PLAN_CONTRACT_OPEN, contractJson, PLAN_CONTRACT_CLOSE]) {
        hash.write(unsafe { part.rawData() })
    }
    let digest = hash.finish(); let hex = "0123456789abcdef".toArray()
    let result = Array<Byte>(64, repeat: 0)
    for (index in 0..digest.size) {
        result[index * 2] = hex[Int64(digest[index]) / 16]
        result[index * 2 + 1] = hex[Int64(digest[index]) % 16]
    }
    String.fromUtf8(result)
}
