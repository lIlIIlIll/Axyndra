package agent_runtime

import yjson_support.*

import yjson.*

import std.deriving.*
import std.collection.*
import std.convert.*
import std.sync.*
import agent_domain.*

@Derive[Equatable]
public enum ModelLaneRole {
    Main | Reviewer | Compactor | Subagent | Memory
}

public class ModelLaneCapabilitiesSnapshot {
    public let streaming: Bool
    public let tools: Bool
    public let reasoning: Bool
    public let structuredOutput: Bool
    public let imageInput: Bool
    public let promptCache: Bool
    public let providerOpaqueState: Bool

    public init(
        streaming!: Bool = true,
        tools!: Bool = true,
        reasoning!: Bool = false,
        structuredOutput!: Bool = false,
        imageInput!: Bool = false,
        promptCache!: Bool = false,
        providerOpaqueState!: Bool = false
    ) {
        this.streaming = streaming
        this.tools = tools
        this.reasoning = reasoning
        this.structuredOutput = structuredOutput
        this.imageInput = imageInput
        this.promptCache = promptCache
        this.providerOpaqueState = providerOpaqueState
    }
}

public class ToolSnapshotEntry {
    public let name: String
    public let description: String
    public let inputSchema: AgentValue
    public let executorVersion: String
    public let implementationFingerprint: String
    public let schemaDigest: String
    public let availableAtSnapshot: Bool
    public let requiredCapabilities: Array<Capability>

    public init(
        name: String,
        description: String,
        inputSchema: AgentValue,
        executorVersion: String,
        requiredCapabilities: Array<Capability>,
        implementationFingerprint!: String = "",
        schemaDigest!: String = "",
        availableAtSnapshot!: Bool = true
    ) {
        if (name.trimAscii() == "" || executorVersion.trimAscii() == "" ||
            inputSchema.unifiedKind != ValueKind.Object ||
            (schemaDigest != "" && schemaDigest != modelPolicySha256Text(
                canonicalAgentValue(inputSchema)
            ))) {
            throw IllegalArgumentException(
                "tool snapshot requires a name, object schema, and valid identity"
            )
        }
        this.name = name.trimAscii()
        this.description = description
        this.inputSchema = inputSchema
        this.executorVersion = executorVersion.trimAscii()
        this.implementationFingerprint = implementationFingerprint.trimAscii()
        this.schemaDigest = schemaDigest.trimAscii()
        this.availableAtSnapshot = availableAtSnapshot
        this.requiredCapabilities = requiredCapabilities
    }

    public func hasCompleteIdentity(): Bool {
        implementationFingerprint != "" && schemaDigest != ""
    }
}

public class ToolHookHandlerSnapshot {
    public let event: String
    public let pluginId: String
    public let pluginVersion: String
    public let contentDigest: String
    public let packageRoot: String
    public let matcher: String
    public let command: String
    public let timeoutMillis: Int64

    public init(
        event: String,
        pluginId: String,
        pluginVersion: String,
        contentDigest: String,
        packageRoot: String,
        matcher: String,
        command: String,
        timeoutMillis: Int64
    ) {
        if ((event != "PreToolUse" && event != "PostToolUse") ||
            pluginId.trimAscii() == "" || pluginVersion.trimAscii() == "" ||
            contentDigest.trimAscii() == "" || packageRoot.trimAscii() == "" ||
            matcher.trimAscii() == "" || command.trimAscii() == "" ||
            command.size > 8192 || command.contains("\u{0000}") ||
            timeoutMillis < 1 || timeoutMillis > 30000) {
            throw IllegalArgumentException("tool hook snapshot identity or limits are invalid")
        }
        this.event = event
        this.pluginId = pluginId.trimAscii()
        this.pluginVersion = pluginVersion.trimAscii()
        this.contentDigest = contentDigest.trimAscii()
        this.packageRoot = packageRoot.trimAscii()
        this.matcher = matcher.trimAscii()
        this.command = command
        this.timeoutMillis = timeoutMillis
    }
}

public class ToolSetSnapshot {
    public let id: String
    public let threadId: ?ThreadId
    public let entries: Array<ToolSnapshotEntry>
    public let hookHandlers: Array<ToolHookHandlerSnapshot>

