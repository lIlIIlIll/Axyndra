package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func contextPrivateRequire<T>(result: Result<T>): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code)
    }
}

// Probe the actual shared aggregate through its public reservation API. No
// private usage getter, replacement pool or simulated release is involved.
private func contextPrivateAllocationPossible(): Bool {
    try {
        let actual = reserveNativeDocumentPayload(4194304)
        actual.close()
        true
    } catch (_: LogicalJsonPayloadError) { false }
}

private class ContextPrivateOutputFixture {
    let root: String
    let database: SqliteDatabase
    let artifacts: HostArtifactStore
    init() {
        let actualRoot = Directory.createTemp("/tmp").toString()
        let actualDatabase = SqliteDatabase(actualRoot + "/state/state.sqlite")
        root = actualRoot
        database = actualDatabase
        artifacts = HostArtifactStore(actualRoot + "/state", database: Some(actualDatabase))
    }
    func blobs(): String { root + "/state/blobs" }
    func onlyPrivateFile(): String {
        let entries = Directory.readFrom(blobs())
        if (entries.size != 1) { throw IllegalStateException("expected one actual private writer file") }
        blobs() + "/" + entries[0].name
    }
    func expectUnpublished(): Unit {
        for (table in ["artifacts", "operations", "operation_receipts", "audit_events", "items", "plugin_documents"]) {
            @Expect(database.scalarInt("SELECT COUNT(*) FROM " + table), 0)
        }
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}

private class ContextPrivateCleanupProbe {
    var path = ""
    var saved = ""
    var blocked = false
    func blockActualPath(path: String): Unit {
        this.path = path
        saved = path + ".owned"
        rename(path, to: saved, overwrite: false)
        Directory.create(path)
        // A nonempty directory makes the original nonrecursive remove fail.
        File.writeTo(path + "/blocker", "actual cleanup must retry".toArray())
        blocked = true
    }
    func restoreActualFile(): Unit {
        if (blocked) {
            remove(path, recursive: true)
            rename(saved, to: path, overwrite: false)
            blocked = false
        }
    }
}

private func contextPrivateFinishedWriter(owner: HostDocumentDataSession, raw: String): HostServiceArtifactWriter {
    let writer = contextPrivateRequire(owner.newWriter())
    if (raw.size > 0) { contextPrivateRequire(writer.append(0, raw, 4096)) }
    contextPrivateRequire(writer.finish(raw.size, modelPolicySha256Text(raw)))
    writer
}

// These are private data/ownership contracts. They create no canonical Source,
// document grant, Run, ToolCall or Receipt; each actual SQLite table stays empty.
@Test
class ContextPrivateOutputTests {
    @TestCase
    func sameSessionPrivateFileRemainsUnpublishedAndDecodedUntilConsumerAck(): Unit {
        let fixture = ContextPrivateOutputFixture()
        let pressure = reserveNativeDocumentPayload(8388608)
        pressure.ensureRetainedPeak(nativeControlMetadataCapacity113() - 67108864)
        let owner = fixture.artifacts.documentDataSession()
        try {
            @Expect(contextPrivateAllocationPossible())
            let raw = encodeAgentValue(objectValue([ValueField("body", textValue("opaque雪")), ValueField("ready", boolValue(true))]))
            let currentCalls = AtomicInt64(0)
            let result = owner.run({ session =>
                let writer = contextPrivateFinishedWriter(session, raw)
                @Expect(Directory.readFrom(fixture.blobs()).size, 1)
                fixture.expectUnpublished()
                session.readPrivateContextValue(writer, 4096, { =>
                    currentCalls.fetchAdd(1); Result<Unit>.Ok(()) })
            })
            @Expect(result.isOk())
            let value = contextPrivateRequire(result)
            @Expect(encodeAgentValue(value), raw)
            @Expect(currentCalls.load() > 0)
            @Expect(Directory.readFrom(fixture.blobs()).size, 0)
            fixture.expectUnpublished()
            // Hold all but the original 64 MiB window. The 32 MiB probe fits
            // before decoding, but not while the actual output is retained.
            @Expect(!contextPrivateAllocationPossible())
            let unacknowledged = owner.close()
            @Expect(unacknowledged.isError())
            @Expect(unacknowledged.error().getOrThrow().code, "plugin.document_result_ack_pending")
            @Expect(!owner.collect())
            @Expect(!contextPrivateAllocationPossible())
            let output = HostContextWindowQueryOutput(value, owner)
            @Expect(encodeAgentValue(output.value), raw)
            contextPrivateRequire(output.close())
            contextPrivateRequire(output.close())
            @Expect(owner.collect())
            @Expect(contextPrivateAllocationPossible())
            fixture.expectUnpublished()
        } finally {
            try { owner.acknowledgeOutput(); contextPrivateRequire(owner.close()) }
            finally { pressure.close(); fixture.close() }
        }
    }

