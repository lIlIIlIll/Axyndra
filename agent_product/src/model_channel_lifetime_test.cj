package agent_product

import agent_domain.*
import agent_ports.*
import model_provider_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func modelLifetimeRequest(root: String, owner: ProcessResourceOwner, timeout: Int64): ProcessRequest {
    ProcessRequest("/usr/bin/python3", resourceOwner: Some(owner), arguments: [root + "/resource.py"],
        workingDirectory: root, filesystemRoot: root, sandboxMode: ProcessSandboxMode.IsolatedReadOnly,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), timeoutMillis: timeout,
        processLimits: ExecutionResourceLimits(maxOutputBytes: 4096))
}

@Test
class ModelChannelLifetimeTests {
    @TestCase
    func zeroAndLongTimeoutNeedActualModelGateAndKeepRawLimits(): Unit {
        installedModelLifetime204()
    }

    @TestCase
    func zeroTimeoutActualRunCancellationStillReapsItsProcess(): Unit {
        installedModelCancellation204(zeroTimeout: true)
    }

    @TestCase
    func actualModelInputAboveRawCeilingStillHasAnExactCumulativeBound(): Unit {
        installedModelLargeInput204()
    }

    @TestCase
    func installedFrameBetween64And256KiBUsesBoundedPhysicalWrites(): Unit {
        let fixture = InstalledModelProductFixture("chat", contextWindow: 1048576, timeoutMillis: 0)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("mid-physical-model")))
            session.setThinking(ThinkingLevel.Off)
            lifecycleTestRequire(session.submit(String.fromUtf8(Array<Byte>(90000, repeat: b'p'))))
            @Expect(fixture.observed().size, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }
}