    public init(
        id: String,
        entries: Array<ToolSnapshotEntry>,
        hookHandlers!: Array<ToolHookHandlerSnapshot> = [],
        threadId!: ?ThreadId = None
    ) {
        if (id.trimAscii() == "") {
            throw IllegalArgumentException("tool-set snapshot id must not be empty")
        }
        for (index in 0..entries.size) {
            for (other in index + 1..entries.size where entries[index].name == entries[other].name) {
                throw IllegalArgumentException("tool-set snapshot contains duplicate names")
            }
        }
        var preCount: Int64 = 0
        var postCount: Int64 = 0
        for (handler in hookHandlers) {
            if (handler.event == "PreToolUse") { preCount += 1 }
            if (handler.event == "PostToolUse") { postCount += 1 }
        }
        if (preCount > 32 || postCount > 32) {
            throw IllegalArgumentException("tool-set snapshot exceeds the per-event hook limit")
        }
        this.id = id.trimAscii()
        this.threadId = threadId
        this.entries = entries
        this.hookHandlers = hookHandlers
    }
}
public class ModelLane {
    public let role: ModelLaneRole
    private var providerIdData159: String
    public prop providerId: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); providerIdData159 } finally { metadataLock159.unlock() }
        }
    }
    private var modelIdData159: String
    public prop modelId: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); modelIdData159 } finally { metadataLock159.unlock() }
        }
    }
    private var protocolData159: String
    public prop protocol: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); protocolData159 } finally { metadataLock159.unlock() }
        }
    }
    private var capabilitiesData159: ?ModelLaneCapabilitiesSnapshot
    public prop capabilities: ModelLaneCapabilitiesSnapshot {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); capabilitiesData159.getOrThrow() }
            finally { metadataLock159.unlock() }
        }
    }
    public let contextWindow: Int64
    public let outputReserve: Int64
    public let providerSafetyMargin: Int64
    private var estimatorIdData159: String
    public prop estimatorId: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); estimatorIdData159 } finally { metadataLock159.unlock() }
        }
    }
    private var retryPolicyIdData159: String
    public prop retryPolicyId: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); retryPolicyIdData159 } finally { metadataLock159.unlock() }
        }
    }
    private var cachePolicyIdData159: String
    public prop cachePolicyId: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); cachePolicyIdData159 } finally { metadataLock159.unlock() }
        }
    }
    private let toolDataLock159 = Mutex()
    private let metadataLock159 = Mutex()
    private var rawToolSet159: ?ToolSetSnapshot
    private var modelLaneFrameReturned159 = false
    private let historicalLaneEscaped159 = AtomicBool(false)
    private var ownedToolSet159: ?SharedToolSetSnapshot159
    private var metadataCustody159: ?ModelLaneMetadataCustody159 = None<ModelLaneMetadataCustody159>
    // Compatibility export is explicit Held. Production closed consumers below
    // do not use this getter; remaining raw serializers are still being migrated.
    public prop toolSet: ToolSetSnapshot {
        get() {
            toolDataLock159.lock()
            try {
                match (rawToolSet159) {
                    case Some(value) => value
                    case None => ownedToolSet159.getOrThrow().exportHistoricalSnapshot159()
                }
            } finally { toolDataLock159.unlock() }
        }
    }
    private var systemInstructionVersionData159: String
    public prop systemInstructionVersion: String {
        get() {
            metadataLock159.lock()
            try { requireModelLaneFrame159(); systemInstructionVersionData159 } finally { metadataLock159.unlock() }
        }
    }

    public init(
        role: ModelLaneRole,
        providerId: String,
        modelId: String,
        protocol: String,
        capabilities: ModelLaneCapabilitiesSnapshot,
        contextWindow: Int64,
        outputReserve: Int64,
        providerSafetyMargin: Int64,
        estimatorId: String,
        retryPolicyId: String,
        cachePolicyId: String,
        toolSet: ToolSetSnapshot,
        systemInstructionVersion: String
    ) {
        for (value in [
            providerId, modelId, protocol, estimatorId, retryPolicyId,
            cachePolicyId, systemInstructionVersion
        ] where value.trimAscii() == "") {
            throw IllegalArgumentException("model lane identity fields must not be empty")
        }
        if (contextWindow < 1 || outputReserve < 1 || providerSafetyMargin < 0 ||
            outputReserve + providerSafetyMargin >= contextWindow) {
            throw IllegalArgumentException("model lane token budget is invalid")
        }
        if (!capabilities.tools) {
            for (entry in toolSet.entries where entry.availableAtSnapshot) {
                throw IllegalArgumentException("tool-free model lane cannot expose tools")
            }
        }
        this.role = role
        this.providerIdData159 = providerId.trimAscii()
        this.modelIdData159 = modelId.trimAscii()
        this.protocolData159 = protocol.trimAscii()
        this.capabilitiesData159 = Some(capabilities)
        this.contextWindow = contextWindow
        this.outputReserve = outputReserve
        this.providerSafetyMargin = providerSafetyMargin
        this.estimatorIdData159 = estimatorId.trimAscii()
        this.retryPolicyIdData159 = retryPolicyId.trimAscii()
        this.cachePolicyIdData159 = cachePolicyId.trimAscii()
        this.rawToolSet159 = Some(toolSet)
        this.ownedToolSet159 = None<SharedToolSetSnapshot159>
        this.systemInstructionVersionData159 = systemInstructionVersion.trimAscii()
    }

    init(
        role: ModelLaneRole,
        providerId: String,
        modelId: String,
        protocol: String,
        capabilities: ModelLaneCapabilitiesSnapshot,
        contextWindow: Int64,
        outputReserve: Int64,
        providerSafetyMargin: Int64,
        estimatorId: String,
        retryPolicyId: String,
        cachePolicyId: String,
        toolSet: SharedToolSetSnapshot159,
        systemInstructionVersion: String,
        metadataCustody159: ModelLaneMetadataCustody159
    ) {
        for (value in [
            providerId, modelId, protocol, estimatorId, retryPolicyId,
            cachePolicyId, systemInstructionVersion
        ] where value.trimAscii() == "") {
            throw IllegalArgumentException("model lane identity fields must not be empty")
        }
        if (contextWindow < 1 || outputReserve < 1 || providerSafetyMargin < 0 ||
            outputReserve + providerSafetyMargin >= contextWindow) {
            throw IllegalArgumentException("model lane token budget is invalid")
        }
        if (!capabilities.tools) {
            if (toolSet.hasAvailableTools159()) {
                throw IllegalArgumentException("tool-free model lane cannot expose tools")
            }
        }
        this.role = role
        this.providerIdData159 = String.fromUtf8(providerId.trimAscii().toArray())
        this.modelIdData159 = String.fromUtf8(modelId.trimAscii().toArray())
        this.protocolData159 = String.fromUtf8(protocol.trimAscii().toArray())
        this.capabilitiesData159 = Some(ModelLaneCapabilitiesSnapshot(
            streaming: capabilities.streaming, tools: capabilities.tools, reasoning: capabilities.reasoning,
            structuredOutput: capabilities.structuredOutput, imageInput: capabilities.imageInput,
            promptCache: capabilities.promptCache, providerOpaqueState: capabilities.providerOpaqueState))
        this.contextWindow = contextWindow
        this.outputReserve = outputReserve
        this.providerSafetyMargin = providerSafetyMargin
        this.estimatorIdData159 = String.fromUtf8(estimatorId.trimAscii().toArray())
        this.retryPolicyIdData159 = String.fromUtf8(retryPolicyId.trimAscii().toArray())
        this.cachePolicyIdData159 = String.fromUtf8(cachePolicyId.trimAscii().toArray())
        this.rawToolSet159 = None<ToolSetSnapshot>
        this.ownedToolSet159 = Some(toolSet)
        this.metadataCustody159 = Some(metadataCustody159)
        this.systemInstructionVersionData159 = String.fromUtf8(systemInstructionVersion.trimAscii().toArray())
    }

    private func requireModelLaneFrame159(): Unit {
        if (modelLaneFrameReturned159) { throw IllegalStateException("owned ModelLane frame has returned") }
    }
    // A typed SDK/Runtime consumer gets independent prepaid metadata copies
    // and its own snapshot share. The legacy unowned fixture returns None.
    func hasOwnedLaneFrame159(): Bool {
        toolDataLock159.lock()
        try { ownedToolSet159.isSome() && metadataCustody159.isSome() }
        finally { toolDataLock159.unlock() }
    }
    public func forkOwnedLaneFrame159(): ?ModelLane {
        toolDataLock159.lock()
        try {
            requireModelLaneFrame159()
            match (ownedToolSet159) {
                case Some(value) => Some(modelLaneWithSharedToolSet159(role, providerIdData159,
                    modelIdData159, protocolData159, capabilitiesData159.getOrThrow(), contextWindow,
                    outputReserve, providerSafetyMargin, estimatorIdData159, retryPolicyIdData159,
                    cachePolicyIdData159, value, systemInstructionVersionData159))
                case None => None<ModelLane>
            }
        } finally { toolDataLock159.unlock() }
    }
    // Explicit DATA frame return, never called by Runtime.finish or a generic
    // callback. All actual consumers must first clear their raw field aliases.
    // Historical DOM serializers may retain provider/policy Strings as well
    // as the tool graph. Their metadata payment is not an implicit frame ACK.
    func markHistoricalLaneExport159(): Unit { historicalLaneEscaped159.store(true) }
    public func returnOwnedLaneFrame159(): Unit {
        let returned = clearOwnedLaneFrame159()
        match (returned[0]) { case Some(value) => value.close159(); case None => () }
        match (returned[1]) { case Some(value) => value.returnMetadataFrame159(); case None => () }
    }
    private func clearOwnedLaneFrame159(): (?SharedToolSetSnapshot159, ?ModelLaneMetadataCustody159) {
        toolDataLock159.lock()
        try {
            if (modelLaneFrameReturned159 || ownedToolSet159.isNone()) {
                return (None<SharedToolSetSnapshot159>, None<ModelLaneMetadataCustody159>) }
            let returned = ownedToolSet159
            ownedToolSet159 = None<SharedToolSetSnapshot159>
            rawToolSet159 = None<ToolSetSnapshot>
            var metadata: ?ModelLaneMetadataCustody159 = None<ModelLaneMetadataCustody159>
            metadataLock159.lock()
            try {
                if (!historicalLaneEscaped159.load()) {
                    providerIdData159 = ""; modelIdData159 = ""; protocolData159 = ""
                    estimatorIdData159 = ""; retryPolicyIdData159 = ""; cachePolicyIdData159 = ""
                    systemInstructionVersionData159 = ""; capabilitiesData159 = None<ModelLaneCapabilitiesSnapshot>
                    metadata = metadataCustody159; metadataCustody159 = None<ModelLaneMetadataCustody159>
                }
                // Unknown raw String aliases keep their separately paid
                // metadata owner, but cannot retain the unrelated tool graph.
                modelLaneFrameReturned159 = true
            } finally { metadataLock159.unlock() }
            (returned, metadata)
        } finally { toolDataLock159.unlock() }
    }
    public func snapshotEqualsLane159(expected: ModelLane): Bool {
        let first = ownedSnapshotValue159()
        match (first) {
            case Some(actual) =>
                let second = expected.ownedSnapshotValue159()
                match (second) {
                    case Some(other) =>
                        let answer = modelLaneEqualClosedFrame159(actual, other)
                        actual.recordClosedComparisonReturned159(); other.recordClosedComparisonReturned159()
                        modelLaneReturnedPayments159(other.detachReturnedFrame159())
                        modelLaneReturnedPayments159(actual.detachReturnedFrame159())
                        answer
                    case None =>
                        // The historical public lane remains an explicitly
                        // unowned fixture path; do not mint a replacement bank.
                        let answer = modelLaneEqualLegacyFrame159(actual, expected)
                        actual.recordClosedComparisonReturned159()
                        modelLaneReturnedPayments159(actual.detachReturnedFrame159())
                        answer
                }
            case None => canonicalAgentValue(modelLaneSnapshotValue(this)) == canonicalAgentValue(modelLaneSnapshotValue(expected))
        }
    }
    public func continuationLaunchDigestEquals159(context: AgentValue, budget: AgentValue, expected: String): Bool {
        match (ownedSnapshotValue159()) {
            case Some(input) =>
                let result = modelLaneContinuationDigestFrame159(input, context, budget, expected)
                input.recordClosedComparisonReturned159()
                modelLaneReturnedPayments159(input.detachReturnedFrame159())
                result
            case None => continuationRunLaunchDigest(modelLaneSnapshotValue(this), context, budget) == expected
        }
    }
    public func snapshotDigestEquals159(expected: String): Bool {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) {
                case Some(value) => value.laneDigestEquals159(this, expected)
                case None => modelPolicySha256Text(canonicalAgentValue(modelLaneSnapshotFrame159(this, rawToolSet159.getOrThrow()))) == expected
            }
        } finally { toolDataLock159.unlock() }
    }
    public func legacyToolSetSnapshot159(): ?ToolSetSnapshot {
        toolDataLock159.lock()
        try { rawToolSet159 } finally { toolDataLock159.unlock() }
    }
    public func forkOwnedToolSetSnapshot159(): ?SharedToolSetSnapshot159 {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => Some(value.fork159())
                case None => None<SharedToolSetSnapshot159> }
        } finally { toolDataLock159.unlock() }
    }
    public func hasAvailableTools159(): Bool {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => return value.hasAvailableTools159(); case None => () }
            for (entry in rawToolSet159.getOrThrow().entries where entry.availableAtSnapshot) { return true }
            false
        } finally { toolDataLock159.unlock() }
    }
    public func hasNoToolEntriesOrHooks159(): Bool {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => value.hasNoEntriesOrHooks159()
                case None => rawToolSet159.getOrThrow().entries.isEmpty() && rawToolSet159.getOrThrow().hookHandlers.isEmpty() }
        } finally { toolDataLock159.unlock() }
    }
    public func permitsToolThread159(thread: ThreadId): Bool {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => return value.permitsThread159(thread); case None => () }
            match (rawToolSet159.getOrThrow().threadId) { case Some(value) => value.value == thread.value; case None => true }
        } finally { toolDataLock159.unlock() }
    }
    public func hasCompleteToolIdentities159(): Bool {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => return value.hasCompleteIdentities159(); case None => () }
            for (entry in rawToolSet159.getOrThrow().entries where !entry.hasCompleteIdentity()) { return false }
            true
        } finally { toolDataLock159.unlock() }
    }
    public func estimateSystemInstructions159(estimator: ThreadTokenEstimator): Int64 {
        match (estimator) { case _: ConservativeThreadTokenEstimator => ()
            case _ => markHistoricalLaneExport159() }
        estimator.estimateSystemInstructions(systemInstructionVersion)
    }
    public func estimateToolSet159(estimator: ThreadTokenEstimator): Int64 {
        // Unknown estimators can reenter the lane as well as retain its input.
        // Export under the lock, then release it before invoking arbitrary code.
        let historical: ToolSetSnapshot
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) {
                case Some(value) => match (estimator) {
                    case _: ConservativeThreadTokenEstimator => return value.estimateConservativeTokens159()
                    case _ => historical = value.exportHistoricalSnapshot159()
                }
                case None => historical = rawToolSet159.getOrThrow()
            }
        } finally { toolDataLock159.unlock() }
        estimator.estimateToolSet(historical)
    }
    public func ownedModelTools159(): ?OwnedModelTools159 {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => Some(value.copyOwnedModelTools159())
                case None => None<OwnedModelTools159> }
        } finally { toolDataLock159.unlock() }
    }
    public func ownedManifestCatalog159(): ?OwnedToolCatalogValue159 {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => Some(value.manifestCatalog159())
                case None => None<OwnedToolCatalogValue159> }
        } finally { toolDataLock159.unlock() }
    }
    func ownedSnapshotValue159(): ?OwnedModelLaneSnapshot159 {
        toolDataLock159.lock()
        try {
            match (ownedToolSet159) { case Some(value) => Some(value.modelLaneSnapshot159(this))
                case None => None<OwnedModelLaneSnapshot159> }
        } finally { toolDataLock159.unlock() }
    }
    public func maxEstimatedInput(): Int64 {
        contextWindow - outputReserve - providerSafetyMargin
    }
}

