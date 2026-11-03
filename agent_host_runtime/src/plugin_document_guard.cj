package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Not public, serializable, returned to IPC, or a separate authority registry.
// Every guard belongs to one actual prepared invocation held by its executor.
public class HostPluginDocumentGuard {
    private let host: HostJavaScriptPluginHost
    private let context: ToolInvocationContext
    private let root: PreparedToolInvocation
    private let configuration: HostPluginDocumentConfiguration
    private let generation: UInt64
    private let bindingJson: String
    private let bindingDigest: String
    private let cancelled = AtomicBool(false)
    private var registration: ?CancellationRegistration = None

    init(host: HostJavaScriptPluginHost, context: ToolInvocationContext, root: PreparedToolInvocation,
        configuration: HostPluginDocumentConfiguration, generation: UInt64, binding: AgentValue) {
        this.host = host; this.context = context; this.root = root; this.configuration = configuration
        this.generation = generation; this.bindingJson = stringifyUnifiedJson(binding)
        this.bindingDigest = canonicalAgentValue(binding)
    }
    public func arm(): Result<Unit> {
        // onCancel can run inline: the callback takes no Runtime/host/DB lock.
        registration = Some(context.cancellation.onCancel({ _ => cancelled.store(true) }))
        validate()
    }
    public func close(): Unit { cancelled.store(true); match (registration) { case Some(value) => value.dispose(); case None => () }; registration = None }

