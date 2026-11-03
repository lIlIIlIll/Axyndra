package agent_product

import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func lifecycleCwdWriteWorker(path: String): Unit {
    File.writeTo(path, "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".toArray())
    let _ = FileInfo(path).setExecutable(true)
    if (!FileInfo(path).canExecute()) { throw IllegalStateException("cwd fixture requires executable worker") }
}

func lifecycleCwdConfigure(fixture: McpProductFixture, cwd: String, executable: String): Unit {
    let document = parseUnifiedJson(String.fromUtf8(File.readFrom(fixture.files.settings + "/plugins/lifecycle.json")))
    let service = document.field("plugins").getOrThrow().items[0].field("services").getOrThrow().items[0]
    service.put("cwd", textValue(cwd)); service.put("executable", textValue(executable))
    fixture.files.write(document)
}

@Test
class PluginLifecycleCwdTests {
    @TestCase
    func relativeCwdAndExecutableFreezePlanAndRecheckBeforeHandoff(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let nested = fixture.packageRoot + "/nested"
            Directory.create(nested)
            lifecycleCwdWriteWorker(nested + "/worker")
            let service = fixture.service()
            service.put("cwd", textValue("nested")); service.put("executable", textValue("./worker"))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.launchPlan.field("cwd").getOrThrow().text, nested)
            @Expect(grant.launchPlan.field("cwd_authored").getOrThrow().text, "nested")
            @Expect(grant.launchPlan.field("executable_authored").getOrThrow().text, "./worker")
            @Expect(grant.launchPlan.field("executable").getOrThrow().text, nested + "/worker")
            @Expect(grant.launchPlan.field("read_only_mounts").getOrThrow().items.isEmpty())
            let request = lifecycleTestRequire(grant.processRequest(OperationId("cwd-real-operation")))
            @Expect(request.workingDirectory, nested)
            @Expect(request.executable, nested + "/worker")
            File.writeTo(nested + "/worker", "#!/bin/sh\nexit 1\n".toArray())
            @Expect(grant.processRequest(OperationId("changed-cwd-worker")).error().getOrThrow().code,
                "plugin.lifecycle_executable_changed")
        } finally { fixture.close() }
    }

    @TestCase
    func cwdCannotCreateMountsAndReadonlyDirectoryNeedsExplicitGrant(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let service = fixture.service()
            for (cwd in [fixture.external, "../external", "/usr", fixture.executable]) {
                service.put("cwd", textValue(cwd))
                fixture.write(fixture.document(service: Some(service)))
                @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).isError())
            }
            service.put("cwd", textValue(fixture.external))
            service.put("read_only_mounts", listValue([textValue(fixture.external)]))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.launchPlan.field("cwd").getOrThrow().text, fixture.external)
            @Expect(grant.launchPlan.field("workspace_mode").getOrThrow().text, "isolated_readonly")
            @Expect(grant.launchPlan.field("read_only_mounts").getOrThrow().items.size, 1)
            service.put("cwd", textValue(fixture.root))
            fixture.write(fixture.document(service: Some(service)))
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).error().getOrThrow().code,
                "plugin.lifecycle_cwd_not_mounted")
        } finally { fixture.close() }
    }

    @TestCase
    func cwdSymlinkRetargetRevokesTheFrozenGrantEvenInsideSameMount(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let first = fixture.packageRoot + "/first"
            let second = fixture.packageRoot + "/second"
            Directory.create(first); Directory.create(second)
            let link = fixture.packageRoot + "/current"
            SymbolicLink.create(link, to: first)
            let service = fixture.service(); service.put("cwd", textValue("current"))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.stillCurrent().isOk())
            remove(link); SymbolicLink.create(link, to: second)
            @Expect(grant.processRequest(OperationId("retargeted-cwd")).error().getOrThrow().code,
                "plugin.lifecycle_cwd_changed")
            remove(link); SymbolicLink.create(link, to: fixture.external)
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).error().getOrThrow().code,
                "plugin.lifecycle_cwd_not_mounted")
        } finally { fixture.close() }
    }

    @TestCase
    func bareExecutableUsesFrozenCwdThenFixedSystemSearchAndRejectsShadowing(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let service = fixture.service(); service.put("executable", textValue("python3"))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            let selected = grant.launchPlan.field("executable").getOrThrow().text
            @Expect(selected.startsWith("/usr/") || selected.startsWith("/bin/"))
            lifecycleCwdWriteWorker(fixture.packageRoot + "/python3")
            @Expect(grant.processRequest(OperationId("shadowed-command")).error().getOrThrow().code,
                "plugin.lifecycle_executable_changed")
            let fresh = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(fresh.launchPlan.field("executable").getOrThrow().text, fixture.packageRoot + "/python3")
            remove(fixture.packageRoot + "/python3")
            @Expect(fresh.stillCurrent().isError())
            // A same-named link outside all grants is rejected, not silently
            // skipped in favour of a later system candidate.
            lifecycleCwdWriteWorker(fixture.external + "/python3")
            SymbolicLink.create(fixture.packageRoot + "/python3", to: fixture.external + "/python3")
            @Expect(fixture.bind(lifecycleTestRequire(fixture.load())).error().getOrThrow().code,
                "plugin.lifecycle_executable_not_mounted")
        } finally { fixture.close() }
    }

    @TestCase
    func invalidCwdAndExecutableInputsAreRejectedBeforeAnyGrant(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            for (field in ["cwd", "executable"]) {
                for (value in [textValue(""), textValue("bad\npath"), textValue("bad\u{0000}path"), integerValue(3)]) {
                    let service = fixture.service(); service.put(field, value)
                    fixture.write(fixture.document(service: Some(service)))
                    @Expect(fixture.load().isError())
                }
            }
        } finally { fixture.close() }
    }

    @TestCase
    func actualMcpPeerStartsInRelativeWorkspaceCwdUsingRelativeExecutable(): Unit {
        let fixture = McpProductFixture(mode: "cwd")
        try {
            let nested = fixture.files.workspace + "/nested"
            Directory.create(nested)
            File.writeTo(nested + "/cwd-data.txt", "actual nested data 雪".toArray())
            lifecycleCwdWriteWorker(nested + "/worker")
            lifecycleCwdConfigure(fixture, "nested", "./worker")
            @Expect(!managedCompleted(fixture.start("mcp-cwd-relative")).isError)
            let result = managedCompleted(fixture.call("mcp-cwd-relative", "mcp-cwd-call"))
            @Expect(!result.isError)
            let observed = parseUnifiedJson(result.output.field("result").getOrThrow()
                .field("content").getOrThrow().items[0].field("text").getOrThrow().text)
            @Expect(observed.field("cwd").getOrThrow().text, nested)
            @Expect(observed.field("relative_data").getOrThrow().text, "actual nested data 雪")
            @Expect(fixture.calls(), 1)
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 3)
        } finally { fixture.close() }
    }

    @TestCase
    func actualMcpPeerUsesExplicitReadonlyCwdAndBareSystemExecutable(): Unit {
        let fixture = McpProductFixture(mode: "cwd")
        try {
            let nested = fixture.files.external + "/nested"
            Directory.create(nested)
            File.writeTo(nested + "/cwd-data.txt", "actual mounted data".toArray())
            lifecycleCwdConfigure(fixture, nested, "python3")
            @Expect(!managedCompleted(fixture.start("mcp-cwd-mounted")).isError)
            let result = managedCompleted(fixture.call("mcp-cwd-mounted", "mcp-mounted-call"))
            @Expect(!result.isError)
            let observed = parseUnifiedJson(result.output.field("result").getOrThrow()
                .field("content").getOrThrow().items[0].field("text").getOrThrow().text)
            @Expect(observed.field("cwd").getOrThrow().text, nested)
            @Expect(observed.field("relative_data").getOrThrow().text, "actual mounted data")
            @Expect(fixture.calls(), 1)
            @Expect(fixture.childReceipts("completed"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func actualMcpInvalidCwdHasNoBackendIoOrCompletedReceipt(): Unit {
        let fixture = McpProductFixture()
        try {
            lifecycleCwdConfigure(fixture, fixture.files.root, "/usr/bin/python3")
            @Expect(managedRejected(fixture.start("mcp-cwd-denied")))
            @Expect(fixture.observed().isEmpty())
            @Expect(!fixture.visible("mcp-cwd-denied"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
        } finally { fixture.close() }
    }
}