public class RunModelUsageSample {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let requestSequence: Int64
    public let role: ModelLaneRole
    public let estimatedInputTokens: Int64
    public let actual: ModelUsage
    public let observedAtMillis: Int64

    public init(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        requestSequence: Int64,
        role: ModelLaneRole,
        estimatedInputTokens: Int64,
        actual: ModelUsage,
        observedAtMillis: Int64
    ) {
        if (epoch < 1 || requestSequence < 1 || estimatedInputTokens < 0 ||
            observedAtMillis < 0) {
            throw IllegalArgumentException("Run model usage sample metadata is invalid")
        }
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.requestSequence = requestSequence
        this.role = role
        this.estimatedInputTokens = estimatedInputTokens
        this.actual = actual
        this.observedAtMillis = observedAtMillis
    }
}

// Provider DTOs are deliberately excluded. This is the immutable semantic
// snapshot needed to explain and recover a Run after configuration changes.
public func modelLaneSnapshotValue(lane: ModelLane): AgentValue {
    // Existing raw API explicitly retains historical aliases. The installed
    // TurnStarted path uses its own paid, non-exported snapshot loan instead.
    lane.markHistoricalLaneExport159()
    modelLaneSnapshotFrame159(lane, lane.toolSet)
}

func modelLaneSnapshotFrame159(lane: ModelLane, snapshot: ToolSetSnapshot): AgentValue {
    let tools = ArrayList<AgentValue>()
    for (entry in snapshot.entries) {
        let capabilities = ArrayList<AgentValue>()
        for (capability in entry.requiredCapabilities) {
            capabilities.add(objectValue([
                ValueField("kind", textValue(modelLaneCapabilityName(capability.kind))),
                ValueField("resource", textValue(capability.resource))
            ]))
        }
        tools.add(objectValue([
            ValueField("name", textValue(entry.name)),
            ValueField("description", textValue(entry.description)),
            ValueField("input_schema", entry.inputSchema),
            ValueField("executor_version", textValue(entry.executorVersion)),
            ValueField("implementation_fingerprint", textValue(entry.implementationFingerprint)),
            ValueField("schema_digest", textValue(entry.schemaDigest)),
            ValueField("available_at_snapshot", boolValue(entry.availableAtSnapshot)),
            ValueField("capabilities", listValue(capabilities.toArray()))
        ]))
    }
    let hooks = ArrayList<AgentValue>()
    for (handler in snapshot.hookHandlers) {
        hooks.add(objectValue([
            ValueField("event", textValue(handler.event)),
            ValueField("plugin_id", textValue(handler.pluginId)),
            ValueField("plugin_version", textValue(handler.pluginVersion)),
            ValueField("content_digest", textValue(handler.contentDigest)),
            ValueField("package_root", textValue(handler.packageRoot)),
            ValueField("matcher", textValue(handler.matcher)),
            ValueField("command", textValue(handler.command)),
            ValueField("timeout_millis", integerValue(handler.timeoutMillis))
        ]))
    }
    let fields = ArrayList<ValueField>([
        ValueField("role", textValue(modelLaneRoleName(lane.role))),
        ValueField("provider_id", textValue(lane.providerId)),
        ValueField("model_id", textValue(lane.modelId)),
        ValueField("protocol", textValue(lane.protocol)),
        ValueField("capabilities", objectValue([
            ValueField("streaming", boolValue(lane.capabilities.streaming)),
            ValueField("tools", boolValue(lane.capabilities.tools)),
            ValueField("reasoning", boolValue(lane.capabilities.reasoning)),
            ValueField("structured_output", boolValue(lane.capabilities.structuredOutput)),
            ValueField("image_input", boolValue(lane.capabilities.imageInput)),
            ValueField("prompt_cache", boolValue(lane.capabilities.promptCache)),
            ValueField("provider_opaque_state", boolValue(lane.capabilities.providerOpaqueState))
        ])),
        ValueField("context_window", integerValue(lane.contextWindow)),
        ValueField("output_reserve", integerValue(lane.outputReserve)),
        ValueField("provider_safety_margin", integerValue(lane.providerSafetyMargin)),
        ValueField("estimator_id", textValue(lane.estimatorId)),
        ValueField("retry_policy_id", textValue(lane.retryPolicyId)),
        ValueField("cache_policy_id", textValue(lane.cachePolicyId)),
        ValueField("tool_set_id", textValue(snapshot.id)),
        ValueField("tools", listValue(tools.toArray())),
        ValueField("hooks", listValue(hooks.toArray())),
        ValueField("system_instruction_version", textValue(lane.systemInstructionVersion))
    ])
    match (snapshot.threadId) {
        case Some(value) => fields.add(ValueField("tool_set_thread_id", textValue(value.value)))
        case None => ()
    }
    objectValue(fields.toArray())
}

