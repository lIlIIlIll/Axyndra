package agent_product

import agent_domain.*
import agent_store.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.overflow.*
import std.process.*
import std.sync.*

let PRODUCT_ARTIFACT_PREVIEW_BYTES: Int64 = 1048576
let PRODUCT_ARTIFACT_CONTENT_TYPE = "text/plain; charset=utf-8"
let PRODUCT_ARTIFACT_PREFIX = "blob:sha256:"

public class ProductArtifact {
    public let reference: String
    public let sha256: String
    public let bytes: Int64
    public let contentType: String

    public init(
        reference: String,
        sha256: String,
        bytes: Int64,
        contentType!: String = PRODUCT_ARTIFACT_CONTENT_TYPE
    ) {
        this.reference = reference
        this.sha256 = sha256
        this.bytes = bytes
        this.contentType = contentType
    }

    public func value(stream!: String = ""): AgentValue {
        let fields = ArrayList<ValueField>()
        if (stream != "") {
            fields.add(ValueField("stream", textValue(stream)))
        }
        fields.add(ValueField("ref", textValue(reference)))
        fields.add(ValueField("sha256", textValue(sha256)))
        fields.add(ValueField("bytes", integerValue(bytes)))
        fields.add(ValueField("content_type", textValue(contentType)))
        objectValue(fields.toArray())
    }
}

public class ProductArtifactRead {
    public let reference: String
    public let content: String
    public let bytes: Int64
    public let offset: Int64
    public let returnedBytes: Int64
    public let truncated: Bool
    public let contentType: String

    public init(
        reference: String,
        content: String,
        bytes: Int64,
        offset: Int64,
        returnedBytes: Int64,
        truncated: Bool,
        contentType!: String = PRODUCT_ARTIFACT_CONTENT_TYPE
    ) {
        this.reference = reference
        this.content = content
        this.bytes = bytes
        this.offset = offset
        this.returnedBytes = returnedBytes
        this.truncated = truncated
        this.contentType = contentType
    }

    public func value(): AgentValue {
        objectValue(
            [
                ValueField("path", textValue(reference)),
                ValueField("artifact_ref", textValue(reference)),
                ValueField("content", textValue(content)),
                ValueField("bytes", integerValue(bytes)),
                ValueField("returned_bytes", integerValue(returnedBytes)),
                ValueField("offset", integerValue(offset)),
                ValueField("truncated", boolValue(truncated)),
                ValueField("content_type", textValue(contentType)),
                ValueField("immutable", boolValue(true))
            ]
        )
    }
}

public class ProductArtifactCapture {
    public let stream: String
    public let preview: String
    public let bytes: Int64
    public let truncated: Bool
    public let artifact: ?ProductArtifact
    public let error: ?AgentError

    public init(
        stream: String,
        preview: String,
        bytes: Int64,
        truncated: Bool,
        artifact!: ?ProductArtifact = None,
        error!: ?AgentError = None
    ) {
        this.stream = stream
        this.preview = preview
        this.bytes = bytes
        this.truncated = truncated
        this.artifact = artifact
        this.error = error
    }
}

// Content-addressed storage for complete textual tool output. The store never
// accepts a filesystem path from a model: callers provide either text or a
// strictly validated blob:sha256 reference.
public class ProductArtifactStore {
    private let root: String
    private let previewBytes: Int64
    private let database: ?SqliteDatabase
    private let lock = Mutex()

    public init(
        stateRoot: String,
        previewBytes!: Int64 = PRODUCT_ARTIFACT_PREVIEW_BYTES,
        database!: ?SqliteDatabase = None
    ) {
        if (stateRoot.trimAscii() == "") {
            throw IllegalArgumentException("artifact state root must not be empty")
        }
        if (previewBytes < 256 || previewBytes > PRODUCT_ARTIFACT_PREVIEW_BYTES) {
            throw IllegalArgumentException("artifact preview limit must be between 256 bytes and 1 MiB")
        }
        this.root = Path(stateRoot).normalize().toString() + "/blobs"
        this.previewBytes = previewBytes
        this.database = database
    }

