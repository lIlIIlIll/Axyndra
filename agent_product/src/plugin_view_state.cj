package agent_product

import agent_domain.*
import agent_host_runtime.*
import agent_plugin_registry.*
import agent_sdk.isPluginViewPlainText
import process4cj as view_process
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

class ProductPluginViewSourceError <: Exception {
    init() { super("View refers to no actual Host primary source") }
}

// Ephemeral presentation DATA, not an operation/approval store. The retained
// index excludes the primary document and all non-interactive presentation.
// Its loan comes from the selected installed package's actual metadata bank.
class ProductPluginViewState {
    private let lock = Mutex()
    private var index: ?AgentValue = None
    private var payment: ?LogicalJsonOwnerReservation
    private var closed = false
    private var readers: Int64 = 0
    private var actionActive = false
    private var pending: ?ProductPluginViewPending = None
    private var revocation: ?view_process.CancellationRegistration = None

    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }

    func initialize(metadata: AgentValue, model: AgentValue, mode: String): Unit {
        let paid = payment.getOrThrow()
        paid.ensureRetainedPeak(1048576)
        let nodes = ArrayList<AgentValue>()
        for (node in model.field("nodes").getOrThrow().items) {
            let kind = httpIntentText(node, "kind")
            if (kind == "input") {
                let source = httpIntentText(node, "source")
                if (source != "" && (source != "primary" ||
                    !(metadata.field("primary").getOrThrow().field("available").getOrThrow().asBool()))) {
                    throw ProductPluginViewSourceError() }
                nodes.add(objectValue([ValueField("id", node.field("id").getOrThrow()),
                    ValueField("kind", textValue(kind)), ValueField("source", textValue(source))]))
            } else if (kind == "list" || kind == "table") {
                let ids = ArrayList<AgentValue>()
                for (item in node.field(if (kind == "table") { "rows" } else { "items" }).getOrThrow().items) {
                    ids.add(item.field("id").getOrThrow()) }
                nodes.add(objectValue([ValueField("id", node.field("id").getOrThrow()),
                    ValueField("kind", textValue(kind)), ValueField("ids", listValue(ids.toArray()))]))
            } else if (kind == "document" && (httpIntentText(node, "source") != "primary" ||
                !(metadata.field("primary").getOrThrow().field("available").getOrThrow().asBool()))) {
                throw ProductPluginViewSourceError() }
        }
        let value = objectValue([ValueField("metadata", metadata), ValueField("work_mode", textValue(mode)),
            ValueField("nodes", listValue(nodes.toArray())), ValueField("actions", model.field("actions").getOrThrow())])
        let bytes = logicalJsonWriteReservationBytes(value, 196608)
        let count = logicalJsonValueNodeCount(value)
        paid.ensureRetainedPeak(bytes * 16 + count * 1024 + 2097152)
        index = Some(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 196608, maxDepth: 32))
    }

    // Entry/return is controlled by Application's whole synchronous helpers.
    // Revocation cannot refund storage while an original consumer still reads.
    func enter(id: String, revision: String, confirmation!: Bool = false): Result<Unit> {
        lock.lock()
        try {
            if (closed || index.isNone() || readers != 0 || actionActive ||
                (confirmation != pending.isSome())) {
                return pluginViewObservationError("view.stale_event", "View no longer accepts this user event") }
            let metadata = index.getOrThrow().field("metadata").getOrThrow()
            if (httpIntentText(metadata, "view_id") != id || revision != (if (confirmation) { "2" } else { "1" })) {
                return pluginViewObservationError("view.stale_event", "View identity or revision does not match") }
            readers++; actionActive = true
            Result.Ok(())
        } finally { lock.unlock() }
    }
    func wholeConsumerReturned(): Unit {
        lock.lock()
        try {
            if (readers != 1) { throw IllegalStateException("View consumer returned without entry") }
            readers--; actionActive = false
            retireIfClosed()
        } finally { lock.unlock() }
    }
    func attachRevocation(registration: view_process.CancellationRegistration): Unit {
        lock.lock()
        let dispose = try {
            if (closed) { true } else { revocation = Some(registration); false }
        } finally { lock.unlock() }
        if (dispose) { registration.dispose() }
    }
    func close(): Unit {
        lock.lock()
        let registration = try {
            closed = true
            let value = revocation; revocation = None
            retireIfClosed()
            value
        } finally { lock.unlock() }
        // Disposal cannot hold the presentation mutex while a real generation
        // callback concurrently enters close. In-flight readers retain DATA.
        match (registration) { case Some(value) => value.dispose(); case None => () }
    }
    private func retireIfClosed(): Unit {
        if (!closed || readers != 0) { return }
        index = None
        match (pending) { case Some(value) => value.close(); pending = None; case None => () }
        match (payment) { case Some(value) => value.close(); payment = None; case None => () }
    }
    func data(): AgentValue { index.getOrThrow() }
    func metadata(): AgentValue { data().field("metadata").getOrThrow() }
    func isClosed(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
    func matchesId(id: String): Bool {
        lock.lock()
        try { !closed && index.isSome() &&
            httpIntentText(index.getOrThrow().field("metadata").getOrThrow(), "view_id") == id }
        finally { lock.unlock() }
    }
    func current(runtime: ProductRuntime, actualSession: SessionId, actualMode: String): Result<Unit> {
        if (isClosed()) { return pluginViewObservationError("view.closed", "View has been closed") }
        let metadata = this.metadata()
        if (httpIntentText(metadata, "session_id") != actualSession.value || httpIntentText(data(), "work_mode") != actualMode) {
            return pluginViewObservationError("view.session_changed", "View belongs to a different actual session or mode") }
        let binding = match (runtime.vnext.javascriptPlugins.viewBinding(httpIntentText(metadata, "namespace"), httpIntentText(metadata, "name"))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (binding.digest != httpIntentText(metadata, "package_digest") ||
            binding.generation.toString() != httpIntentText(metadata, "generation")) {
            return pluginViewObservationError("view.changed", "View's installed package or generation has changed") }
        Result.Ok(())
    }
    func action(id: String): Result<AgentValue> {
        for (value in data().field("actions").getOrThrow().items where httpIntentText(value, "id") == id) {
            return Result.Ok(value) }
        pluginViewObservationError("view.action_missing", "user selected no declared View action")
    }
    func validateFields(fields: AgentValue): Result<Unit> {
        if (fields.unifiedKind != ValueKind.Object) {
            return pluginViewObservationError("view.fields_invalid", "View fields must be an object") }
        let nodes = data().field("nodes").getOrThrow().items
        if (fields.fields.size != nodes.size) {
            return pluginViewObservationError("view.fields_invalid", "View event must contain its actual declared fields") }
        let seen = HashSet<String>()
        for (field in fields.fields) {
            if (seen.contains(field.name) || field.value.unifiedKind != ValueKind.Text || !isPluginViewPlainText(field.value.text)) {
                return pluginViewObservationError("view.fields_invalid", "View event has duplicate, non-text or unsafe fields") }
            seen.add(field.name)
            var declared = false
            for (node in nodes where httpIntentText(node, "id") == field.name) {
                declared = true
                let kind = httpIntentText(node, "kind")
                if (kind == "input") {
                    let maximum = if (httpIntentText(node, "source") == "primary") { CONTENT_PAYLOAD_RESULT_BYTES } else { 16384 }
                    if (field.value.text.size > maximum) {
                        return pluginViewObservationError("view.fields_limit", "View input exceeds its actual source or inline bound") }
                } else {
                    var found = field.value.text == ""
                    for (id in node.field("ids").getOrThrow().items where id.text == field.value.text) { found = true }
                    if (!found) { return pluginViewObservationError("view.selection_invalid", "View selection is not a declared item") }
                }
            }
            if (!declared) { return pluginViewObservationError("view.fields_invalid", "View event contains an undeclared field") }
        }
        Result.Ok(())
    }
    func validateControl(control: ProductPluginViewControl, fields: AgentValue): Result<Unit> {
        let metadata = this.metadata()
        if (control.binding.namespace != httpIntentText(metadata, "namespace") ||
            control.binding.generation.toString() != httpIntentText(metadata, "generation") ||
            control.binding.digest != httpIntentText(metadata, "package_digest") ||
            httpIntentText(metadata.field("primary").getOrThrow(), "kind") != "plan" ||
            control.contentHash != httpIntentText(metadata.field("primary").getOrThrow(), "sha256")) {
            return pluginViewObservationError("view.control_binding_mismatch", "business request does not match the actual displayed source") }
        var plan = false; var feedback = false
        for (node in data().field("nodes").getOrThrow().items where httpIntentText(node, "kind") == "input") {
            if (httpIntentText(node, "id") == control.planField && httpIntentText(node, "source") == "primary") { plan = true }
            if (httpIntentText(node, "id") == control.feedbackField && httpIntentText(node, "source") == "") { feedback = true }
        }
        if (!plan || !feedback || fields.field(control.planField).isNone() || fields.field(control.feedbackField).isNone()) {
            return pluginViewObservationError("view.control_fields_invalid", "business field references do not resolve to the actual View inputs") }
        Result.Ok(())
    }
    func stage(value: ProductPluginViewPending): Result<Unit> {
        lock.lock()
        try {
            if (closed || readers != 1 || !actionActive || pending.isSome()) {
                return pluginViewObservationError("view.stale_event", "View changed before its business request was staged") }
            pending = Some(value)
            Result.Ok(())
        } finally { lock.unlock() }
    }
    func confirmation(): ProductPluginViewPending { pending.getOrThrow() }
}

// Owns only the real user's frozen fields and the requested typed control.
// Never accepts fields from a later confirmation or reconstructs them from a
// plugin response/history. Closing follows the complete original consumer.
class ProductPluginViewPending {
    private var value: ?AgentValue = None
    private var payment: ?LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }
    func initialize(control: ProductPluginViewControl, fields: AgentValue): Unit {
        let paid = payment.getOrThrow(); paid.ensureRetainedPeak(1048576)
        let data = objectValue([ValueField("action", textValue(control.action)),
            ValueField("content_hash", textValue(control.contentHash)), ValueField("plan_field", textValue(control.planField)),
            ValueField("feedback_field", textValue(control.feedbackField)), ValueField("request_digest", textValue(control.sourceDigest)),
            ValueField("fields", fields)])
        let bytes = logicalJsonWriteReservationBytes(data, CONTENT_PAYLOAD_INPUT_BYTES)
        paid.ensureRetainedPeak(bytes * 16 + logicalJsonValueNodeCount(data) * 1024 + 2097152)
        value = Some(parseUnifiedJson(stringifyUnifiedJson(data), maxBytes: CONTENT_PAYLOAD_INPUT_BYTES, maxDepth: 32))
    }
    func data(): AgentValue { value.getOrThrow() }
    func close(): Unit {
        value = None
        match (payment) { case Some(paid) => paid.close(); payment = None; case None => () }
    }
}