public func modelLaneFromSnapshotValue(value: AgentValue): ModelLane {
    let capabilityValue = laneObjectField(value, "capabilities")
    let toolValues = laneField(value, "tools")
    if (toolValues.unifiedKind != ValueKind.List) {
        throw IllegalStateException("ModelLane tools snapshot is not a list")
    }
    let tools = ArrayList<ToolSnapshotEntry>()
    for (tool in toolValues.items) {
        let capabilityItems = laneField(tool, "capabilities")
        if (capabilityItems.unifiedKind != ValueKind.List) {
            throw IllegalStateException("Tool capability snapshot is not a list")
        }
        let capabilities = ArrayList<Capability>()
        for (item in capabilityItems.items) {
            capabilities.add(Capability(
                laneCapabilityKind(laneTextField(item, "kind")),
                resource: laneTextField(item, "resource")
            ))
        }
        tools.add(ToolSnapshotEntry(
            laneTextField(tool, "name"), laneTextField(tool, "description"),
            laneField(tool, "input_schema"), laneTextField(tool, "executor_version"),
            capabilities.toArray(),
            implementationFingerprint: laneOptionalTextField(tool, "implementation_fingerprint"),
            schemaDigest: laneOptionalTextField(tool, "schema_digest"),
            availableAtSnapshot: laneOptionalBoolField(tool, "available_at_snapshot")
        ))
    }
    let hookValues = match (value.field("hooks")) {
        case Some(item) => item
        case None => listValue([])
    }
    if (hookValues.unifiedKind != ValueKind.List) {
        throw IllegalStateException("ModelLane hooks snapshot is not a list")
    }
    let hooks = ArrayList<ToolHookHandlerSnapshot>()
    for (handler in hookValues.items) {
        hooks.add(ToolHookHandlerSnapshot(
            laneTextField(handler, "event"),
            laneTextField(handler, "plugin_id"),
            laneTextField(handler, "plugin_version"),
            laneTextField(handler, "content_digest"),
            laneTextField(handler, "package_root"),
            laneTextField(handler, "matcher"),
            laneTextField(handler, "command"),
            laneIntField(handler, "timeout_millis")
        ))
    }
    ModelLane(
        laneRole(laneTextField(value, "role")),
        laneTextField(value, "provider_id"), laneTextField(value, "model_id"),
        laneTextField(value, "protocol"),
        ModelLaneCapabilitiesSnapshot(
            streaming: laneBoolField(capabilityValue, "streaming"),
            tools: laneBoolField(capabilityValue, "tools"),
            reasoning: laneBoolField(capabilityValue, "reasoning"),
            structuredOutput: laneBoolField(capabilityValue, "structured_output"),
            imageInput: laneBoolField(capabilityValue, "image_input"),
            promptCache: laneBoolField(capabilityValue, "prompt_cache"),
            providerOpaqueState: laneBoolField(capabilityValue, "provider_opaque_state")
        ),
        laneIntField(value, "context_window"), laneIntField(value, "output_reserve"),
        laneIntField(value, "provider_safety_margin"),
        laneTextField(value, "estimator_id"), laneTextField(value, "retry_policy_id"),
        laneTextField(value, "cache_policy_id"),
        ToolSetSnapshot(
            laneTextField(value, "tool_set_id"), tools.toArray(),
            hookHandlers: hooks.toArray(),
            threadId: match (value.field("tool_set_thread_id")) {
                case Some(field) => if (field.unifiedKind == ValueKind.Text) { Some(ThreadId(field.text)) }
                    else { throw IllegalStateException("tool snapshot Thread must be a nonempty identifier") }
                case None => None
            }
        ),
        laneTextField(value, "system_instruction_version")
    )
}

