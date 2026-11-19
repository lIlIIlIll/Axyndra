package artifact_contract

import yjson_support.*

import yjson.*

import agent_runtime.*
import agent_domain.*
import agent_product.*
import workspace_legacy_oracle.*
import shell_native_contract.*
import eval_native_contract.{NativeEvalContractBinding, nativeEvalStartChecked}
import agent_store.*
import agent_testkit.*
import persistence_runtime.*
import tool_runtime.*
import std.convert.*
import std.fs.*

let ONE_MIB: Int64 = 1048576

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        runStoreContract(root + "/store")
        runSqliteMetadataContract(root + "/sqlite")
        runToolContract(root + "/tools")
        runPersistenceFailureContract(root + "/failure")
        println("artifact contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func runSqliteMetadataContract(root: String): Unit {
    let state = root + "/state"
    let database = SqliteDatabase(state + "/state.db")
    let store = ProductArtifactStore(state, database: Some(database))
    let artifact = store.persistText("SQLite metadata").value().getOrThrow()
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM artifacts WHERE hash='" + artifact.sha256 + "'"
    ) == 1 && !exists(Path(metaPath(state, artifact.sha256))) &&
        readAll(store, artifact.reference) == "SQLite metadata",
        "production artifact metadata is canonical in SQLite while blob bodies remain files")
    database.close()
}