func productPluginViewPayment(runtime: ProductRuntime, namespace: String, generation: UInt64,
    digest: String): Result<LogicalJsonOwnerReservation> {
    let mounted = match (runtime.vnext.javascriptPlugins.servicePackage(namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        if (!mounted.textEquals(PluginDescriptorText.ContentDigest, digest)) {
            return pluginViewObservationError("view.changed", "View lost its actual installed package DATA owner") }
        Result.Ok(mounted.deriveCopiedDataPayment(65536))
    } catch (_: LogicalJsonPayloadError) {
        pluginViewObservationError("view.query_limit", "View cannot acquire its actual package DATA custody")
    } finally { mounted.close() }
}

func freezeProductPluginViewState(runtime: ProductRuntime, binding: HostPluginViewBinding,
    metadata: AgentValue, model: AgentValue, mode: String): Result<ProductPluginViewState> {
    let paid = match (productPluginViewPayment(runtime, binding.namespace, binding.generation, binding.digest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let state = ProductPluginViewState(paid)
    var retained = false
    try {
        state.initialize(metadata, model, mode)
        let registration = match (runtime.vnext.javascriptPlugins.observeServiceRevocationReturning180(
            binding.namespace, binding.generation, { => state.close() })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        state.attachRevocation(registration)
        if (state.isClosed()) {
            return pluginViewObservationError("view.changed", "actual View generation closed before presentation") }
        retained = true
        Result.Ok(state)
    } catch (error: ProductPluginViewSourceError) {
        pluginViewObservationError("view.source_unavailable", error.message)
    } catch (error: Exception) {
        pluginViewObservationError("view.query_limit", "View index cannot be frozen within its installed-package custody: " + error.message)
    } finally { if (!retained) { state.close() } }
}

func freezeProductPluginViewPending(runtime: ProductRuntime, control: ProductPluginViewControl,
    fields: AgentValue): Result<ProductPluginViewPending> {
    let source = match (productPluginViewPayment(runtime, control.binding.namespace,
        control.binding.generation, control.binding.digest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    // User fields live until this actual confirmation is resolved, not until
    // the installed Registry's last metadata/pin owner closes. Preserve the
    // original bank, per-message floor, slot limit and complete freeze invoice.
    let paid = try { source.acquireIndependentDataFrame(65536) }
        catch (_: LogicalJsonPayloadError) {
            return pluginViewObservationError("view.fields_limit", "user confirmation cannot acquire its source bank's DATA frame") }
        finally { source.close() }
    let pending = ProductPluginViewPending(paid)
    var retained = false
    try {
        pending.initialize(control, fields)
        retained = true
        Result.Ok(pending)
    } catch (_: Exception) {
        pluginViewObservationError("view.fields_limit", "actual user fields cannot be frozen within their installed-package DATA custody")
    } finally { if (!retained) { pending.close() } }
}

class ProductPluginViewTransition {
    private var value: ?AgentValue = None
    private var payment: ?LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }
    func initialize(metadata: AgentValue, action: String, hash: String, feedback: String): Unit {
        let paid = payment.getOrThrow(); paid.ensureRetainedPeak(1048576)
        let data = objectValue([ValueField("action", textValue(action)), ValueField("content_hash", textValue(hash)),
            ValueField("feedback", textValue(feedback)), ValueField("route", textValue("plugin." +
                httpIntentText(metadata, "namespace") + "." + httpIntentText(metadata, "name")))])
        let bytes = logicalJsonWriteReservationBytes(data, 65536)
        paid.ensureRetainedPeak(bytes * 16 + logicalJsonValueNodeCount(data) * 1024 + 2097152)
        value = Some(parseUnifiedJson(stringifyUnifiedJson(data), maxBytes: 65536, maxDepth: 8))
    }
    func data(): AgentValue { value.getOrThrow() }
    func close(): Unit {
        value = None
        match (payment) { case Some(paid) => paid.close(); payment = None; case None => () }
    }
}

func freezeProductPluginViewTransition(runtime: ProductRuntime, metadata: AgentValue, action: String,
    hash: String, feedback: String): Result<ProductPluginViewTransition> {
    let binding = match (runtime.vnext.javascriptPlugins.viewBinding(
        httpIntentText(metadata, "namespace"), httpIntentText(metadata, "name"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (binding.digest != httpIntentText(metadata, "package_digest") ||
        binding.generation.toString() != httpIntentText(metadata, "generation")) {
        return pluginViewObservationError("view.changed", "View changed before its user transition could be frozen") }
    let paid = match (productPluginViewPayment(runtime, binding.namespace, binding.generation, binding.digest)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let transition = ProductPluginViewTransition(paid)
    var retained = false
    try {
        transition.initialize(metadata, action, hash, feedback)
        retained = true
        Result.Ok(transition)
    } catch (_: Exception) {
        pluginViewObservationError("view.query_limit", "user transition cannot acquire its installed-package DATA custody")
    } finally { if (!retained) { transition.close() } }
}

// Host-owned wording, independent of plugin labels and presentation status.
// This is business consent only; ordinary Tool permissions still apply.
func productPluginViewControlDescription(action: String): String {
    match (action) {
        case "approve_fresh" => "Record any plan edits, approve the reviewed plan, and start execution in a fresh session. Tool operations still require their own permissions."
        case "approve_compact" => "Record any plan edits, approve the reviewed plan, compact context, and start execution. Tool operations still require their own permissions."
        case "approve_keep" => "Record any plan edits, approve the reviewed plan, and start execution with current context. Tool operations still require their own permissions."
        case "save" => "Save the edited plan as actual user input. Do not execute the plan."
        case "refine" => "Record any plan edits and submit the feedback as actual user input to request refinement without execution."
        case "continue" => "Record any plan edits and submit the feedback as actual user input to continue planning without execution."
        case "reject" => "Record any plan edits, reject the plan, preserve its history, and request revision without execution."
        case _ => throw IllegalArgumentException("view.control_unknown")
    }
}