public func modelLaneRoleName(role: ModelLaneRole): String {
    match (role) {
        case ModelLaneRole.Main => "main"
        case ModelLaneRole.Reviewer => "reviewer"
        case ModelLaneRole.Compactor => "compactor"
        case ModelLaneRole.Subagent => "subagent"
        case ModelLaneRole.Memory => "memory"
    }
}

func modelLaneCapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func laneRole(value: String): ModelLaneRole {
    match (value) {
        case "main" => ModelLaneRole.Main
        case "reviewer" => ModelLaneRole.Reviewer
        case "compactor" => ModelLaneRole.Compactor
        case "subagent" => ModelLaneRole.Subagent
        case "memory" => ModelLaneRole.Memory
        case _ => throw IllegalStateException("unknown ModelLane role: " + value)
    }
}

func laneCapabilityKind(value: String): CapabilityKind {
    match (value) {
        case "workspace_read" => CapabilityKind.WorkspaceRead
        case "workspace_write" => CapabilityKind.WorkspaceWrite
        case "process_spawn" => CapabilityKind.ProcessSpawn
        case "network_access" => CapabilityKind.NetworkAccess
        case "peer_message" => CapabilityKind.PeerMessage
        case "delegate" => CapabilityKind.Delegate
        case "extension_invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalStateException("unknown ModelLane capability: " + value)
    }
}

