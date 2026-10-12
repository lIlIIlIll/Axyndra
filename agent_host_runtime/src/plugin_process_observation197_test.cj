package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func processObservationSelection197(services: Array<String>, invocation!: String = "workspace.read"): AgentValue {
    objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
        ValueField("namespace", textValue("axyndra:workflow")),
        ValueField("package_digest", textValue("sha256:" + modelPolicySha256Text("observation-package-197"))),
        ValueField("tools", listValue([objectValue([ValueField("name", textValue("observe197")),
            ValueField("profile", textValue("frozen-primitives-v1")), ValueField("preparation_provider", textValue("prepare197")),
            ValueField("services", listValue(services.map { value => textValue(value) })),
            ValueField("invocation_capability", textValue(invocation))])]))])]))])
}
private func processObservationSelectionAccepted197(services: Array<String>, invocation!: String = "workspace.read"): Bool {
    hostPrimitiveSelections111(processObservationSelection197(services, invocation: invocation), "axyndra:workflow",
        "sha256:" + modelPolicySha256Text("observation-package-197")).isOk()
}

@Test
class ActualProcessObservationSelection197Tests {
    @TestCase
    func exactObserverSelectionPreservesTheOriginalTwoServiceMaximum(): Unit {
        @Expect(processObservationSelectionAccepted197(["process.observe"]))
        @Expect(processObservationSelectionAccepted197(["process.observe"], invocation: "extension.invoke"))
        @Expect(processObservationSelectionAccepted197(["peer.list", "peer.receive"]))
        @Expect(!processObservationSelectionAccepted197(["peer.list", "peer.receive", "job.list"]))
        @Expect(processObservationSelectionAccepted197(["process.service"], invocation: "process.spawn"))
    }
    @TestCase
    func observersAndWriteServicesRequireTheirOwnExclusiveContribution(): Unit {
        for (other in ["peer.list", "job.wait", "process.service", "child.start", "child.result.write"]) {
            @Expect(!processObservationSelectionAccepted197(["process.observe", other]))
            @Expect(!processObservationSelectionAccepted197([other, "process.observe"]))
        }
        @Expect(!processObservationSelectionAccepted197(["process.observe", "process.observe"]))
        @Expect(!processObservationSelectionAccepted197(["process.service", "peer.list"], invocation: "process.spawn"))
    }
    @TestCase
    func observerMappingCannotClaimSpawnDelegateOrAnUnknownPrimitive(): Unit {
        @Expect(!processObservationSelectionAccepted197(["process.observe"], invocation: "process.spawn"))
        @Expect(!processObservationSelectionAccepted197(["process.observe"], invocation: "delegate"))
        @Expect(!processObservationSelectionAccepted197(["process.observe"], invocation: "peer.message"))
        @Expect(!processObservationSelectionAccepted197(["process.observe.unknown"]))
        @Expect(!processObservationSelectionAccepted197(["process.service"], invocation: "workspace.read"))
    }
}
