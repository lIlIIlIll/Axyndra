package operation_domain_vnext_contract

import yjson.*
import yjson_support.*
import agent_domain.*

func planExecutionDomainContract(): Unit {
    let action = PlanAction("probe", ["command_probe"], ["denied"],
        OperationEffectClass.ReadOnly, objectValue([ValueField("executable", textValue("node"))]), 1,
        evidence: "exit_zero", toolIdentities: planContractPin())
    let contract = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("verify"), [], true, [action])])
    expect(validatePlanContract(contract).isOk(), "approved contract validates")
    let roundtrip = parsePlanContract(planContractValue(contract))
    expect(roundtrip.isOk() && canonicalAgentValue(planContractValue(roundtrip.value().getOrThrow())) ==
        canonicalAgentValue(planContractValue(contract)), "contract serialization roundtrips without changing approval content")
    let operation = NormalizedOperationPlan("command_probe",
        objectValue([ValueField("executable", textValue("node")), ValueField("argv", listValue([textValue("--test")]))]),
        [Capability(CapabilityKind.ProcessSpawn)], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Safe, "binding", cwd: "/workspace", approvedWriteRoots: ["/workspace"], toolVersion: "1",
        implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(planActionAllows(contract, action, operation), "approved subset arguments and identity admit an Operation")
    let broadScope = NormalizedOperationPlan("command_probe", operation.canonicalArguments,
        [Capability(CapabilityKind.ProcessSpawn)], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Safe, "binding", cwd: "/workspace", approvedWriteRoots: ["/"], toolVersion: "1",
        implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(!planActionAllows(contract, action, broadScope), "process write mounts cannot exceed the approved target roots")
    let missingScope = NormalizedOperationPlan("command_probe", operation.canonicalArguments,
        [Capability(CapabilityKind.ProcessSpawn)], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Safe, "binding", cwd: "/workspace", toolVersion: "1",
        implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(!planActionAllows(contract, action, missingScope), "supervised process cannot omit its trusted write-root ceiling")
    let wrongTool = NormalizedOperationPlan("command_probe", operation.canonicalArguments,
        [Capability(CapabilityKind.ProcessSpawn)], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Safe, "binding", cwd: "/workspace", approvedWriteRoots: ["/workspace"], toolVersion: "2",
        implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(!planActionAllows(contract, action, wrongTool), "changed tool identity requires renewed approval")
    let wrongPath = NormalizedOperationPlan("command_probe", operation.canonicalArguments,
        [Capability(CapabilityKind.ProcessSpawn)], OperationEffectClass.ReadOnly,
        OperationRetryDisposition.Safe, "binding", cwd: "/outside", approvedWriteRoots: ["/workspace"], toolVersion: "1",
        implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(!planActionAllows(contract, action, wrongPath), "scope bounds apply to the actual normalized working directory")
    expect(!planArgumentsMatch(objectValue([ValueField("argv", listValue([textValue("--test")]))]),
        objectValue([ValueField("argv", listValue([textValue("--test"), textValue("other")]))]), false),
        "subset matching does not weaken list constraints")
    let cycles = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("a"), ["b"], true, [action]),
        PlanExecutionStep(PlanStepId("b"), ["a"], true, [PlanAction("other", ["command_probe"], ["denied"],
            OperationEffectClass.ReadOnly, objectValue([]), 1, toolIdentities: planContractPin())])])
    expect(validatePlanContract(cycles).isError(), "cyclic dependency contracts fail closed")
    let zeroBudget = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("a"), [], true,
        [PlanAction("bad", ["command_probe"], ["denied"], OperationEffectClass.ReadOnly,
            objectValue([]), 0, toolIdentities: planContractPin())])])
    expect(validatePlanContract(zeroBudget).isError(), "zero attempt budget fails validation")
    let completed = VNextOperationReceipt("receipt", OperationId("op"), OperationOutcome.Completed,
        objectValue([ValueField("exit_code", integerValue(0)), ValueField("timed_out", boolValue(false))]),
        objectValue([]), 1)
    expect(planReceiptEvidence(action, completed), "structured command completion is valid exit-zero evidence")
    let forged = VNextOperationReceipt("receipt", OperationId("op"), OperationOutcome.Completed,
        objectValue([ValueField("stdout", textValue("exit_code=0 timed_out=false"))]), objectValue([]), 1)
    expect(!planReceiptEvidence(action, forged), "stdout cannot masquerade as structured probe evidence")
    let memberProjection = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("hidden-sibling"), [], false, []),
        PlanExecutionStep(PlanStepId("visible"), ["hidden-sibling"], true, [action])])
    let parsedProjection = parsePlanContractProjection(planContractValue(memberProjection))
    expect(parsedProjection.isOk() && parsePlanContract(planContractValue(memberProjection)).isError() &&
        validatePlanContract(parsedProjection.value().getOrThrow()).isError(),
        "a filtered member view can support pure matching but cannot activate as an executable approved contract")
    let unpinned = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("a"), [], true,
        [PlanAction("unpinned", ["command_probe"], ["denied"], OperationEffectClass.ReadOnly, objectValue([]), 1)])])
    expect(parsePlanContract(planContractValue(unpinned)).isError() &&
        parsePlanContract(planContractValue(unpinned), requireToolIdentities: false).isOk(),
        "preview may enrich missing pins but executable approval requires identities")
}
func planContractPin(): AgentValue {
    objectValue([ValueField("command_probe", objectValue([
        ValueField("version", textValue("1")), ValueField("fingerprint", textValue("implementation")),
        ValueField("schema_digest", textValue("schema"))]))])
}