func runStoreContract(root: String): Unit {
    Directory.create(root, recursive: true)
    let state = root + "/state"
    let workspaceRoot = root + "/workspace"
    Directory.create(workspaceRoot, recursive: true)
    Directory.create(workspaceRoot + "/exports", recursive: true)
    let store = ProductArtifactStore(state)

    expect(
        store.persistText("").value().getOrThrow().sha256 ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" &&
        store.persistText("abc").value().getOrThrow().sha256 ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" &&
        store.persistText(repeatText("a", 1000000)).value().getOrThrow().sha256 ==
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        "SHA-256 matches the NIST empty, abc, and million-a vectors"
    )

    let small = store.capture("stdout", "small 输出 😀")
    let empty = store.capture("stderr", "")
    expect(
        !small.truncated && small.preview == "small 输出 😀" &&
        small.artifact.isNone() && small.error.isNone() &&
        empty.bytes == 0 && empty.preview == "" && empty.artifact.isNone(),
        "small and empty streams stay inline without unnecessary blobs"
    )

    // The head budget is 524208 bytes. Place a four-byte emoji so the raw
    // boundary would split it after one byte; the preview must back up to the
    // previous complete rune and still include the real tail.
    let unicodeLarge = repeatText("A", 524207) + "😀" +
        repeatText("B", 530000) + "\nTAIL-中文-🚀"
    let captured = store.capture("stdout", unicodeLarge)
    let artifact = captured.artifact.getOrThrow()
    expect(
        captured.truncated && captured.error.isNone() &&
        captured.preview.startsWith(repeatText("A", 32)) &&
        captured.preview.endsWith("TAIL-中文-🚀") &&
        captured.preview.contains("[omitted ") &&
        !captured.preview.contains("\u{FFFD}") &&
        captured.preview.toArray().size <= ONE_MIB,
        "head-tail preview is bounded and UTF-8 safe across an emoji boundary"
    )
    expect(
        artifact.reference ==
            "blob:sha256:c1f543daaf5398771c86529cfca05bf3b937959650a06ccf23df2df5a66cfc0b" &&
        artifact.sha256.size == 64 && artifact.bytes == unicodeLarge.toArray().size &&
        exists(Path(blobPath(state, artifact.sha256))) &&
        exists(Path(metaPath(state, artifact.sha256))) &&
        String.fromUtf8(File.readFrom(blobPath(state, artifact.sha256))) == unicodeLarge,
        "oversized text is stored completely under its lowercase SHA-256"
    )

    let duplicate = store.persistText(unicodeLarge).value().getOrThrow()
    expect(
        duplicate.reference == artifact.reference &&
        matchingArtifactFiles(state, artifact.sha256) == 2 &&
        noTemporaryArtifacts(state),
        "content addressing deduplicates blobs and leaves no temporary files"
    )

    let pageSource = repeatText("x", ONE_MIB - 2) + "😀" + "分页尾"
    let paged = store.persistText(pageSource).value().getOrThrow()
    let first = store.read(
        paged.reference,
        offset: 0,
        limit: ONE_MIB - 1
    ).value().getOrThrow()
    let second = store.read(
        paged.reference,
        offset: first.offset + first.returnedBytes,
        limit: ONE_MIB
    ).value().getOrThrow()
    expect(
        first.returnedBytes == ONE_MIB - 2 && first.truncated &&
        first.content + second.content == pageSource &&
        !first.content.contains("\u{FFFD}") && !second.content.contains("\u{FFFD}") &&
        !second.truncated,
        "byte pagination backs up at a split emoji and resumes without loss"
    )
    expect(
        store.read(paged.reference, offset: ONE_MIB - 1, limit: 10).error().getOrThrow().code ==
            "artifact.offset_not_utf8_boundary" &&
        store.read("blob:sha256:../../escape").error().getOrThrow().code == "artifact.ref_invalid" &&
        store.read("blob:sha256:" + paged.sha256.toAsciiUpper()).error().getOrThrow().code ==
            "artifact.ref_invalid",
        "artifact reads reject non-boundary offsets and noncanonical references"
    )

    let workspace = LocalWorkspace(workspaceRoot)
    let exported = exportProductArtifact(store, 
        paged.reference,
        workspace,
        "exports/page.txt"
    ).value().getOrThrow()
    expect(
        fieldText(exported, "artifact_ref") == paged.reference &&
        String.fromUtf8(File.readFrom(workspaceRoot + "/exports/page.txt")) == pageSource &&
        exportProductArtifact(store, paged.reference, workspace, root + "/outside.txt").error().getOrThrow().code ==
            "artifact.export_outside_workspace",
        "explicit export is atomic inside the workspace and rejects escape targets"
    )

    let corruptSource = repeatText("c", ONE_MIB + 17)
    let corrupt = store.persistText(corruptSource).value().getOrThrow()
    File.writeTo(blobPath(state, corrupt.sha256), "corrupt".toArray())
    expect(
        store.persistText(corruptSource).error().getOrThrow().code == "artifact.blob_corrupt" &&
        store.read(corrupt.reference).error().getOrThrow().code == "artifact.blob_corrupt",
        "an existing corrupt content-addressed blob is neither overwritten nor returned"
    )

    let symlinkState = root + "/symlink-state"
    Directory.create(symlinkState + "/blobs", recursive: true)
    let victim = root + "/victim.txt"
    File.writeTo(victim, "victim-safe".toArray())
    let symlinkSource = repeatText("s", ONE_MIB + 19)
    let symlinkHash = "d765bc3dd4045e8ae2a088e238d58542bdf1535d6bf11d1bf9b0f6c66704ffb6"
    SymbolicLink.create(blobPath(symlinkState, symlinkHash), to: victim)
    let symlinkStore = ProductArtifactStore(symlinkState)
    expect(
        symlinkStore.persistText(symlinkSource).error().getOrThrow().code == "artifact.blob_conflict" &&
        String.fromUtf8(File.readFrom(victim)) == "victim-safe" && noTemporaryArtifacts(symlinkState),
        "pre-planted symlinks cannot redirect artifact writes"
    )
}

func runToolContract(root: String): Unit {
    let workspaceRoot = root + "/workspace"
    Directory.create(workspaceRoot, recursive: true)
    Directory.create(workspaceRoot + "/exports", recursive: true)
    let scope = NativeShellContractScope(workspaceRoot, approvalMode: ApprovalMode.Yolo)
    try {
        let binding = scope.binding()
        let database = SqliteDatabase(binding.product.stateRoot + "/state.db")
        try { runArtifactTools(root, workspaceRoot, database, binding) } finally { database.close() }
    } finally { scope.close() }
}