    public func capture(stream: String, content: String): ProductArtifactCapture {
        let bytes = content.toArray()
        if (bytes.size <= previewBytes) {
            return ProductArtifactCapture(stream, content, bytes.size, false)
        }
        let preview = artifactPreview(bytes, previewBytes)
        match (persistText(content)) {
            case Result.Ok(artifact) => ProductArtifactCapture(
                stream,
                preview,
                bytes.size,
                true,
                artifact: Some(artifact)
            )
            case Result.Err(error) => ProductArtifactCapture(
                stream,
                preview,
                bytes.size,
                true,
                error: Some(error)
            )
        }
    }

    // Explicit persistence is also the user-facing API used before exporting
    // a small value; normal Bash/Eval capture only calls it for oversized
    // streams.
    public func persistText(content: String): Result<ProductArtifact> {
        let bytes = content.toArray()
        let hash = artifactSha256(bytes)
        let artifact = ProductArtifact(
            PRODUCT_ARTIFACT_PREFIX + hash,
            hash,
            bytes.size
        )
        lock.lock()
        try {
            match (ensureArtifactRoot()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (persistArtifactFile(artifact, bytes)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (persistArtifactMetadata(artifact)) {
                case Result.Ok(_) => Result.Ok(artifact)
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    // Blob offsets and limits are byte based. The returned window is always
    // valid UTF-8 and is capped at one MiB even when a larger limit is asked.
    public func read(
        reference: String,
        offset!: Int64 = 0,
        limit!: Int64 = PRODUCT_ARTIFACT_PREVIEW_BYTES
    ): Result<ProductArtifactRead> {
        if (offset < 0) {
            return artifactError<ProductArtifactRead>(
                AgentErrorKind.InvalidInput,
                "artifact.offset_invalid",
                "artifact offset must not be negative",
                reference
            )
        }
        if (limit < 1) {
            return artifactError<ProductArtifactRead>(
                AgentErrorKind.InvalidInput,
                "artifact.limit_invalid",
                "artifact limit must be positive",
                reference
            )
        }
        let hash = match (artifactHash(reference)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        lock.lock()
        try {
            let bytes = match (validatedArtifactBytes(hash)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let start = min(offset, bytes.size)
            if (!artifactUtf8Boundary(bytes, start)) {
                return artifactError<ProductArtifactRead>(
                    AgentErrorKind.InvalidInput,
                    "artifact.offset_not_utf8_boundary",
                    "artifact offset must point to a UTF-8 boundary",
                    reference
                )
            }
            let requested = min(limit, PRODUCT_ARTIFACT_PREVIEW_BYTES)
            let prefix = artifactUtf8Prefix(bytes[start..], requested)
            if (prefix.isEmpty() && start < bytes.size) {
                return artifactError<ProductArtifactRead>(
                    AgentErrorKind.InvalidInput,
                    "artifact.limit_splits_utf8",
                    "artifact limit is too small to return the next UTF-8 character",
                    reference
                )
            }
            Result.Ok(
                ProductArtifactRead(
                    reference,
                    String.fromUtf8(prefix),
                    bytes.size,
                    start,
                    prefix.size,
                    start + prefix.size < bytes.size
                )
            )
        } finally {
            lock.unlock()
        }
    }

    public func export(
        reference: String,
        workspace: LocalWorkspace,
        destination: String
    ): Result<AgentValue> {
        let target = match (workspace.inspectWriteTarget(destination)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (target.permissionClass != "workspace.write") {
            return artifactError<AgentValue>(
                AgentErrorKind.PermissionDenied,
                "artifact.export_outside_workspace",
                "artifact export destination must resolve inside the workspace",
                reference
            )
        }
        let hash = match (artifactHash(reference)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let content = lockAndReadText(hash)
        let source = match (content) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (workspace.writeFile(destination, source)) {
            case Result.Ok(_) => Result.Ok(
                objectValue(
                    [
                        ValueField("artifact_ref", textValue(reference)),
                        ValueField("path", textValue(target.normalizedPath)),
                        ValueField("bytes", integerValue(source.toArray().size)),
                        ValueField("content_type", textValue(PRODUCT_ARTIFACT_CONTENT_TYPE))
                    ]
                )
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func lockAndReadText(hash: String): Result<String> {
        lock.lock()
        try {
            match (validatedArtifactBytes(hash)) {
                case Result.Ok(bytes) => Result.Ok(String.fromUtf8(bytes))
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    private func ensureArtifactRoot(): Result<Unit> {
        try {
            if (!exists(Path(root))) {
                Directory.create(root, recursive: true)
            }
            let info = FileInfo(Path(root))
            if (!info.isDirectory() || info.isSymbolicLink()) {
                return artifactError<Unit>(
                    AgentErrorKind.PermissionDenied,
                    "artifact.root_unsafe",
                    "artifact root must be a real directory",
                    root
                )
            }
            artifactChmod(root, "700")
        } catch (error: Exception) {
            artifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.root_failed",
                error.message,
                root
            )
        }
    }

    private func persistArtifactFile(
        artifact: ProductArtifact,
        bytes: Array<Byte>
    ): Result<Unit> {
        let path = blobPath(artifact.sha256)
        if (exists(Path(path))) {
            return validateExistingBlob(path, artifact.sha256, bytes.size)
        }
        match (atomicArtifactWrite(path, bytes)) {
            case Result.Ok(_) => validateExistingBlob(path, artifact.sha256, bytes.size)
            case Result.Err(error) =>
                if (exists(Path(path))) {
                    validateExistingBlob(path, artifact.sha256, bytes.size)
                } else {
                    Result.Err(error)
                }
        }
    }

    private func persistArtifactMetadata(artifact: ProductArtifact): Result<Unit> {
        match (database) {
            case Some(value) => return persistArtifactMetadataRow(value, artifact)
            case None => ()
        }
        let path = metadataPath(artifact.sha256)
        let body = artifactMetadata(artifact).toArray()
        if (exists(Path(path))) {
            return validateExistingMetadata(path, body, artifact.reference)
        }
        match (atomicArtifactWrite(path, body)) {
            case Result.Ok(_) => validateExistingMetadata(path, body, artifact.reference)
            case Result.Err(error) =>
                if (exists(Path(path))) {
                    validateExistingMetadata(path, body, artifact.reference)
                } else {
                    Result.Err(error)
                }
        }
    }

    private func validatedArtifactBytes(hash: String): Result<Array<Byte>> {
        let path = blobPath(hash)
        let meta = metadataPath(hash)
        let metadataExists = match (database) {
            case Some(value) => value.scalarInt(
                "SELECT COUNT(*) FROM artifacts WHERE hash=" + sqliteText(hash)
            ) == 1
            case None => exists(Path(meta))
        }
        if (!exists(Path(path)) || !metadataExists) {
            return artifactError<Array<Byte>>(
                AgentErrorKind.InvalidInput,
                "artifact.not_found",
                "artifact blob or metadata does not exist",
                PRODUCT_ARTIFACT_PREFIX + hash
            )
        }
        try {
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink()) {
                return artifactError<Array<Byte>>(
                    AgentErrorKind.PermissionDenied,
                    "artifact.blob_unsafe",
                    "artifact blob must be a regular non-symlink file",
                    PRODUCT_ARTIFACT_PREFIX + hash
                )
            }
            let bytes = File.readFrom(path)
            if (artifactSha256(bytes) != hash) {
                return artifactError<Array<Byte>>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_corrupt",
                    "artifact blob does not match its SHA-256 name",
                    PRODUCT_ARTIFACT_PREFIX + hash
                )
            }
            let artifact = ProductArtifact(
                PRODUCT_ARTIFACT_PREFIX + hash,
                hash,
                bytes.size
            )
            let metadataValidation = match (database) {
                case Some(value) => validateArtifactMetadataRow(value, artifact)
                case None => validateExistingMetadata(
                    meta,
                    artifactMetadata(artifact).toArray(),
                    artifact.reference
                )
            }
            match (metadataValidation) {
                case Result.Ok(_) => Result.Ok(bytes)
                case Result.Err(error) => Result.Err(error)
            }
        } catch (error: Exception) {
            artifactError<Array<Byte>>(
                AgentErrorKind.Internal,
                "artifact.read_failed",
                error.message,
                PRODUCT_ARTIFACT_PREFIX + hash
            )
        }
    }

    private func validateExistingBlob(
        path: String,
        expectedHash: String,
        expectedBytes: Int64
    ): Result<Unit> {
        try {
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink()) {
                return artifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_conflict",
                    "existing artifact blob is not a safe regular file",
                    PRODUCT_ARTIFACT_PREFIX + expectedHash
                )
            }
            if (info.size != expectedBytes) {
                return artifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_corrupt",
                    "existing artifact blob has a different byte length",
                    PRODUCT_ARTIFACT_PREFIX + expectedHash
                )
            }
            let actual = artifactSha256(File.readFrom(path))
            if (actual != expectedHash) {
                return artifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.blob_corrupt",
                    "existing artifact blob does not match its SHA-256 name",
                    PRODUCT_ARTIFACT_PREFIX + expectedHash
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            artifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.blob_validate_failed",
                error.message,
                PRODUCT_ARTIFACT_PREFIX + expectedHash
            )
        }
    }

    private func validateExistingMetadata(
        path: String,
        expected: Array<Byte>,
        reference: String
    ): Result<Unit> {
        try {
            let info = FileInfo(Path(path))
            if (!info.isRegular() || info.isSymbolicLink()) {
                return artifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.metadata_conflict",
                    "existing artifact metadata is not a safe regular file",
                    reference
                )
            }
            if (File.readFrom(path) != expected) {
                return artifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.metadata_corrupt",
                    "existing artifact metadata does not match the blob",
                    reference
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            artifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.metadata_validate_failed",
                error.message,
                reference
            )
        }
    }

    private func blobPath(hash: String): String {
        root + "/" + hash + ".txt"
    }

    private func metadataPath(hash: String): String {
        root + "/" + hash + ".json"
    }

    private func persistArtifactMetadataRow(
        database: SqliteDatabase,
        artifact: ProductArtifact
    ): Result<Unit> {
        try {
            database.execute(
                "INSERT OR IGNORE INTO artifacts(hash,mime,size,metadata,relative_path) VALUES(" +
                    sqliteText(artifact.sha256) + "," + sqliteText(artifact.contentType) + "," +
                    artifact.bytes.toString() + "," + sqliteText(artifactMetadata(artifact)) + "," +
                    sqliteText("blobs/" + artifact.sha256 + ".txt") + ")"
            )
            validateArtifactMetadataRow(database, artifact)
        } catch (error: Exception) {
            artifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.metadata_commit_failed",
                error.message,
                artifact.reference
            )
        }
    }

    private func validateArtifactMetadataRow(
        database: SqliteDatabase,
        artifact: ProductArtifact
    ): Result<Unit> {
        try {
            let rows = database.query(
                "SELECT mime,size,metadata,relative_path FROM artifacts WHERE hash=" +
                    sqliteText(artifact.sha256)
            )
            if (rows.size != 1 || rows[0].required(0) != artifact.contentType ||
                Int64.parse(rows[0].required(1)) != artifact.bytes ||
                rows[0].required(2) != artifactMetadata(artifact) ||
                rows[0].required(3) != "blobs/" + artifact.sha256 + ".txt") {
                return artifactError<Unit>(
                    AgentErrorKind.Conflict,
                    "artifact.metadata_corrupt",
                    "artifact metadata row does not match the blob",
                    artifact.reference
                )
            }
            Result.Ok(())
        } catch (error: Exception) {
            artifactError<Unit>(
                AgentErrorKind.Internal,
                "artifact.metadata_validate_failed",
                error.message,
                artifact.reference
            )
        }
    }
}

class ProductProcessArtifactCapture {
    let stdout: ProductArtifactCapture
    let stderr: ProductArtifactCapture

    init(
        store: ?ProductArtifactStore,
        stdout: String,
        stderr: String
    ) {
        this.stdout = captureProductArtifactStream(store, "stdout", stdout)
        this.stderr = captureProductArtifactStream(store, "stderr", stderr)
    }

    func artifactsValue(): AgentValue {
        let values = ArrayList<AgentValue>()
        match (stdout.artifact) {
            case Some(value) => values.add(value.value(stream: "stdout"))
            case None => ()
        }
        match (stderr.artifact) {
            case Some(value) => values.add(value.value(stream: "stderr"))
            case None => ()
        }
        listValue(values.toArray())
    }

    func errorValue(): AgentValue {
        let values = ArrayList<AgentValue>()
        addArtifactCaptureError(values, stdout)
        addArtifactCaptureError(values, stderr)
        if (values.isEmpty()) {
            return nullValue()
        }
        objectValue([ValueField("errors", listValue(values.toArray()))])
    }
}

func captureProductProcessArtifacts(
    store: ?ProductArtifactStore,
    stdout: String,
    stderr: String
): ProductProcessArtifactCapture {
    ProductProcessArtifactCapture(store, stdout, stderr)
}

func captureProductArtifactStream(
    store: ?ProductArtifactStore,
    stream: String,
    content: String
): ProductArtifactCapture {
    let bytes = content.toArray()
    if (bytes.size <= PRODUCT_ARTIFACT_PREVIEW_BYTES) {
        return ProductArtifactCapture(stream, content, bytes.size, false)
    }
    match (store) {
        case Some(value) => value.capture(stream, content)
        case None => ProductArtifactCapture(
            stream,
            artifactPreview(bytes, PRODUCT_ARTIFACT_PREVIEW_BYTES),
            bytes.size,
            true,
            error: Some(
                AgentError(
                    AgentErrorKind.Configuration,
                    "artifact.store_unavailable",
                    "complete oversized output could not be stored because no artifact store is installed",
                    fields: [ErrorField("stream", stream)]
                )
            )
        )
    }
}

func addArtifactCaptureError(
    values: ArrayList<AgentValue>,
    capture: ProductArtifactCapture
): Unit {
    match (capture.error) {
        case Some(error) => values.add(
            objectValue(
                [
                    ValueField("stream", textValue(capture.stream)),
                    ValueField("code", textValue(error.code)),
                    ValueField("message", textValue(error.message))
                ]
            )
        )
        case None => ()
    }
}

public func isProductArtifactReference(value: String): Bool {
    value.startsWith("blob:")
}

func artifactHash(reference: String): Result<String> {
    if (!reference.startsWith(PRODUCT_ARTIFACT_PREFIX)) {
        return artifactError<String>(
            AgentErrorKind.InvalidInput,
            "artifact.ref_invalid",
            "artifact reference must use blob:sha256:<64 lowercase hex>",
            reference
        )
    }
    let hash = reference[PRODUCT_ARTIFACT_PREFIX.size..]
    if (hash.size != 64) {
        return artifactError<String>(
            AgentErrorKind.InvalidInput,
            "artifact.ref_invalid",
            "artifact reference must contain exactly 64 lowercase hex characters",
            reference
        )
    }
    for (byte in hash.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return artifactError<String>(
                AgentErrorKind.InvalidInput,
                "artifact.ref_invalid",
                "artifact reference must contain exactly 64 lowercase hex characters",
                reference
            )
        }
    }
    Result.Ok(hash)
}

func artifactSha256(bytes: Array<Byte>): String {
    let roundConstants: Array<UInt32> = [
        0x428a2f98u32, 0x71374491u32, 0xb5c0fbcfu32, 0xe9b5dba5u32,
        0x3956c25bu32, 0x59f111f1u32, 0x923f82a4u32, 0xab1c5ed5u32,
        0xd807aa98u32, 0x12835b01u32, 0x243185beu32, 0x550c7dc3u32,
        0x72be5d74u32, 0x80deb1feu32, 0x9bdc06a7u32, 0xc19bf174u32,
        0xe49b69c1u32, 0xefbe4786u32, 0x0fc19dc6u32, 0x240ca1ccu32,
        0x2de92c6fu32, 0x4a7484aau32, 0x5cb0a9dcu32, 0x76f988dau32,
        0x983e5152u32, 0xa831c66du32, 0xb00327c8u32, 0xbf597fc7u32,
        0xc6e00bf3u32, 0xd5a79147u32, 0x06ca6351u32, 0x14292967u32,
        0x27b70a85u32, 0x2e1b2138u32, 0x4d2c6dfcu32, 0x53380d13u32,
        0x650a7354u32, 0x766a0abbu32, 0x81c2c92eu32, 0x92722c85u32,
        0xa2bfe8a1u32, 0xa81a664bu32, 0xc24b8b70u32, 0xc76c51a3u32,
        0xd192e819u32, 0xd6990624u32, 0xf40e3585u32, 0x106aa070u32,
        0x19a4c116u32, 0x1e376c08u32, 0x2748774cu32, 0x34b0bcb5u32,
        0x391c0cb3u32, 0x4ed8aa4au32, 0x5b9cca4fu32, 0x682e6ff3u32,
        0x748f82eeu32, 0x78a5636fu32, 0x84c87814u32, 0x8cc70208u32,
        0x90befffau32, 0xa4506cebu32, 0xbef9a3f7u32, 0xc67178f2u32
    ]
    var state0 = 0x6a09e667u32
    var state1 = 0xbb67ae85u32
    var state2 = 0x3c6ef372u32
    var state3 = 0xa54ff53au32
    var state4 = 0x510e527fu32
    var state5 = 0x9b05688cu32
    var state6 = 0x1f83d9abu32
    var state7 = 0x5be0cd19u32
    let remainder = bytes.size % 64
    let zeroPadding = if (remainder <= 55) { 55 - remainder } else { 119 - remainder }
    let paddedSize = bytes.size + 1 + zeroPadding + 8
    let bitLength = UInt64(bytes.size).wrappingMul(8u64)
    var blockStart: Int64 = 0
    while (blockStart < paddedSize) {
        let schedule = Array<UInt32>(64, repeat: 0u32)
        for (index in 0..16) {
            let start = blockStart + index * 4
            schedule[index] =
                (UInt32(artifactShaPaddedByte(bytes, start, paddedSize, bitLength)) << 24) |
                (UInt32(artifactShaPaddedByte(bytes, start + 1, paddedSize, bitLength)) << 16) |
                (UInt32(artifactShaPaddedByte(bytes, start + 2, paddedSize, bitLength)) << 8) |
                UInt32(artifactShaPaddedByte(bytes, start + 3, paddedSize, bitLength))
        }
        for (index in 16..64) {
            let small0 = artifactShaRotateRight(schedule[index - 15], 7u32) ^
                artifactShaRotateRight(schedule[index - 15], 18u32) ^
                (schedule[index - 15] >> 3)
            let small1 = artifactShaRotateRight(schedule[index - 2], 17u32) ^
                artifactShaRotateRight(schedule[index - 2], 19u32) ^
                (schedule[index - 2] >> 10)
            schedule[index] = schedule[index - 16]
                .wrappingAdd(small0)
                .wrappingAdd(schedule[index - 7])
                .wrappingAdd(small1)
        }
        var a = state0
        var b = state1
        var c = state2
        var d = state3
        var e = state4
        var f = state5
        var g = state6
        var h = state7
        for (index in 0..64) {
            let big1 = artifactShaRotateRight(e, 6u32) ^
                artifactShaRotateRight(e, 11u32) ^ artifactShaRotateRight(e, 25u32)
            let choose = (e & f) ^ ((!e) & g)
            let temporary1 = h.wrappingAdd(big1)
                .wrappingAdd(choose)
                .wrappingAdd(roundConstants[index])
                .wrappingAdd(schedule[index])
            let big0 = artifactShaRotateRight(a, 2u32) ^
                artifactShaRotateRight(a, 13u32) ^ artifactShaRotateRight(a, 22u32)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = big0.wrappingAdd(majority)
            h = g
            g = f
            f = e
            e = d.wrappingAdd(temporary1)
            d = c
            c = b
            b = a
            a = temporary1.wrappingAdd(temporary2)
        }
        state0 = state0.wrappingAdd(a)
        state1 = state1.wrappingAdd(b)
        state2 = state2.wrappingAdd(c)
        state3 = state3.wrappingAdd(d)
        state4 = state4.wrappingAdd(e)
        state5 = state5.wrappingAdd(f)
        state6 = state6.wrappingAdd(g)
        state7 = state7.wrappingAdd(h)
        blockStart += 64
    }
    let hex = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f"
    ]
    var result = ""
    for (word in [state0, state1, state2, state3, state4, state5, state6, state7]) {
        for (shift in [24u32, 16u32, 8u32, 0u32]) {
            let value = Int64((word >> shift) & 0xffu32)
            result += hex[value / 16] + hex[value % 16]
        }
    }
    result
}

func artifactShaPaddedByte(
    bytes: Array<Byte>,
    index: Int64,
    paddedSize: Int64,
    bitLength: UInt64
): Byte {
    if (index < bytes.size) {
        return bytes[index]
    }
    if (index == bytes.size) {
        return 0x80u8
    }
    if (index >= paddedSize - 8) {
        let shift = UInt64((paddedSize - 1 - index) * 8)
        return UInt8((bitLength >> shift) & 0xffu64)
    }
    0u8
}

func artifactShaRotateRight(value: UInt32, distance: UInt32): UInt32 {
    (value >> distance) | (value << (32u32 - distance))
}

func artifactMetadata(artifact: ProductArtifact): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("version", integerValue(1)),
                ValueField("ref", textValue(artifact.reference)),
                ValueField("sha256", textValue(artifact.sha256)),
                ValueField("bytes", integerValue(artifact.bytes)),
                ValueField("content_type", textValue(artifact.contentType))
            ]
        )
    ) + "\n"
}

func artifactPreview(bytes: Array<Byte>, limit: Int64): String {
    if (bytes.size <= limit) {
        return String.fromUtf8(bytes)
    }
    // Reserve enough space for the omission marker and its decimal count.
    let payloadBudget = max(0, limit - 160)
    let head = artifactUtf8Prefix(bytes, payloadBudget / 2)
    let tail = artifactUtf8Suffix(bytes, payloadBudget - head.size)
    let omitted = max(0, bytes.size - head.size - tail.size)
    String.fromUtf8(head) + "\n... [omitted " + omitted.toString() + " bytes] ...\n" + String.fromUtf8(tail)
}

func artifactUtf8Prefix(bytes: Array<Byte>, limit: Int64): Array<Byte> {
    var end = min(bytes.size, max(limit, 0))
    while (end > 0) {
        let candidate = bytes[..end]
        try {
            let _ = String.fromUtf8(candidate)
            return candidate
        } catch (_: Exception) {
            end--
        }
    }
    []
}

func artifactUtf8Suffix(bytes: Array<Byte>, limit: Int64): Array<Byte> {
    var start = max(0, bytes.size - max(limit, 0))
    while (start < bytes.size) {
        let candidate = bytes[start..]
        try {
            let _ = String.fromUtf8(candidate)
            return candidate
        } catch (_: Exception) {
            start++
        }
    }
    []
}

func artifactUtf8Boundary(bytes: Array<Byte>, offset: Int64): Bool {
    if (offset == 0 || offset == bytes.size) {
        return true
    }
    try {
        let _ = String.fromUtf8(bytes[..offset])
        true
    } catch (_: Exception) {
        false
    }
}

func atomicArtifactWrite(path: String, bytes: Array<Byte>): Result<Unit> {
    var temporary = ""
    try {
        // File.createTemp uses the platform's exclusive temporary-file
        // primitive in the destination directory. It cannot follow a
        // pre-planted predictable symlink, and the open handle is used for
        // the complete write before the atomic rename.
        let file = File.createTemp(Path(path).parent)
        temporary = file.info.path.toString()
        try {
            file.write(bytes)
        } finally {
            file.close()
        }
        let info = FileInfo(Path(temporary))
        if (!info.isRegular() || info.isSymbolicLink()) {
            let _ = removeIfExists(temporary)
            return artifactError<Unit>(
                AgentErrorKind.PermissionDenied,
                "artifact.temporary_unsafe",
                "artifact temporary file is not a safe regular file",
                path
            )
        }
        match (artifactChmod(temporary, "600")) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = removeIfExists(temporary)
                return Result.Err(error)
        }
        rename(temporary, to: path, overwrite: false)
        Result.Ok(())
    } catch (error: Exception) {
        if (temporary != "") {
            let _ = removeIfExists(temporary)
        }
        artifactError<Unit>(
            AgentErrorKind.Internal,
            "artifact.atomic_write_failed",
            error.message,
            path
        )
    }
}

func artifactChmod(path: String, mode: String): Result<Unit> {
    let (code, _, error) = executeWithOutput("/usr/bin/chmod", [mode, "--", path])
    if (code == 0) {
        return Result.Ok(())
    }
    artifactError<Unit>(
        AgentErrorKind.PermissionDenied,
        "artifact.permissions_failed",
        String.fromUtf8(error).trimAscii(),
        path
    )
}

func artifactError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    reference: String
): Result<T> {
    Result.Err(
        AgentError(
            kind,
            code,
            message,
            fields: [ErrorField("artifact", reference)]
        )
    )
}
