package agent_product

import agent_plugin_registry.*

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import agent_sdk.*
import std.convert.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

let PRODUCT_COMMAND_PROPOSAL_SCHEMA = "axyndra.command-proposal/v1"

// Application creates this object for one actual user invocation. Neither a
// Tool/Provider result, persisted JSON nor an RPC argument can reconstruct it.
// The trusted Application interaction port remains outside plugin data.
class ProductPluginCommandScope {
    let sessionId: SessionId
    let commandId: String
    let route: String
    let argumentsDigest: String
    let cancellation: CancellationToken
    private let applicationCurrent: () -> Result<Unit>
    private let continuationCurrent: () -> Result<Unit>
    private let prepareControl: (ProductCommandProposal) -> Result<String>
    private let lock = Mutex()
    private var binding: ?ProductCommandBinding = None
    private var captured: ?ProductCommandProposal = None
    private var consumed = false
    private var closed = false
    private var participant: ?ProductCommandPreparationParticipant = None

    init(sessionId: SessionId, commandId: String, route: String, arguments: String,
        cancellation: CancellationToken, current: () -> Result<Unit>,
        continuationCurrent: () -> Result<Unit>, prepareControl: (ProductCommandProposal) -> Result<String>) {
        this.sessionId = sessionId; this.commandId = commandId; this.route = route
        this.argumentsDigest = modelPolicySha256Text(arguments)
        this.cancellation = cancellation; this.applicationCurrent = current
        this.continuationCurrent = continuationCurrent; this.prepareControl = prepareControl
    }
    func bind(host: ProductJavaScriptPluginHost, selected: ProductJavaScriptPluginCommand,
        arguments: String, actualSession: SessionId, actualCommand: String): Result<Unit> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (applicationCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (actualSession.value != sessionId.value || actualCommand != commandId || selected.routeName != route ||
            modelPolicySha256Text(arguments) != argumentsDigest) { return commandControlError("plugin.command_scope_mismatch") }
        let descriptor = match (host.servicePackage(selected.extensionId, selected.instanceGeneration)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let next = try { ProductCommandBinding(host, selected, descriptor) }
            finally { descriptor.close() }
        match (next.verify()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (closed || binding.isSome()) { return commandControlError("plugin.command_scope_consumed") }
            binding = Some(next); Result.Ok(())
        } finally { lock.unlock() }
    }
    func current(): Result<Unit> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (applicationCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        let actual = try {
            if (closed || binding.isNone()) { return commandControlError("plugin.command_scope_closed") }
            binding.getOrThrow()
        } finally { lock.unlock() }
        actual.verify()
    }
    func capture(value: AgentValue): Result<Unit> {
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let encoded = try { encodeAgentValue(value) } catch (_: Exception) { return commandControlError("plugin.command_proposal_invalid") }
        if (encoded.size > 65536) { return commandControlError("plugin.command_proposal_too_large") }
        let frozen = match (decodeAgentValue(encoded, maxBytes: 65536)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        lock.lock()
        let actual = try {
            if (closed || captured.isSome() || consumed || binding.isNone()) { return commandControlError("plugin.command_scope_consumed") }
            binding.getOrThrow()
        } finally { lock.unlock() }
        let proposal = match (parseProductCommandProposal(frozen, actual, sessionId, commandId, argumentsDigest)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
        lock.lock()
        try {
            if (closed || captured.isSome() || consumed) { return commandControlError("plugin.command_scope_consumed") }
            captured = Some(proposal); Result.Ok(())
        } finally { lock.unlock() }
    }
    func take(): Result<?ProductCommandProposal> {
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (closed || consumed) { return commandControlError("plugin.command_scope_consumed") }
            consumed = true; Result.Ok(captured)
        } finally { lock.unlock() }
    }
    func close(): Unit { lock.lock(); try { closed = true; captured = None; participant = None } finally { lock.unlock() } }
    func prepareUserControl(proposal: ProductCommandProposal): Result<String> { prepareControl(proposal) }
    func continuationApplicationCurrent(): Result<Unit> { continuationCurrent() }
    func retainParticipant(value: ProductCommandPreparationParticipant): Result<Unit> {
        lock.lock(); try {
            if (closed || participant.isSome() || !consumed) { return commandControlError("plugin.command_scope_consumed") }
            participant = Some(value); Result.Ok(())
        } finally { lock.unlock() }
    }
    func preparationResolved(): Bool {
        match (committedParticipant()) { case Some(value) => value.isResolved(); case None => false }
    }
    func resolvedProposal(original: ProductCommandProposal): ProductCommandProposal {
        let actual = committedParticipant()
        match (actual) { case Some(value) => value.resolvedProposal(); case None => original }
    }
    func committedParticipant(): ?ProductCommandPreparationParticipant {
        lock.lock(); try { participant } finally { lock.unlock() }
    }
}

class ProductCommandBinding {
    let host: ProductJavaScriptPluginHost
    let namespace: String
    let contribution: String
    let generation: UInt64
    let digest: String
    private let root: String
    private let entrypoint: String
    private let native: Bool
    private let controls: Array<String>
    private let tools: Array<String>
    init(host: ProductJavaScriptPluginHost, selected: ProductJavaScriptPluginCommand, descriptor: OwnedPluginPackageDescriptor) {
        this.host = host; this.namespace = selected.extensionId; this.contribution = selected.name
        this.generation = selected.instanceGeneration; this.digest = productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest))
        this.root = productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Root)); this.entrypoint = productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Entrypoint))
        this.native = descriptor.entryKind == PluginEntryKind.NativeExecutable
        var found: Array<String> = []
        for (item in productRegistryContributions83(descriptor) where item.kind == PluginContributionKind.Command && productRegistryCopyText83(item.copyText(PluginContributionText.Name)) == selected.name) {
            found = productRegistryAllowedControls83(descriptor, item)
        }
        this.controls = found
        let names = ArrayList<String>()
        for (item in productRegistryContributions83(descriptor) where item.kind == PluginContributionKind.Tool) { names.add(productRegistryCopyText83(item.copyText(PluginContributionText.Name))) }
        this.tools = names.toArray()
    }
    func allowsControl(): Bool { controls.contains("continuation") }
    func allowsTool(name: String): Bool { tools.contains(name) }
    func verify(): Result<Unit> {
        let actual = match (host.servicePackage(namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (!actual.textEquals(PluginDescriptorText.Root, root) ||
                !actual.textEquals(PluginDescriptorText.Entrypoint, entrypoint) ||
                !actual.textEquals(PluginDescriptorText.ContentDigest, digest)) {
                return commandControlError("plugin.command_package_changed") }
            if (native && !actual.hasContribution(PluginContributionKind.Command, contribution)) {
                return commandControlError("plugin.command_contribution_changed") }
            // Called at command/approval/effect boundaries, never on a streaming poll.
            match (host.registryPackageMatches81(root, digest: Some(digest), entrypoint: Some(entrypoint))) {
                case Result.Err(_) => return commandControlError("plugin.command_package_changed")
                case Result.Ok(matches) => if (!matches) { return commandControlError("plugin.command_package_changed") }
            }
            match (host.servicePackage(namespace, generation)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) => try {
                    if (value.textEquals(PluginDescriptorText.ContentDigest, digest)) { Result.Ok(()) }
                    else { commandControlError("plugin.command_package_changed") }
                } finally { value.close() }
            }
        } finally { actual.close() }
    }
}

