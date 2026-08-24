package agent_app

import agent_domain.*
import agent_product.*
import std.unittest.*
import std.unittest.testmacro.*
import tool_runtime.*

@Test
class AcpProductConfigTests {
    @TestCase
    func sessionFactoryPreservesCliWallTimeout(): Unit {
        let base = ProductConfig(
            settingsRoot: "/settings",
            stateRoot: "/state",
            workspaceRoot: "/original-workspace",
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            approvalRoutingModeOverride: Some(ApprovalRoutingMode.Trusted),
            modelOverride: "fixture-model",
            asyncEnabled: false,
            wallTimeoutMillis: 300000
        )

        let session = acpSessionProductConfig(base, "/acp-workspace")

        @Expect(session.settingsRoot, base.settingsRoot)
        @Expect(session.stateRoot, base.stateRoot)
        @Expect(session.workspaceRoot, "/acp-workspace")
        @Expect(session.fixture, base.fixture)
        @Expect(session.approvalMode == ApprovalMode.Yolo)
        @Expect(session.approvalRoutingModeOverride == Some(ApprovalRoutingMode.Trusted))
        @Expect(session.modelOverride, base.modelOverride)
        @Expect(session.asyncEnabled, base.asyncEnabled)
        @Expect(session.wallTimeoutMillis, 300000)
    }
}
