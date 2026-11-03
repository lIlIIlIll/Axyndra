package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func processObservationInput197(op: String): AgentValue {
    let fields = if (op == "ps") { [ValueField("op", textValue(op)), ValueField("actual_target", nullValue())] }
        else if (op == "logs") { [ValueField("op", textValue(op)), ValueField("name", textValue("sample")),
            ValueField("lines", integerValue(32)), ValueField("head", boolValue(false)), ValueField("follow", boolValue(false)),
            ValueField("cursor", integerValue(0)), ValueField("cursor_present", boolValue(false)),
            ValueField("timeout_ms", integerValue(0)), ValueField("grep", textValue("")), ValueField("actual_target", nullValue())] }
        else if (op == "wait") { [ValueField("op", textValue(op)), ValueField("name", textValue("sample")),
            ValueField("condition", textValue("exit")), ValueField("pattern", textValue("")),
            ValueField("timeout_ms", integerValue(0)), ValueField("actual_target", nullValue())] }
        else { [ValueField("op", textValue(op)), ValueField("name", textValue("sample")), ValueField("actual_target", nullValue())] }
    objectValue([ValueField("schema", textValue("axyndra.hub-process-request/v1")),
        ValueField("request", objectValue(fields)), ValueField("facts", objectValue([
            ValueField("shell_mode", textValue("restricted")), ValueField("broker_available", boolValue(true))]))])
}
private func processObservationIntent197(op: String, service!: String = "process.observe"): AgentValue {
    objectValue([ValueField("id", textValue("observe-197")), ValueField("service", textValue(service)),
        ValueField("input", processObservationInput197(op))])
}
private func processObservationChild197(op: String, service!: String = "process.observe", invocation!: String = "workspace.read"): AgentValue {
    objectValue([ValueField("schema", textValue(PLUGIN_CHILD_INTENT111)),
        ValueField("binding", documentTestBinding()), ValueField("intent", processObservationIntent197(op, service: service)),
        ValueField("invocation_capability", textValue(invocation))])
}
private func processObservationPlan197(args: AgentValue, kind!: CapabilityKind = CapabilityKind.WorkspaceRead,
    effect!: OperationEffectClass = OperationEffectClass.ReadOnly, parent!: Bool = false): NormalizedOperationPlan {
    let binding = if (parent) { args.field("host_plan").getOrThrow().field("binding").getOrThrow() }
        else { args.field("binding").getOrThrow() }
    NormalizedOperationPlan(if (parent) { httpIntentText(binding, "contribution") } else { HOST_PLUGIN_CHILD_TOOL111 },
        args, [Capability(kind)], effect, OperationRetryDisposition.Never, "observation-plan-197",
        replayDisposition: Some(ReplayDisposition.NeverReplay),
        toolVersion: if (parent) { "observation-parent-197" } else { HOST_PLUGIN_CHILD_FINGERPRINT111 },
        implementationFingerprint: if (parent) { httpIntentText(binding, "implementation_fingerprint") } else { HOST_PLUGIN_CHILD_FINGERPRINT111 },
        schemaDigest: httpIntentText(binding, "schema_digest"))
}

