package agent_app

import agent_domain.*
import agent_domain.LogicalJsonOwnerReservation
import agent_domain.LogicalJsonCopiedDisplayOwnerPort
import agent_cli.*
import agent_tui.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import agent_product.*
import agent_runtime.*

import std.sync.*
import std.time.MonoTime
// Raw transport bytes and decoder/DOM overlap have distinct, simultaneous
// shares from the same actual peer bank. Enclosing real read/consumer helpers
// retain the exact cell until all their transferred references have ended.
class TuiOwnerReadFrame180 {
    private var rawPaid: ?LogicalJsonOwnerReservation
    private var codecPaid: ?LogicalJsonOwnerReservation = None
    private var rawData180: ?String = None<String>
    private var decodedData180: ?AgentValue = None<AgentValue>
    private let lock = Mutex()
    private var viewTransfer = false
    private var readReturned = false
    private var deliveryReturned = false
    private var decoderReturned = false
    var next180: ?TuiOwnerReadFrame180 = None
    init(rawPaid: LogicalJsonOwnerReservation) { this.rawPaid = Some(rawPaid) }
    func initializeCodec180(peer: ProductOwnerPeer180): Unit {
        if (codecPaid.isSome()) { throw IllegalStateException("owner codec is already registered") }
        codecPaid = Some(peer.deriveOwnerFrameData180(4096))
    }
    func readAndDecode180(peer: ProductOwnerPeer180, maxBytes: Int64, deadline!: ?MonoTime = None): AgentValue {
        let raw = match (peer.readOwnerFrame180(rawPaid.getOrThrow(), deadline)) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(value) => value }
        rawData180 = Some(raw)
        codecPaid.getOrThrow().ensureRetainedPeak(ownerFrontendDecodeInvoice180(raw))
        let decoded = match (decodeAgentValue(raw, maxBytes: maxBytes)) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(value) => value }
        decodedData180 = Some(decoded)
        decoded
    }
    func newCopiedAllocation180(invoice: Int64): LogicalJsonCopiedDisplayAllocation {
        codecPaid.getOrThrow().acquireCopiedDisplayAllocation(invoice).value().getOrThrow()
    }
    func copyViewDocument180(value: AgentValue): TuiPluginViewDocument {
        tuiOwnerShape180(value, 3)
        let paid = codecPaid.getOrThrow().acquireIndependentDataFrame(65536)
        var retained = false
        try {
            paid.ensureRetainedPeak(tuiOwnerInvoiceAdd180(2097152, tuiOwnerDataInvoice180(value)))
            let document = TuiPluginViewDocument(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]),
                tuiOwnerText180(value.items[2]), { bytes => paid.ensureRetainedPeak(bytes) }, { => paid.close() })
            retained = true
            document
        } finally { if (!retained) { paid.close() } }
    }
    func transferView180(): Unit {
        lock.lock()
        try {
            if (viewTransfer) { throw IllegalStateException("owner View frame was already transferred") }
            viewTransfer = true
        } finally { lock.unlock() }
    }
    func viewReadReturned180(): Unit {
        lock.lock(); try { readReturned = true; retireViewIfReturned180() } finally { lock.unlock() }
    }
    func viewDeliveryReturned180(): Unit {
        lock.lock(); try { deliveryReturned = true; retireViewIfReturned180() } finally { lock.unlock() }
    }
    func viewDecoderReturned180(): Unit {
        lock.lock(); try { decoderReturned = true; retireViewIfReturned180() } finally { lock.unlock() }
    }
    private func retireViewIfReturned180(): Unit {
        if (viewTransfer && readReturned && deliveryReturned && decoderReturned) {
            retireAfterWholeReadConsumer180()
        }
    }
    func retireAfterWholeReadConsumer180(): Unit {
        rawData180 = None<String>; decodedData180 = None<AgentValue>
        match (codecPaid) { case Some(paid) => paid.close(); codecPaid = None; case None => () }
        match (rawPaid) { case Some(paid) => paid.close(); rawPaid = None; case None => () }
    }
}

// Conservative physical UTF-8/JSON/DOM/String overlap counted before encoding.
func tuiOwnerInvoiceAdd180(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) { throw IllegalArgumentException("tui.owner_invoice_overflow") }; left + right
}
func tuiOwnerInvoice180(value: String): Int64 {
    // Count original UTF-8 without allocating an escaped surrogate string.
    var encoded: Int64 = 2
    for (byte in unsafe { value.rawData() }) {
        encoded = tuiOwnerInvoiceAdd180(encoded,
            if (byte < 32) { 6 } else if (byte == b'"' || byte == b'\\') { 2 } else { 1 })
    }
    if (value.size > Int64.Max / 4 || encoded > Int64.Max / 4) { throw IllegalArgumentException("tui.owner_invoice_overflow") }
    tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceAdd180(value.size * 4, encoded * 4))
}
// Actual lexical density pays DOM/container slots before the decoder creates
// them. Flat large text keeps its original frame bound rather than acquiring
// a smaller implicit bound from a worst-case per-byte node multiplier.
func ownerFrontendDecodeInvoice180(raw: String): Int64 {
    if (raw.size > (Int64.Max - 65536) / 8) { throw IllegalArgumentException("tui.owner_invoice_overflow") }
    var total: Int64 = 65536 + raw.size * 8
    var quoted = false; var escaped = false; var atom = false
    for (byte in unsafe { raw.rawData() }) {
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') {
            quoted = true; atom = false; total = tuiOwnerInvoiceAdd180(total, 512)
        } else if (byte == b'[' || byte == b'{') {
            atom = false; total = tuiOwnerInvoiceAdd180(total, 512)
        } else if (byte == b',' || byte == b':' || byte == b']' || byte == b'}') {
            atom = false
        } else if (byte != b' ' && byte != b'\t' && byte != b'\r' && byte != b'\n' && !atom) {
            atom = true; total = tuiOwnerInvoiceAdd180(total, 512)
        }
    }
    total
}
func tuiOwnerInvoice180(_: Int64): Int64 { 512 }
func tuiOwnerInvoice180(_: Bool): Int64 { 512 }
func tuiOwnerInvoiceArray180<T>(values: Array<T>, invoice: (T) -> Int64): Int64 {
    var total: Int64 = 512; for (value in values) { total = tuiOwnerInvoiceAdd180(total, invoice(value)) }; total
}
func tuiOwnerInvoiceOption180<T>(value: ?T, invoice: (T) -> Int64): Int64 {
    match (value) { case Some(actual) => tuiOwnerInvoiceAdd180(512, invoice(actual)); case None => 512 }
}

func tuiOwnerInvoice180(value: TuiAttemptScope): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.runId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.semanticRequestId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.attemptId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.sequence))
    total
}

func tuiOwnerInvoice180(value: TuiToolCompletionPayload): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.detailPreview))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.stdoutPreview))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.stderrPreview))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.exitCode))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.stdoutBytes))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.stderrBytes))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.sourceTruncated))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.previewTruncated))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.artifactId))
    total
}

func tuiOwnerInvoice180(value: TuiAskOption): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.label))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.description))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.preview))
    total
}

func tuiOwnerInvoice180(value: TuiAskQuestion): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.id))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.question))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.options, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.header))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.multi))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceOption180(value.recommended, { item => tuiOwnerInvoice180(item) }))
    total
}

func tuiOwnerInvoice180(value: TuiAskRequest): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.requestId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.questions, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.callId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.runId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.sessionId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.operationId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.commandId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.epoch))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.interactionKind))
    total
}

func tuiOwnerInvoice180(value: TuiAskAnswer): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.id))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.selectedOptions, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceOption180(value.customInput, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceOption180(value.note, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.timedOut))
    total
}

func tuiOwnerInvoice180(value: TuiTodoSaveResult): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.saved))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.message))
    total
}

func tuiOwnerInvoice180(value: TuiTodoLoadResult): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.loaded))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.markdown))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.message))
    total
}

func tuiOwnerInvoice180(value: TuiSetupRequest): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.profileId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.provider))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.protocol))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.model))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.baseUrl))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.apiKeyEnv))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.credential))
    total
}

