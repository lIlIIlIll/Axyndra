package extensions_contract

import agent_domain.*
import legacy_extension_host.*
import agent_runtime.*
import agent_testkit.*
import tool_runtime.*
import yjson.*
import yjson_support.*

class BatchTrustedExecutor <: ToolExecutor {
    public func execute(_context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        Result.Ok(ToolResult(prepared.call.callId, objectValue([ValueField("executed", boolValue(true))])))
    }
}

func batchTrustedDescriptor(name: String, version: String): ToolDescriptor {
    ToolDescriptor(ModelToolDefinition(name, "batch retry fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), implementationVersion: version,
        implementationFingerprint: "trusted-batch-" + version + ":" + name)
}

class BatchTrustedExtension <: TrustedAgentExtension {
    let contributions: Array<TrustedToolContribution> = [
        TrustedToolContribution(batchTrustedDescriptor("trusted_fresh", "v1"), BatchTrustedExecutor()),
        TrustedToolContribution(batchTrustedDescriptor("trusted_conflict", "v1"), BatchTrustedExecutor())
    ]
    public func id(): String { "contract.trusted-batch" }
    public func tools(): Array<TrustedToolContribution> { contributions }
}

func atomicInstallerRetryContract(): Unit {
    let host = RecordingHost()
    let sdkCatalog = ToolCatalog()
    let sdkInstaller = ExtensionInstaller(host)
    let sdkExtension = AtomicConflictExtension()
    expect(sdkCatalog.register(batchTrustedDescriptor("write", "blocker-v0"), BatchTrustedExecutor()).isOk(),
        "install a distinct pre-existing SDK name collision")
    let beforeSdk = sdkCatalog.toolSetSnapshot("before-sdk-batch",
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
    expect(match (sdkInstaller.install(sdkExtension, sdkCatalog)) {
        case Result.Err(error) => error.code == "tool.duplicate"
        case Result.Ok(_) => false
    }, "SDK second contribution rejects the whole publication")
    expect(sdkCatalog.definitions().size == 1 && !hasDefinition(sdkCatalog, "atomic_fresh") &&
        sdkInstaller.snapshots().isEmpty() && host.searchExecutions == 0 && host.writeExecutions == 0,
        "failed SDK batch retains neither a first executor identity nor installed metadata")
    expect(sdkCatalog.unregister("write"), "retire the unrelated collision")
    expect(sdkInstaller.install(sdkExtension, sdkCatalog).isOk() && sdkCatalog.definitions().size == 2 &&
        hasDefinition(sdkCatalog, "atomic_fresh") && hasDefinition(sdkCatalog, "write") &&
        sdkInstaller.snapshots().size == 1 && beforeSdk.entries.size == 1,
        "same SDK identity retries successfully because the rejected batch left no retired prefix")

    let trustedCatalog = ToolCatalog()
    let trustedInstaller = ExtensionInstaller(host)
    let trustedExtension = BatchTrustedExtension()
    expect(trustedCatalog.register(batchTrustedDescriptor("trusted_conflict", "blocker-v0"), BatchTrustedExecutor()).isOk(),
        "install a distinct pre-existing trusted name collision")
    expect(match (trustedInstaller.installTrusted(trustedExtension, trustedCatalog)) {
        case Result.Err(error) => error.code == "tool.duplicate"
        case Result.Ok(_) => false
    }, "trusted second contribution rejects the whole publication")
    expect(trustedCatalog.definitions().size == 1 && !hasDefinition(trustedCatalog, "trusted_fresh") &&
        trustedInstaller.snapshots().isEmpty(), "trusted failure leaves no partial directory or installed record")
    expect(trustedCatalog.unregister("trusted_conflict"), "retire the unrelated trusted collision")
    expect(trustedInstaller.installTrusted(trustedExtension, trustedCatalog).isOk() &&
        trustedCatalog.definitions().size == 2 && trustedInstaller.snapshots().size == 1,
        "same trusted executor identity retries successfully after atomic rejection")
    let pipeline = ToolPipeline(trustedCatalog, InMemoryOperationRuntimePort(), RecordingAuditPort(),
        DeterministicIds(prefix: "trusted-retry"))
    let context = ToolInvocationContext(RunId("trusted-retry"), SessionId("trusted-retry"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
    match (executePipelineCall(pipeline, context, ToolCall("trusted-retry", "trusted_fresh", objectValue([])))) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => expect(
            value.output.field("executed").getOrThrow().boolValue && value.receiptId != "",
            "retry publishes the real executor through the canonical Pipeline and Receipt path")
        case _ => throw IllegalStateException("retried trusted contribution did not execute")
    }
    let original = trustedCatalog.toolSetSnapshot("trusted-original",
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
    expect(trustedInstaller.uninstall(trustedExtension.id(), trustedCatalog).isOk(), "retire trusted instance")
    expect(trustedInstaller.installTrusted(BatchTrustedExtension(), trustedCatalog).isError(),
        "a new executor cannot reuse the retired instance identity")
    expect(match (trustedInstaller.installTrusted(BatchTrustedExtension(), trustedCatalog,
        instanceIdentity: "untrusted instance whitespace")) {
        case Result.Err(error) => error.code == "tool.instance_invalid"
        case Result.Ok(_) => false
    }, "invalid identity is a typed failure and publishes no prefix")
    expect(trustedCatalog.definitions().isEmpty() && trustedInstaller.snapshots().isEmpty(),
        "invalid identity retains no registrations or installed metadata")
    expect(trustedInstaller.installTrusted(BatchTrustedExtension(), trustedCatalog,
        instanceIdentity: "host-minted-second-instance").isOk(),
        "host-bound replacement of the same package installs without reviving its retired identity")
    let replacement = trustedCatalog.toolSetSnapshot("trusted-replacement",
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
    expect(original.entries[0].executorVersion != replacement.entries[0].executorVersion &&
        original.entries[0].implementationFingerprint == replacement.entries[0].implementationFingerprint &&
        original.entries[0].schemaDigest == replacement.entries[0].schemaDigest,
        "host instance binding separates otherwise identical executor tuples")
    println("Atomic ExtensionInstaller retry contract passed")
}
