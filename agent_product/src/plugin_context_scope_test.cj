package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func contextScopeFixtureConfig(settings: String): Unit {
    let directory = Path(settings).join("plugins")
    if (!exists(directory)) { Directory.create(directory, recursive: true) }
    File.writeTo(directory.join("read-scopes.json"), stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("roots", listValue([
            textValue("$" + "{settings_root}/managed-skills"), textValue("$" + "{settings_root}/skills"),
            textValue("$" + "{settings_root}/missing")]))])).toArray())
}
func contextScopeAssertDiscarded(f: SkillsProviderProductFixture, request: AgentRunRequest,
    capture: SkillsReadUpdateCapture): Unit {
    @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Discarded)
    @Expect(skillsReadCount(f, "completed"), 0)
    @Expect(contextReadProjectionDigest(skillsReadSnapshot(f, request)), contextReadProjectionDigest(request.contextSnapshot))
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
    skillsReadSettled(f)
}

@Test
class PluginContextScopeTests {
    @TestCase
    func credentialsInsideConfiguredContentStayHardDeniedUnderYolo(): Unit {
        for (child in [".ssh", ".git", "credentials"]) {
            let f = SkillsProviderProductFixture()
            try {
                let source = f.root + "/settings/skills/" + child
                writeObservedSkill(source, "MUST-NOT-BECOME-CONTEXT")
                let request = skillsReadRequest(f)
                let capture = SkillsReadUpdateCapture(f, request, listValue([skillsReadResource(source, "selected")]), ["selected"])
                @Expect(f.product.client.start(request, { event => capture.event(event) }).isOk())
                contextScopeAssertDiscarded(f, request, capture)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.context.read'"), 0)
            } finally { f.close() }
        }
    }
    @TestCase
    func unconfiguredSettingsDirectoriesDoNotBecomeContentRoots(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let source = f.root + "/settings/operator-private"
            writeObservedSkill(source, "UNDECLARED-CONTENT")
            let request = skillsReadRequest(f)
            let capture = SkillsReadUpdateCapture(f, request, listValue([skillsReadResource(source, "selected")]), ["selected"])
            @Expect(f.product.client.start(request, { event => capture.event(event) }).isOk())
            contextScopeAssertDiscarded(f, request, capture)
        } finally { f.close() }
    }
    @TestCase
    func configuredRootNeverRaisesActualRunReadCapability(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let source = f.root + "/settings/skills"
            writeObservedSkill(source, "OUTSIDE-ACTUAL-CAPABILITY")
            let original = skillsReadRequest(f)
            let request = AgentRunRequest(original.runId, original.sessionId, original.model, original.prompt,
                system: original.system, contextSnapshot: original.contextSnapshot, toolContext: original.toolContext,
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: f.root + "/ordinary.txt")]),
                budget: original.budget, approvalModeOverride: Some(ApprovalMode.Yolo))
            let capture = SkillsReadUpdateCapture(f, request, listValue([skillsReadResource(source, "selected")]), ["selected"])
            @Expect(f.product.client.start(request, { event => capture.event(event) }).isOk())
            contextScopeAssertDiscarded(f, request, capture)
        } finally { f.close() }
    }
    @TestCase
    func removingOrReplacingScopeFileCannotResumeAnOldApprovedRead(): Unit {
        for (restoreSameBytes in [false, true]) {
            let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                let source = f.root + "/settings/skills"
                writeObservedSkill(source, "UNREAD-AFTER-SCOPE-CHANGE")
                let request = skillsReadRequest(f)
                let capture = SkillsReadUpdateCapture(f, request, listValue([skillsReadResource(source, "selected")]), ["selected"])
                let approval = match (f.product.client.start(request, { event => capture.event(event) })) {
                    case Result.Ok(AgentRunOutcome.AwaitingApproval(_, value)) => value
                    case _ => throw IllegalStateException("configured data read did not enter real approval") }
                @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(approval.metadata.capabilityLabel, "outside-workspace.read")
                @Expect(skillsReadCount(f, "completed"), 0)
                let path = f.root + "/settings/plugins/read-scopes.json"
                let original = File.readFrom(path)
                rename(path, to: path + ".previous")
                if (restoreSameBytes) { File.writeTo(path, original) }
                let _ = f.product.client.decide(request, approval, ApprovalDecision.Approve, { _ => () })
                contextScopeAssertDiscarded(f, request, capture)
            } finally { f.close() }
        }
    }
    @TestCase
    func scopeCannotSoftenStateOrControlDirectoriesOrOrdinaryReadViews(): Unit {
        let root = pluginContractTemp("context-scope-exclusions")
        let settings = root + "/settings"
        try {
            contextScopeFixtureConfig(settings)
            let host = ProductJavaScriptPluginHost(settingsRoot: settings, readViewStateRoot: settings + "/skills/private-state")
            let scopes = lifecycleTestRequire(host.captureContextReadScopes())
            @Expect(scopes.permission(host, settings + "/skills/readme.md", "workspace.read"), "outside-workspace.read")
            @Expect(scopes.permission(host, settings + "/skills/private-state/state.db", "workspace.read"), "sensitive-path.read")
            // The ordinary process read-view classifier has no scope input.
            @Expect(host.readViewSensitive(settings + "/skills/readme.md"))
            for (value in [settings, settings + "/plugins", settings + "/plugins/store", settings + "/.ssh"]) {
                File.writeTo(settings + "/plugins/read-scopes.json", stringifyUnifiedJson(objectValue([
                    ValueField("version", integerValue(1)), ValueField("roots", listValue([textValue(value)]))])).toArray())
                @Expect(host.captureContextReadScopes().isError())
            }
        } finally { remove(root, recursive: true) }
    }
    @TestCase
    func malformedOrLinkedScopeConfigurationNeverFallsBackToDefaults(): Unit {
        let root = pluginContractTemp("context-scope-config")
        let settings = root + "/settings"
        try {
            contextScopeFixtureConfig(settings)
            let host = ProductJavaScriptPluginHost(settingsRoot: settings)
            let path = settings + "/plugins/read-scopes.json"
            File.writeTo(path, "{\"version\":1,\"roots\":[],\"unknown\":true}".toArray())
            @Expect(host.captureContextReadScopes().isError())
            remove(path); SymbolicLink.create(path, to: root + "/missing-config")
            @Expect(host.captureContextReadScopes().isError())
        } finally { remove(root, recursive: true) }
    }
}