func tuiOwnerInvoice180(value: TuiSessionNode): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.id))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.name))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.summary))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.parentId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.model))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.workMode))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.updatedAt))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.current))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.archived))
    total
}

func tuiOwnerInvoice180(value: TuiSubagentInfo): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.id))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.agent))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.status))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.task))
    total
}

func tuiOwnerInvoice180(value: TuiTranscriptItem): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.id))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.kind))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.title))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.body))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.state))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.collapsed))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.toolName))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.toolArguments))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.toolCallId))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.toolOutput))
    total
}

func tuiOwnerInvoice180(value: TuiConversationView): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.id))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.label))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.status))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.isMain))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.items, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.nextBeforeOrdinal))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.hasMore))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.provisionalEvents, { item => tuiOwnerInvoice180(item) }))
    total
}

func tuiOwnerInvoice180(value: TuiTranscriptPage): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.items, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.nextBeforeOrdinal))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.hasMore))
    total
}

func tuiOwnerInvoice180(value: TuiThemeDefinition): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.name))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.raised))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.userMessageBg))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.text))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.muted))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.accent))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.secondary))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.success))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.warning))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.danger))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.userMessageText))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.reasoning))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.tool))
    total
}

func tuiOwnerInvoice180(value: SlashCommandDefinition): Int64 {
    var total: Int64 = 512
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.name))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.group))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.description))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.usage))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.aliases, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoice180(value.source))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.subcommands, { item => tuiOwnerInvoice180(item) }))
    total = tuiOwnerInvoiceAdd180(total, tuiOwnerInvoiceArray180(value.pathArgumentPrefixes, { item => tuiOwnerInvoiceArray180(item, { item => tuiOwnerInvoice180(item) }) }))
    total
}

func tuiOwnerInvoice180(value: TuiPluginViewField): Int64 {
    tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(value.id), tuiOwnerInvoice180(value.value)))
}
func tuiOwnerInvoice180(value: TuiPluginViewDocument): Int64 {
    value.withPresentation({ metadata, model, primary =>
        tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(metadata),
            tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(model), tuiOwnerInvoice180(primary)))
    })
}

