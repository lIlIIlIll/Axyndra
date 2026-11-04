package agent_product

import yjson.*
import yjson_support.*

import agent_domain.*
import tool_runtime.*
import process4cj.*
import sandbox4cj.*
import std.fs.*
import std.env.*
import std.process.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CommandProbeContracts {
    @TestCase
    func commandProbeRequiresItsOwnOperationAuthorization(): Unit {
        for (authorization in [PreparedAuthorization.ParentIntent, PreparedAuthorization.ManagedJob,
            PreparedAuthorization.ApprovalRequired]) { @Expect(!commandProbeAuthorizationAllowed(authorization)) }
        for (authorization in [PreparedAuthorization.StaticPolicy, PreparedAuthorization.SessionGrant,
            PreparedAuthorization.Approved]) { @Expect(commandProbeAuthorizationAllowed(authorization)) }
        @Expect(commandProbeAuthorizationSource(PreparedAuthorization.ParentIntent), "parent_intent")
        @Expect(commandProbeAuthorizationSource(PreparedAuthorization.ManagedJob), "managed_job")
    }

    @TestCase
    func networkedProbeDisallowsShellConfigAndUncontrolledInstall(): Unit {
        let curl = ["--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--", "https://example.test/fixture"]
        @Expect(validNetworkProbeArguments("curl", curl))
        @Expect(!validNetworkProbeArguments("sh", ["-c", "curl https://example.test"]))
        @Expect(!validNetworkProbeArguments("curl", ["--config", "config"]))
        @Expect(!validNetworkProbeArguments("curl", ["--output", "app.js", "https://example.test"]))
        @Expect(!validNetworkProbeArguments("curl", ["--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--", "file:///secret"]))
        @Expect(validNetworkProbeArguments("npm", ["view", "three", "version"]))
        @Expect(validNetworkProbeArguments("npm", ["install", "--ignore-scripts", "--no-save", "--no-audit", "--no-fund", "three@0.180.0"]))
        @Expect(!validNetworkProbeArguments("npm", ["install", "three"]))
        @Expect(!validNetworkProbeArguments("npm", ["exec", "--", "sh"]))
        @Expect(!validNetworkProbeArguments("npm", ["install", "--ignore-scripts", "--no-save", "--no-audit", "--no-fund", "three@latest"]))
        @Expect(!validProbePackage("https://example.test/package", true))
        for (value in ["alice/repo", "alice/repo@1.2.3", "thing.tgz", "thing.tar.gz", "thing.tar", "./thing",
            "/thing", "@scope//thing", "thing@@1.2.3", "thing@1..2.3", "thing@01.2.3", "thing@latest"]) {
            @Expect(!validProbePackage(value, true))
            @Expect(!validProbePackage(value, false))
        }
        for (value in ["three@0.180.0", "@scope/package@1.2.3"]) {
            @Expect(validProbePackage(value, true))
        }
        @Expect(validProbePackage("@scope/package", false))
        @Expect(npmProbePrivatePathsOverlapWorkspace("/tmp"))
        @Expect(npmProbePrivatePathsOverlapWorkspace("/tmp/axyndra-npm-probe-prefix"))
        @Expect(npmProbePrivatePathsOverlapWorkspace("/tmp/axyndra-npm-probe-cache/child"))
        @Expect(!npmProbePrivatePathsOverlapWorkspace("/tmp/independent-app"))

    }

    @TestCase
    func packageManagerIgnoresAmbientConfigAndRejectsExistingProjectsBeforeSpawn(): Unit {
        let parent = match (getVariable("TMPDIR")) { case Some(value) => value; case None => "target" }
        if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
        let root = Directory.createTemp(parent).toString()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let fresh = Path(root).join("fresh").toString()
            Directory.create(fresh)
            let marker = Path(root).join("executed-marker").toString()
            File.writeTo(Path(root).join("malicious-git"), ("#!/bin/sh\nprintf unsafe > " + marker).toArray())
            let (executable, _, _) = executeWithOutput("/usr/bin/chmod", ["700", "--", Path(root).join("malicious-git").toString()])
            @Expect(executable, 0)
            File.writeTo(Path(root).join(".npmrc"), "git=./malicious-git\nscript-shell=./malicious-git\nregistry=https://example.test/\n".toArray())
            File.writeTo(Path(root).join("package.json"), "{\"dependencies\":{\"unexpected\":\"git+https://example.test/repo.git\"}}".toArray())
            let network = NetworkPolicy(NetworkPolicyMode.HostNetwork)
            let install = ["install", "--ignore-scripts", "--no-save", "--no-audit", "--no-fund", "three@0.180.0"]
            let unsafeRoot = commandProbeEffectiveArguments("/usr/bin/npm", ["view", "three", "version"],
                network, fresh, workspaceRoot: "/tmp").error().getOrThrow()
            @Expect(unsafeRoot.code, "probe.private_storage_unavailable")
            @Expect(unsafeRoot.field("started").getOrThrow(), "false")
            let rejected = commandProbeEffectiveArguments("/usr/bin/npm", install, network, root).error().getOrThrow()
            @Expect(rejected.code, "probe.npm_prefix_not_fresh")
            @Expect(!exists(Path(marker)))
            let effective = commandProbeEffectiveArguments("/usr/bin/npm", install, network, fresh).value().getOrThrow()
            @Expect(effective.contains("--prefix=" + fresh))
            @Expect(effective.contains("--git=/usr/bin/false") && effective.contains("--ignore-scripts"))
            // Load the installed npm's actual configuration implementation.
            // This does no fetch or installation and runs with denied network.
            let script = "process.env.NODE_DISABLE_COMPILE_CACHE='1';" +
                "const fs=require('node:fs'),p=require('node:path');" +
                "const root=p.dirname(p.dirname(fs.realpathSync('/usr/bin/npm')));" +
                "const Config=require(root+'/node_modules/@npmcli/config');" +
                "const defs=require(root+'/node_modules/@npmcli/config/lib/definitions');" +
                "const npa=require(root+'/node_modules/npm-package-arg');" +
                "for(const s of ['three@0.180.0','@scope/package@1.2.3'])if(npa(s).type!=='version')process.exit(7);" +
                "if(npa('alice/repo').type!=='git'||npa('alice/repo@1.2.3').type!=='directory'||npa('thing.tgz').type!=='file')process.exit(8);" +
                "const a=JSON.parse(process.argv[1]);" +
                "const c=new Config({...defs,npmPath:root,argv:[process.execPath,root+'/bin/npm-cli.js',...a]});" +
                "c.load().then(()=>{if(c.get('git')!='/usr/bin/false'||!c.get('ignore-scripts')||c.get('package-lock')!==false||" +
                "c.get('registry')!=='https://registry.npmjs.org/'||c.get('fetch-retries')!==0||" +
                "require(root+'/node_modules/@npmcli/git/lib/which')({git:c.flat.git})!=='/usr/bin/false')process.exit(5);console.log('isolated')})" +
                ".catch(e=>{console.error(e);process.exit(6)})"
            let arguments = Array<AgentValue>(effective.size, {index => textValue(effective[index])})
            let checked = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/usr/bin/node", workingDirectory: root,
                arguments: ["-e", script, listValue(arguments).toJson()], timeoutMillis: 3000)).value().getOrThrow()
            @Expect(checked.stderr, "")
            @Expect(checked.exitCode, 0)
            @Expect(checked.stdout, "isolated\n")
            @Expect(!exists(Path(marker)))
            File.writeTo(Path(fresh).join(".npmrc"), "git=../malicious-git\n".toArray())
            @Expect(commandProbeEffectiveArguments("/usr/bin/npm", install, network, fresh).isError())
            @Expect(!exists(Path(marker)))
        } finally { let _ = port.close(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func curlCannotLoadHomeConfigurationOrWriteItsTraceMarker(): Unit {
        let parent = match (getVariable("TMPDIR")) { case Some(value) => value; case None => "target" }
        if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
        let root = Directory.createTemp(parent).toString()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let marker = Path(root).join("curl-trace-marker").toString()
            File.writeTo(Path(root).join(".curlrc"), ("trace-ascii = \"" + marker + "\"\n").toArray())
            let requested = ["--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--", "https://127.0.0.1:1/"]
            let effective = commandProbeEffectiveArguments("/usr/bin/curl", requested,
                NetworkPolicy(NetworkPolicyMode.HostNetwork), root).value().getOrThrow()
            @Expect(effective[0], "--disable")
            @Expect(effective.contains("--proto-redir"))
            // Read-write workspace makes this meaningful: an accidentally
            // loaded trace configuration could really create the marker.
            let control = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/usr/bin/curl", workingDirectory: root,
                arguments: effective[1..], timeoutMillis: 1000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite)).value().getOrThrow()
            @Expect(control.started && control.completed && control.exitCode != 0)
            @Expect(exists(Path(marker)))
            removeIfExists(Path(marker))
            let result = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/usr/bin/curl", workingDirectory: root,
                arguments: effective, timeoutMillis: 1000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite)).value().getOrThrow()
            @Expect(result.started && result.completed && result.exitCode != 0)
            @Expect(!exists(Path(marker)))
        } finally { let _ = port.close(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func outputDoesNotControlProbeStatusAndExit124IsNotTimeout(): Unit {
        let result = runProcessWithDeadline(ProcessCommand("/bin/sh",
            arguments: ["-c", "printf 'rc=0 EXIT=0'; exit 124"]), 1000)
        @Expect(result.result.status.code, 124)
        @Expect(!result.timedOut)
        @Expect(String.fromUtf8(result.result.stdout), "rc=0 EXIT=0")
        let pipeline = runProcessWithDeadline(ProcessCommand("/bin/sh",
            arguments: ["-c", "false | cat; printf 'rc=124'"]), 1000)
        @Expect(pipeline.result.status.code, 0)
        @Expect(!pipeline.timedOut)
    }

    @TestCase
    func nativeDeadlineTerminatesARealChildAndDrainsBoundedOutput(): Unit {
        let started = MonoTime.now()
        let result = runProcessWithDeadline(ProcessCommand("/bin/sh",
            arguments: ["-c", "printf before; sleep 5"], maxOutputBytes: 4), 80)
        @Expect(result.timedOut)
        @Expect(result.result.truncated)
        @Expect(String.fromUtf8(result.result.stdout), "befo")
        @Expect(MonoTime.now() - started < Duration.second * 2)
    }

    @TestCase
    func trustedFramePreservesTargetStatusAndRejectsForgery(): Unit {
        let exit124 = decodeCommandProbeFrame(
            "AXYNDRA-PROBE/1 1 1 124 0 0 0 4 0\nrc=0".toArray(), "", SecretRedactor([])).value().getOrThrow()
        @Expect(exit124.started && exit124.completed)
        @Expect(!exit124.timedOut)
        @Expect(exit124.exitCode, 124)
        let absent = decodeCommandProbeFrame(
            "AXYNDRA-PROBE/1 0 0 127 0 0 2 0 0\n".toArray(), "", SecretRedactor([])).value().getOrThrow()
        @Expect(!absent.started && !absent.completed)
        @Expect(absent.launchErrno, 2)
        for (frame in ["FORGEDAXYNDRA-PROBE/1 1 1 0 0 0 0 0 0\n",
            "AXYNDRA-PROBE/1 0 1 0 0 0 0 0 0\n", "rc=0"]) {
            let error = decodeCommandProbeFrame(frame.toArray(), "", SecretRedactor([])).error().getOrThrow()
            @Expect(error.kind == AgentErrorKind.RecoveryRequired)
        }
    }

    @TestCase
    func actualSandboxProbeAttestsExecAndChildExit124(): Unit {
        let parent = match (getVariable("TMPDIR")) { case Some(value) => value; case None => "target" }
        if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
        let root = Directory.createTemp(parent).toString()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let absent = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/nonexistent/command-probe-fixture",
                workingDirectory: root, timeoutMillis: 1000)).value().getOrThrow()
            @Expect(!absent.started && !absent.completed)
            @Expect(absent.launchErrno, 2)
            let exited = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/sh", workingDirectory: root,
                arguments: ["-c", "printf 'rc=0'; exit 124"], timeoutMillis: 1000)).value().getOrThrow()
            @Expect(exited.started && exited.completed && !exited.timedOut)
            @Expect(exited.exitCode, 124)
            @Expect(exited.stdout, "rc=0")
            File.writeTo(Path(root).join("source.txt"), "original".toArray())
            let write = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/sh", workingDirectory: root,
                arguments: ["-c", "printf changed > source.txt"], timeoutMillis: 1000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadOnly)).value().getOrThrow()
            @Expect(write.started && write.completed && write.exitCode != 0)
            @Expect(String.fromUtf8(File.readFrom(Path(root).join("source.txt"))), "original")
            let timed = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/sleep", workingDirectory: root,
                arguments: ["5"], timeoutMillis: 100)).value().getOrThrow()
            @Expect(timed.started && !timed.completed && timed.timedOut)
        } finally {
            let _ = port.close()
            removeIfExists(Path(root), recursive: true)
        }
    }

    @TestCase
    func rawProbeRejectsModelAttemptWithoutOperationOwnership(): Unit {
        let root = newScopedProbeDirectory()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let request = ProcessRequest("/bin/sh",
                resourceOwner: Some(ProcessResourceOwner.ModelAttempt(ModelAttemptId("probe-unclaimed-attempt"), "fixture")),
                arguments: ["-c", "printf bad > denied-marker"], workingDirectory: root,
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite)
            let error = port.executeProbe(request).error().getOrThrow()
            @Expect(error.kind == AgentErrorKind.PermissionDenied)
            @Expect(error.code, "model.process_admission_denied")
            @Expect(!exists(Path(root).join("denied-marker")))
        } finally { let _ = port.close(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func gatewayStagesAndErrorReceiptPreserveTypedDiagnostics(): Unit {
        let policy = NetworkPolicy(NetworkPolicyMode.Mediated)
        let missing = LocalNetworkGatewayPort(executable: "/nonexistent/probe-network-bridge")
        let error = missing.acquire(OperationId("missing-helper"), policy).error().getOrThrow()
        @Expect(error.field("stage").getOrThrow(), "helper_missing")
        @Expect(error.field("started").getOrThrow(), "false")
        @Expect(operationFailureClass(error), "infrastructure_unavailable")
        let encoded = operationErrorValue(error)
        @Expect(encoded.field("kind").getOrThrow().text, "transport")
        @Expect(encoded.field("failure_class").getOrThrow().text, "infrastructure_unavailable")
        @Expect(encoded.field("fields").getOrThrow().items.size >= 3)
        @Expect(encoded.field("fallback_allowed").isSome())
        @Expect(!error.retryable && !error.fallbackAllowed)
        let exited = LocalNetworkGatewayPort(executable: "/usr/bin/true")
        let exitError = exited.acquire(OperationId("exited-helper"), policy).error().getOrThrow()
        @Expect(exitError.field("stage").getOrThrow(), "exited_before_ready")
        @Expect(exitError.field("helper_exit_code").getOrThrow(), "0")
        @Expect(sanitizedGatewayStderr("token=secret <private-path>"), "[unrecognized gateway diagnostic redacted]")
        @Expect(sanitizedGatewayStderr("sandbox-net-bridge: cannot bind gateway socket: private-address"),
            "sandbox-net-bridge: cannot bind gateway socket")
    }

    @TestCase
    func gatewayLaunchFailureAndReadinessDeadlineCleanUpReaders(): Unit {
        let parent = match (getVariable("TMPDIR")) { case Some(value) => value; case None => "target" }
        if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
        let root = Directory.createTemp(parent).toString()
        try {
            let fixture = Path(root).join("bridge").toString()
            File.writeTo(fixture, "#!/bin/sh\nwhile true; do printf sensitive-token >&2; done\n".toArray())
            let (code, _, _) = executeWithOutput("/usr/bin/chmod", ["700", "--", fixture])
            @Expect(code, 0)
            let started = MonoTime.now()
            let result = LocalNetworkGatewayPort(executable: fixture).acquire(
                OperationId("no-readiness"), NetworkPolicy(NetworkPolicyMode.Mediated))
            let error = result.error().getOrThrow()
            @Expect(error.field("stage").getOrThrow(), "ready_timeout")
            @Expect(error.field("stderr_excerpt").getOrThrow(), "[unrecognized gateway diagnostic redacted]")
            @Expect(MonoTime.now() - started < Duration.second * 3)
            let (permission, _, _) = executeWithOutput("/usr/bin/chmod", ["600", "--", fixture])
            @Expect(permission, 0)
            let launch = LocalNetworkGatewayPort(executable: fixture).acquire(
                OperationId("cannot-launch"), NetworkPolicy(NetworkPolicyMode.Mediated)).error().getOrThrow()
            @Expect(launch.field("stage").getOrThrow(), "launch_failed")
        } finally { removeIfExists(Path(root), recursive: true) }
    }
    @TestCase
    func scopedProcessesCanWriteOnlyApprovedDirectories(): Unit {
        let root = newScopedProbeDirectory()
        let first = Path(root).join("first").toString()
        let second = Path(root).join("second").toString()
        let outside = Path(root).join("outside").toString()
        for (path in [first, second, outside]) { Directory.create(path) }
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let script = "printf inside > allowed; " +
                "if printf bad > ../outside/relative 2>/dev/null; then exit 41; fi; " +
                "if printf bad > " + shellQuote(Path(outside).join("absolute").toString()) +
                " 2>/dev/null; then exit 42; fi; printf checked"
            let bash = requiredProbeResult(executeProcessSandboxFixture(port, probeSandboxFixtureRequest("/bin/bash", arguments: ["-c", script],
                workingDirectory: first, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                approvedWriteRoots: [first])))
            @Expect(bash.exitCode, 0)
            @Expect(bash.stdout, "checked")
            @Expect(exists(Path(first).join("allowed")))
            @Expect(!exists(Path(outside).join("relative")) && !exists(Path(outside).join("absolute")))
            let multiple = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/sh",
                arguments: ["-c", "printf one > one; printf two > " + shellQuote(Path(second).join("two").toString())],
                workingDirectory: first, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                approvedWriteRoots: [first, second])).value().getOrThrow()
            @Expect(multiple.exitCode, 0)
            @Expect(exists(Path(first).join("one")) && exists(Path(second).join("two")))
            let readonly = requiredProbeResult(executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/sh", arguments: ["-c", "printf bad > denied"],
                workingDirectory: first, sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
                approvedWriteRoots: [first])))
            @Expect(readonly.started && readonly.completed && readonly.exitCode != 0)
            @Expect(!exists(Path(first).join("denied")))
            let escaped = probeSandboxFixtureRequest("/bin/sh", arguments: ["-c", "printf bad > escaped"],
                workingDirectory: outside, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                approvedWriteRoots: [first])
            for (error in [executeProcessSandboxFixture(port, escaped).error().getOrThrow(), executeProbeSandboxFixture(port, escaped).error().getOrThrow(),
                executeProbeSandboxFixture(port, escaped).error().getOrThrow()]) {
                @Expect(error.kind == AgentErrorKind.PermissionDenied)
                @Expect(error.field("started").getOrThrow(), "false")
            }
            @Expect(!exists(Path(outside).join("escaped")))
            let (link, _, _) = executeWithOutput("/usr/bin/ln", ["-s", "--", outside, Path(root).join("link").toString()])
            @Expect(link, 0)
            let changed = executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/sh", arguments: ["-c", "true"],
                workingDirectory: first, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                approvedWriteRoots: [Path(root).join("link").toString()])).error().getOrThrow()
            @Expect(changed.kind == AgentErrorKind.PermissionDenied)
        } finally { let _ = port.close(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func pinnedDirectoryCapabilitiesCloseAndPreventScopeReplacement(): Unit {
        let root = newScopedProbeDirectory()
        let first = Path(root).join("first").toString()
        let saved = Path(root).join("saved").toString()
        let outside = Path(root).join("outside").toString()
        Directory.create(first)
        Directory.create(outside)
        let pinned = PinnedProcessDirectory(root)
        let descriptorPath = pinned.sourcePath
        @Expect(exists(Path(descriptorPath)))
        let child = runProcessWithDeadline(ProcessCommand("/usr/bin/python3", arguments: ["-c",
            "import os,sys; p=sys.argv[1]; found=False\nfor f in os.listdir('/proc/self/fd'):\n try:\n  found |= os.readlink('/proc/self/fd/'+f)==p\n except OSError: pass\nsys.exit(5 if found else 0)", root]), 1000)
        @Expect(child.result.status.code, 0)
        pinned.close()
        pinned.close()
        @Expect(!exists(Path(descriptorPath)))
        let policy = WorkspaceSandboxPolicy(root, filesystem: FilesystemIsolationMode.WorkspaceReadWrite,
            writableRoots: [first])
        let sandbox = WorkspaceSandbox(policy)
        let plan = match (sandbox.plan(WorkspaceSandboxCommand("/bin/sh",
            arguments: ["-c", "printf fixed > marker"], workingDirectory: first))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => throw IllegalStateException(error.message)
        }
        try {
            let (moved, _, _) = executeWithOutput("/usr/bin/mv", ["--", first, saved])
            @Expect(moved, 0)
            let (linked, _, _) = executeWithOutput("/usr/bin/ln", ["-s", "--", outside, first])
            @Expect(linked, 0)
            let execution = runProcessWithDeadline(ProcessCommand(plan.sandboxExecutable,
                arguments: plan.sandboxArguments, passedFileDescriptors: plan.passedFileDescriptors()), 1000)
            @Expect(!exists(Path(outside).join("marker")))
            if (execution.result.status.code == 0) { @Expect(exists(Path(saved).join("marker"))) }
        } finally { plan.releasePinnedRoots(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func scopedProbeInvocationsBindDirectoryIdentity(): Unit {
        let root = newScopedProbeDirectory()
        let first = Path(root).join("first").toString()
        let saved = Path(root).join("saved").toString()
        Directory.create(first)
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let firstCommand = probeSandboxFixtureRequest("/bin/bash", arguments: ["-c", "SCOPED_VALUE=old; printf old"],
                workingDirectory: first, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite, approvedWriteRoots: [first])
            @Expect(requiredProbeResult(executeProbeSandboxFixture(port, firstCommand)).stdout, "old")
            let (moved, _, _) = executeWithOutput("/usr/bin/mv", ["--", first, saved])
            @Expect(moved, 0)
            Directory.create(first)
            let second = requiredProbeResult(executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/bin/bash",
                arguments: ["-c", "printf '%s' \"$" + "{SCOPED_VALUE-unset}\"; printf new > new-marker"],
                workingDirectory: first, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                approvedWriteRoots: [first])))
            @Expect(second.stdout, "unset")
            @Expect(exists(Path(first).join("new-marker")))
            @Expect(!exists(Path(saved).join("new-marker")))
        } finally { let _ = port.close(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func probeStopsDetachedDescendantsBeforeReturning(): Unit {
        let root = newScopedProbeDirectory()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        try {
            let script = "import os,time\nif os.fork()==0:\n os.setsid()\n if os.fork()>0: os._exit(0)\n" +
                " os.close(0);os.close(1);os.close(2);time.sleep(.25);open('late-marker','w').write('bad');os._exit(0)\nos._exit(0)"
            let result = requiredProbeResult(executeProbeSandboxFixture(port, probeSandboxFixtureRequest("/usr/bin/python3", arguments: ["-c", script],
                workingDirectory: root, sandboxMode: ProcessSandboxMode.WorkspaceReadWrite,
                approvedWriteRoots: [root], timeoutMillis: 1000)))
            @Expect(result.started && result.completed && result.exitCode == 0)
            sleep(Duration.millisecond * 400)
            @Expect(!exists(Path(root).join("late-marker")))
        } finally { let _ = port.close(); removeIfExists(Path(root), recursive: true) }
    }

    @TestCase
    func controlledNetworkReadsStayReadOnlyAndOnlyStoppedProfilesAllowFallback(): Unit {
        let root = newScopedProbeDirectory()
        let workspace = LocalWorkspace(root)
        let processes = LocalProcessPort(workspace, sandboxEnabled: true)
        try {
            let catalog = ToolCatalog()
            @Expect(registerCommandProbeTool(catalog, workspace, processes, ShellNetworkMode.Restricted).isOk())
            let policy = NetworkPolicy(NetworkPolicyMode.HostNetwork)
            let context = ToolInvocationContext(RunId("scope-readonly"), SessionId("scope-readonly"), CapabilitySet(),
                toolContext: ToolContextDescriptor(workspaceRoot: root, cwd: root))
            for ((name, arguments) in [("npm", ["view", "three", "version"]),
                ("curl", ["--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--", "https://example.test/"])]) {
                let call = ToolCall("network-read", "command_probe", objectValue([
                    ValueField("executable", textValue(name)),
                    ValueField("argv", listValue(Array<AgentValue>(arguments.size, {index => textValue(arguments[index])}))),
                    ValueField("network", networkPolicyCanonicalValue(policy))]))
                let descriptor = catalog.resolvedDescriptor(call).getOrThrow()
                @Expect(!descriptor.sideEffecting)
                @Expect(normalizedToolOperationPlan(context, call, descriptor).effectClass == OperationEffectClass.ReadOnly)
                @Expect(commandProbeFallbackAllowed(call, policy, ProcessResult(137, timedOut: true), []))
                @Expect(!commandProbeFallbackAllowed(call, NetworkPolicy(NetworkPolicyMode.Denied), ProcessResult(7), []))
            }
            let installArguments = ["install", "--ignore-scripts", "--no-save", "--no-audit", "--no-fund", "three@0.180.0"]
            let installCall = ToolCall("install-failed", "command_probe", objectValue([
                ValueField("executable", textValue("npm")),
                ValueField("argv", listValue(Array<AgentValue>(installArguments.size, {index => textValue(installArguments[index])}))),
                ValueField("network", networkPolicyCanonicalValue(policy))]))
            @Expect(commandProbeSideEffecting(installCall))
            @Expect(!commandProbeFallbackAllowed(installCall, policy, ProcessResult(137, timedOut: true), []))
            @Expect(commandProbeFallbackAllowed(installCall, policy, ProcessResult(137, timedOut: true), [root]))
        } finally { let _ = processes.close(); removeIfExists(Path(root), recursive: true) }
    }

}

func newScopedProbeDirectory(): String {
    let parent = match (getVariable("TMPDIR")) { case Some(value) => value; case None => "target" }
    if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
    Directory.createTemp(parent).toString()
}

func requiredProbeResult(result: Result<ProcessResult>): ProcessResult {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
    }
}

// These explicit host-authored fixture owners exercise only the process port
// and real sandbox. They are resource identities, not canonical admission or
// approval evidence. Product plan tests exercise the published tool pipeline.
func probeSandboxFixtureRequest(
    executable: String,
    arguments!: Array<String> = [],
    workingDirectory!: String = "",
    timeoutMillis!: Int64 = 60000,
    sandboxMode!: ProcessSandboxMode = ProcessSandboxMode.WorkspaceReadOnly,
    approvedWriteRoots!: Array<String> = []
): ProcessRequest {
    ProcessRequest(executable,
        resourceOwner: Some(ProcessResourceOwner.Operation(OperationId("probe-sandbox-fixture"))),
        arguments: arguments, workingDirectory: workingDirectory,
        timeoutMillis: timeoutMillis, sandboxMode: sandboxMode,
        approvedWriteRoots: approvedWriteRoots)
}

func executeProbeSandboxFixture(port: LocalProcessPort, request: ProcessRequest): Result<ProcessResult> {
    port.reserveOperation(request.operationId)
    try { port.executeProbe(request) } finally { port.releaseOperation(request.operationId) }
}

func executeProcessSandboxFixture(port: LocalProcessPort, request: ProcessRequest): Result<ProcessResult> {
    port.reserveOperation(request.operationId)
    try { port.execute(request) } finally { port.releaseOperation(request.operationId) }
}
