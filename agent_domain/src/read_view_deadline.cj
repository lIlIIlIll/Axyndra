package agent_domain

import std.collection.*
import std.convert.*
import std.math.*
import yjson.*
import yjson_support.*

public let READ_VIEW_FINITE_DEADLINE_VERSION = "read-view-finite-deadline/v1"
public let READ_VIEW_FINITE_DEADLINE_MAX_MILLIS: Int64 = 600000

// Descriptive operator profile only. This codec cannot admit a worker, grant a
// capability, extend a Run deadline, or substitute for the actual parent Source.
public func validReadViewDeadlineGrants(value: AgentValue): Bool {
    if (value.unifiedKind != ValueKind.List || value.items.size > 64) { return false }
    let seen = HashSet<String>()
    for (grant in value.items) {
        let name = httpIntentText(grant, "contribution")
        if (!httpIntentExactFields(grant, ["contribution", "maximum_ms"]) || !channelIntentIdentifier(name) || seen.contains(name) ||
            grant.field("maximum_ms").getOrThrow().unifiedKind != ValueKind.Number) { return false }
        let maximum = try { Int64.parse(grant.field("maximum_ms").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
        if (maximum < 1 || maximum > READ_VIEW_FINITE_DEADLINE_MAX_MILLIS || maximum.toString() != grant.field("maximum_ms").getOrThrow().asNumberText()) { return false }
        seen.add(name)
    }
    true
}
public func readViewDeadlineGrantMaximum(value: AgentValue, contribution: String): ?Int64 {
    if (!validReadViewDeadlineGrants(value)) { return None }
    for (grant in value.items where httpIntentText(grant, "contribution") == contribution) {
        return Some(Int64.parse(grant.field("maximum_ms").getOrThrow().asNumberText())) }
    None
}
public func readViewDeadlineProfileValid(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["version", "maximum_ms", "schema_digest"]) ||
        httpIntentText(value, "version") != READ_VIEW_FINITE_DEADLINE_VERSION || !httpIntentDigest(httpIntentText(value, "schema_digest")) ||
        value.field("maximum_ms").getOrThrow().unifiedKind != ValueKind.Number) { return false }
    let maximum = try { Int64.parse(value.field("maximum_ms").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    maximum > 0 && maximum <= READ_VIEW_FINITE_DEADLINE_MAX_MILLIS && maximum.toString() == value.field("maximum_ms").getOrThrow().asNumberText()
}
public func validateReadViewIntent(intent: AgentValue): Result<Unit> {
    if (intent.field("deadline_profile").isNone()) { return validateDefaultReadViewIntent(intent) }
    if (!httpIntentExactFields(intent, ["id", "request", "resources", "requires_approval", "deadline_profile"]) ||
        !readViewDeadlineProfileValid(intent.field("deadline_profile").getOrThrow())) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "read_view.deadline_profile_invalid", "finite deadline has invalid fixed fields")) }
    let request = intent.field("request").getOrThrow()
    let timeout = request.field("timeout_ms") ?? nullValue()
    let millis = try { Int64.parse(timeout.asNumberText()) } catch (_: Exception) { -1 }
    let maximum = Int64.parse(intent.field("deadline_profile").getOrThrow().field("maximum_ms").getOrThrow().asNumberText())
    if (timeout.unifiedKind != ValueKind.Number || millis < 1 || millis > maximum || millis.toString() != timeout.asNumberText()) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "read_view.deadline_profile_invalid", "worker exceeds its exact finite deadline")) }
    // Run every original input/resource/shape/argv/byte validation. Only the
    // explicit separately frozen deadline permits a larger finite timeout.
    let requestFields = ArrayList<ValueField>()
    for (field in request.fields) { requestFields.add(ValueField(field.name, if (field.name == "timeout_ms") { integerValue(min(millis, 60000)) } else { field.value })) }
    let plain = ArrayList<ValueField>()
    for (field in intent.fields where field.name != "deadline_profile") {
        plain.add(ValueField(field.name, if (field.name == "request") { objectValue(requestFields.toArray()) } else { field.value })) }
    match (validateDefaultReadViewIntent(objectValue(plain.toArray()))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (stringifyUnifiedJson(intent).size > 1048576) {
        return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "read_view.intent_invalid", "view exceeds total metadata bound")) }
    Result.Ok(())
}

// The call window retains only the same canonical text it previously generated
// at construction. Neither the profile DOM nor its source strings escape.
public func frozenReadViewDeadlineText(input: ToolResolverInput): ?String {
    input.domainProjection({ call =>
        let host = call.arguments.field("host_plan").getOrThrow()
        let intent = host.field("intents").getOrThrow().items[0]
        match (intent.field("deadline_profile")) {
            case Some(profile) => Some(canonicalAgentValue(profile))
            case None => None<String>
        }
    })
}

// Re-read the actual frozen profile after Host has checked its live grant.
// Only its finite maximum leaves the reader on an exact configuration/profile match.
public func matchingReadViewDeadlineMillis(input: ToolResolverInput, digest: String, expected: String): ?Int64 {
    input.domainProjection({ call =>
        let host = call.arguments.field("host_plan").getOrThrow()
        let profile = host.field("intents").getOrThrow().items[0].field("deadline_profile") ?? nullValue()
        if (httpIntentText(host, "configuration_digest") != digest || canonicalAgentValue(profile) != expected) {
            None<Int64>
        } else { Some(Int64.parse(profile.field("maximum_ms").getOrThrow().asNumberText())) }
    })
}
