package process4cj

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func namespaceFixtureArguments(borrowed: Bool, program: String, arguments: Array<String>): Array<String> {
    let prefix: Array<String> = if (borrowed) { [] } else {
        ["--unshare-user", "--disable-userns", "--unshare-pid", "--unshare-net"]
    }
    let common: Array<String> = ["--die-with-parent", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
        "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
        "--chdir", "/tmp", "--clearenv", "--", program]
    Array<String>(prefix.size + common.size + arguments.size, {index: Int64 =>
        if (index < prefix.size) { prefix[index] }
        else if (index < prefix.size + common.size) { common[index - prefix.size] }
        else { arguments[index - prefix.size - common.size] }
    })
}

@Test
class OwnedSandboxNamespaceTests {
    @TestCase
    func actualUnisolatedNativeTreeCannotBeUsedAsSandboxNamespace() {
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]))
        try {
            var rejected = false
            try { let lease = process.borrowSandboxNamespaces(); lease.close() }
            catch (_: ProcessError) { rejected = true }
            @Expect(rejected, true)
        } finally { let _ = process.close() }
    }

    @TestCase
    func publicBackendWrapperWithActualPidCannotConstructNativeNamespaceLease() {
        let backend = TerminationFaultBackend(forcedOnly: false)
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"]), backend: backend)
        try {
            @Expect(process.pid > 0, true)
            var rejected = false
            try { let lease = process.borrowSandboxNamespaces(); lease.close() }
            catch (_: ProcessError) { rejected = true }
            @Expect(rejected, true)
        } finally { backend.cleanup(); let _ = process.close() }
    }

    @TestCase
    func leaderOnlyManagedProcessCannotBorrowTreeNamespaces() {
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["30"], terminateProcessTree: false))
        try {
            var rejected = false
            try { let lease = process.borrowSandboxNamespaces(); lease.close() }
            catch (_: ProcessError) { rejected = true }
            @Expect(rejected, true)
        } finally { let _ = process.close() }
    }

    @TestCase
    func actualBorrowedNamespaceReturnsPayloadPidAndRejectsClosedLease() {
        let service = startProcess(ProcessCommand("/usr/bin/bwrap",
            arguments: namespaceFixtureArguments(false, "/usr/bin/python3",
                ["-u", "-c", "import sys; print('READY',flush=True); sys.stdin.buffer.read()"])))
        try {
            @Expect(readLineBounded(service.stdout, 64).getOrThrow(), "READY")
            let lease = service.borrowSandboxNamespaces()
            try {
                @Expect(lease.current(), true)
                let child = startProcessInSandboxNamespaces(ProcessCommand("/usr/bin/bwrap",
                    arguments: namespaceFixtureArguments(true, "/bin/sleep", ["30"])), lease)
                try {
                    var identity: ?ProcessSandboxPayloadIdentity = None
                    let deadline = MonoTime.now() + 2 * Duration.second
                    while (identity.isNone() && MonoTime.now() < deadline) {
                        try { identity = Some(child.sandboxPayloadIdentity(lease, "/bin/sleep")) }
                        catch (_: ProcessError) { sleep(5 * Duration.millisecond) }
                    }
                    @Expect(identity.isSome(), true)
                    let actual = identity.getOrThrow()
                    @Expect(actual.hostPid > 0 && actual.startTime > 0 && actual.namespacePid > 2, true)
                    @Expect(actual.hostPid != child.pid && actual.hostPid != service.pid, true)
                    lease.close()
                    @Expect(lease.current(), false)
                    var rejected = false
                    try {
                        let invalid = startProcessInSandboxNamespaces(ProcessCommand("/bin/true"), lease)
                        let _ = invalid.close()
                    } catch (_: ProcessError) { rejected = true }
                    @Expect(rejected, true)
                } finally { let _ = child.close() }
            } finally { lease.close() }
        } finally { let _ = service.close() }
    }
}
