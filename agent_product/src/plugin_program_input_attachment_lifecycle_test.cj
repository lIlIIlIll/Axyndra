package agent_product

import agent_domain.*
import agent_store.*
import agent_extension_runtime.{reserveNativeDocumentPayload}
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// This observes the existing aggregate through its actual allocation API.
// A failed probe closes its own attempted reservation and releases no other owner.
private func inputAttachmentSixtyFourMiBAvailable(): Bool {
    try {
        let reservation = reserveNativeDocumentPayload(8388608)
        reservation.close()
        true
    } catch (_: LogicalJsonPayloadError) { false }
}

private class InputAttachmentPartialFileProbe {
    private let directory: String
    private let completedName: String
    private let completeBytes: Int64
    var path = ""
    var saved = ""
    var witnessedBytes: Int64 = 0
    private var blocked = false

    init(root: String, code: String) {
        directory = root + "/state/blobs"
        completedName = modelPolicySha256Text(code) + ".txt"
        completeBytes = code.size
    }
    func awaitPartial(): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        while (MonoTime.now() < deadline) {
            if (exists(Path(directory))) {
                let entries = Directory.readFrom(directory)
                // This new fixture has no preexisting blobs. Observe the sole
                // actual writer, never a path supplied by a plugin or DTO.
                if (entries.size == 1 && entries[0].name != completedName) {
                    let actual = directory + "/" + entries[0].name
                    let info = FileInfo(Path(actual))
                    if (info.isRegular() && !info.isSymbolicLink() && info.size > 0 && info.size < completeBytes) {
                        path = actual; witnessedBytes = info.size
                        return
                    }
                }
            }
            sleep(Duration.millisecond)
        }
        throw IllegalStateException("actual input writer did not expose a partial copy before the original five-second observation bound")
    }
    func blockActualPath(): Unit {
        if (path == "" || !path.startsWith(directory + "/") || witnessedBytes <= 0 || witnessedBytes >= completeBytes) {
            throw IllegalStateException("cleanup probe requires its actual partial writer")
        }
        saved = path + ".owned"
        rename(path, to: saved, overwrite: false)
        Directory.create(path)
        blocked = true
        File.writeTo(path + "/blocker", "same actual writer must retain cleanup ownership".toArray())
    }
    func restoreActualPath(): Unit {
        if (blocked) {
            remove(path, recursive: true)
            rename(saved, to: path, overwrite: false)
            blocked = false
        }
    }
    func expectBlocked(): Unit {
        @Expect(blocked)
        @Expect(exists(Path(saved)))
        @Expect(exists(Path(path + "/blocker")))
    }
    func expectNoPrivateFiles(): Unit {
        if (exists(Path(directory))) { @Expect(Directory.readFrom(directory).size, 0) }
    }
}

private func inputAttachmentLongLiteral(): String {
    // A valid original Program literal plus whitespace, below the original
    // 262144 source ceiling and far above one actual 16384-byte file chunk.
    "return 7;" + String.fromUtf8(Array<Byte>(245760, repeat: b' '))
}

private func inputAttachmentExpectNoPublication(f: ProgramDelegationFixture, thread: String): Unit {
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 0)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
    @Expect(f.children(thread), 0)
    let receipts = f.database.query("SELECT receipt.id,receipt.outcome,e.reserved_receipt_id FROM operations o " +
        "JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id WHERE r.thread_id=?",
        [SqlParameter.Text(thread)])
    @Expect(receipts.size, 1)
    @Expect(receipts[0].required(0), receipts[0].required(2))
    @Expect(receipts[0].required(1), "cancelled")
}