private func runArtifactTools(root: String, workspaceRoot: String, database: SqliteDatabase,
    binding: NativeShellContractBinding): Unit {
    let workspace = LocalWorkspace(workspaceRoot)
    let store = ProductArtifactStore(binding.product.stateRoot, database: Some(database))
    let processes = LocalProcessPort(workspace, sandboxEnabled: true)
    let catalog = ToolCatalog()
    installLegacyLocalTools(
        catalog,
        workspace,
        processes,
        artifactStore: Some(store)
    ).value().getOrThrow()
    let pipeline = ToolPipeline(
        catalog,
        InMemoryOperationRuntimePort(),
        SqliteAuditRepository(database),
        ProductIds(),
        policy: DefaultCapabilityPolicy(
            mode: ApprovalMode.AlwaysAsk,
            allowWorkspaceWrites: true
        )
    )
    // A stricter authenticated request must survive selection of the independent read.
    let session = SessionId("artifact-session")
    binding.start(session)
    let first = binding.product.invokeShellTool(session,
        objectValue(
            [
                ValueField(
                    "command",
                    textValue(
                        "printf x >> bash-count.txt; /usr/bin/python3 -c 'import sys;" +
                        "sys.stdout.write(\"OUT-BEGIN\\n\"+\"o\"*1049000+\"\\nOUT-END\");" +
                        "sys.stderr.write(\"ERR-BEGIN\\n\"+\"e\"*1049010+\"\\nERR-END\")'"
                    )
                ),
                ValueField("timeout", integerValue(30))
            ]
        ), operatorOptions180: Some(ProductOperatorOptions180(approvalMode: ApprovalMode.AlwaysAsk))
    ).value().getOrThrow()
    let pending = first.approval().getOrThrow()
    let count = Path(workspaceRoot).join("bash-count.txt")
    expect(!exists(count), "oversized Bash must not execute before its own approval")
    first.decide(pending.operationId.value, ApprovalDecision.Approve).value().getOrThrow()
    let envelope = first.observedOutput().value().getOrThrow()
    let output = envelope.field("result").getOrThrow()
    expect(
        first.failure().isNone() && first.receiptId() != "" && fieldText(envelope, "status") == "complete" &&
        fieldBool(output, "truncated") &&
        fieldInteger(output, "stdoutBytes") > ONE_MIB && fieldInteger(output, "stderrBytes") > ONE_MIB &&
        output.field("artifacts").getOrThrow().items.size == 2 &&
        output.field("artifact_error").getOrThrow().unifiedKind == ValueKind.Null &&
        fieldText(output, "stdout").startsWith("OUT-BEGIN\n") && fieldText(output, "stdout").endsWith("OUT-END") &&
        fieldText(output, "stderr").startsWith("ERR-BEGIN\n") && fieldText(output, "stderr").endsWith("ERR-END") &&
        String.fromUtf8(File.readFrom(count)) == "x",
        "Bash preserves compatible previews plus complete dual-stream artifact metadata"
    )
    let stdoutRef = artifactRef(output, "stdout")
    let stderrRef = artifactRef(output, "stderr")
    expect(
        store.read(stdoutRef, limit: ONE_MIB).value().getOrThrow().content.startsWith("OUT-BEGIN\n") &&
        readAll(store, stdoutRef).endsWith("OUT-END") &&
        readAll(store, stderrRef).startsWith("ERR-BEGIN\n") &&
        readAll(store, stderrRef).endsWith("ERR-END"),
        "Bash artifact references retrieve the complete stdout and stderr"
    )
    let read = first.beginArtifactRead(stdoutRef).value().getOrThrow()
    try {
        let review = match (read.approval()) {
            case Some(request) => request
            case None => match (read.failure()) {
                case Some(error) => throw IllegalStateException("artifact read failed before review: " + error.code)
                case None => throw IllegalStateException("artifact read has no review; receipt=" + read.receiptId())
            }
        }
        expect(review.operationId.value != pending.operationId.value && !review.sessionApprovalAllowed &&
            read.decide(pending.operationId.value, ApprovalDecision.Approve).isError() &&
            read.approval().getOrThrow().operationId.value == review.operationId.value &&
            read.receiptId() == "" && read.output().isError(),
            "the Shell approval cannot expose the independent read's page")
        read.decide(review.operationId.value, ApprovalDecision.Approve).value().getOrThrow()
        let actual = read.output().value().getOrThrow()
        expect(read.receiptId() != "" && read.receiptId() != first.receiptId() &&
            fieldText(actual, "artifact_ref") == stdoutRef && fieldInteger(actual, "offset") == 0 &&
            fieldInteger(actual, "returned_bytes") == ONE_MIB && fieldBool(actual, "truncated") &&
            fieldText(actual, "content") == store.read(stdoutRef, limit: ONE_MIB).value().getOrThrow().content,
            "a separately approved ordinary Root returns the exact first page of the retained Shell output")
        expect(database.query("SELECT p.id FROM operation_receipts p JOIN operation_effect_records e " +
            "ON e.operation_id=p.operation_id AND e.reserved_receipt_id=p.id WHERE p.id=? AND p.operation_id=? " +
            "AND e.tool_id='read_resource' AND p.outcome='completed' AND NOT EXISTS " +
            "(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=p.operation_id)",
            [SqlParameter.Text(read.receiptId()), SqlParameter.Text(review.operationId.value)]).size == 1,
            "the approved page has its own completed Root Receipt")
    } finally { read.close().value().getOrThrow() }
    first.close().value().getOrThrow()

    let page = completedResult(
        executePipelineCall(pipeline,
            toolContext("read-run", "artifact-session"),
            ToolCall(
                "read-page",
                "read",
                objectValue(
                    [
                        ValueField("path", textValue(stdoutRef)),
                        ValueField("offset", integerValue(ONE_MIB)),
                        ValueField("limit", integerValue(128))
                    ]
                )
            )
        ),
        "read pages a blob reference without approval"
    )
    expect(
        fieldText(page.output, "artifact_ref") == stdoutRef &&
        fieldInteger(page.output, "returned_bytes") == 128 &&
        fieldInteger(page.output, "offset") == ONE_MIB,
        "read routes blob references to byte pagination instead of workspace path resolution"
    )

    let exportContext = toolContext("export-run", "artifact-session")
    let exportPending = pendingResult(
        executePipelineCall(pipeline,
            exportContext,
            ToolCall(
                "export-artifact",
                "read",
                objectValue(
                    [
                        ValueField("path", textValue(stdoutRef)),
                        ValueField("destination", textValue("exports/stdout.txt"))
                    ]
                )
            )
        ),
        "artifact export requests write approval"
    )
    expect(
        exportPending.capability.kind == CapabilityKind.WorkspaceWrite &&
        exportPending.capability.resource == workspaceRoot + "/exports/stdout.txt" &&
        exportPending.metadata.capabilityLabel == "workspace.write" &&
        exportPending.metadata.assessment.level == ApprovalRiskLevel.Medium &&
        containsString(exportPending.metadata.assessment.flags, "artifact_export") &&
        !exists(Path(workspaceRoot + "/exports/stdout.txt")),
        "read destination resolves to a real medium-risk WorkspaceWrite before execution"
    )
    let exported = completedResult(
        pipeline.decide(exportContext, exportPending.operationId, ApprovalDecision.Approve),
        "approved read destination exports the artifact"
    )
    expect(
        fieldText(exported.output, "artifact_ref") == stdoutRef &&
        String.fromUtf8(File.readFrom(workspaceRoot + "/exports/stdout.txt")) == readAll(store, stdoutRef),
        "approved read export atomically writes the complete artifact"
    )

    let outsideContext = toolContext("outside-run", "artifact-session")
    let outside = root + "/outside-never.txt"
    let outsidePending = pendingResult(
        executePipelineCall(pipeline,
            outsideContext,
            ToolCall(
                "outside-export",
                "read",
                objectValue(
                    [
                        ValueField("path", textValue(stdoutRef)),
                        ValueField("destination", textValue(outside))
                    ]
                )
            )
        ),
        "outside artifact export is classified before execution"
    )
    expect(
        outsidePending.capability.kind == CapabilityKind.WorkspaceWrite &&
        outsidePending.metadata.capabilityLabel == "outside-workspace.write" &&
        completedOrDeniedCode(
            pipeline.decide(outsideContext, outsidePending.operationId, ApprovalDecision.Approve)
        ) == "artifact.export_outside_workspace" && !exists(Path(outside)),
        "outside export remains denied even after a one-shot approval"
    )

    let sensitiveDenial = deniedResult(
        executePipelineCall(pipeline,
            toolContext("sensitive-run", "artifact-session"),
            ToolCall(
                "sensitive-export",
                "read",
                objectValue(
                    [
                        ValueField("path", textValue(stdoutRef)),
                        ValueField("destination", textValue(".ssh/secret.txt"))
                    ]
                )
            )
        ),
        "sensitive export is hard-denied without execution"
    )
    expect(
        sensitiveDenial.reason.code == "tool.hard_denied" &&
        sensitiveDenial.reason.message.contains("credential or protected system paths") &&
        !exists(Path(workspaceRoot + "/.ssh/secret.txt")),
        "sensitive export target is classified as a protected write and never executed"
    )

    let eval = NativeEvalContractBinding(binding.product, maxOutputBytes: 16777216, outputArtifacts: true)
    let evalThread = SessionId("eval-session")
    nativeEvalStartChecked(eval, evalThread)
    let app = ApplicationSession(binding.product, sessionId: Some(evalThread),
        operatorOptions180: Some(ProductOperatorOptions180(approvalMode: ApprovalMode.AlwaysAsk)))
    let cell = objectValue([ValueField("language", textValue("py")), ValueField("timeout", integerValue(30)),
        ValueField("code", textValue("import sys\n" +
            "count = open('eval-count.txt', 'a').write('x')\n" +
            "out_count = sys.stdout.write('EVAL-OUT-BEGIN\\n' + 'u' * 1049000 + '\\nEVAL-OUT-END')\n" +
            "err_count = sys.stderr.write('EVAL-ERR-BEGIN\\n' + 'v' * 1049010 + '\\nEVAL-ERR-END')\n"))])
    binding.product.fixtureProbe.getOrThrow().enqueueToolCallReply("eval-large", eval.name, cell)
    app.submit("Run the requested Python cell after approval.").value().getOrThrow()
    let approval = app.approval().getOrThrow()
    let marker = Path(workspaceRoot + "/eval-count.txt")
    expect(!exists(marker), "oversized Eval cannot execute before its own approval")
    app.decide(approval.operationId.value, ApprovalDecision.Approve).value().getOrThrow()
    for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(evalThread.value)).items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(id, _, _, envelope, isError) => if (id.value == "eval-large") {
                let result = envelope.field("result").getOrThrow()
                expect(!isError && fieldText(envelope, "status") == "complete" && fieldInteger(result, "exit_code") == 0 &&
                    fieldBool(result, "truncated") && result.field("artifacts").getOrThrow().items.size == 2 &&
                    readAll(store, artifactRef(result, "stdout")) == "EVAL-OUT-BEGIN\n" + repeatText("u", 1049000) + "\nEVAL-OUT-END" &&
                    readAll(store, artifactRef(result, "stderr")) == "EVAL-ERR-BEGIN\n" + repeatText("v", 1049010) + "\nEVAL-ERR-END" &&
                    String.fromUtf8(File.readFrom(marker)) == "x" &&
                    eval.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=? AND outcome='completed'",
                        parameters: [SqlParameter.Text(approval.operationId.value)]) == 1 &&
                    eval.count("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='service_artifact_observed'",
                        parameters: [SqlParameter.Text(approval.operationId.value)]) == 2,
                    "approved Eval retains both complete streams on its original Operation without replay")
                return
            }
            case _ => ()
        }
    }
    throw IllegalStateException("approved oversized Eval has no committed tool result")
}

