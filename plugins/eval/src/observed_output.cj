package eval_plugin

import std.collection.*
import std.convert.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// Only previews and Host-confirmed references survive an invocation.
class EvalObservedStream {
    let preview: String
    let size: Int64
    let artifact: ?JsonNode
    let storageError: ?JsonNode
    init(value: String) { preview = value; size = value.size; artifact = None; storageError = None }
    init(preview: String, size: Int64, artifact: ?JsonNode, storageError: ?JsonNode) {
        this.preview = preview; this.size = size; this.artifact = artifact; this.storageError = storageError
    }
}

class EvalObservedCell {
    let exitCode: Int64
    let timedOut: Bool
    let duration: Int64
    let stdout: EvalObservedStream
    let stderr: EvalObservedStream
    init(meta: (Int64, Bool, Int64), stdout: EvalObservedStream, stderr: EvalObservedStream) {
        exitCode = meta[0]; timedOut = meta[1]; duration = meta[2]
        this.stdout = stdout; this.stderr = stderr
    }
}

class EvalRunnerFrames {
    private let port: BrokerChannel
    private let buffer = Array<Byte>(16384, repeat: 0)
    private var at: Int64 = 0
    private var count: Int64 = 0
    init(port: BrokerChannel) { this.port = port }
    func line(limit: Int64): String {
        let result = StringBuilder()
        while (true) {
            if (at == count) {
                count = port.stdout.read(buffer); at = 0
                require(count > 0, "eval_plugin.runner_closed")
            }
            let start = at
            while (at < count && buffer[at] != 10u8) { at++ }
            require(at-start <= limit-result.size, "eval_plugin.runner_output_limit")
            result.append(String.fromUtf8(buffer[start..at]))
            if (at < count) { at++; return result.toString() }
        }
        ""
    }
    private func metadata(parts: Array<String>, start: Int64): (Int64, Bool, Int64) {
        let code = Int64.parse(parts[start]); let timed = parts[start+1]; let duration = Int64.parse(parts[start+2])
        require(duration >= 0 && (timed == "0" || timed == "1"), "eval_plugin.runner_protocol_invalid")
        (code, timed == "1", duration)
    }
    func cell(binding: String): EvalObservedCell {
        let parts = line(131072).split("|")
        if (binding == "" || parts[0] == "INLINE") {
            let i: Int64 = if (binding == "") { 1 } else { 2 }
            require(parts.size == i+5 && (if (i == 1) { parts[0] == "OK" } else { parts[1] == binding && at == count &&
                parts[i+3].size + parts[i+4].size <= 8192 }), "eval_plugin.runner_protocol_invalid")
            return EvalObservedCell(metadata(parts, i),
                EvalObservedStream(String.fromUtf8(unhex(parts[i+3], 65536))), EvalObservedStream(String.fromUtf8(unhex(parts[i+4], 65536))))
        }
        require(parts.size == 9 && parts[0] == "OUT" && parts[1] == binding, "eval_plugin.runner_protocol_invalid")
        let outBytes = Int64.parse(parts[5]); let errBytes = Int64.parse(parts[7])
        require(outBytes >= 0 && errBytes >= 0 && outBytes <= 16777216-errBytes && outBytes+errBytes > 4096, "eval_plugin.output_extent_invalid")
        let meta = metadata(parts, 2)
        validDigest(parts[6]); validDigest(parts[8])
        let stdout = stream("stdout", outBytes, parts[6]); let stderr = stream("stderr", errBytes, parts[8])
        require(line(256) == "END|" + binding && at == count, "eval_plugin.output_incomplete")
        EvalObservedCell(meta, stdout, stderr)
    }
    private func observe(action: String, name: String, fields: Array<JsonObjectEntry>): JsonNode {
        let args = jsonObject(fields); args.put("action", jsonString(action)); args.put("stream", jsonString(name))
        port.request("output.artifact", args).getOrThrow()
    }
    private func validDigest(digest: String): Unit {
        require(digest.size == 64, "eval_plugin.output_digest_invalid")
        for (byte in digest.toArray()) { require((byte >= 48u8 && byte <= 57u8) || (byte >= 97u8 && byte <= 102u8), "eval_plugin.output_digest_invalid") }
    }
    private func stream(name: String, length: Int64, digest: String): EvalObservedStream {
        let large = length > 1024
        let edge = StringBuilder(); var unretained = false
        if (large) {
            let begin = observe("begin", name, [JsonObjectEntry("bytes", jsonNumber(length.toString())), JsonObjectEntry("sha256", jsonString(digest))])
            unretained = begin.field("storage_error").isSome()
            if (unretained) { exact(begin, ["storage_error"]); require(text(begin, "storage_error") == "artifact.root_unsafe", "eval_plugin.output_ack_invalid") }
            else { exact(begin, ["accepted_bytes"]); require(number(begin, "accepted_bytes") == length, "eval_plugin.output_ack_invalid") }
        }
        var offset: Int64 = 0
        while (offset < length) {
            let raw = unhex(line(32768), 16384); let value = String.fromUtf8(raw)
            require(raw.size > 0 && raw.size <= length-offset && value.size == raw.size, "eval_plugin.output_extent_invalid")
            if (large) {
                let ack = observe(if (unretained) { "observe_append" } else { "append" }, name,
                    [JsonObjectEntry("offset", jsonNumber(offset.toString())), JsonObjectEntry("text", jsonString(value))])
                let key = if (unretained) { "observed_offset" } else { "next_offset" }
                exact(ack, [key]); require(number(ack, key) == offset + raw.size, "eval_plugin.output_ack_invalid")
                var start = max(0, length - 512 - offset)
                while (start < value.size && (value[start] & 192u8) == 128u8) { start++ }
                if (start < value.size) { edge.append(value[start..]) }
            } else { edge.append(value) }
            offset += raw.size
        }
        if (!large) { let value = edge.toString(); require(sha(value) == digest, "eval_plugin.output_digest_invalid"); return EvalObservedStream(value) }
        let end = observe(if (unretained) { "observe_finish" } else { "finish" }, name, [])
        var artifact: ?JsonNode = None; var storageError: ?JsonNode = None
        if (unretained) {
            exact(end, ["storage_error", "observed_bytes", "sha256", "preview"])
            let failure = field(end, "storage_error"); exact(failure, ["stream", "code", "message"])
            require(text(failure, "stream") == name && text(failure, "code") == "artifact.root_unsafe" && number(end, "observed_bytes") == length && text(end, "sha256") == digest, "eval_plugin.output_ack_invalid")
            storageError = Some(failure)
        } else {
            exact(end, ["artifact", "preview", "truncated"]); let ref = field(end, "artifact")
            require(text(ref, "stream") == name && number(ref, "bytes") == length && text(ref, "sha256") == digest && text(ref, "ref") == "blob:sha256:" + digest, "eval_plugin.output_ack_invalid")
            artifact = Some(ref)
        }
        require(field(end, "preview").unifiedKind == UnifiedJsonKind.Text, "eval_plugin.output_ack_invalid")
        let prefix = text(end, "preview"); var cut = min(512, prefix.size)
        while (cut < prefix.size && cut > 0 && (prefix[cut] & 192u8) == 128u8) { cut-- }
        let suffix = edge.toString()
        let preview = prefix[..cut] + "\n... [omitted " + (length-cut-suffix.size).toString() + " bytes] ...\n" + suffix
        EvalObservedStream(preview, length, artifact, storageError)
    }
}