    @TestCase
    func foreignUnfinishedWriterIsRejectedBeforeCurrentOrPrivateFileLookup(): Unit {
        let fixture = ContextPrivateOutputFixture()
        let writerOwner = fixture.artifacts.documentDataSession()
        let target = fixture.artifacts.documentDataSession()
        let currentCalls = AtomicInt64(0)
        try {
            let original = writerOwner.run({ session =>
                let otherWriter = contextPrivateRequire(session.newWriter())
                contextPrivateRequire(otherWriter.append(0, "unfinished", 4096))
                @Expect(Directory.readFrom(fixture.blobs()).size, 1)
                let result = target.run({ actual => actual.readPrivateContextValue(otherWriter, 4096, { =>
                    currentCalls.fetchAdd(1); Result<Unit>.Ok(()) }) })
                @Expect(result.isError())
                @Expect(result.error().getOrThrow().code, "context.document_result_owner")
                @Expect(currentCalls.load(), 0)
                // The unfinished foreign writer cannot even supply completed
                // metadata. Ownership rejection precedes that lookup and fd IO.
                @Expect(Directory.readFrom(fixture.blobs()).size, 1)
                fixture.expectUnpublished()
                Result<AgentValue>.Ok(nullValue())
            })
            @Expect(original.isOk())
            @Expect(Directory.readFrom(fixture.blobs()).size, 0)
            @Expect(target.collect())
            fixture.expectUnpublished()
        } finally { contextPrivateRequire(target.close()); contextPrivateRequire(writerOwner.close()); fixture.close() }
    }

    @TestCase
    func incompleteAndWrongDigestOutputsNeverOpenPrivateDecoder(): Unit {
        let fixture = ContextPrivateOutputFixture()
        try {
            for (mode in ["incomplete", "digest"]) {
                let owner = fixture.artifacts.documentDataSession()
                let callbacks = AtomicInt64(0)
                try {
                    let result = owner.run({ session =>
                        let writer = contextPrivateRequire(session.newWriter())
                        contextPrivateRequire(writer.append(0, "null", 4096))
                        let finished = if (mode == "incomplete") {
                            writer.finish(5, modelPolicySha256Text("null"))
                        } else { writer.finish(4, modelPolicySha256Text("true")) }
                        @Expect(finished.isError())
                        @Expect(finished.error().getOrThrow().code,
                            if (mode == "incomplete") { "artifact.stream_incomplete" } else { "artifact.stream_digest_mismatch" })
                        let decoded = writer.withPrivateContextResultInput({ =>
                            callbacks.fetchAdd(1); Result<Unit>.Ok(()) }, { _, _ =>
                            callbacks.fetchAdd(1); Result<AgentValue>.Ok(nullValue()) })
                        @Expect(decoded.isError())
                        @Expect(decoded.error().getOrThrow().code, "context.document_result_closed")
                        @Expect(callbacks.load(), 0)
                        fixture.expectUnpublished()
                        Result<AgentValue>.Ok(nullValue())
                    })
                    @Expect(result.isOk())
                    @Expect(owner.collect())
                    @Expect(Directory.readFrom(fixture.blobs()).size, 0)
                    fixture.expectUnpublished()
                } finally { contextPrivateRequire(owner.close()) }
            }
        } finally { fixture.close() }
    }