func runPersistenceFailureContract(root: String): Unit {
    let workspaceRoot = root + "/workspace"
    Directory.create(workspaceRoot, recursive: true)
    let scope = NativeShellContractScope(workspaceRoot, approvalMode: ApprovalMode.AlwaysAsk)
    try {
        let binding = scope.binding()
        let thread = SessionId("failure-session")
        binding.start(thread)
        let call = binding.product.invokeShellTool(thread, objectValue([
            ValueField("command", textValue(
                "printf x >> failure-count.txt; /usr/bin/python3 -c 'print(\"f\"*1049000, end=\"\")'"))
        ])).value().getOrThrow()
        try {
            let pending = call.approval().getOrThrow()
            let count = Path(workspaceRoot + "/failure-count.txt")
            expect(call.receiptId() == "" && !exists(count), "artifact failure Bash needs its own approval")
            let blobs = binding.product.stateRoot + "/blobs"
            let saved = blobs + ".before-fault"
            let hadRoot = exists(Path(blobs))
            if (hadRoot) { rename(blobs, to: saved, overwrite: false) }
            try {
                File.writeTo(blobs, "not-a-directory".toArray())
                call.decide(pending.operationId.value, ApprovalDecision.Approve).value().getOrThrow()
                let envelope = call.observedOutput().value().getOrThrow()
                let output = envelope.field("result").getOrThrow()
                expect(call.failure().isNone() && call.receiptId() != "" &&
                    fieldText(envelope, "status") == "complete" && fieldInteger(output, "exitCode") == 0 &&
                    fieldBool(output, "truncated") && fieldInteger(output, "stdoutBytes") == 1049000 &&
                    output.field("artifacts").getOrThrow().items.isEmpty() &&
                    firstArtifactErrorCode(output) == "artifact.root_unsafe" &&
                    String.fromUtf8(File.readFrom(count)) == "x" &&
                    String.fromUtf8(File.readFrom(blobs)) == "not-a-directory" &&
                    binding.count("SELECT COUNT(*) FROM operation_receipts WHERE id=? AND operation_id=? AND " +
                        "outcome='completed'", parameters: [SqlParameter.Text(call.receiptId()),
                        SqlParameter.Text(pending.operationId.value)]) == 1 &&
                    binding.count("SELECT COUNT(*) FROM artifacts WHERE size=1049000") == 0 &&
                    binding.count("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND " +
                        "kind='service_artifact_observed'", parameters: [SqlParameter.Text(pending.operationId.value)]) == 0,
                    "storage failure preserves actual command exit and bytes without a retained artifact")
            } finally {
                let _ = removeIfExists(blobs)
                if (hadRoot) { rename(saved, to: blobs, overwrite: false) }
            }
        } finally { call.close().value().getOrThrow() }
    } finally { scope.close() }
}