func tuiOwnerInvoice180(value: TuiApprovalDecision): Int64 {
    match (value) {
        case TuiApprovalDecision.AllowOnce => 512
        case TuiApprovalDecision.AllowSession => 512
        case TuiApprovalDecision.Reject(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
    }
}


func tuiOwnerInvoice180(value: TuiQueueWithdrawal): Int64 {
    match (value) {
        case TuiQueueWithdrawal.Withdrawn(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiQueueWithdrawal.AlreadyDelivered => 512
        case TuiQueueWithdrawal.Failed(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
    }
}

func tuiOwnerInvoice180(value: TuiAskResolution): Int64 {
    match (value) {
        case TuiAskResolution.Answers(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceArray180(v0, { item => tuiOwnerInvoice180(item) }))
        case TuiAskResolution.Chat => 512
        case TuiAskResolution.Cancelled => 512
    }
}

func tuiOwnerInvoice180(value: UiCardKind): Int64 {
    match (value) {
        case UiCardKind.User => 512
        case UiCardKind.Assistant => 512
        case UiCardKind.Reasoning => 512
        case UiCardKind.Tool => 512
        case UiCardKind.Approval => 512
        case UiCardKind.Permission => 512
        case UiCardKind.Ask => 512
        case UiCardKind.Plan => 512
        case UiCardKind.Subagent => 512
        case UiCardKind.Advisor => 512
        case UiCardKind.Reviewer => 512
        case UiCardKind.Job => 512
        case UiCardKind.Warning => 512
        case UiCardKind.Compaction => 512
        case UiCardKind.Summary => 512
        case UiCardKind.Error => 512
        case UiCardKind.Steer => 512
        case UiCardKind.Setup => 512
        case UiCardKind.Mcp => 512
    }
}

func tuiOwnerInvoice180(value: TuiTurnAction): Int64 {
    match (value) {
        case TuiTurnAction.NoAction => 512
        case TuiTurnAction.Exit => 512
        case TuiTurnAction.OpenProviderSetup => 512
        case TuiTurnAction.OpenModelSelector => 512
        case TuiTurnAction.OpenBranchSelector => 512
        case TuiTurnAction.OpenPluginView(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.PluginViewLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.ConfirmPluginView(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.OpenDocument(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiTurnAction.ModelsLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceArray180(v0, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.ThemeSelected(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoiceArray180(v2, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.SessionsLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceArray180(v0, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.BranchesLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceArray180(v0, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.SessionTreeLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceArray180(v0, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.SubagentsLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceArray180(v0, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.ConversationFocused(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.TodoLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.ModelSelected(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiTurnAction.SessionSelected(v0, v1, v2, v3) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2)), tuiOwnerInvoiceOption180(v3, { item => tuiOwnerInvoice180(item) }))
        case TuiTurnAction.BranchSelected(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiTurnAction.ResetCompleted(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.SetupConfigured(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.TodoSaved(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.DraftLoaded(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiTurnAction.UiStatus(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
    }
}

func tuiOwnerInvoice180(value: TuiAgentEvent): Int64 {
    match (value) {
        case TuiAgentEvent.AttemptStarted(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.AttemptTextDelta(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.AttemptReasoningDelta(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.AttemptToolStarted(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.AttemptToolArguments(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.AttemptFailed(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.AttemptCancelled(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.AttemptAborted(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.AttemptRetryScheduled(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.DecisionCommitted(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.TextDelta(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.ReasoningDelta(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.ToolStarted(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.ToolStartedWithId(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.ToolOutput(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.ToolCompleted(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.ToolCompletedWithId(v0, v1, v2, v3) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2)), tuiOwnerInvoice180(v3))
        case TuiAgentEvent.InputInjected(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.JobStatus(v0, v1, v2, v3, v4, v5) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2)), tuiOwnerInvoice180(v3)), tuiOwnerInvoice180(v4)), tuiOwnerInvoice180(v5))
        case TuiAgentEvent.SubagentStatus(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.SubagentStream(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.Approval(v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2)), tuiOwnerInvoice180(v3)), tuiOwnerInvoice180(v4)), tuiOwnerInvoice180(v5)), tuiOwnerInvoice180(v6)), tuiOwnerInvoice180(v7)), tuiOwnerInvoice180(v8)), tuiOwnerInvoice180(v9)), tuiOwnerInvoice180(v10)), tuiOwnerInvoice180(v11)), tuiOwnerInvoice180(v12))
        case TuiAgentEvent.ApprovalReview(v0, v1, v2, v3, v4, v5, v6, v7, v8) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2)), tuiOwnerInvoice180(v3)), tuiOwnerInvoice180(v4)), tuiOwnerInvoice180(v5)), tuiOwnerInvoice180(v6)), tuiOwnerInvoice180(v7)), tuiOwnerInvoice180(v8))
        case TuiAgentEvent.Ask(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.PluginViewClosed(v0, v1) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoiceAdd180(tuiOwnerInvoice180(v0), tuiOwnerInvoice180(v1)))
        case TuiAgentEvent.Usage(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.Setup(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.Plan(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.PluginNotice(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.Warning(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiAgentEvent.Compaction(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiAgentEvent.Summary(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.Error(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiAgentEvent.OwnedToolDisplay(_) | TuiAgentEvent.OwnedFailureDisplay113(_) | TuiAgentEvent.OwnedRegistryError167(_, _) => throw IllegalArgumentException("tui.owner_owned_serializer_required")
    }
}

func tuiOwnerInvoice180(value: TuiSubagentStreamEvent): Int64 {
    match (value) {
        case TuiSubagentStreamEvent.AttemptStarted(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.AttemptTextDelta(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiSubagentStreamEvent.AttemptReasoningDelta(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiSubagentStreamEvent.AttemptToolStarted(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiSubagentStreamEvent.AttemptToolArguments(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiSubagentStreamEvent.AttemptFailed(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.AttemptCancelled(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.AttemptAborted(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.DecisionCommitted(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.TextDelta(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.ReasoningDelta(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
        case TuiSubagentStreamEvent.ToolStarted(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiSubagentStreamEvent.ToolStartedWithId(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiSubagentStreamEvent.ToolOutput(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiSubagentStreamEvent.ToolCompleted(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiSubagentStreamEvent.ToolCompletedWithId(v0, v1, v2, v3) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2)), tuiOwnerInvoice180(v3))
        case TuiSubagentStreamEvent.InputInjected(v0, v1, v2) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1)), tuiOwnerInvoice180(v2))
        case TuiSubagentStreamEvent.Usage(v0, v1) => tuiOwnerInvoiceAdd180(tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0)), tuiOwnerInvoice180(v1))
        case TuiSubagentStreamEvent.Error(v0) => tuiOwnerInvoiceAdd180(512, tuiOwnerInvoice180(v0))
    }
}
func tuiOwnerDataInvoice180(value: AgentValue): Int64 {
    var total: Int64 = 512
    match (value.unifiedKind) {
        case ValueKind.Text => total = tuiOwnerInvoice180(value.text)
        case ValueKind.List => for (item in value.items) { total = tuiOwnerInvoiceAdd180(total, tuiOwnerDataInvoice180(item)) }
        case ValueKind.Object => throw IllegalArgumentException("tui.owner_unexpected_object")
        case _ => () }
    total
}
// Typed DATA only. No Source, Prepared invocation or execution authority is
// reconstructed by this codec. Unknown tags and malformed shapes fail closed.
func tuiOwnerText180(value: AgentValue): String {
    if (value.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("tui.owner_expected_text") }; String.fromUtf8(value.text.toArray())
}
func tuiOwnerInteger180(value: AgentValue): Int64 {
    if (value.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("tui.owner_expected_integer") }; Int64.parse(value.numberText)
}
func tuiOwnerBoolean180(value: AgentValue): Bool {
    if (value.unifiedKind != ValueKind.Boolean) { throw IllegalArgumentException("tui.owner_expected_boolean") }; value.boolValue
}
func tuiOwnerShape180(value: AgentValue, count: Int64): Unit {
    if (value.unifiedKind != ValueKind.List || value.items.size != count) { throw IllegalArgumentException("tui.owner_invalid_shape") }
}
func tuiOwnerEncodeArray180<T>(values: Array<T>, encode: (T) -> AgentValue): AgentValue {
    listValue(values.map { item => encode(item) })
}
func tuiOwnerDecodeArray180<T>(value: AgentValue, decode: (AgentValue) -> T): Array<T> {
    if (value.unifiedKind != ValueKind.List) { throw IllegalArgumentException("tui.owner_expected_array") }
    Array<T>(value.items.size, { i => decode(value.items[i]) })
}
func tuiOwnerEncodeOption180<T>(value: ?T, encode: (T) -> AgentValue): AgentValue {
    match (value) { case Some(item) => listValue([encode(item)]); case None => listValue([]) }
}
func tuiOwnerDecodeOption180<T>(value: AgentValue, decode: (AgentValue) -> T): ?T {
    if (value.unifiedKind != ValueKind.List || value.items.size > 1) { throw IllegalArgumentException("tui.owner_invalid_option") }
    if (value.items.size == 0) { Option<T>.None } else { Some(decode(value.items[0])) }
}

func tuiOwnerEncode180(value: TuiAttemptScope): AgentValue {
    listValue([textValue(value.runId), textValue(value.semanticRequestId), textValue(value.attemptId), integerValue(value.sequence)])
}
func tuiOwnerDecodeTuiAttemptScope180(value: AgentValue): TuiAttemptScope {
    tuiOwnerShape180(value, 4)
    TuiAttemptScope(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerInteger180(value.items[3]))
}

func tuiOwnerEncode180(value: TuiToolCompletionPayload): AgentValue {
    listValue([textValue(value.detailPreview), textValue(value.stdoutPreview), textValue(value.stderrPreview), textValue(value.exitCode), integerValue(value.stdoutBytes), integerValue(value.stderrBytes), boolValue(value.sourceTruncated), boolValue(value.previewTruncated), textValue(value.artifactId)])
}
func tuiOwnerDecodeTuiToolCompletionPayload180(value: AgentValue): TuiToolCompletionPayload {
    tuiOwnerShape180(value, 9)
    TuiToolCompletionPayload(detailPreview: tuiOwnerText180(value.items[0]), stdoutPreview: tuiOwnerText180(value.items[1]), stderrPreview: tuiOwnerText180(value.items[2]), exitCode: tuiOwnerText180(value.items[3]), stdoutBytes: tuiOwnerInteger180(value.items[4]), stderrBytes: tuiOwnerInteger180(value.items[5]), sourceTruncated: tuiOwnerBoolean180(value.items[6]), previewTruncated: tuiOwnerBoolean180(value.items[7]), artifactId: tuiOwnerText180(value.items[8]))
}

func tuiOwnerEncode180(value: TuiAskOption): AgentValue {
    listValue([textValue(value.label), textValue(value.description), textValue(value.preview)])
}
func tuiOwnerDecodeTuiAskOption180(value: AgentValue): TuiAskOption {
    tuiOwnerShape180(value, 3)
    TuiAskOption(tuiOwnerText180(value.items[0]), description: tuiOwnerText180(value.items[1]), preview: tuiOwnerText180(value.items[2]))
}

func tuiOwnerEncode180(value: TuiAskQuestion): AgentValue {
    listValue([textValue(value.id), textValue(value.question), tuiOwnerEncodeArray180(value.options, { item => tuiOwnerEncode180(item) }), textValue(value.header), boolValue(value.multi), tuiOwnerEncodeOption180(value.recommended, { item => integerValue(item) })])
}
func tuiOwnerDecodeTuiAskQuestion180(value: AgentValue): TuiAskQuestion {
    tuiOwnerShape180(value, 6)
    TuiAskQuestion(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerDecodeArray180<TuiAskOption>(value.items[2], { item => tuiOwnerDecodeTuiAskOption180(item) }), header: tuiOwnerText180(value.items[3]), multi: tuiOwnerBoolean180(value.items[4]), recommended: tuiOwnerDecodeOption180<Int64>(value.items[5], { item => tuiOwnerInteger180(item) }))
}

func tuiOwnerEncode180(value: TuiAskRequest): AgentValue {
    listValue([textValue(value.requestId), tuiOwnerEncodeArray180(value.questions, { item => tuiOwnerEncode180(item) }), textValue(value.callId), textValue(value.runId), textValue(value.sessionId), textValue(value.operationId), textValue(value.commandId), integerValue(value.epoch), textValue(value.interactionKind)])
}
func tuiOwnerDecodeTuiAskRequest180(value: AgentValue): TuiAskRequest {
    tuiOwnerShape180(value, 9)
    TuiAskRequest(tuiOwnerText180(value.items[0]), tuiOwnerDecodeArray180<TuiAskQuestion>(value.items[1], { item => tuiOwnerDecodeTuiAskQuestion180(item) }), callId: tuiOwnerText180(value.items[2]), runId: tuiOwnerText180(value.items[3]), sessionId: tuiOwnerText180(value.items[4]), operationId: tuiOwnerText180(value.items[5]), commandId: tuiOwnerText180(value.items[6]), epoch: tuiOwnerInteger180(value.items[7]), interactionKind: tuiOwnerText180(value.items[8]))
}

func tuiOwnerEncode180(value: TuiAskAnswer): AgentValue {
    listValue([textValue(value.id), tuiOwnerEncodeArray180(value.selectedOptions, { item => textValue(item) }), tuiOwnerEncodeOption180(value.customInput, { item => textValue(item) }), tuiOwnerEncodeOption180(value.note, { item => textValue(item) }), boolValue(value.timedOut)])
}
func tuiOwnerDecodeTuiAskAnswer180(value: AgentValue): TuiAskAnswer {
    tuiOwnerShape180(value, 5)
    TuiAskAnswer(tuiOwnerText180(value.items[0]), selectedOptions: tuiOwnerDecodeArray180<String>(value.items[1], { item => tuiOwnerText180(item) }), customInput: tuiOwnerDecodeOption180<String>(value.items[2], { item => tuiOwnerText180(item) }), note: tuiOwnerDecodeOption180<String>(value.items[3], { item => tuiOwnerText180(item) }), timedOut: tuiOwnerBoolean180(value.items[4]))
}

func tuiOwnerEncode180(value: TuiTodoSaveResult): AgentValue {
    listValue([boolValue(value.saved), textValue(value.message)])
}
func tuiOwnerDecodeTuiTodoSaveResult180(value: AgentValue): TuiTodoSaveResult {
    tuiOwnerShape180(value, 2)
    TuiTodoSaveResult(tuiOwnerBoolean180(value.items[0]), tuiOwnerText180(value.items[1]))
}

func tuiOwnerEncode180(value: TuiTodoLoadResult): AgentValue {
    listValue([boolValue(value.loaded), textValue(value.markdown), textValue(value.message)])
}
func tuiOwnerDecodeTuiTodoLoadResult180(value: AgentValue): TuiTodoLoadResult {
    tuiOwnerShape180(value, 3)
    TuiTodoLoadResult(tuiOwnerBoolean180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
}

func tuiOwnerEncode180(value: TuiSetupRequest): AgentValue {
    listValue([textValue(value.profileId), textValue(value.provider), textValue(value.protocol), textValue(value.model), textValue(value.baseUrl), textValue(value.apiKeyEnv), textValue(value.credential)])
}
func tuiOwnerDecodeTuiSetupRequest180(value: AgentValue): TuiSetupRequest {
    tuiOwnerShape180(value, 7)
    TuiSetupRequest(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerText180(value.items[4]), tuiOwnerText180(value.items[5]), tuiOwnerText180(value.items[6]))
}

func tuiOwnerEncode180(value: TuiSessionNode): AgentValue {
    listValue([textValue(value.id), textValue(value.name), textValue(value.summary), textValue(value.parentId), textValue(value.model), textValue(value.workMode), integerValue(value.updatedAt), boolValue(value.current), boolValue(value.archived)])
}
func tuiOwnerDecodeTuiSessionNode180(value: AgentValue): TuiSessionNode {
    tuiOwnerShape180(value, 9)
    TuiSessionNode(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerText180(value.items[4]), tuiOwnerText180(value.items[5]), tuiOwnerInteger180(value.items[6]), tuiOwnerBoolean180(value.items[7]), archived: tuiOwnerBoolean180(value.items[8]))
}

func tuiOwnerEncode180(value: TuiSubagentInfo): AgentValue {
    listValue([textValue(value.id), textValue(value.agent), textValue(value.status), textValue(value.task)])
}
func tuiOwnerDecodeTuiSubagentInfo180(value: AgentValue): TuiSubagentInfo {
    tuiOwnerShape180(value, 4)
    TuiSubagentInfo(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
}

func tuiOwnerEncode180(value: TuiTranscriptItem): AgentValue {
    listValue([textValue(value.id), tuiOwnerEncode180(value.kind), textValue(value.title), textValue(value.body), textValue(value.state), boolValue(value.collapsed), textValue(value.toolName), textValue(value.toolArguments), textValue(value.toolCallId), textValue(value.toolOutput)])
}
func tuiOwnerDecodeTuiTranscriptItem180(value: AgentValue): TuiTranscriptItem {
    tuiOwnerShape180(value, 10)
    TuiTranscriptItem(tuiOwnerText180(value.items[0]), tuiOwnerDecodeUiCardKind180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), state: tuiOwnerText180(value.items[4]), collapsed: tuiOwnerBoolean180(value.items[5]), toolName: tuiOwnerText180(value.items[6]), toolArguments: tuiOwnerText180(value.items[7]), toolCallId: tuiOwnerText180(value.items[8]), toolOutput: tuiOwnerText180(value.items[9]))
}

func tuiOwnerEncode180(value: TuiConversationView): AgentValue {
    listValue([textValue(value.id), textValue(value.label), textValue(value.status), boolValue(value.isMain), tuiOwnerEncodeArray180(value.items, { item => tuiOwnerEncode180(item) }), integerValue(value.nextBeforeOrdinal), boolValue(value.hasMore), tuiOwnerEncodeArray180(value.provisionalEvents, { item => tuiOwnerEncode180(item) })])
}
func tuiOwnerDecodeTuiConversationView180(value: AgentValue): TuiConversationView {
    tuiOwnerShape180(value, 8)
    TuiConversationView(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerBoolean180(value.items[3]), tuiOwnerDecodeArray180<TuiTranscriptItem>(value.items[4], { item => tuiOwnerDecodeTuiTranscriptItem180(item) }), nextBeforeOrdinal: tuiOwnerInteger180(value.items[5]), hasMore: tuiOwnerBoolean180(value.items[6]), provisionalEvents: tuiOwnerDecodeArray180<TuiAgentEvent>(value.items[7], { item => tuiOwnerDecodeTuiAgentEvent180(item) }))
}

func tuiOwnerEncode180(value: TuiTranscriptPage): AgentValue {
    listValue([tuiOwnerEncodeArray180(value.items, { item => tuiOwnerEncode180(item) }), integerValue(value.nextBeforeOrdinal), boolValue(value.hasMore)])
}
func tuiOwnerDecodeTuiTranscriptPage180(value: AgentValue): TuiTranscriptPage {
    tuiOwnerShape180(value, 3)
    TuiTranscriptPage(tuiOwnerDecodeArray180<TuiTranscriptItem>(value.items[0], { item => tuiOwnerDecodeTuiTranscriptItem180(item) }), tuiOwnerInteger180(value.items[1]), tuiOwnerBoolean180(value.items[2]))
}

func tuiOwnerEncode180(value: TuiThemeDefinition): AgentValue {
    listValue([textValue(value.name), textValue(value.raised), textValue(value.userMessageBg), textValue(value.text), textValue(value.muted), textValue(value.accent), textValue(value.secondary), textValue(value.success), textValue(value.warning), textValue(value.danger), textValue(value.userMessageText), textValue(value.reasoning), textValue(value.tool)])
}
func tuiOwnerDecodeTuiThemeDefinition180(value: AgentValue): TuiThemeDefinition {
    tuiOwnerShape180(value, 13)
    TuiThemeDefinition(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerText180(value.items[4]), tuiOwnerText180(value.items[5]), tuiOwnerText180(value.items[6]), tuiOwnerText180(value.items[7]), tuiOwnerText180(value.items[8]), tuiOwnerText180(value.items[9]), tuiOwnerText180(value.items[10]), tuiOwnerText180(value.items[11]), tuiOwnerText180(value.items[12]))
}

func tuiOwnerEncode180(value: SlashCommandDefinition): AgentValue {
    listValue([textValue(value.name), textValue(value.group), textValue(value.description), textValue(value.usage), tuiOwnerEncodeArray180(value.aliases, { item => textValue(item) }), textValue(value.source), tuiOwnerEncodeArray180(value.subcommands, { item => textValue(item) }), tuiOwnerEncodeArray180(value.pathArgumentPrefixes, { item => tuiOwnerEncodeArray180(item, { item => textValue(item) }) })])
}
func tuiOwnerDecodeSlashCommandDefinition180(value: AgentValue): SlashCommandDefinition {
    tuiOwnerShape180(value, 8)
    SlashCommandDefinition(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), usage: tuiOwnerText180(value.items[3]), aliases: tuiOwnerDecodeArray180<String>(value.items[4], { item => tuiOwnerText180(item) }), source: tuiOwnerText180(value.items[5]), subcommands: tuiOwnerDecodeArray180<String>(value.items[6], { item => tuiOwnerText180(item) }), pathArgumentPrefixes: tuiOwnerDecodeArray180<Array<String>>(value.items[7], { item => tuiOwnerDecodeArray180<String>(item, { item => tuiOwnerText180(item) }) }))
}

func tuiOwnerEncode180(value: TuiPluginViewField): AgentValue {
    listValue([textValue(value.id), textValue(value.value)])
}
func tuiOwnerDecodeTuiPluginViewField180(value: AgentValue): TuiPluginViewField {
    tuiOwnerShape180(value, 2)
    TuiPluginViewField(tuiOwnerText180(value.items[0]), tuiOwnerText180(value.items[1]))
}
func tuiOwnerEncode180(value: TuiPluginViewDocument): AgentValue {
    value.withPresentation({ metadata, model, primary =>
        listValue([textValue(metadata), textValue(model), textValue(primary)])
    })
}

func tuiOwnerEncode180(value: TuiApprovalDecision): AgentValue {
    match (value) {
        case TuiApprovalDecision.AllowOnce => listValue([textValue("AllowOnce")])
        case TuiApprovalDecision.AllowSession => listValue([textValue("AllowSession")])
        case TuiApprovalDecision.Reject(v0) => listValue([textValue("Reject"), textValue(v0)])
    }
}
func tuiOwnerDecodeTuiApprovalDecision180(value: AgentValue): TuiApprovalDecision {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "AllowOnce" => tuiOwnerShape180(value, 1); TuiApprovalDecision.AllowOnce
        case "AllowSession" => tuiOwnerShape180(value, 1); TuiApprovalDecision.AllowSession
        case "Reject" => tuiOwnerShape180(value, 2); TuiApprovalDecision.Reject(tuiOwnerText180(value.items[1]))
        case _ => throw IllegalArgumentException("tui.owner_unknown_TuiApprovalDecision")
    }
}


func tuiOwnerEncode180(value: TuiQueueWithdrawal): AgentValue {
    match (value) {
        case TuiQueueWithdrawal.Withdrawn(v0, v1) => listValue([textValue("Withdrawn"), textValue(v0), textValue(v1)])
        case TuiQueueWithdrawal.AlreadyDelivered => listValue([textValue("AlreadyDelivered")])
        case TuiQueueWithdrawal.Failed(v0) => listValue([textValue("Failed"), textValue(v0)])
    }
}
func tuiOwnerDecodeTuiQueueWithdrawal180(value: AgentValue): TuiQueueWithdrawal {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "Withdrawn" => tuiOwnerShape180(value, 3); TuiQueueWithdrawal.Withdrawn(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "AlreadyDelivered" => tuiOwnerShape180(value, 1); TuiQueueWithdrawal.AlreadyDelivered
        case "Failed" => tuiOwnerShape180(value, 2); TuiQueueWithdrawal.Failed(tuiOwnerText180(value.items[1]))
        case _ => throw IllegalArgumentException("tui.owner_unknown_TuiQueueWithdrawal")
    }
}

func tuiOwnerEncode180(value: TuiAskResolution): AgentValue {
    match (value) {
        case TuiAskResolution.Answers(v0) => listValue([textValue("Answers"), tuiOwnerEncodeArray180(v0, { item => tuiOwnerEncode180(item) })])
        case TuiAskResolution.Chat => listValue([textValue("Chat")])
        case TuiAskResolution.Cancelled => listValue([textValue("Cancelled")])
    }
}
func tuiOwnerDecodeTuiAskResolution180(value: AgentValue): TuiAskResolution {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "Answers" => tuiOwnerShape180(value, 2); TuiAskResolution.Answers(tuiOwnerDecodeArray180<TuiAskAnswer>(value.items[1], { item => tuiOwnerDecodeTuiAskAnswer180(item) }))
        case "Chat" => tuiOwnerShape180(value, 1); TuiAskResolution.Chat
        case "Cancelled" => tuiOwnerShape180(value, 1); TuiAskResolution.Cancelled
        case _ => throw IllegalArgumentException("tui.owner_unknown_TuiAskResolution")
    }
}

func tuiOwnerEncode180(value: UiCardKind): AgentValue {
    match (value) {
        case UiCardKind.User => listValue([textValue("User")])
        case UiCardKind.Assistant => listValue([textValue("Assistant")])
        case UiCardKind.Reasoning => listValue([textValue("Reasoning")])
        case UiCardKind.Tool => listValue([textValue("Tool")])
        case UiCardKind.Approval => listValue([textValue("Approval")])
        case UiCardKind.Permission => listValue([textValue("Permission")])
        case UiCardKind.Ask => listValue([textValue("Ask")])
        case UiCardKind.Plan => listValue([textValue("Plan")])
        case UiCardKind.Subagent => listValue([textValue("Subagent")])
        case UiCardKind.Advisor => listValue([textValue("Advisor")])
        case UiCardKind.Reviewer => listValue([textValue("Reviewer")])
        case UiCardKind.Job => listValue([textValue("Job")])
        case UiCardKind.Warning => listValue([textValue("Warning")])
        case UiCardKind.Compaction => listValue([textValue("Compaction")])
        case UiCardKind.Summary => listValue([textValue("Summary")])
        case UiCardKind.Error => listValue([textValue("Error")])
        case UiCardKind.Steer => listValue([textValue("Steer")])
        case UiCardKind.Setup => listValue([textValue("Setup")])
        case UiCardKind.Mcp => listValue([textValue("Mcp")])
    }
}
func tuiOwnerDecodeUiCardKind180(value: AgentValue): UiCardKind {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "User" => tuiOwnerShape180(value, 1); UiCardKind.User
        case "Assistant" => tuiOwnerShape180(value, 1); UiCardKind.Assistant
        case "Reasoning" => tuiOwnerShape180(value, 1); UiCardKind.Reasoning
        case "Tool" => tuiOwnerShape180(value, 1); UiCardKind.Tool
        case "Approval" => tuiOwnerShape180(value, 1); UiCardKind.Approval
        case "Permission" => tuiOwnerShape180(value, 1); UiCardKind.Permission
        case "Ask" => tuiOwnerShape180(value, 1); UiCardKind.Ask
        case "Plan" => tuiOwnerShape180(value, 1); UiCardKind.Plan
        case "Subagent" => tuiOwnerShape180(value, 1); UiCardKind.Subagent
        case "Advisor" => tuiOwnerShape180(value, 1); UiCardKind.Advisor
        case "Reviewer" => tuiOwnerShape180(value, 1); UiCardKind.Reviewer
        case "Job" => tuiOwnerShape180(value, 1); UiCardKind.Job
        case "Warning" => tuiOwnerShape180(value, 1); UiCardKind.Warning
        case "Compaction" => tuiOwnerShape180(value, 1); UiCardKind.Compaction
        case "Summary" => tuiOwnerShape180(value, 1); UiCardKind.Summary
        case "Error" => tuiOwnerShape180(value, 1); UiCardKind.Error
        case "Steer" => tuiOwnerShape180(value, 1); UiCardKind.Steer
        case "Setup" => tuiOwnerShape180(value, 1); UiCardKind.Setup
        case "Mcp" => tuiOwnerShape180(value, 1); UiCardKind.Mcp
        case _ => throw IllegalArgumentException("tui.owner_unknown_UiCardKind")
    }
}

func tuiOwnerEncode180(value: TuiTurnAction): AgentValue {
    match (value) {
        case TuiTurnAction.NoAction => listValue([textValue("NoAction")])
        case TuiTurnAction.Exit => listValue([textValue("Exit")])
        case TuiTurnAction.OpenProviderSetup => listValue([textValue("OpenProviderSetup")])
        case TuiTurnAction.OpenModelSelector => listValue([textValue("OpenModelSelector")])
        case TuiTurnAction.OpenBranchSelector => listValue([textValue("OpenBranchSelector")])
        case TuiTurnAction.OpenPluginView(v0) => listValue([textValue("OpenPluginView"), textValue(v0)])
        case TuiTurnAction.PluginViewLoaded(v0) => listValue([textValue("PluginViewLoaded"), tuiOwnerEncode180(v0)])
        case TuiTurnAction.ConfirmPluginView(v0) => listValue([textValue("ConfirmPluginView"), textValue(v0)])
        case TuiTurnAction.OpenDocument(v0, v1) => listValue([textValue("OpenDocument"), textValue(v0), textValue(v1)])
        case TuiTurnAction.ModelsLoaded(v0) => listValue([textValue("ModelsLoaded"), tuiOwnerEncodeArray180(v0, { item => textValue(item) })])
        case TuiTurnAction.ThemeSelected(v0, v1, v2) => listValue([textValue("ThemeSelected"), textValue(v0), boolValue(v1), tuiOwnerEncodeArray180(v2, { item => tuiOwnerEncode180(item) })])
        case TuiTurnAction.SessionsLoaded(v0) => listValue([textValue("SessionsLoaded"), tuiOwnerEncodeArray180(v0, { item => tuiOwnerEncode180(item) })])
        case TuiTurnAction.BranchesLoaded(v0) => listValue([textValue("BranchesLoaded"), tuiOwnerEncodeArray180(v0, { item => textValue(item) })])
        case TuiTurnAction.SessionTreeLoaded(v0) => listValue([textValue("SessionTreeLoaded"), tuiOwnerEncodeArray180(v0, { item => tuiOwnerEncode180(item) })])
        case TuiTurnAction.SubagentsLoaded(v0) => listValue([textValue("SubagentsLoaded"), tuiOwnerEncodeArray180(v0, { item => tuiOwnerEncode180(item) })])
        case TuiTurnAction.ConversationFocused(v0) => listValue([textValue("ConversationFocused"), tuiOwnerEncode180(v0)])
        case TuiTurnAction.TodoLoaded(v0) => listValue([textValue("TodoLoaded"), tuiOwnerEncode180(v0)])
        case TuiTurnAction.ModelSelected(v0, v1, v2) => listValue([textValue("ModelSelected"), textValue(v0), boolValue(v1), textValue(v2)])
        case TuiTurnAction.SessionSelected(v0, v1, v2, v3) => listValue([textValue("SessionSelected"), textValue(v0), boolValue(v1), textValue(v2), tuiOwnerEncodeOption180(v3, { item => tuiOwnerEncode180(item) })])
        case TuiTurnAction.BranchSelected(v0, v1) => listValue([textValue("BranchSelected"), boolValue(v0), textValue(v1)])
        case TuiTurnAction.ResetCompleted(v0) => listValue([textValue("ResetCompleted"), textValue(v0)])
        case TuiTurnAction.SetupConfigured(v0) => listValue([textValue("SetupConfigured"), textValue(v0)])
        case TuiTurnAction.TodoSaved(v0) => listValue([textValue("TodoSaved"), tuiOwnerEncode180(v0)])
        case TuiTurnAction.DraftLoaded(v0) => listValue([textValue("DraftLoaded"), textValue(v0)])
        case TuiTurnAction.UiStatus(v0) => listValue([textValue("UiStatus"), textValue(v0)])
    }
}
func tuiOwnerDecodeTuiTurnAction180(value: AgentValue, viewSource!: ?TuiOwnerReadFrame180 = None): TuiTurnAction {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "NoAction" => tuiOwnerShape180(value, 1); TuiTurnAction.NoAction
        case "Exit" => tuiOwnerShape180(value, 1); TuiTurnAction.Exit
        case "OpenProviderSetup" => tuiOwnerShape180(value, 1); TuiTurnAction.OpenProviderSetup
        case "OpenModelSelector" => tuiOwnerShape180(value, 1); TuiTurnAction.OpenModelSelector
        case "OpenBranchSelector" => tuiOwnerShape180(value, 1); TuiTurnAction.OpenBranchSelector
        case "OpenPluginView" => tuiOwnerShape180(value, 2); TuiTurnAction.OpenPluginView(tuiOwnerText180(value.items[1]))
        case "PluginViewLoaded" =>
            tuiOwnerShape180(value, 2)
            TuiTurnAction.PluginViewLoaded(viewSource.getOrThrow().copyViewDocument180(value.items[1]))
        case "ConfirmPluginView" => tuiOwnerShape180(value, 2); TuiTurnAction.ConfirmPluginView(tuiOwnerText180(value.items[1]))
        case "OpenDocument" => tuiOwnerShape180(value, 3); TuiTurnAction.OpenDocument(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "ModelsLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.ModelsLoaded(tuiOwnerDecodeArray180<String>(value.items[1], { item => tuiOwnerText180(item) }))
        case "ThemeSelected" => tuiOwnerShape180(value, 4); TuiTurnAction.ThemeSelected(tuiOwnerText180(value.items[1]), tuiOwnerBoolean180(value.items[2]), tuiOwnerDecodeArray180<TuiThemeDefinition>(value.items[3], { item => tuiOwnerDecodeTuiThemeDefinition180(item) }))
        case "SessionsLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.SessionsLoaded(tuiOwnerDecodeArray180<TuiSessionNode>(value.items[1], { item => tuiOwnerDecodeTuiSessionNode180(item) }))
        case "BranchesLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.BranchesLoaded(tuiOwnerDecodeArray180<String>(value.items[1], { item => tuiOwnerText180(item) }))
        case "SessionTreeLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.SessionTreeLoaded(tuiOwnerDecodeArray180<TuiSessionNode>(value.items[1], { item => tuiOwnerDecodeTuiSessionNode180(item) }))
        case "SubagentsLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.SubagentsLoaded(tuiOwnerDecodeArray180<TuiSubagentInfo>(value.items[1], { item => tuiOwnerDecodeTuiSubagentInfo180(item) }))
        case "ConversationFocused" => tuiOwnerShape180(value, 2); TuiTurnAction.ConversationFocused(tuiOwnerDecodeTuiConversationView180(value.items[1]))
        case "TodoLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.TodoLoaded(tuiOwnerDecodeTuiTodoLoadResult180(value.items[1]))
        case "ModelSelected" => tuiOwnerShape180(value, 4); TuiTurnAction.ModelSelected(tuiOwnerText180(value.items[1]), tuiOwnerBoolean180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "SessionSelected" => tuiOwnerShape180(value, 5); TuiTurnAction.SessionSelected(tuiOwnerText180(value.items[1]), tuiOwnerBoolean180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerDecodeOption180<TuiConversationView>(value.items[4], { item => tuiOwnerDecodeTuiConversationView180(item) }))
        case "BranchSelected" => tuiOwnerShape180(value, 3); TuiTurnAction.BranchSelected(tuiOwnerBoolean180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "ResetCompleted" => tuiOwnerShape180(value, 2); TuiTurnAction.ResetCompleted(tuiOwnerText180(value.items[1]))
        case "SetupConfigured" => tuiOwnerShape180(value, 2); TuiTurnAction.SetupConfigured(tuiOwnerText180(value.items[1]))
        case "TodoSaved" => tuiOwnerShape180(value, 2); TuiTurnAction.TodoSaved(tuiOwnerDecodeTuiTodoSaveResult180(value.items[1]))
        case "DraftLoaded" => tuiOwnerShape180(value, 2); TuiTurnAction.DraftLoaded(tuiOwnerText180(value.items[1]))
        case "UiStatus" => tuiOwnerShape180(value, 2); TuiTurnAction.UiStatus(tuiOwnerText180(value.items[1]))
        case _ => throw IllegalArgumentException("tui.owner_unknown_TuiTurnAction")
    }
}

func tuiOwnerEncode180(value: TuiAgentEvent): AgentValue {
    match (value) {
        case TuiAgentEvent.AttemptStarted(v0) => listValue([textValue("AttemptStarted"), tuiOwnerEncode180(v0)])
        case TuiAgentEvent.AttemptTextDelta(v0, v1) => listValue([textValue("AttemptTextDelta"), tuiOwnerEncode180(v0), textValue(v1)])
        case TuiAgentEvent.AttemptReasoningDelta(v0, v1) => listValue([textValue("AttemptReasoningDelta"), tuiOwnerEncode180(v0), textValue(v1)])
        case TuiAgentEvent.AttemptToolStarted(v0, v1, v2) => listValue([textValue("AttemptToolStarted"), tuiOwnerEncode180(v0), textValue(v1), textValue(v2)])
        case TuiAgentEvent.AttemptToolArguments(v0, v1, v2) => listValue([textValue("AttemptToolArguments"), tuiOwnerEncode180(v0), textValue(v1), textValue(v2)])
        case TuiAgentEvent.AttemptFailed(v0, v1) => listValue([textValue("AttemptFailed"), tuiOwnerEncode180(v0), textValue(v1)])
        case TuiAgentEvent.AttemptCancelled(v0) => listValue([textValue("AttemptCancelled"), tuiOwnerEncode180(v0)])
        case TuiAgentEvent.AttemptAborted(v0) => listValue([textValue("AttemptAborted"), tuiOwnerEncode180(v0)])
        case TuiAgentEvent.AttemptRetryScheduled(v0) => listValue([textValue("AttemptRetryScheduled"), tuiOwnerEncode180(v0)])
        case TuiAgentEvent.DecisionCommitted(v0, v1) => listValue([textValue("DecisionCommitted"), tuiOwnerEncode180(v0), textValue(v1)])
        case TuiAgentEvent.TextDelta(v0) => listValue([textValue("TextDelta"), textValue(v0)])
        case TuiAgentEvent.ReasoningDelta(v0) => listValue([textValue("ReasoningDelta"), textValue(v0)])
        case TuiAgentEvent.ToolStarted(v0, v1) => listValue([textValue("ToolStarted"), textValue(v0), textValue(v1)])
        case TuiAgentEvent.ToolStartedWithId(v0, v1, v2) => listValue([textValue("ToolStartedWithId"), textValue(v0), textValue(v1), textValue(v2)])
        case TuiAgentEvent.ToolOutput(v0, v1, v2) => listValue([textValue("ToolOutput"), textValue(v0), textValue(v1), boolValue(v2)])
        case TuiAgentEvent.ToolCompleted(v0, v1, v2) => listValue([textValue("ToolCompleted"), textValue(v0), boolValue(v1), tuiOwnerEncode180(v2)])
        case TuiAgentEvent.ToolCompletedWithId(v0, v1, v2, v3) => listValue([textValue("ToolCompletedWithId"), textValue(v0), textValue(v1), boolValue(v2), tuiOwnerEncode180(v3)])
        case TuiAgentEvent.InputInjected(v0, v1, v2) => listValue([textValue("InputInjected"), textValue(v0), textValue(v1), textValue(v2)])
        case TuiAgentEvent.JobStatus(v0, v1, v2, v3, v4, v5) => listValue([textValue("JobStatus"), textValue(v0), textValue(v1), textValue(v2), textValue(v3), integerValue(v4), textValue(v5)])
        case TuiAgentEvent.SubagentStatus(v0, v1, v2) => listValue([textValue("SubagentStatus"), tuiOwnerEncode180(v0), integerValue(v1), textValue(v2)])
        case TuiAgentEvent.SubagentStream(v0, v1) => listValue([textValue("SubagentStream"), textValue(v0), tuiOwnerEncode180(v1)])
        case TuiAgentEvent.Approval(v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12) => listValue([textValue("Approval"), textValue(v0), textValue(v1), textValue(v2), textValue(v3), textValue(v4), textValue(v5), textValue(v6), textValue(v7), textValue(v8), textValue(v9), textValue(v10), boolValue(v11), textValue(v12)])
        case TuiAgentEvent.ApprovalReview(v0, v1, v2, v3, v4, v5, v6, v7, v8) => listValue([textValue("ApprovalReview"), textValue(v0), textValue(v1), textValue(v2), textValue(v3), textValue(v4), textValue(v5), textValue(v6), integerValue(v7), textValue(v8)])
        case TuiAgentEvent.Ask(v0) => listValue([textValue("Ask"), tuiOwnerEncode180(v0)])
        case TuiAgentEvent.PluginViewClosed(v0, v1) => listValue([textValue("PluginViewClosed"), textValue(v0), textValue(v1)])
        case TuiAgentEvent.Usage(v0, v1) => listValue([textValue("Usage"), integerValue(v0), integerValue(v1)])
        case TuiAgentEvent.Setup(v0) => listValue([textValue("Setup"), textValue(v0)])
        case TuiAgentEvent.Plan(v0, v1) => listValue([textValue("Plan"), textValue(v0), textValue(v1)])
        case TuiAgentEvent.PluginNotice(v0, v1) => listValue([textValue("PluginNotice"), textValue(v0), textValue(v1)])
        case TuiAgentEvent.Warning(v0, v1) => listValue([textValue("Warning"), textValue(v0), textValue(v1)])
        case TuiAgentEvent.Compaction(v0, v1, v2) => listValue([textValue("Compaction"), integerValue(v0), integerValue(v1), textValue(v2)])
        case TuiAgentEvent.Summary(v0) => listValue([textValue("Summary"), textValue(v0)])
        case TuiAgentEvent.Error(v0) => listValue([textValue("Error"), textValue(v0)])
        case TuiAgentEvent.OwnedToolDisplay(_) | TuiAgentEvent.OwnedFailureDisplay113(_) | TuiAgentEvent.OwnedRegistryError167(_, _) => throw IllegalArgumentException("tui.owner_owned_serializer_required")
    }
}
func tuiOwnerDecodeTuiAgentEvent180(value: AgentValue): TuiAgentEvent {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "AttemptStarted" => tuiOwnerShape180(value, 2); TuiAgentEvent.AttemptStarted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "AttemptTextDelta" => tuiOwnerShape180(value, 3); TuiAgentEvent.AttemptTextDelta(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "AttemptReasoningDelta" => tuiOwnerShape180(value, 3); TuiAgentEvent.AttemptReasoningDelta(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "AttemptToolStarted" => tuiOwnerShape180(value, 4); TuiAgentEvent.AttemptToolStarted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "AttemptToolArguments" => tuiOwnerShape180(value, 4); TuiAgentEvent.AttemptToolArguments(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "AttemptFailed" => tuiOwnerShape180(value, 3); TuiAgentEvent.AttemptFailed(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "AttemptCancelled" => tuiOwnerShape180(value, 2); TuiAgentEvent.AttemptCancelled(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "AttemptAborted" => tuiOwnerShape180(value, 2); TuiAgentEvent.AttemptAborted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "AttemptRetryScheduled" => tuiOwnerShape180(value, 2); TuiAgentEvent.AttemptRetryScheduled(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "DecisionCommitted" => tuiOwnerShape180(value, 3); TuiAgentEvent.DecisionCommitted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "TextDelta" => tuiOwnerShape180(value, 2); TuiAgentEvent.TextDelta(tuiOwnerText180(value.items[1]))
        case "ReasoningDelta" => tuiOwnerShape180(value, 2); TuiAgentEvent.ReasoningDelta(tuiOwnerText180(value.items[1]))
        case "ToolStarted" => tuiOwnerShape180(value, 3); TuiAgentEvent.ToolStarted(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "ToolStartedWithId" => tuiOwnerShape180(value, 4); TuiAgentEvent.ToolStartedWithId(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "ToolOutput" => tuiOwnerShape180(value, 4); TuiAgentEvent.ToolOutput(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerBoolean180(value.items[3]))
        case "ToolCompleted" => tuiOwnerShape180(value, 4); TuiAgentEvent.ToolCompleted(tuiOwnerText180(value.items[1]), tuiOwnerBoolean180(value.items[2]), tuiOwnerDecodeTuiToolCompletionPayload180(value.items[3]))
        case "ToolCompletedWithId" => tuiOwnerShape180(value, 5); TuiAgentEvent.ToolCompletedWithId(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerBoolean180(value.items[3]), tuiOwnerDecodeTuiToolCompletionPayload180(value.items[4]))
        case "InputInjected" => tuiOwnerShape180(value, 4); TuiAgentEvent.InputInjected(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "JobStatus" => tuiOwnerShape180(value, 7); TuiAgentEvent.JobStatus(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerText180(value.items[4]), tuiOwnerInteger180(value.items[5]), tuiOwnerText180(value.items[6]))
        case "SubagentStatus" => tuiOwnerShape180(value, 4); TuiAgentEvent.SubagentStatus(tuiOwnerDecodeTuiSubagentInfo180(value.items[1]), tuiOwnerInteger180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "SubagentStream" => tuiOwnerShape180(value, 3); TuiAgentEvent.SubagentStream(tuiOwnerText180(value.items[1]), tuiOwnerDecodeTuiSubagentStreamEvent180(value.items[2]))
        case "Approval" => tuiOwnerShape180(value, 14); TuiAgentEvent.Approval(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerText180(value.items[4]), tuiOwnerText180(value.items[5]), tuiOwnerText180(value.items[6]), tuiOwnerText180(value.items[7]), tuiOwnerText180(value.items[8]), tuiOwnerText180(value.items[9]), tuiOwnerText180(value.items[10]), tuiOwnerText180(value.items[11]), tuiOwnerBoolean180(value.items[12]), tuiOwnerText180(value.items[13]))
        case "ApprovalReview" => tuiOwnerShape180(value, 10); TuiAgentEvent.ApprovalReview(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]), tuiOwnerText180(value.items[4]), tuiOwnerText180(value.items[5]), tuiOwnerText180(value.items[6]), tuiOwnerText180(value.items[7]), tuiOwnerInteger180(value.items[8]), tuiOwnerText180(value.items[9]))
        case "Ask" => tuiOwnerShape180(value, 2); TuiAgentEvent.Ask(tuiOwnerDecodeTuiAskRequest180(value.items[1]))
        case "PluginViewClosed" => tuiOwnerShape180(value, 3); TuiAgentEvent.PluginViewClosed(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "Usage" => tuiOwnerShape180(value, 3); TuiAgentEvent.Usage(tuiOwnerInteger180(value.items[1]), tuiOwnerInteger180(value.items[2]))
        case "Setup" => tuiOwnerShape180(value, 2); TuiAgentEvent.Setup(tuiOwnerText180(value.items[1]))
        case "Plan" => tuiOwnerShape180(value, 3); TuiAgentEvent.Plan(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "PluginNotice" => tuiOwnerShape180(value, 3); TuiAgentEvent.PluginNotice(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "Warning" => tuiOwnerShape180(value, 3); TuiAgentEvent.Warning(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "Compaction" => tuiOwnerShape180(value, 4); TuiAgentEvent.Compaction(tuiOwnerInteger180(value.items[1]), tuiOwnerInteger180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "Summary" => tuiOwnerShape180(value, 2); TuiAgentEvent.Summary(tuiOwnerText180(value.items[1]))
        case "Error" => tuiOwnerShape180(value, 2); TuiAgentEvent.Error(tuiOwnerText180(value.items[1]))
        case _ => throw IllegalArgumentException("tui.owner_unknown_TuiAgentEvent")
    }
}

func tuiOwnerEncode180(value: TuiSubagentStreamEvent): AgentValue {
    match (value) {
        case TuiSubagentStreamEvent.AttemptStarted(v0) => listValue([textValue("AttemptStarted"), tuiOwnerEncode180(v0)])
        case TuiSubagentStreamEvent.AttemptTextDelta(v0, v1) => listValue([textValue("AttemptTextDelta"), tuiOwnerEncode180(v0), textValue(v1)])
        case TuiSubagentStreamEvent.AttemptReasoningDelta(v0, v1) => listValue([textValue("AttemptReasoningDelta"), tuiOwnerEncode180(v0), textValue(v1)])
        case TuiSubagentStreamEvent.AttemptToolStarted(v0, v1, v2) => listValue([textValue("AttemptToolStarted"), tuiOwnerEncode180(v0), textValue(v1), textValue(v2)])
        case TuiSubagentStreamEvent.AttemptToolArguments(v0, v1, v2) => listValue([textValue("AttemptToolArguments"), tuiOwnerEncode180(v0), textValue(v1), textValue(v2)])
        case TuiSubagentStreamEvent.AttemptFailed(v0) => listValue([textValue("AttemptFailed"), tuiOwnerEncode180(v0)])
        case TuiSubagentStreamEvent.AttemptCancelled(v0) => listValue([textValue("AttemptCancelled"), tuiOwnerEncode180(v0)])
        case TuiSubagentStreamEvent.AttemptAborted(v0) => listValue([textValue("AttemptAborted"), tuiOwnerEncode180(v0)])
        case TuiSubagentStreamEvent.DecisionCommitted(v0) => listValue([textValue("DecisionCommitted"), tuiOwnerEncode180(v0)])
        case TuiSubagentStreamEvent.TextDelta(v0) => listValue([textValue("TextDelta"), textValue(v0)])
        case TuiSubagentStreamEvent.ReasoningDelta(v0) => listValue([textValue("ReasoningDelta"), textValue(v0)])
        case TuiSubagentStreamEvent.ToolStarted(v0, v1) => listValue([textValue("ToolStarted"), textValue(v0), textValue(v1)])
        case TuiSubagentStreamEvent.ToolStartedWithId(v0, v1, v2) => listValue([textValue("ToolStartedWithId"), textValue(v0), textValue(v1), textValue(v2)])
        case TuiSubagentStreamEvent.ToolOutput(v0, v1, v2) => listValue([textValue("ToolOutput"), textValue(v0), textValue(v1), boolValue(v2)])
        case TuiSubagentStreamEvent.ToolCompleted(v0, v1, v2) => listValue([textValue("ToolCompleted"), textValue(v0), boolValue(v1), tuiOwnerEncode180(v2)])
        case TuiSubagentStreamEvent.ToolCompletedWithId(v0, v1, v2, v3) => listValue([textValue("ToolCompletedWithId"), textValue(v0), textValue(v1), boolValue(v2), tuiOwnerEncode180(v3)])
        case TuiSubagentStreamEvent.InputInjected(v0, v1, v2) => listValue([textValue("InputInjected"), textValue(v0), textValue(v1), textValue(v2)])
        case TuiSubagentStreamEvent.Usage(v0, v1) => listValue([textValue("Usage"), integerValue(v0), integerValue(v1)])
        case TuiSubagentStreamEvent.Error(v0) => listValue([textValue("Error"), textValue(v0)])
    }
}
func tuiOwnerDecodeTuiSubagentStreamEvent180(value: AgentValue): TuiSubagentStreamEvent {
    if (value.unifiedKind != ValueKind.List || value.items.size < 1) { throw IllegalArgumentException("tui.owner_invalid_tagged_value") }
    match (tuiOwnerText180(value.items[0])) {
        case "AttemptStarted" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.AttemptStarted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "AttemptTextDelta" => tuiOwnerShape180(value, 3); TuiSubagentStreamEvent.AttemptTextDelta(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "AttemptReasoningDelta" => tuiOwnerShape180(value, 3); TuiSubagentStreamEvent.AttemptReasoningDelta(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "AttemptToolStarted" => tuiOwnerShape180(value, 4); TuiSubagentStreamEvent.AttemptToolStarted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "AttemptToolArguments" => tuiOwnerShape180(value, 4); TuiSubagentStreamEvent.AttemptToolArguments(tuiOwnerDecodeTuiAttemptScope180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "AttemptFailed" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.AttemptFailed(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "AttemptCancelled" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.AttemptCancelled(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "AttemptAborted" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.AttemptAborted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "DecisionCommitted" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.DecisionCommitted(tuiOwnerDecodeTuiAttemptScope180(value.items[1]))
        case "TextDelta" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.TextDelta(tuiOwnerText180(value.items[1]))
        case "ReasoningDelta" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.ReasoningDelta(tuiOwnerText180(value.items[1]))
        case "ToolStarted" => tuiOwnerShape180(value, 3); TuiSubagentStreamEvent.ToolStarted(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]))
        case "ToolStartedWithId" => tuiOwnerShape180(value, 4); TuiSubagentStreamEvent.ToolStartedWithId(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "ToolOutput" => tuiOwnerShape180(value, 4); TuiSubagentStreamEvent.ToolOutput(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerBoolean180(value.items[3]))
        case "ToolCompleted" => tuiOwnerShape180(value, 4); TuiSubagentStreamEvent.ToolCompleted(tuiOwnerText180(value.items[1]), tuiOwnerBoolean180(value.items[2]), tuiOwnerDecodeTuiToolCompletionPayload180(value.items[3]))
        case "ToolCompletedWithId" => tuiOwnerShape180(value, 5); TuiSubagentStreamEvent.ToolCompletedWithId(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerBoolean180(value.items[3]), tuiOwnerDecodeTuiToolCompletionPayload180(value.items[4]))
        case "InputInjected" => tuiOwnerShape180(value, 4); TuiSubagentStreamEvent.InputInjected(tuiOwnerText180(value.items[1]), tuiOwnerText180(value.items[2]), tuiOwnerText180(value.items[3]))
        case "Usage" => tuiOwnerShape180(value, 3); TuiSubagentStreamEvent.Usage(tuiOwnerInteger180(value.items[1]), tuiOwnerInteger180(value.items[2]))
        case "Error" => tuiOwnerShape180(value, 2); TuiSubagentStreamEvent.Error(tuiOwnerText180(value.items[1]))
        case _ => throw IllegalArgumentException("tui.owner_unknown_TuiSubagentStreamEvent")
    }
}
