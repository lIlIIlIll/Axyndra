package sandbox4cj

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Sandbox4CjTests {
    @TestCase
    func outputCapAndBinaryBytesPreserveCommandResult() {
        let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(sandboxTestRoot(),
            resources: SandboxResourceLimits(maxOutputBytes: 2)))
        let first = sandbox.execute(
            WorkspaceSandboxCommand("/bin/sh", arguments: ["-c", "printf '中'; exit 7"])
        )
        match (first) {
            case SandboxResult.Ok(result) =>
                @Expect(result.exitCode, 7)
                @Expect(result.outputTruncated, true)
                @Expect(result.stdout, "��")
            case SandboxResult.Err(error) =>
                // Hosts without a usable enforcer (CI runners restrict
                // unprivileged user namespaces) must fail closed instead of
                // executing an unsandboxed command; the byte-cap contract
                // itself stays covered on enforcer-capable hosts below.
                if (error.code != "sandbox.platform_unsupported" &&
                    error.code != "sandbox.bubblewrap_unavailable" &&
                    error.code != "sandbox.isolation_unsupported") {
                    @Fail("sandbox must fail closed without a usable enforcer: " +
                        error.code + ": " + error.message)
                }
                return
        }
        match (sandbox.execute(WorkspaceSandboxCommand("/bin/sh", arguments: ["-c", "printf '\\377A'; exit 9"]))) {
            case SandboxResult.Ok(result) =>
                @Expect(result.exitCode, 9)
                @Expect(result.outputTruncated, false)
                @Expect(result.stdout, "�A")
            case SandboxResult.Err(error) => @Fail(error.code + ": " + error.message)
        }
    }

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
