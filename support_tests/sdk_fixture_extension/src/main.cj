package sdk_fixture_extension

import agent_sdk.*
import yjson.*
import yjson_support.*

// An actual Native provider handler; the separate executable invokes it from
// the existing complete native wire loop. It does not request Host services.
public class ThirdPartyFixturePlugin <: NativePluginHandler {
    public init() {}
    public func definition(): NativePluginDefinition {
        NativePluginDefinition("third-party.fixture", "1.0.0",
            [PluginContributionDefinition("fixture_echo", PluginContributionKind.Provider)])
    }
    public func validate(kind: PluginContributionKind, contribution: String, input: JsonNode): SdkResult<JsonNode> {
        if (kind != PluginContributionKind.Provider || contribution != "fixture_echo") {
            return SdkResult.Err(SdkError(SdkErrorKind.Unsupported,
                "fixture.contribution_unknown", "unknown fixture contribution"))
        }
        match (input.field("text")) {
            case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Text) {
                SdkResult.Ok(input)
            } else { invalid() }
            case None => invalid()
        }
    }
    public func invoke(invocation: NativePluginInvocation): SdkResult<JsonNode> {
        if (invocation.cancellation.isCancelled()) {
            return SdkResult.Err(SdkError(SdkErrorKind.Cancelled,
                "fixture.cancelled", invocation.cancellation.reason()))
        }
        validate(invocation.contributionKind, invocation.contribution, invocation.input)
    }
    private func invalid(): SdkResult<JsonNode> {
        SdkResult.Err(SdkError(SdkErrorKind.Validation,
            "fixture.text_required", "text is required"))
    }
}

public func runFixtureContract(): Int64 {
    let handler = ThirdPartyFixturePlugin()
    let definition = handler.definition()
    expect(definition.id == "third-party.fixture" && definition.version == "1.0.0",
        "independent Native consumer exposes package data")
    expect(definition.contributions.size == 1 && definition.contributions[0].name == "fixture_echo",
        "native contribution is enumerable")
    expect(definition.capabilities.isEmpty(), "pure Native provider requests no Host capability")
    var duplicateRejected = false
    try { let _ = NativePluginDefinition("third-party.fixture", "1.0.0",
        [definition.contributions[0], definition.contributions[0]]) }
    catch (_: IllegalArgumentException) { duplicateRejected = true }
    expect(duplicateRejected, "duplicate native contribution is rejected")
    expect(match (handler.validate(PluginContributionKind.Provider, "fixture_echo", jsonObject([]))) {
        case SdkResult.Err(error) => error.kind == SdkErrorKind.Validation
        case SdkResult.Ok(_) => false }, "native input validation is typed")
    let input = jsonObject([JsonObjectEntry("text", jsonString("\u{0000}中文 fixture"))])
    let result = match (handler.invoke(NativePluginInvocation("fixture-call", "fixture_echo", input))) {
        case SdkResult.Ok(value) => value
        case SdkResult.Err(error) => throw IllegalStateException(error.code) }
    expect(result.field("text").getOrThrow().text == "\u{0000}中文 fixture", "native result keeps full business data")
    expect(match (handler.invoke(NativePluginInvocation("fixture-cancelled", "fixture_echo", input,
        cancellation: CancelledFixture()))) {
        case SdkResult.Err(error) => error.kind == SdkErrorKind.Cancelled
        case SdkResult.Ok(_) => false }, "native handler observes cancellation without parent Run authority")
    let deadline = InvocationDeadline(expiresAtMillis: 100)
    expect(deadline.isSet() && deadline.exceeded(100), "deadline surface is deterministic")
    println("independent native agent_sdk consumer contract passed")
    0
}
class CancelledFixture <: InvocationCancellation {
    public func isCancelled(): Bool { true }
    public func reason(): String { "fixture cancellation" }
}
func expect(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