func toolContext(run: String, session: String): ToolInvocationContext {
    ToolInvocationContext(
        RunId(run),
        SessionId(session),
        CapabilitySet(
            values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite),
                Capability(CapabilityKind.ProcessSpawn)
            ]
        )
    )
}

func pendingResult(value: Result<ToolInvocationResult>, message: String): ApprovalRequest {
    match (value) {
        case Result.Ok(ToolInvocationResult.NeedsApproval(request)) => request
        case Result.Ok(_) => throw IllegalStateException(message + ": did not request approval")
        case Result.Err(error) => throw IllegalStateException(message + ": " + error.describe())
    }
}

func completedResult(value: Result<ToolInvocationResult>, message: String): ToolResult {
    match (value) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result
        case Result.Ok(ToolInvocationResult.Denied(denial)) =>
            throw IllegalStateException(message + ": denied: " + denial.reason.describe())
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
            throw IllegalStateException(message + ": still awaiting approval")
        case Result.Err(error) => throw IllegalStateException(message + ": " + error.describe())
    }
}

func deniedResult(value: Result<ToolInvocationResult>, message: String): ToolDenial {
    match (value) {
        case Result.Ok(ToolInvocationResult.Denied(denial)) => denial
        case Result.Ok(_) => throw IllegalStateException(message + ": was not denied")
        case Result.Err(error) => throw IllegalStateException(message + ": " + error.describe())
    }
}

