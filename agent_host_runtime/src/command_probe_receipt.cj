package agent_host_runtime

import agent_domain.*
import process4cj.*
import sandbox4cj.*
import std.convert.*

public func hostDecodeCommandProbeFrame(bytes: Array<Byte>, cwd: String, redactor: SecretRedactor): Result<ProcessResult> {
    try {
        var end: Int64 = 0
        while (end < bytes.size && end < 256 && bytes[end] != b'\n') { end += 1 }
        if (end >= bytes.size || end >= 256) { throw IllegalArgumentException("invalid frame header") }
        let header = String.fromUtf8(bytes[..end]).split(" ")
        if (header.size != 9 || header[0] != "AXYNDRA-PROBE/1") {
            throw IllegalArgumentException("invalid frame version")
        }
        let values = Array<Int64>(8, {index => Int64.parse(header[index + 1])})
        for (index in [0, 1, 3, 4] where values[index] < 0 || values[index] > 1) {
            throw IllegalArgumentException("invalid frame flag")
        }
        if (values[2] < 0 || values[2] > 255 || values[5] < 0 || values[5] > 4096 ||
            values[6] < 0 || values[7] < 0 || values[6] > 67108864 || values[7] > 67108864 ||
            values[6] + values[7] > 67108864 ||
            end + 1 + values[6] + values[7] != bytes.size ||
            values[1] != (if (values[0] == 1 && values[3] == 0) { 1 } else { 0 }) ||
            (values[0] == 1 && values[5] != 0) ||
            (values[0] == 0 && values[3] == 0 && values[5] == 0)) {
            throw IllegalArgumentException("inconsistent frame status")
        }
        let middle = end + 1 + values[6]
        Result.Ok(ProcessResult(values[2],
            stdout: redactor.redact(decodeProcessOutput(bytes[end + 1..middle])),
            stderr: redactor.redact(decodeProcessOutput(bytes[middle..])),
            timedOut: values[3] == 1, truncated: values[4] == 1,
            workingDirectory: cwd, started: values[0] == 1, completed: values[1] == 1,
            launchErrno: values[5]))
    } catch (_: Exception) {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "probe.receipt_invalid", "the trusted command probe receipt is missing or invalid"))
    }
}
