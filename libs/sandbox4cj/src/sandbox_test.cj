package sandbox4cj

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Sandbox4CjTests {
    @TestCase
    func filtersEnvironmentAndRedactsGrantedSecrets() {
        let filter = EnvironmentFilter(
            allowlist: ["VISIBLE", "API_TOKEN"],
            allowedSecrets: ["API_TOKEN"]
        )
        let filtered = filter.filter([
            SandboxEnvironmentEntry("VISIBLE", "value"),
            SandboxEnvironmentEntry("API_TOKEN", "very-secret-token"),
            SandboxEnvironmentEntry("IGNORED", "no")
        ])
        @Expect(filtered.entries.size, 2)
        @Expect(filtered.redactor().redact("token=very-secret-token"), "token=[REDACTED]")

        @Expect(EnvironmentFilter(allowlist: ["API_TOKEN"]).validateRequested([
            SandboxEnvironmentEntry("API_TOKEN", "very-secret-token")
        ]).isOk(), false)
    }

    @TestCase
    func createsExplicitIsolationPlan() {
        let root = sandboxTestRoot()
        let plan = match (WorkspaceSandbox(WorkspaceSandboxPolicy(
            root,
            filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
            process: ProcessIsolationMode.Isolated,
            network: NetworkIsolationMode.Denied,
            resources: SandboxResourceLimits(openFiles: 64, processes: 8),
            bubblewrapExecutable: "/usr/bin/true",
            timeoutExecutable: "/usr/bin/true"
        )).plan(WorkspaceSandboxCommand("/usr/bin/true"))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => throw error
        }
        @Expect(containsSandboxArgument(plan.sandboxArguments, "--unshare-net"), true)
        @Expect(containsSandboxArgument(plan.sandboxArguments, "--unshare-pid"), true)
        @Expect(containsSandboxArgument(plan.sandboxArguments, "--ro-bind"), true)
        @Expect(containsSandboxArgument(plan.sandboxArguments, "--nofile=64"), true)
    }

    @TestCase
    func rejectsPathEscapeAndFailsClosedWithoutEnforcer() {
        let root = sandboxTestRoot()
        let pathEscape = WorkspaceSandbox(WorkspaceSandboxPolicy(
            root,
            bubblewrapExecutable: "/usr/bin/true",
            timeoutExecutable: "/usr/bin/true"
        )).plan(WorkspaceSandboxCommand("/usr/bin/true", workingDirectory: ".."))
        @Expect(sandboxResultCode(pathEscape), "sandbox.path_escape")

        let unavailable = WorkspaceSandbox(WorkspaceSandboxPolicy(
            root,
            bubblewrapExecutable: "/definitely/missing/bwrap"
        )).execute(WorkspaceSandboxCommand("/usr/bin/true"))
        @Expect(sandboxResultCode(unavailable), "sandbox.bubblewrap_unavailable")
    }
}

func sandboxTestRoot(): String {
    let root = Path("target/sandbox4cj-tests")
    if (!exists(root)) { Directory.create(root, recursive: true) }
    canonicalize(root).toString()
}

func containsSandboxArgument(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) { return true }
    false
}

func sandboxResultCode<T>(value: SandboxResult<T>): String {
    match (value) { case SandboxResult.Ok(_) => ""; case SandboxResult.Err(error) => error.code }
}
