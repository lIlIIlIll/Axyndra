package axyndra_agent_testkit

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.collection.*

// A pure fixture observation. This is not a Kernel Prepared invocation and
// never carries Source, approval, Receipt, Host executor or I/O authority.
public class PreparedNativePluginCase {
    public let definition: NativePluginDefinition
    public let invocation: NativePluginInvocation
    init(definition: NativePluginDefinition, invocation: NativePluginInvocation) {
        this.definition = definition; this.invocation = invocation
    }
}

public class NativePluginContractHarness {
    private let handler: NativePluginHandler
    public init(handler: NativePluginHandler) { this.handler = handler }

    public func definition(): NativePluginDefinition { handler.definition() }
    public func contributionNames(): Array<String> {
        let names = ArrayList<String>()
        for (value in handler.definition().contributions) { names.add(value.name) }
        names.toArray()
    }
    public func prepare(contribution: String, input: JsonNode,
        callId!: String = "test-call",
        contributionKind!: PluginContributionKind = PluginContributionKind.Provider,
        cancellation!: InvocationCancellation = NeverCancelled(),
        deadline!: InvocationDeadline = InvocationDeadline()): SdkResult<PreparedNativePluginCase> {
        let definition = handler.definition()
        var present = false
        for (value in definition.contributions where value.name == contribution && value.kind == contributionKind) { present = true }
        if (!present) {
            return SdkResult.Err(SdkError(SdkErrorKind.Validation,
                "testkit.contribution_missing", "native fixture has no requested contribution"))
        }
        match (handler.validate(contributionKind, contribution, input)) {
            case SdkResult.Err(error) => SdkResult.Err(error)
            case SdkResult.Ok(value) => SdkResult.Ok(PreparedNativePluginCase(definition,
                NativePluginInvocation(callId, contribution, value,
                    contributionKind: contributionKind, cancellation: cancellation, deadline: deadline)))
        }
    }
    public func invoke(prepared: PreparedNativePluginCase,
        nowMillis!: Int64 = 0): SdkResult<JsonNode> {
        if (prepared.invocation.cancellation.isCancelled()) {
            return SdkResult.Err(SdkError(SdkErrorKind.Cancelled,
                "testkit.cancelled", prepared.invocation.cancellation.reason()))
        }
        if (prepared.invocation.deadline.exceeded(nowMillis)) {
            return SdkResult.Err(SdkError(SdkErrorKind.Deadline,
                "testkit.deadline", "native fixture deadline expired"))
        }
        handler.invoke(prepared.invocation)
    }
}

public func requireSdkOk<T>(result: SdkResult<T>, label!: String = "SDK result"): T {
    match (result) {
        case SdkResult.Ok(value) => value
        case SdkResult.Err(error) => throw IllegalStateException(
            label + " failed: code=" + error.code + " message=" + error.message)
    }
}
public func assertCapabilityRequested(definition: NativePluginDefinition, capability: String): Unit {
    for (value in definition.capabilities where value == capability) { return }
    throw IllegalStateException("expected capability=" + capability + " plugin=" + definition.id)
}
public func assertCapabilityNotRequested(definition: NativePluginDefinition, capability: String): Unit {
    for (value in definition.capabilities where value == capability) {
        throw IllegalStateException("unexpected capability=" + capability + " plugin=" + definition.id)
    }
}