func laneField(value: AgentValue, name: String): AgentValue {
    if (value.unifiedKind != ValueKind.Object) {
        throw IllegalStateException("ModelLane snapshot is not an object")
    }
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalStateException("ModelLane snapshot field is missing: " + name)
    }
}

func laneObjectField(value: AgentValue, name: String): AgentValue {
    let item = laneField(value, name)
    if (item.unifiedKind != ValueKind.Object) {
        throw IllegalStateException("ModelLane snapshot field is not an object: " + name)
    }
    item
}

func laneTextField(value: AgentValue, name: String): String {
    let item = laneField(value, name)
    if (item.unifiedKind != ValueKind.Text) {
        throw IllegalStateException("ModelLane snapshot field is not text: " + name)
    }
    item.text
}

func laneOptionalTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind != ValueKind.Text) {
                throw IllegalStateException("ModelLane snapshot field is not text: " + name)
            }
            item.text
        case None => ""
    }
}

func laneOptionalBoolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind != ValueKind.Boolean) {
                throw IllegalStateException("ModelLane snapshot field is not boolean: " + name)
            }
            item.asBool()
        case None => true
    }
}

func laneBoolField(value: AgentValue, name: String): Bool {
    let item = laneField(value, name)
    if (item.unifiedKind != ValueKind.Boolean) {
        throw IllegalStateException("ModelLane snapshot field is not boolean: " + name)
    }
    item.asBool()
}