func completedOrDeniedCode(value: Result<ToolInvocationResult>): String {
    match (value) {
        case Result.Ok(ToolInvocationResult.Denied(denial)) => denial.reason.code
        case Result.Ok(ToolInvocationResult.Completed(result)) => if (result.isError) {
            fieldText(result.output, "error")
        } else {
            "completed"
        }
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) => "pending"
        case Result.Err(error) => error.code
    }
}

func artifactRef(output: AgentValue, stream: String): String {
    let artifacts = output.field("artifacts").getOrThrow()
    for (value in artifacts.items where fieldText(value, "stream") == stream) {
        return fieldText(value, "ref")
    }
    throw IllegalStateException("missing " + stream + " artifact")
}

func firstArtifactErrorCode(output: AgentValue): String {
    let error = output.field("artifact_error").getOrThrow()
    if (error.unifiedKind != ValueKind.Object) {
        return ""
    }
    let errors = error.field("errors").getOrThrow()
    if (errors.items.isEmpty()) {
        return ""
    }
    fieldText(errors.items[0], "code")
}

func readAll(store: ProductArtifactStore, reference: String): String {
    var offset: Int64 = 0
    var result = ""
    while (true) {
        let page = store.read(reference, offset: offset, limit: ONE_MIB).value().getOrThrow()
        result += page.content
        offset += page.returnedBytes
        if (!page.truncated) {
            return result
        }
        expect(page.returnedBytes > 0, "artifact pagination must make progress")
    }
    result
}