    @TestCase
    func sameLengthTamperAndTruncationNeverPublishOrReturnDecodedValue(): Unit {
        let fixture = ContextPrivateOutputFixture()
        try {
            for (mode in ["same-length", "truncated"]) {
                let owner = fixture.artifacts.documentDataSession()
                try {
                    let result = owner.run({ session =>
                        let writer = contextPrivateFinishedWriter(session, "null")
                        let path = fixture.onlyPrivateFile()
                        File.writeTo(path, (if (mode == "same-length") { "true" } else { "nul" }).toArray())
                        fixture.expectUnpublished()
                        session.readPrivateContextValue(writer, 4096, { => Result<Unit>.Ok(()) })
                    })
                    @Expect(result.isError())
                    @Expect(result.error().getOrThrow().code,
                        if (mode == "same-length") { "context.document_result_changed" } else { "plugin.document_payload_file_changed" })
                    @Expect(owner.collect())
                    @Expect(Directory.readFrom(fixture.blobs()).size, 0)
                    fixture.expectUnpublished()
                } finally { contextPrivateRequire(owner.close()) }
            }
        } finally { fixture.close() }
    }

    @TestCase
    func noncanonicalEmptyAndOverBoundPrivateValuesFailClosed(): Unit {
        let fixture = ContextPrivateOutputFixture()
        try {
            for (mode in ["noncanonical", "empty", "over-bound"]) {
                let owner = fixture.artifacts.documentDataSession()
                let currentCalls = AtomicInt64(0)
                try {
                    let raw = if (mode == "noncanonical") { " null" } else if (mode == "empty") { "" } else { "null" }
                    let result = owner.run({ session =>
                        let writer = contextPrivateFinishedWriter(session, raw)
                        session.readPrivateContextValue(writer, if (mode == "over-bound") { 3 } else { 4096 }, { =>
                            currentCalls.fetchAdd(1); Result<Unit>.Ok(()) })
                    })
                    @Expect(result.isError())
                    @Expect(result.error().getOrThrow().code,
                        if (mode == "noncanonical") { "context.document_result_codec" } else { "context.document_result_limit" })
                    if (mode != "noncanonical") { @Expect(currentCalls.load(), 0) }
                    @Expect(owner.collect())
                    @Expect(Directory.readFrom(fixture.blobs()).size, 0)
                    fixture.expectUnpublished()
                } finally { contextPrivateRequire(owner.close()) }
            }
        } finally { fixture.close() }
    }

    @TestCase
    func failedCleanupRetainsUnreturnedDecodedChargeUntilSameOwnerRetry(): Unit {
        let fixture = ContextPrivateOutputFixture()
        let pressure = reserveNativeDocumentPayload(8388608)
        pressure.ensureRetainedPeak(nativeControlMetadataCapacity113() - 67108864)
        let owner = fixture.artifacts.documentDataSession()
        let probe = ContextPrivateCleanupProbe()
        try {
            @Expect(contextPrivateAllocationPossible())
            let result = owner.run({ session =>
                let writer = contextPrivateFinishedWriter(session, "null")
                let actualPath = fixture.onlyPrivateFile()
                let decoded = session.readPrivateContextValue(writer, 4096, { => Result<Unit>.Ok(()) })
                @Expect(decoded.isOk())
                // Replace only the known fixture-owned temp path after the real
                // verifier has closed. A real removal failure precedes return.
                probe.blockActualPath(actualPath)
                decoded
            })
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "artifact.stream_cleanup_pending")
            @Expect(!contextPrivateAllocationPossible())
            @Expect(owner.close().isError())
            @Expect(!owner.collect())
            @Expect(!contextPrivateAllocationPossible())
            @Expect(exists(Path(probe.saved)))
            @Expect(exists(Path(probe.path + "/blocker")))
            fixture.expectUnpublished()
            probe.restoreActualFile()
            // No output object exists, so no consumer acknowledgement is
            // fabricated. Only the actual same-owner cleanup retry releases it.
            contextPrivateRequire(owner.close())
            @Expect(owner.collect())
            @Expect(contextPrivateAllocationPossible())
            @Expect(Directory.readFrom(fixture.blobs()).size, 0)
            fixture.expectUnpublished()
        } finally {
            try { probe.restoreActualFile(); contextPrivateRequire(owner.close()) }
            finally { pressure.close(); fixture.close() }
        }
    }
}