    // No host/Runtime locks here: safe inside the one canonical transaction.
    private func currentData(): Result<Unit> {
        if (cancelled.load() || context.cancellation.isCancelled()) {
            return Result.Err(AgentError(AgentErrorKind.Cancelled, "plugin.document_cancelled", "document invocation was cancelled")) }
        let binding = parseUnifiedJson(bindingJson, maxBytes: 16384)
        if (context.sessionId.value != httpIntentText(binding, "thread_id") || context.runId.value != httpIntentText(binding, "run_id") ||
            context.epoch.toString() != binding.field("epoch").getOrThrow().asNumberText() ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke, resource: configuration.namespace) ||
            !isFrozenPluginDocumentParentPlan(root.operationPlan) ||
            canonicalAgentValue(root.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()) != bindingDigest ||
            root.call.callId != httpIntentText(binding, "parent_call_id") || root.call.name != httpIntentText(binding, "contribution")) {
            return hostPluginResourceError("plugin.document_scope_changed", "document invocation lost its exact Run or frozen parent") }
        let frozen=root.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
        if(httpIntentText(frozen,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
            match(pluginDocumentRowJournalFrozenResultCurrent(frozen,agentUtcMillis())){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        configuration.validateCurrent()
    }
    public func validate(): Result<Unit> {
        match (currentData()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (root.source.kind == PreparedInvocationSourceKind.Derived || root.source.operationRoot.isNone()) {
            return hostPluginResourceError("plugin.document_source_invalid", "document requires its actual sealed canonical root") }
        match (root.source.operationRoot.getOrThrow()) {
            case OperationRootSource.Direct(source) => match (source.validateLiveSource()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case OperationRootSource.Committed(_) => ()
        }
        let current = match (host.servicePackageData81(configuration.namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (current.contentDigest != configuration.packageDigest || !current.requestedCapabilities.contains("document.store")) {
            return hostPluginResourceError("plugin.document_owner_stale", "document package was replaced or did not request this service") }
        Result.Ok(())
    }
    public func accepts(child: NormalizedOperationPlan): Result<Unit> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!pluginDocumentParentAllows(root.operationPlan, child)) {
            return hostPluginResourceError("plugin.document_intent_changed", "child differs from the exact frozen document intent") }
        if(isPluginDocumentRowJournalChildPlan(child)){
            let intent=parsePluginDocumentRowJournalIntent(child.canonicalArguments).value().getOrThrow()
            let prefix="plugin."+configuration.namespace+".";let name=root.call.name
            if(!name.startsWith(prefix) || !configuration.readWindows(name[prefix.size..]) ||
                !configuration.permits(name[prefix.size..],intent.key,intent.append)){
                return hostPluginResourceError("plugin.document_rights_denied","operator did not grant this exact window action")}
            return Result.Ok(())}
        let intent = parsePluginDocumentIntent(child.canonicalArguments).value().getOrThrow()
        let prefix = "plugin." + configuration.namespace + "."
        let name = root.call.name
        if (!name.startsWith(prefix) || !configuration.permits(name[prefix.size..], intent.key, intent.compareExchange)) {
            return hostPluginResourceError("plugin.document_rights_denied", "operator did not grant this exact contribution and document action") }
        Result.Ok(())
    }
    private func commitWindow(operations:OperationRuntimePort,child:PreparedToolInvocation,receipt:VNextOperationReceipt,
        participant:?PluginDocumentCommitParticipant):Result<Unit>{
        let intent=parsePluginDocumentRowJournalIntent(child.operationPlan.canonicalArguments).value().getOrThrow()
        if(!intent.append && participant.isSome()){
            return hostPluginResourceError("plugin.document_window_read_participant_denied","read-only window cannot execute a mutation participant")}
        let reader:?HostDocumentPayloadCommitReader=if(intent.append){Some(match(host.documentPayloadCommitReader(
            context.runId,root.operationId,child.operationId,{=>currentData()})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})}else{None}
        try{return host.commitDocumentEffect(configuration.namespace,generation,configuration.packageDigest,{=>
            match(reader){case Some(actual)=>return actual.runCommit({committer=>
                operations.settlePluginRowJournalOperation(context.runId,root.operationId,receipt,{=>currentData()},participant,committer)})
                case None=>()}
            operations.settlePluginRowJournalOperation(context.runId,root.operationId,receipt,{=>currentData()})})
        }finally{match(reader){case Some(actual)=>let _=actual.close();case None=>()}}
    }
    public func commit(operations: OperationRuntimePort, child: PreparedToolInvocation, receipt: VNextOperationReceipt,
        participant!: ?PluginDocumentCommitParticipant = None): Result<Unit> {
        match (accepts(child.operationPlan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (child.source.kind != PreparedInvocationSourceKind.Derived || child.source.parentOperationId.isNone() ||
            child.source.parentOperationId.getOrThrow().value != root.operationId.value ||
            child.operationId.value != receipt.operationId.value || receipt.outcome != OperationOutcome.Completed) {
            return hostPluginResourceError("plugin.document_commit_invalid", "document commit belongs to another canonical child") }
        if(isPluginDocumentRowJournalChildPlan(child.operationPlan)){
            return commitWindow(operations,child,receipt,participant)}
        let intent=parsePluginDocumentIntent(child.operationPlan.canonicalArguments).value().getOrThrow()
        let payloadReader: ?HostDocumentPayloadCommitReader = if(intent.referencesPayload && intent.compareExchange) {
            Some(match(host.documentPayloadCommitReader(context.runId,root.operationId,child.operationId,{ => currentData() })) {
                case Result.Err(error) => return Result.Err(error);case Result.Ok(value) => value })
        } else { None }
        try { return host.commitDocumentEffect(configuration.namespace, generation, configuration.packageDigest, { =>
            match(payloadReader) { case Some(reader) => return reader.runCommit({ committer =>
                operations.settlePluginDocumentOperation(context.runId,root.operationId,receipt,{ => currentData() },participant,committer) })
                case None => () }
            match (participant) {
                case Some(value) => operations.settlePluginDocumentOperation(context.runId, root.operationId, receipt, { => currentData() }, value)
                case None => operations.settlePluginDocumentOperation(context.runId, root.operationId, receipt, { => currentData() })
            }
        }) } finally {
            // Failure is already retained in the ContextRead cleanup owner.
            // runCommit reports a missing ACK; an early generation refusal
            // still closes the inert reader without opening any file.
            match(payloadReader) { case Some(reader) => let _=reader.close();case None => () }
        }
    }
}

public func hostOpenPluginDocumentGuard(identity: HostPluginServiceIdentity, context: ToolInvocationContext,
    prepared: PreparedToolInvocation): Result<HostPluginDocumentGuard> {
    if (!isFrozenPluginDocumentParentPlan(prepared.operationPlan)) {
        return hostPluginResourceError("plugin.document_parent_invalid", "document service requires its exact prepared parent") }
    let binding = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    if (httpIntentText(binding, "namespace") != identity.namespace || httpIntentText(binding, "generation") != identity.generation.toString()) {
        return hostPluginResourceError("plugin.document_owner_stale", "document plan belongs to another executor generation") }
    let configuration = match (identity.host.documentConfiguration(identity.namespace, httpIntentText(binding, "package_digest"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (configuration.digest != httpIntentText(binding, "configuration_digest")) {
        return hostPluginResourceError("plugin.document_grant_changed", "document plan does not match current operator rights") }
    let guard = HostPluginDocumentGuard(identity.host, context, prepared, configuration, identity.generation, binding)
    match (guard.arm()) { case Result.Err(error) => guard.close(); Result.Err(error); case Result.Ok(_) => Result.Ok(guard) }
}