class ProductCommandProposal {
    let binding: ProductCommandBinding
    let callId: String
    let localTool: String
    let sourceDigest: String
    private let inputJson: String
    private let controlJson: ?String
    init(binding: ProductCommandBinding, callId: String, localTool: String, input: String, control: ?String, source: String) {
        this.binding = binding; this.callId = callId; this.localTool = localTool
        this.inputJson = input; this.controlJson = control; this.sourceDigest = source
    }
    func call(): ToolCall { ToolCall(callId, "plugin." + binding.namespace + "." + localTool,
        decodeAgentValue(inputJson, maxBytes: 65536).value().getOrThrow()) }
    func withResolvedControl(control: ?AgentValue, parentArguments: String): ProductCommandProposal {
        let selected: ?String = match (control) { case Some(value) => Some(encodeAgentValue(value)); case None => None }
        let digest = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("command_proposal_digest", textValue(sourceDigest)),
            ValueField("parent_arguments_sha256", textValue(modelPolicySha256Text(parentArguments))),
            ValueField("user_control", control ?? nullValue())])))
        ProductCommandProposal(binding, callId, localTool, inputJson, selected, digest)
    }
    func control(): ?AgentValue { match (controlJson) { case Some(value) => Some(decodeAgentValue(value, maxBytes: 16384).value().getOrThrow()); case None => None } }
}