func laneIntField(value: AgentValue, name: String): Int64 {
    let item = laneField(value, name)
    if (item.unifiedKind != ValueKind.Number) {
        throw IllegalStateException("ModelLane snapshot field is not numeric: " + name)
    }
    try { Int64.parse(item.asNumberText()) } catch (_: Exception) {
        throw IllegalStateException("ModelLane snapshot field is not an integer: " + name)
    }
}

private func modelLaneMetadataText159(total: Int64, value: String): Int64 {
    if (value.size > (Int64.Max - total - 1024) / 32) {
        throw IllegalStateException("model lane metadata invoice overflow")
    }
    total + 1024 + value.size * 32
}
public func modelLaneWithSharedToolSet159(role: ModelLaneRole, providerId: String,
    modelId: String, protocol: String, capabilities: ModelLaneCapabilitiesSnapshot,
    contextWindow: Int64, outputReserve: Int64, providerSafetyMargin: Int64,
    estimatorId: String, retryPolicyId: String, cachePolicyId: String,
    toolSet: SharedToolSetSnapshot159, systemInstructionVersion: String): ModelLane {
    var invoice: Int64 = 16384
    invoice = modelLaneMetadataText159(invoice, providerId)
    invoice = modelLaneMetadataText159(invoice, modelId)
    invoice = modelLaneMetadataText159(invoice, protocol)
    invoice = modelLaneMetadataText159(invoice, estimatorId)
    invoice = modelLaneMetadataText159(invoice, retryPolicyId)
    invoice = modelLaneMetadataText159(invoice, cachePolicyId)
    invoice = modelLaneMetadataText159(invoice, systemInstructionVersion)
    let metadata = ModelLaneMetadataCustody159(toolSet.deriveLaneMetadata159(invoice))
    let owned = toolSet.fork159()
    // Both payments precede their carriers/copies. Failure remains reachable
    // in the registered metadata owner, never an automatic refund.
    let value = ModelLane(role, providerId, modelId, protocol, capabilities, contextWindow,
        outputReserve, providerSafetyMargin, estimatorId, retryPolicyId,
        cachePolicyId, owned, systemInstructionVersion, metadata)
    metadata.bind159(value)
    value
}