@Test
class PluginProgramInputAttachmentLifecycleTests {
    @TestCase
    func cancellationAfterActualPartialCopyAcknowledgesItsOwnerWithoutPublishing(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        let thread = "input-attachment-mid-copy-cancel"
        let code = inputAttachmentLongLiteral()
        let probe = InputAttachmentPartialFileProbe(f.root, code)
        let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
        f.product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, f.name, f.input(code: code))
        let pending = spawn { session.submit("Cancel this actual input while its file is being copied.") }
        try {
            probe.awaitPartial()
            @Expect(probe.witnessedBytes > 0); @Expect(probe.witnessedBytes < code.size)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events a JOIN runs r ON r.id=a.run_id " +
                "WHERE r.thread_id='input-attachment-mid-copy-cancel' AND a.kind='operation_execution_handoff'"), 1)
            @Expect(session.cancel().isOk())
            let _ = pending.get()
            inputAttachmentExpectNoPublication(f, thread)
            probe.expectNoPrivateFiles()
            @Expect(inputAttachmentSixtyFourMiBAvailable())
            @Expect(f.product.threadItems(SessionId(thread)).isOk())
        } finally { let _ = session.cancel(); let _ = pending.get(); f.close() }
    }

    @TestCase
    func failedActualPartialWriterCleanupRetainsChargeAndStoreUntilSameOwnerRetry(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        let thread = "input-attachment-mid-copy-cleanup"
        let code = inputAttachmentLongLiteral()
        let probe = InputAttachmentPartialFileProbe(f.root, code)
        let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
        f.product.fixtureProbe.getOrThrow().enqueueToolCallReply(thread, f.name, f.input(code: code))
        @Expect(inputAttachmentSixtyFourMiBAvailable())
        var productClosed = false
        let pending = spawn { session.submit("Cancel this actual input and retry its failed writer cleanup.") }
        try {
            probe.awaitPartial()
            @Expect(probe.witnessedBytes > 0); @Expect(probe.witnessedBytes < code.size)
            probe.blockActualPath()
            @Expect(session.cancel().isOk())
            let _ = pending.get()
            inputAttachmentExpectNoPublication(f, thread)
            probe.expectBlocked()
            // The actual 64MiB owner plus its failed writer still occupies the
            // one shared 128MiB pool. No output exists, so no ACK is fabricated.
            @Expect(!inputAttachmentSixtyFourMiBAvailable())
            @Expect(f.product.close().isError())
            @Expect(!inputAttachmentSixtyFourMiBAvailable())
            // This method uses Product's own database, not the fixture's
            // separate connection: failed cleanup must not destroy the Store.
            let items = f.product.threadItems(SessionId(thread)).value().getOrThrow()
            @Expect(items.size > 0)
            probe.expectBlocked()
            probe.restoreActualPath()
            @Expect(f.product.close().isOk())
            productClosed = true
            @Expect(inputAttachmentSixtyFourMiBAvailable())
            probe.expectNoPrivateFiles()
        } finally {
            if (!productClosed) { let _ = session.cancel() }
            let _ = pending.get()
            probe.restoreActualPath(); f.close()
        }
    }

    @TestCase
    func actualTerminalToolErrorHoldsSharedChargeUntilItsConsumerPayloadAck(): Unit {
        let f = ProgramDelegationFixture(inputAttachment: true)
        try {
            @Expect(inputAttachmentSixtyFourMiBAvailable())
            let code = "return await fetch(\"https://forbidden.invalid\");"
            let budget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            let result = f.completed(f.direct("input-attachment-error-charge", f.input(code: code), budget))
            try {
                @Expect(result.isError); @Expect(result.payloadLease.isSome())
                @Expect(!inputAttachmentSixtyFourMiBAvailable())
                @Expect(result.receiptId != "")
                let ref = httpIntentText(result.output, "program_artifact")
                @Expect(ProductArtifactStore(f.root + "/state", database: Some(f.database)).read(ref).value().getOrThrow().content, code)
                @Expect(budget.snapshot().toolCalls, 1); @Expect(budget.snapshot().activeTools, 0)
                @Expect(f.children("input-attachment-error-charge"), 0)
                @Expect(f.product.close().isError())
                @Expect(!inputAttachmentSixtyFourMiBAvailable())
                @Expect(f.product.threadItems(SessionId("input-attachment-error-charge")).isOk())
            } finally { result.releasePayload() }
            @Expect(f.product.close().isOk())
            @Expect(inputAttachmentSixtyFourMiBAvailable())
        } finally { f.close() }
    }
}
