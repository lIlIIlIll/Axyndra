package tool_runtime_contract

import agent_domain.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func contextResourcePolicyPlan(special: Bool): NormalizedOperationPlan {
    let args = objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)), ValueField("binding", objectValue([])),
        ValueField("requires_approval", boolValue(special)), ValueField("resources", listValue([
            objectValue([ValueField("kind", textValue("file")), ValueField("source", textValue("/workspace/data")),
                ValueField("path", textValue("data")), ValueField("witness", textValue("f:1:2:3:4:5")),
                ValueField("bytes", integerValue(4)), ValueField("permission", textValue(if (special) { "sensitive-path.read" } else { "workspace.read" }))])]))])
    NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, args,
        [Capability(CapabilityKind.WorkspaceRead, resource: "/workspace/data")], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never, "context-read-policy-fixture", toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
        implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
}
func extensionContextReadPolicyPlan(schema: String): NormalizedOperationPlan {
    let digest = modelPolicySha256Text("policy-fixture")
    let binding = objectValue([ValueField("namespace", textValue("axyndra:workflow")),
        ValueField("package_digest", textValue("sha256:" + digest)), ValueField("generation", textValue("1")),
        ValueField("configuration_digest", textValue(digest)), ValueField("thread_id", textValue("policy-thread")),
        ValueField("lane_id", textValue("main")), ValueField("run_id", textValue("policy-run")),
        ValueField("epoch", integerValue(1)), ValueField("parent_call_id", textValue("policy-parent")),
        ValueField("contribution", textValue("plugin.axyndra:workflow.todo")),
        ValueField("implementation_fingerprint", textValue("policy-v1:" + digest)), ValueField("schema_digest", textValue(digest))])
    let args = objectValue([ValueField("schema", textValue(schema)), ValueField("binding", binding),
        ValueField("projection_digest", textValue(digest)), ValueField("keys", listValue([textValue("todo")]))])
    NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, args,
        [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow")], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Never, "extension-context-policy", toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
        implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
}
func runContextReadPolicyContract(): Unit {
    let context = ToolInvocationContext(RunId("policy-run"), SessionId("policy-thread"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
    let ordinary = contextResourcePolicyPlan(false); let sensitive = contextResourcePolicyPlan(true)
    expect(DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk).evaluate(context, ordinary).requirement == PermissionRequirement.Safe,
        "existing ReadOnly workspace policy creates no additional read approval")
    expect(DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk).evaluate(context, sensitive).requirement == PermissionRequirement.Confirm,
        "host resource classification selects the existing approval path")
    expect(DefaultCapabilityPolicy(mode: ApprovalMode.Yolo).evaluate(context, sensitive).requirement == PermissionRequirement.Safe,
        "host resource shape does not override an explicit effective Yolo mode")
    let override = ToolInvocationContext(context.runId, context.sessionId, context.capabilities,
        approvalModeOverride: Some(ApprovalMode.Yolo))
    expect(DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk).evaluate(override, sensitive).requirement == PermissionRequirement.Safe,
        "effective invocation mode is retained")
    let denied = ToolInvocationContext(context.runId, context.sessionId, CapabilitySet())
    expect(DefaultCapabilityPolicy(mode: ApprovalMode.Yolo).evaluate(denied, ordinary).requirement == PermissionRequirement.Deny &&
        DefaultCapabilityPolicy(mode: ApprovalMode.Yolo).evaluate(denied, sensitive).requirement == PermissionRequirement.Deny,
        "neither classification nor Yolo grants a missing capability")
    sensitive.canonicalArguments.put("requires_approval", boolValue(false))
    expect(DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk).evaluate(context, sensitive).requirement == PermissionRequirement.Confirm,
        "forged inconsistent approval classification cannot suppress review")
    let extension = ToolInvocationContext(context.runId, context.sessionId,
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "axyndra:workflow")]))
    for (schema in [PLUGIN_DOCUMENT_READ_SCHEMA, PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA]) {
        let plan = extensionContextReadPolicyPlan(schema)
        expect(isContextReadPlan(plan), "test uses a valid exact ExtensionInvoke read plan")
        expect(DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk).evaluate(extension, plan).requirement == PermissionRequirement.Confirm,
            "AlwaysAsk reviews extension-backed reads independently from mutation")
        expect(DefaultCapabilityPolicy(mode: ApprovalMode.Write).evaluate(extension, plan).requirement == PermissionRequirement.Confirm,
            "Write mode retains its ExtensionInvoke read review")
        expect(DefaultCapabilityPolicy(mode: ApprovalMode.Yolo).evaluate(extension, plan).requirement == PermissionRequirement.Safe,
            "explicit Yolo retains its authorized read policy")
        expect(DefaultCapabilityPolicy(mode: ApprovalMode.Yolo).evaluate(denied, plan).requirement == PermissionRequirement.Deny,
            "Yolo cannot supply the missing ExtensionInvoke capability")
    }
    println("Context resource policy contract passed: 14 scenarios")
}