func parseProductCommandProposal(value: AgentValue, binding: ProductCommandBinding,
    sessionId: SessionId, commandId: String, argumentsDigest: String): Result<ProductCommandProposal> {
    if (!applicationPlanObjectShape(value, ["schema", "local_tool", "input", "user_control"], ["schema", "local_tool", "input"]) ||
        httpIntentText(value, "schema") != PRODUCT_COMMAND_PROPOSAL_SCHEMA ||
        !binding.allowsTool(httpIntentText(value, "local_tool")) || value.field("input").getOrThrow().unifiedKind != ValueKind.Object) {
        return commandControlError("plugin.command_proposal_invalid") }
    let control = value.field("user_control")
    if (control.isSome()) {
        if (!binding.allowsControl()) { return commandControlError("plugin.command_control_not_declared") }
        match (validateCommandContinuationControl(control.getOrThrow())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    }
    let source = modelPolicySha256Text(canonicalAgentValue(objectValue([
        ValueField("thread_id", textValue(sessionId.value)),
        ValueField("namespace", textValue(binding.namespace)), ValueField("contribution", textValue(binding.contribution)),
        ValueField("generation", textValue(binding.generation.toString())), ValueField("package_digest", textValue(binding.digest)),
        ValueField("command_id", textValue(commandId)), ValueField("arguments_digest", textValue(argumentsDigest)),
        ValueField("proposal", value)])))
    Result.Ok(ProductCommandProposal(binding, "command-tool-" + commandId, httpIntentText(value, "local_tool"),
        encodeAgentValue(value.field("input").getOrThrow()), match (control) { case Some(item) => Some(encodeAgentValue(item)); case None => Option<String>.None }, source))
}

func validateCommandContinuationControl(value: AgentValue): Result<Unit> {
    if (!applicationPlanObjectShape(value, ["kind", "document_key", "action", "token_budget", "next_prompt", "restriction"], ["kind", "document_key", "action"]) ||
        httpIntentText(value, "kind") != "continuation" || !httpIntentIdentifier(httpIntentText(value, "document_key"))) {
        return commandControlError("plugin.command_control_invalid") }
    let action = httpIntentText(value, "action")
    if (!["create", "replace", "pause", "resume", "close", "set_budget", "resume_or_create"].contains(action)) {
        return commandControlError("plugin.command_control_invalid") }
    match (value.field("restriction")) {
        case Some(restriction) =>
            if (action == "pause" || action == "close" || !httpIntentExactFields(restriction, ["provider", "selector"]) ||
                !httpIntentIdentifier(httpIntentText(restriction, "provider")) ||
                restriction.field("selector").getOrThrow().unifiedKind != ValueKind.Object) {
                return commandControlError("plugin.command_restriction_invalid") }
            try {
                let frozen = canonicalAgentValue(restriction.field("selector").getOrThrow())
                let copied = decodeAgentValue(encodeAgentValue(restriction.field("selector").getOrThrow()), maxBytes: 4096).value().getOrThrow()
                if (canonicalAgentValue(copied) != frozen) { return commandControlError("plugin.command_restriction_invalid") }
                if (frozen.size > 4096) { return commandControlError("plugin.command_restriction_invalid") }
            } catch (_: Exception) { return commandControlError("plugin.command_restriction_invalid") }
        case None => ()
    }
    let needsPrompt = action == "create" || action == "replace" || action == "resume" || action == "resume_or_create"
    let hasBudget = action == "create" || action == "replace" || action == "set_budget" || action == "resume_or_create"
    if (needsPrompt != value.field("next_prompt").isSome() || hasBudget != value.field("token_budget").isSome()) {
        return commandControlError("plugin.command_control_invalid") }
    if (needsPrompt) {
        let prompt = value.field("next_prompt").getOrThrow()
        if (prompt.unifiedKind != ValueKind.Text || prompt.text.trimAscii() == "" || prompt.text.size > 8192) {
            return commandControlError("plugin.command_control_invalid") }
    }
    if (hasBudget) {
        let budget = value.field("token_budget").getOrThrow()
        if (budget.unifiedKind != ValueKind.Null) {
            try {
                let number = Int64.parse(budget.asNumberText())
                if (budget.unifiedKind != ValueKind.Number || number < 1 || number.toString() != budget.asNumberText()) {
                    return commandControlError("plugin.command_control_invalid") }
            } catch (_: Exception) { return commandControlError("plugin.command_control_invalid") }
        }
    }
    Result.Ok(())
}
func commandControlError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code,
        "plugin command requires its actual user scope, exact frozen proposal and current installed contribution"))
}