func fieldText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func fieldInteger(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Number) {
            try { Int64.parse(item.asNumberText()) } catch (_: Exception) { -1 }
        } else {
            -1
        }
        case None => -1
    }
}

func fieldBool(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.unifiedKind == ValueKind.Boolean && item.asBool()
        case None => false
    }
}

func containsString(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func repeatText(value: String, count: Int64): String {
    var remaining = count
    var chunk = value
    var result = ""
    while (remaining > 0) {
        if (remaining % 2 == 1) {
            result += chunk
        }
        remaining /= 2
        if (remaining > 0) {
            chunk += chunk
        }
    }
    result
}

func blobPath(state: String, hash: String): String {
    state + "/blobs/" + hash + ".txt"
}

func metaPath(state: String, hash: String): String {
    state + "/blobs/" + hash + ".json"
}

func matchingArtifactFiles(state: String, hash: String): Int64 {
    var count: Int64 = 0
    for (entry in Directory.readFrom(state + "/blobs") where entry.name.startsWith(hash + ".")) {
        count++
    }
    count
}

func noTemporaryArtifacts(state: String): Bool {
    if (!exists(Path(state + "/blobs")) || !FileInfo(Path(state + "/blobs")).isDirectory()) {
        return true
    }
    for (entry in Directory.readFrom(state + "/blobs") where entry.name.startsWith("tmpFile")) {
        return false
    }
    true
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
