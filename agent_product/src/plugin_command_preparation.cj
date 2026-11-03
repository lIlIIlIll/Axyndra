package agent_product

import agent_host_runtime.*

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*

// This object exists only on the actual Application command's Direct root.
// The worker supplies data, never this callback/participant. A preparation
// read has a separate context with no participant and cannot consume it.
class ProductCommandPreparationParticipant <: HostDocumentPreparationParticipant {
    private let scope: ProductPluginCommandScope
    private let original: ProductCommandProposal
    private let factory: (ProductCommandProposal) -> Result<ProductCommandCommitParticipant>
    private let lock = Mutex()
    private var run: ?RunId = None
    private var epoch: Int64 = 0
    private var resolving = false
    private var resolved = false
    private var frozenParent = ""
    private var frozenControl = ""
    private var selected: ?ProductCommandProposal = None
    private var participant: ?ProductCommandCommitParticipant = None

    init(scope: ProductPluginCommandScope, original: ProductCommandProposal,
        factory: (ProductCommandProposal) -> Result<ProductCommandCommitParticipant>) {
        this.scope = scope; this.original = original; this.factory = factory
    }
    func bindActualRun(actual: RunId, actualEpoch: Int64): Result<Unit> {
        match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (run.isSome() || actualEpoch < 1) { return commandControlError("plugin.command_participant_rebound") }
            run = Some(actual); epoch = actualEpoch; Result.Ok(())
        } finally { lock.unlock() }
    }
    func isResolved(): Bool { lock.lock(); try { resolved && !resolving } finally { lock.unlock() } }
    func resolvedProposal(): ProductCommandProposal {
        lock.lock(); try { selected ?? original } finally { lock.unlock() }
    }
    func controlParticipant(): Result<?ProductCommandCommitParticipant> {
        lock.lock(); try {
            if (!resolved || resolving) { return commandControlError("plugin.command_preparation_unresolved") }
            Result.Ok(participant)
        } finally { lock.unlock() }
    }
    public func freeze(context: ToolInvocationContext, call: ToolCall, arguments: AgentValue,
        proposed: ?AgentValue): Result<Unit> {
        match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let expected = original.call()
        if (context.sessionId.value != scope.sessionId.value || call.callId != expected.callId || call.name != expected.name ||
            canonicalAgentValue(contextReadBusinessInput(call.arguments)) != canonicalAgentValue(expected.arguments)) {
            return commandControlError("plugin.command_preparation_scope") }
        // An already explicit control is immutable. An absent final field is
        // meaningful for deferred commands: no control was selected.
        let early = original.control()
        if (early.isSome() && proposed.isSome() && canonicalAgentValue(early.getOrThrow()) != canonicalAgentValue(proposed.getOrThrow())) {
            return commandControlError("plugin.command_control_changed") }
        let control = if (early.isSome()) { early } else { proposed }
        match (control) { case Some(value) =>
            if (!original.binding.allowsControl("continuation")) { return commandControlError("plugin.command_control_not_declared") }
            match (validateCommandContinuationControl(value)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let intents = arguments.field("host_plan").getOrThrow().field("intents").getOrThrow()
            // A user control accompanies one exact document mutation; it is
            // never a side effect of an unrelated/multiple child transaction.
            if (intents.items.size != 1 || httpIntentText(intents.items[0], "mode") != "compare_exchange" ||
                httpIntentText(intents.items[0], "key") != httpIntentText(value, "document_key")) {
                return commandControlError("plugin.command_control_document_mismatch") }
            case None => () }
        let frozen = canonicalAgentValue(arguments)
        let controlText = canonicalAgentValue(control ?? nullValue())
        lock.lock()
        let actual = try {
            if (run.isNone() || run.getOrThrow().value != context.runId.value || epoch != context.epoch || resolving) {
                return commandControlError("plugin.command_preparation_scope") }
            if (resolved) {
                if (frozenParent != frozen || frozenControl != controlText) { return commandControlError("plugin.command_preparation_changed") }
                return Result.Ok(())
            }
            resolving = true; (run.getOrThrow(), epoch)
        } finally { lock.unlock() }
        try {
            let next = original.withResolvedControl(control, frozen)
            let delegate = match (control) {
                case Some(_) => match (factory(next)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => Some(value) }
                case None => Option<ProductCommandCommitParticipant>.None }
            match (delegate) { case Some(value) =>
                match (value.bindActualRun(actual[0], actual[1], parentArguments: Some(frozen))) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                case None => () }
            match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            lock.lock()
            try {
                frozenParent = frozen; frozenControl = controlText; selected = Some(next)
                participant = delegate; resolved = true
            } finally { lock.unlock() }
            Result.Ok(())
        } finally { lock.lock(); try { resolving = false } finally { lock.unlock() } }
    }
    public func forCommit(context: ToolInvocationContext, root: PreparedToolInvocation): Result<?PluginDocumentCommitParticipant> {
        match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (!resolved || resolving || run.isNone() || run.getOrThrow().value != context.runId.value || epoch != context.epoch ||
                context.sessionId.value != scope.sessionId.value || root.call.callId != original.callId || root.call.name != original.call().name ||
                canonicalAgentValue(root.operationPlan.canonicalArguments) != frozenParent) {
                return commandControlError("plugin.command_preparation_changed") }
            match (participant) { case Some(value) => Result.Ok(Some(value)); case None => Result.Ok(Option<PluginDocumentCommitParticipant>.None) }
        } finally { lock.unlock() }
    }
    public func consume(proof: PluginDocumentCommitProof): Result<Unit> {
        // The document broker must first select the leaf against its actual
        // frozen parent. Passing this unresolved wrapper directly is denied.
        let _ = proof; commandControlError("plugin.command_preparation_unresolved")
    }
}

func freezeCommandDocumentPreparation(context: ToolInvocationContext, call: ToolCall,
    arguments: AgentValue, control: ?AgentValue): Result<Unit> {
    freezeHostDocumentPreparation(context, call, arguments, control)
}

func commandDocumentCommitParticipant(context: ToolInvocationContext,
    root: PreparedToolInvocation): Result<?PluginDocumentCommitParticipant> {
    selectHostDocumentCommitParticipant(context, root)
}
