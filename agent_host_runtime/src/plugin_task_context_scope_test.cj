package agent_host_runtime

import agent_domain.*
import agent_ports.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import tool_runtime.*
import yjson.*
import yjson_support.*

private class TaskScopeCountingInspector <: HostReadTargetInspector {
    private let root: String
    private let observed: () -> Unit
    init(root: String, observed: () -> Unit) { this.root = root; this.observed = observed }
    public func inspectReadTarget(path: String): Result<HostReadTargetInfo> {
        observed()
        hostInspectReadTarget(root, path)
    }
}

private class TaskScopeReadCounters {
    var inspections: Int64 = 0
    var boundaries: Int64 = 0
}

private class TaskContextCollectorFixture {
    let root: String
    let workspace: String
    let target: String
    let settings: String
    let host: HostJavaScriptPluginHost
    private let counters: TaskScopeReadCounters
    prop inspections: Int64 { get() { counters.inspections } }
    prop boundaries: Int64 { get() { counters.boundaries } }
    init() {
        let temporaryParent = getVariable("TMPDIR").getOrDefault({ =>
            getVariable("HOME").getOrThrow() + "/.cache/agent-tmp"
        })
        if (!exists(Path(temporaryParent))) { Directory.create(temporaryParent, recursive: true) }
        let actualRoot = Directory.createTemp(temporaryParent).toString()
        let actualWorkspace = actualRoot + "/repository"
        let approvedTarget = actualWorkspace + "/target"
        let actualSettings = actualRoot + "/settings"
        let observed = TaskScopeReadCounters()
        Directory.create(approvedTarget, recursive: true)
        Directory.create(actualSettings + "/plugins", recursive: true)
        File.writeTo(actualWorkspace + "/AGENTS.md", "UNRELATED_REPOSITORY_SOURCE".toArray())
        File.writeTo(approvedTarget + "/AGENTS.md", "APPROVED_TARGET_SOURCE".toArray())
        root = actualRoot; workspace = actualWorkspace; target = approvedTarget; settings = actualSettings; counters = observed
        host = HostJavaScriptPluginHost({ path => TaskScopeCountingInspector(path, { => observed.inspections += 1 }) }, settingsRoot: actualSettings)
        host.ownTaskContextReadBoundary({ _, source =>
            observed.boundaries += 1
            if (hostPathComponentsContain(approvedTarget, source)) { Result.Ok(()) }
            else { Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plan.context_source_outside_scope",
                "Context source is outside approved repository participation")) }
        }).value().getOrThrow()
    }
    func context(review!: Bool = false, narrow!: Bool = false): ToolInvocationContext {
        ToolInvocationContext(RunId("task-context-run"), SessionId("task-context-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: if (narrow) { target } else { "" })]),
            toolContext: ToolContextDescriptor(workspaceRoot: workspace, cwd: target, planReviewControl: review))
    }
    func request(source: String): AgentValue {
        listValue([objectValue([ValueField("source", textValue(source)), ValueField("path", textValue("context/AGENTS.md")),
            ValueField("mode", textValue("file"))])])
    }
    func close(): Unit { host.close().value().getOrThrow(); remove(root, recursive: true) }
}

@Test
class HostTaskContextScopeTests {
    @TestCase
    func NativeContextCollectorChecksScopeBeforeFilesystemInspection(): Unit {
        let f = TaskContextCollectorFixture()
        try {
            let denied = HostReadViewCollector(f.context(), f.host, contextSelection: true)
                .collect(f.request(f.workspace + "/AGENTS.md"))
            @Expect(denied.isError()); @Expect(f.boundaries, 1); @Expect(f.inspections, 0)
            let selected = HostReadViewCollector(f.context(), f.host, contextSelection: true)
                .collect(f.request(f.target + "/AGENTS.md"))
            @Expect(selected.isOk()); @Expect(f.inspections > 0)
            @Expect(f.host.ownTaskContextReadBoundary({ _, _ => Result.Ok(()) }).isError())
        } finally { f.close() }
    }
    @TestCase
    func ScopeNeverOverridesSymlinkValidationOrBusinessReadPermissions(): Unit {
        let f = TaskContextCollectorFixture()
        try {
            SymbolicLink.create(f.target + "/escape", to: f.workspace)
            @Expect(HostReadViewCollector(f.context(), f.host, contextSelection: true)
                .collect(f.request(f.target + "/escape/AGENTS.md")).isError())
            let before = f.boundaries
            @Expect(HostReadViewCollector(f.context(), f.host)
                .collect(f.request(f.workspace + "/AGENTS.md")).isOk())
            @Expect(f.boundaries, before)
            @Expect(HostReadViewCollector(f.context(review: true, narrow: true), f.host, contextSelection: true)
                .collect(f.request(f.workspace + "/AGENTS.md")).isError())
            @Expect(f.boundaries, before)
            @Expect(HostReadViewCollector(f.context(review: true), f.host, contextSelection: true)
                .collect(f.request(f.workspace + "/AGENTS.md")).isOk())
        } finally { f.close() }
    }
    @TestCase
    func ExplicitGlobalDataRetainsExistingClassificationWithoutWorkspaceExemption(): Unit {
        let f = TaskContextCollectorFixture()
        try {
            Directory.create(f.settings + "/global")
            File.writeTo(f.settings + "/global/AGENTS.md", "EXPLICIT_GLOBAL_SOURCE".toArray())
            File.writeTo(f.settings + "/plugins/read-scopes.json", objectValue([
                ValueField("version", integerValue(1)), ValueField("roots", listValue([textValue(f.settings + "/global")]))
            ]).toJson().toArray())
            let scopes = f.host.captureContextReadScopes().value().getOrThrow()
            let collector = HostReadViewCollector(f.context(), f.host, contextSelection: true, scopes: Some(scopes))
            let selected = collector.collect(f.request(f.settings + "/global/AGENTS.md"))
            @Expect(selected.isOk()); @Expect(f.boundaries, 0); @Expect(collector.requiresApproval)
            @Expect(!scopes.explicitNonWorkspaceData(f.workspace + "/AGENTS.md", f.workspace))
            @Expect(HostReadViewCollector(f.context(), f.host, contextSelection: true, scopes: Some(scopes))
                .collect(f.request(f.workspace + "/AGENTS.md")).isError())
        } finally { f.close() }
    }
}