private func modelLaneEqualClosedFrame159(first: OwnedModelLaneSnapshot159, second: OwnedModelLaneSnapshot159): Bool {
    first.reserveCopy159(); second.reserveCopy159()
    canonicalAgentValue(first.value159()) == canonicalAgentValue(second.value159())
}
private func modelLaneEqualLegacyFrame159(first: OwnedModelLaneSnapshot159, second: ModelLane): Bool {
    first.reserveCopy159()
    canonicalAgentValue(first.value159()) == canonicalAgentValue(modelLaneSnapshotValue(second))
}
public func modelLaneReplacingSharedToolSet159(lane: ModelLane, snapshot: SharedToolSetSnapshot159): ModelLane {
    // The temporary capabilities carrier is funded before construction. The
    // returned lane owns independent metadata copies and a separate share.
    let phase = snapshot.deriveLaneMetadata159(4096)
    let result = modelLaneReplacingSharedToolSetFrame159(lane, snapshot)
    phase.close()
    result
}
private func modelLaneReplacingSharedToolSetFrame159(lane: ModelLane, snapshot: SharedToolSetSnapshot159): ModelLane {
    let caps = lane.capabilities
    modelLaneWithSharedToolSet159(lane.role, lane.providerId, lane.modelId, lane.protocol,
        ModelLaneCapabilitiesSnapshot(streaming: caps.streaming, tools: snapshot.hasAvailableTools159(),
            reasoning: caps.reasoning, structuredOutput: caps.structuredOutput,
            imageInput: caps.imageInput, promptCache: caps.promptCache, providerOpaqueState: caps.providerOpaqueState),
        lane.contextWindow, lane.outputReserve, lane.providerSafetyMargin, lane.estimatorId,
        lane.retryPolicyId, lane.cachePolicyId, snapshot, lane.systemInstructionVersion)
}

private func modelLaneContinuationDigestFrame159(input: OwnedModelLaneSnapshot159, context: AgentValue, budget: AgentValue, expected: String): Bool {
    // The original complete lane/context/budget grammar and hash are unchanged.
    // All canonical copies are funded before the closed producer call; only
    // its Bool can escape and the entire helper returns before loan retirement.
    input.reserveCopy159(); input.reserveClosedValue159(context); input.reserveClosedValue159(budget)
    continuationRunLaunchDigest(input.value159(), context, budget) == expected
}