@Test
class TrustedProcessObservation197Tests {
    @TestCase
    func allFourNormalizedObserversUseTheTrustedReadCapabilityAndEffect(): Unit {
        for (op in ["ps", "logs", "describe", "wait"]) {
            let child = processObservationChild197(op)
            @Expect(pluginHubProcessObservationInputValid197(child.field("intent").getOrThrow().field("input").getOrThrow()))
            @Expect(pluginHubProcessObservationIntentValid197(child.field("intent").getOrThrow()))
            @Expect(parsePluginChildStartIntent111(child).isOk())
            @Expect(isPluginHubProcessObservationPlan197(processObservationPlan197(child)))
        }
        @Expect(pluginPrimitiveRequiredCapability111("process.observe"), CapabilityKind.WorkspaceRead)
        @Expect(pluginPrimitiveEffect111("process.observe"), OperationEffectClass.ReadOnly)
    }
    @TestCase
    func writeRequestsAndNativeAuthorityClaimsFailBeforeTargetPreparation(): Unit {
        for (op in ["start", "send", "stop", "restart", "PS", "unknown"]) {
            let intent = processObservationIntent197(op)
            @Expect(!pluginHubProcessObservationInputValid197(intent.field("input").getOrThrow()))
            @Expect(!pluginHubProcessObservationIntentValid197(intent))
            @Expect(parsePluginChildStartIntent111(processObservationChild197(op)).isError())
        }
        for (name in ["effect", "capability", "source", "approval"]) {
            let intent = processObservationIntent197("ps")
            intent.put(name, textValue("read_only"))
            @Expect(!pluginHubProcessObservationIntentValid197(intent))
        }
        @Expect(!pluginHubProcessObservationIntentValid197(processObservationIntent197("ps", service: "process.service")))
    }
    @TestCase
    func malformedFactsTargetsAndRequestFieldsCannotBecomeFrozenObservers(): Unit {
        let facts = processObservationInput197("ps")
        facts.field("facts").getOrThrow().put("broker_available", textValue("true"))
        @Expect(!pluginHubProcessObservationInputValid197(facts))
        let target = processObservationInput197("describe")
        target.field("request").getOrThrow().put("actual_target", objectValue([ValueField("pid", integerValue(1))]))
        @Expect(!pluginHubProcessObservationInputValid197(target))
        let extra = processObservationInput197("logs")
        extra.field("request").getOrThrow().put("signal", textValue("TERM"))
        @Expect(!pluginHubProcessObservationInputValid197(extra))
        let duration = processObservationInput197("wait")
        duration.field("request").getOrThrow().put("timeout_ms", integerValue(-1))
        @Expect(!pluginHubProcessObservationInputValid197(duration))
        @Expect(!pluginHubProcessObservationInputValid197(nullValue()))
        @Expect(!pluginHubProcessObservationIntentValid197(objectValue([])))
    }
    @TestCase
    func frozenObserverKeepsExactCapabilitiesEffectBindingAndOneIntent(): Unit {
        let child = processObservationChild197("logs")
        @Expect(!isPluginHubProcessObservationPlan197(processObservationPlan197(child, kind: CapabilityKind.ProcessSpawn)))
        @Expect(!isPluginHubProcessObservationPlan197(processObservationPlan197(child, effect: OperationEffectClass.ExternalMutation)))
        let intent = child.field("intent").getOrThrow()
        let parent = objectValue([ValueField("input", objectValue([])), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_PRIMITIVE_PARENT111)),
                ValueField("binding", child.field("binding").getOrThrow()), ValueField("intents", listValue([intent])),
                ValueField("invocation_capability", textValue("workspace.read"))]))])
        @Expect(pluginChildParentAllows111(processObservationPlan197(parent, parent: true), processObservationPlan197(child)))
        parent.field("host_plan").getOrThrow().put("intents", listValue([intent, processObservationIntent197("ps")]))
        @Expect(!isFrozenPluginChildParent111(processObservationPlan197(parent, parent: true)))
    }
    @TestCase
    func legacyProcessServiceStillRequiresSpawnAndExternalMutation(): Unit {
        @Expect(pluginPrimitiveRequiredCapability111("process.service"), CapabilityKind.ProcessSpawn)
        @Expect(pluginPrimitiveEffect111("process.service"), OperationEffectClass.ExternalMutation)
        let child = processObservationChild197("logs", service: "process.service", invocation: "process.spawn")
        @Expect(isPluginChildStartPlan111(processObservationPlan197(child, kind: CapabilityKind.ProcessSpawn,
            effect: OperationEffectClass.ExternalMutation)))
        @Expect(!isPluginChildStartPlan111(processObservationPlan197(child)))
        @Expect(!isPluginHubProcessObservationPlan197(processObservationPlan197(child, kind: CapabilityKind.ProcessSpawn,
            effect: OperationEffectClass.ExternalMutation)))
    }
}
