package product_thread_runtime_contract

import std.fs.*
import std.collection.*
import agent_app_protocol.*
import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_product.*
import agent_runtime.*
import agent_skills.*
import agent_store.*
import tool_runtime.*
import model_adapters.*

main(): Int64 {
    let root = Directory.createTemp("/tmp").toString()
    try {
        let workspace = root + "/workspace"
        Directory.create(workspace, recursive: true)
        File.writeTo(workspace + "/input.txt", "durable tool input\n".toArray())
        let stateRoot = root + "/state"
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: stateRoot,
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false,
            extensionSignatureVerifier: Some(FixedPluginSignatureVerifier(true)),
            compactionOverride: Some(ProductCompactionSettings(
                keepRecentMessages: 2
            ))
        )).value().getOrThrow()
        let sessionId = SessionId("durable-product-thread")
        let result = product.applicationSession(sessionId: Some(sessionId))
            .submit("persist the canonical owner")
        let firstRunState = match (result) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) => runStateName(snapshot.status)
                case None => "missing_snapshot"
            }
            case Result.Err(error) => "error:" + error.code + ":" + error.message
        }
        expect(result.isOk() && result.value().getOrThrow().snapshot.isSome() &&
            result.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "fixture product completes its Run; actual=" + firstRunState)
        let toolSessionId = SessionId("durable-product-tool-thread")
        let toolResult = product.applicationSession(sessionId: Some(toolSessionId))
            .submit("fixture vnext read")
        expect(toolResult.isOk() && toolResult.value().getOrThrow().snapshot.isSome() &&
            toolResult.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "fixture product completes a canonical Tool trajectory")
        expect(product.compactSession(toolSessionId).value().getOrThrow() > 0,
            "product compaction creates a disposable canonical checkpoint")
        let resumed = product.applicationSession(sessionId: Some(toolSessionId))
            .submit("continue after checkpoint")
        expect(resumed.isOk() && match (product.fixtureProbe.getOrThrow().lastRequest) {
            case Some(request) => !request.messages.isEmpty() &&
                request.messages[0].blocks[0].text.startsWith(
                    "[Compacted canonical Thread through Item"
                )
            case None => false
        }, "next Turn projects checkpoint plus high-fidelity suffix")
        let productSkill = SkillActivation(
            SkillDescriptor(
                "product-review", "product-review", "Product review skill", ["review"],
                "skill://product-review"
            ),
            "Use the Product SkillStack contract."
        )
        let skillResult = product.client.start(
            product.request(
                "run active skill",
                sessionId: Some(SessionId("durable-product-skill-thread")),
                skillStack: SkillStackSnapshot([productSkill], [])
            ),
            {_ => ()}
        )
        expect(skillResult.isOk() && match (product.fixtureProbe.getOrThrow().lastRequest) {
            case Some(request) => request.system.contains("<active_skills ") &&
                request.system.contains("Use the Product SkillStack contract.")
            case None => false
        }, "Product freezes an explicit active SkillStack into the Run")
        let pageEvent = product.appCommand(AppCommand(
            AppCommandMeta(AppCommandId("contract-page"), 1),
            AppCommandPayload.LoadItemsPage(ThreadId(sessionId.value), 0, 16)
        ))
        expect(match (pageEvent) {
            case Result.Ok(event) => match (event.payload) {
                case AppEventPayload.ItemsPage(page) =>
                    page.threadId.value == sessionId.value && page.items.size == 2 &&
                    event.meta.threadRevision == page.threadRevision
                case _ => false
            }
            case Result.Err(_) => false
        }, "Product serves canonical Thread pages through the typed App Protocol")
        expect(!product.appCommand(AppCommand(
            AppCommandMeta(
                AppCommandId("stale-page"),
                2,
                expectedThreadRevision: Some(0)
            ),
            AppCommandPayload.LoadItemsPage(ThreadId(sessionId.value), 0, 16)
        )).isOk(), "App Protocol rejects a stale expected Thread revision")
        let seededSession = SessionId("durable-product-seed-thread")
        expect(product.replaceMessages(seededSession, [
            ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "seeded user history")
            ]),
            ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Unknown, text: "durable system note")
            ])
        ]).isOk(), "Product creates offline canonical history through the seed boundary")
        expect(product.replaceMessages(seededSession, [
            ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "must not overwrite")
            ])
        ]).isError(), "Product cannot replace an existing canonical Thread")
        let forkedSession = SessionId("durable-product-fork-thread")
        expect(product.forkSession(seededSession, forkedSession).isOk(),
            "Product fork clones canonical Items without a provider DTO round trip")
        expect(product.replaceMessages(
            SessionId("durable-product-invalid-seed"),
            [ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Text, text: "assistant first")
            ])]
        ).isError(), "Product rejects invalid offline transcript ownership")

        let queuedApplication = product.applicationSession(sessionId: Some(sessionId))
        expect(queuedApplication.enqueue(
            "persisted-steering", "steer", "inspect the durable boundary"
        ).isOk() && match (queuedApplication.withdrawQueued("persisted-steering")) {
            case Result.Ok(QueuedWithdrawal.Withdrawn(_)) => true
            case _ => false
        } && queuedApplication.enqueue(
            "persisted-follow-up", "follow_up", "continue after recovery"
        ).isOk(),
            "Product Application writes queued interactions through the durable Lane Inbox")
        let deliveredSession = SessionId("durable-delivered-interaction")
        let deliveredApplication = product.applicationSession(
            sessionId: Some(deliveredSession)
        )
        expect(deliveredApplication.enqueue(
            "delivered-follow-up", "follow_up", "second durable intent"
        ).isOk() && deliveredApplication.submit("first durable intent").isOk(),
            "queued follow-up is consumed inside a live Product Run")

        isolatedPluginHostContract(workspace)
        expect(product.vnext.validateIsolatedExtension(
            SignedExtensionPackageManifest(
                "product.signed", "1", "1", "1", "plugins/signed.wasm",
                [], [], [], 1u32, "compatible", "sha256:signed", "signature"
            ),
            ExtensionExecutionKind.WasmComponent, 1u64, []
        ).isOk(),
            "Product validates extension packages only through its configured trust root")

        let remoteTransport = ProductRecordingRemoteTransport()
        let remoteRealm = RemoteExecutionRealm(
            "product-worker", "https://worker.invalid/rpc", "product-worker-key",
            "product-worker-fs", "product-worker-process"
        )
        let remoteEnvelope = sealRemoteCapabilityEnvelope(
            SignedRemoteCapabilityEnvelope(
                "product-envelope", RunId("missing-remote-run"), LaneId("main"),
                remoteRealm.id, CapabilitySet(), 10, 30, "nonce"
            ),
            "signature"
        )
        expect(product.vnext.routeRemote(
            RemoteExecutionRouter(
                remoteRealm, CapabilitySet(), ProductRemoteVerifier(), remoteTransport
            ),
            remoteEnvelope,
            RemoteExecutionRequest(
                OperationId("missing-remote-operation"), RemoteServiceKind.Process,
                objectValue([]), "lane:main"
            ),
            20
        ).isError() && remoteTransport.dispatches == 0,
            "Product remote effects cannot bypass durable Operation admission")

        let mainBranch = product.vnext.laneBranch(
            ThreadId(sessionId.value), LaneId("main")
        ).value().getOrThrow()
        let reviewLane = LaneRecord(
            LaneId("review"), ThreadId(sessionId.value),
            LaneKind.SharedHistoryChild,
            objectValue([ValueField("profile", textValue("review"))]),
            parentLaneId: Some(LaneId("main")),
            forkItemId: Some(mainBranch[0]),
            createdAtMillis: 20
        )
        expect(product.vnext.createSharedHistoryLane(reviewLane).isOk() &&
            product.vnext.laneBranch(
                ThreadId(sessionId.value), LaneId("review")
            ).value().getOrThrow().size == 1,
            "Product exposes durable shared-history Lane creation and branch projection")
        let mainAdmission = product.vnext.acquireLaneRun(
            ThreadId(sessionId.value), LaneId("main"), RunId("product-main-lane-run"),
            "product-main-actor", 100, leaseMillis: 1000
        ).value().getOrThrow()
        let reviewAdmission = product.vnext.acquireLaneRun(
            ThreadId(sessionId.value), LaneId("review"), RunId("product-review-lane-run"),
            "product-review-actor", 100, leaseMillis: 1000
        ).value().getOrThrow()
        expect(product.vnext.acquireLaneRun(
            ThreadId(sessionId.value), LaneId("review"), RunId("product-review-race"),
            "product-review-racer", 100, leaseMillis: 1000
        ).isError() && mainAdmission.fenceToken == 1 &&
            reviewAdmission.fenceToken == 1,
            "Product admits different Lane actors concurrently but fences one Run per Lane")
        product.vnext.releaseLaneRun(mainAdmission, 110).value().getOrThrow()
        product.vnext.releaseLaneRun(reviewAdmission, 110).value().getOrThrow()
        let isolatedFork = product.vnext.forkThread(
            ThreadId(sessionId.value), LaneId("main"),
            mainBranch[mainBranch.size - 1], ThreadId("product-isolated-child"),
            "isolated-workspace", 20
        )
        expect(isolatedFork.isOk() &&
            isolatedFork.value().getOrThrow().size == mainBranch.size &&
            product.vnext.laneBranch(
                ThreadId("product-isolated-child"), LaneId("main")
            ).value().getOrThrow().size == mainBranch.size,
            "Product ForkThread freezes a Lane prefix into an isolated durable Thread")
        let team = TeamRecord(
            TeamId("product-team"), ThreadId(sessionId.value), LaneId("main"),
            "Product review", createdAtMillis: 21
        )
        let coordinator = TeamMemberRecord(
            TeamMemberId("product-coordinator"), team.id,
            ThreadId(sessionId.value), LaneId("main"), "coordinator",
            joinedAtMillis: 22
        )
        let reviewer = TeamMemberRecord(
            TeamMemberId("product-reviewer"), team.id,
            ThreadId(sessionId.value), LaneId("review"), "reviewer",
            joinedAtMillis: 23
        )
        expect(product.vnext.createTeam(team).isOk() &&
            product.vnext.addTeamMember(coordinator).isOk() &&
            product.vnext.addTeamMember(reviewer).isOk() &&
            product.vnext.teamRoster(team.id).value().getOrThrow().size == 2,
            "Product exposes the durable Team roster on real Thread Lanes")
        let storageLease = product.vnext.storageService.acquire(
            ComponentScope(RealmKind.Host, "product-host")
        ).value().getOrThrow()
        expect(storageLease.value == "sqlite-vnext",
            "Product resolves its semantic store through the typed host ServiceRegistry")
        storageLease.release()

        let program = product.vnext.executeReadOnlyToolProgram(
            "product-program",
            "return await tools.read({\"path\":\"input.txt\"});",
            SessionId("durable-product-program-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
        )
        expect(program.isOk() &&
            program.value().getOrThrow().status == ToolProgramStatus.Completed &&
            program.value().getOrThrow().subOperations.size == 1,
            "Product executes opt-in read-only Tool Programs through one durable child Operation")
        product.close().value().getOrThrow()

        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let thread = database.query(
                "SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id='" +
                    sessionId.value + "'"
            )
            expect(thread.size == 1 && thread[0].required(0) == "3" &&
                thread[0].required(1) == "",
                "completed product Turn releases the durable Thread owner")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM turns WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM runs WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'"
            ) == 1,
                "product composition persists matching completed Turn and Run records")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + sessionId.value + "'"
            ) == 2,
                "product composition persists canonical user and assistant Items")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM lane_inbox_entries WHERE thread_id='" +
                    sessionId.value + "' AND lane_id='main' AND status='applied'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE thread_id='" +
                    sessionId.value + "' AND status='completed'"
            ) == 1,
                "product admission and terminal settlement enclose the user input in one durable Step")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM composition_snapshots snapshot JOIN " +
                    "run_composition_bindings binding ON binding.snapshot_id=snapshot.id " +
                    "JOIN runs ON runs.id=binding.run_id WHERE runs.thread_id='" +
                    sessionId.value + "'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM context_manifests WHERE thread_id='" +
                    sessionId.value + "'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM run_continuation_facts facts JOIN runs " +
                    "ON runs.id=facts.run_id WHERE runs.thread_id='" + sessionId.value +
                    "' AND facts.phase='accepted'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM run_continuation_facts facts JOIN runs " +
                    "ON runs.id=facts.run_id WHERE runs.thread_id='" + sessionId.value +
                    "' AND facts.phase='context_ready' AND " +
                    "facts.payload LIKE '%context_manifest_id%'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM run_continuation_facts facts JOIN runs " +
                    "ON runs.id=facts.run_id WHERE runs.thread_id='" + sessionId.value +
                    "' AND facts.phase='model_effect_pending' AND " +
                    "facts.payload LIKE '%context_manifest_id%'"
            ) >= 1,
                "product freezes Composition, accepted continuation and exact Context Manifest before effects")
            let toolThread = database.query(
                "SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id='" +
                    toolSessionId.value + "'"
            )
            expect(toolThread.size == 1 && toolThread[0].required(0) == "8" &&
                toolThread[0].required(1) == "",
                "Tool trajectory and resumed Turn settle under one Thread owner")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + toolSessionId.value + "'"
            ) == 6 && database.scalarInt(
                "SELECT COUNT(*) FROM operations JOIN runs ON runs.id=operations.run_id " +
                    "WHERE runs.thread_id='" + toolSessionId.value + "' AND operations.state='committed'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts JOIN operations " +
                    "ON operations.id=operation_receipts.operation_id JOIN runs " +
                    "ON runs.id=operations.run_id WHERE runs.thread_id='" + toolSessionId.value +
                    "' AND operation_receipts.outcome='completed'"
            ) == 1,
                "Product ToolCall commits one Operation, Receipt and paired ToolResult")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM context_checkpoints WHERE thread_id='" +
                    toolSessionId.value + "'"
            ) == 1,
                "checkpoint is durable while canonical Items remain unmodified")
            let programRuns = database.scalarInt(
                "SELECT COUNT(*) FROM runs WHERE thread_id='durable-product-program-thread' " +
                    "AND state='completed' AND budget LIKE '%programmatic%'"
            )
            let programOperations = database.scalarInt(
                "SELECT COUNT(*) FROM operations op JOIN runs ON " +
                    "runs.id=op.run_id WHERE runs.thread_id=" +
                    "'durable-product-program-thread'"
            )
            let programReceipts = database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts receipt JOIN operations op ON " +
                    "op.id=receipt.operation_id JOIN runs ON runs.id=op.run_id WHERE " +
                    "runs.thread_id='durable-product-program-thread'"
            )
            let programSteps = database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE thread_id=" +
                    "'durable-product-program-thread' AND status='completed'"
            )
            expect(programRuns == 1 && programOperations == 1 && programReceipts == 1 &&
                programSteps == 1,
                "read-only Tool Program owns a separate durable Run, Step, Operation and Receipt " +
                    "boundary; runs=${programRuns} operations=${programOperations} " +
                    "receipts=${programReceipts} steps=${programSteps}")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM step_records step JOIN runs ON runs.id=step.run_id " +
                    "WHERE runs.thread_id='" + toolSessionId.value + "'"
            ) >= 2 && database.scalarInt(
                "SELECT COUNT(DISTINCT manifest.step_id) FROM context_manifests manifest " +
                    "WHERE manifest.thread_id='" + toolSessionId.value + "'"
            ) >= 2,
                "each Product model request owns a distinct durable Step and Context Manifest")
            expect(database.query(
                "SELECT status FROM lane_inbox_entries WHERE thread_id='" +
                    sessionId.value + "' AND payload LIKE '%persisted-steering%'"
            )[0].required(0) == "rejected" && database.query(
                "SELECT status FROM lane_inbox_entries WHERE thread_id='" +
                    sessionId.value + "' AND payload LIKE '%persisted-follow-up%'"
            )[0].required(0) == "queued",
                "withdrawal is durable and undelivered interaction survives process close")
            let deliveredRow = database.query(
                "SELECT id,status FROM lane_inbox_entries WHERE thread_id='" +
                    deliveredSession.value + "' AND payload LIKE '%delivered-follow-up%'"
            )[0]
            let deliveredEntryId = deliveredRow.required(0)
            let deliveredStatus = deliveredRow.required(1)
            let deliveredSteps = database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE thread_id='" +
                    deliveredSession.value + "'"
            )
            let deliveredEnclosures = database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE input_entry_id='" +
                    deliveredEntryId + "' AND accepted_item_id='" + deliveredEntryId + "'"
            )
            expect(deliveredStatus == "applied" && deliveredSteps >= 2 &&
                deliveredEnclosures == 1,
                "delivered interaction is atomically enclosed by its next model Step; " +
                    "status=${deliveredStatus} steps=${deliveredSteps} " +
                    "enclosures=${deliveredEnclosures}")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM audit_events WHERE thread_id='product-isolated-child' " +
                    "AND kind='thread.forked'"
            ) == 1 && SqliteThreadCommitSink(database).loadThread(
                ThreadId("product-isolated-child")
            ).activeRunId.isNone(),
                "isolated Product fork reopens without inheriting active Run authority")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + seededSession.value + "'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + forkedSession.value + "'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + forkedSession.value +
                    "' AND kind='system_note'"
            ) == 1,
                "canonical fork preserves non-provider semantic Items exactly")
        } finally {
            database.close()
        }
        let reopened = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: stateRoot,
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false
        )).value().getOrThrow()
        let restoredInputs = reopened.applicationSession(
            sessionId: Some(sessionId)
        ).takeFollowUps()
        expect(restoredInputs.size == 1 &&
            restoredInputs[0].correlationId == "persisted-follow-up" &&
            restoredInputs[0].text == "continue after recovery",
            "Application restores undelivered durable Inbox input after process reopen")
        reopened.close().value().getOrThrow()
        println("product Thread Runtime contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func isolatedPluginHostContract(workspace: String): Unit {
    let processManifest = SignedExtensionPackageManifest(
        "review.process", "1.0.0", ">=1.0.0 <2.0.0", "1",
        "plugins/reviewer", ["review"], [], ["workspace.read"],
        1u32, "compatible", "sha256:process", "signature-process"
    )
    let processLaunch = match (validateIsolatedPluginPackage(
        processManifest, ExtensionExecutionKind.ProcessPlugin, 7u64,
        ["workspace.read"], FixedPluginSignatureVerifier(true)
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    let processPort = RecordingPluginProcessPort("{\"accepted\":true}")
    let host = ProductIsolatedPluginHost(processPort, workspace)
    expect(host.mountInitial(processLaunch).isOk(),
        "isolated Process generation mounts before admission")
    let processResult = host.invoke(
        "review.process",
        IsolatedPluginInvocation("call-1", "review", encodeAgentValue(objectValue([
            ValueField("path", textValue("input.txt"))
        ])))
    )
    expect(processResult.isOk() && processPort.requests.size == 1 &&
        processPort.requests[0].executable == workspace + "/plugins/reviewer" &&
        processPort.requests[0].sandboxMode == ProcessSandboxMode.WorkspaceReadOnly &&
        !processPort.requests[0].networkAccess &&
        processPort.requests[0].environmentAllowlist.isEmpty() &&
        processPort.requests[0].arguments.size == 2 &&
        processPort.requests[0].arguments[1].contains("axyndra-extension-v1"),
        "Process plugin executes only through the bounded read-only sandbox protocol")
    let processReload = match (validateIsolatedPluginPackage(
        processManifest, ExtensionExecutionKind.ProcessPlugin, 8u64,
        ["workspace.read"], FixedPluginSignatureVerifier(true)
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    expect(host.reload(processReload).isOk() && host.invoke(
        "review.process",
        IsolatedPluginInvocation("call-1b", "review", encodeAgentValue(objectValue([])))
    ).isOk() && host.diagnostics().size == 2 &&
        host.diagnostics()[0].state == ExtensionLifecycleState.Inactive &&
        !host.diagnostics()[0].accepting &&
        host.diagnostics()[1].state == ExtensionLifecycleState.Active &&
        host.diagnostics()[1].generation == 8u64,
        "isolated plugin reload fences the old generation before subsequent admission")

    let wasmManifest = SignedExtensionPackageManifest(
        "review.wasm", "1.0.0", ">=1.0.0 <2.0.0", "1",
        "plugins/reviewer.wasm", ["review"], [],
        ["workspace.write", "network.access"], 1u32, "compatible",
        "sha256:wasm", "signature-wasm"
    )
    let wasmLaunch = match (validateIsolatedPluginPackage(
        wasmManifest, ExtensionExecutionKind.WasmComponent, 8u64,
        ["workspace.write", "network.access"], FixedPluginSignatureVerifier(true)
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    let wasmPort = RecordingPluginProcessPort("{\"accepted\":true}")
    let wasmHost = ProductIsolatedPluginHost(
        wasmPort, workspace, wasmRuntime: "wasmtime-fixture"
    )
    expect(wasmHost.mountInitial(wasmLaunch).isOk() && wasmHost.invoke(
        "review.wasm",
        IsolatedPluginInvocation("call-2", "review", encodeAgentValue(objectValue([])))
    ).isOk() && wasmPort.requests.size == 1 &&
        wasmPort.requests[0].executable == "wasmtime-fixture" &&
        wasmPort.requests[0].arguments[0] == workspace + "/plugins/reviewer.wasm" &&
        wasmPort.requests[0].sandboxMode == ProcessSandboxMode.WorkspaceReadWrite &&
        wasmPort.requests[0].networkAccess,
        "WASM plugin uses the fixed runtime and only its explicitly granted authorities")

    let truncated = RecordingPluginProcessPort("{}", truncated: true)
    let truncatedHost = ProductIsolatedPluginHost(truncated, workspace)
    expect(truncatedHost.mountInitial(processLaunch).isOk() && truncatedHost.invoke(
        "review.process",
        IsolatedPluginInvocation("call-3", "review", encodeAgentValue(objectValue([])))
    ).isError(), "truncated isolated plugin output fails closed")
    expect(validateIsolatedPluginPackage(
        SignedExtensionPackageManifest(
            "escape", "1", "1", "1", "../escape", [], [], [], 1u32,
            "none", "sha256:escape", "signature"
        ),
        ExtensionExecutionKind.ProcessPlugin, 1u64, [],
        FixedPluginSignatureVerifier(true)
    ).isOk() == false, "isolated plugin entrypoint cannot escape its package")
}

class FixedPluginSignatureVerifier <: ExtensionPackageSignatureVerifier {
    private let valid: Bool
    init(valid: Bool) { this.valid = valid }
    public func verify(_manifest: SignedExtensionPackageManifest): Bool {
        let _ = _manifest
        valid
    }
}

class ProductRemoteVerifier <: RemoteCapabilitySignatureVerifier {
    public func verify(
        _envelope: SignedRemoteCapabilityEnvelope,
        transportIdentity: String
    ): Bool {
        let _ = _envelope.id
        transportIdentity == "product-worker-key"
    }
}

class ProductRecordingRemoteTransport <: RemoteWorkerTransport {
    var dispatches: Int64 = 0

    public func dispatch(
        realm: RemoteExecutionRealm,
        envelope: SignedRemoteCapabilityEnvelope,
        request: RemoteExecutionRequest
    ): Result<AgentValue> {
        let _ = realm.id
        let _ = envelope.id
        let _ = request.routeKey
        dispatches += 1
        Result.Ok(objectValue([]))
    }
}

class RecordingPluginProcessPort <: ProcessPort {
    public let requests = ArrayList<ProcessRequest>()
    private let output: String
    private let truncated: Bool

    init(output: String, truncated!: Bool = false) {
        this.output = output
        this.truncated = truncated
    }

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        requests.add(request)
        Result.Ok(ProcessResult(0, stdout: output, truncated: truncated))
    }

    public func cancel(_operationId: OperationId): Result<Unit> {
        let _ = _operationId
        Result.Ok(())
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}
