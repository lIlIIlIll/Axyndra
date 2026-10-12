package agent_extension_runtime

import std.env.*
import std.io.*
import std.sync.*
import std.time.*

// ISOLATED DIAGNOSTIC ONLY. Fixed roles/stages and integer measurements;
// never content, identities, paths, arbitrary error codes or protocol fields.
// The same action is called once and its original value/exception propagates.
let physicalTransportDiagnosticEnabled = getVariable("AXYNDRA_DIAGNOSTIC_PHYSICAL_TRANSPORT") == Some("1")
let physicalTransportDiagnosticLock = Mutex()
let physicalTransportDiagnosticCounts = Array<Int64>(48, repeat: 0)
let physicalTransportDiagnosticNanos = Array<Int64>(48, repeat: 0)
let physicalTransportDiagnosticBytes = Array<Int64>(48, repeat: 0)

func physicalTransportDiagnosticRecord(stage: Int64, role: Int64, elapsed: Int64, bytes: Int64, outcome: Int64): Unit {
    if (!physicalTransportDiagnosticEnabled || role < 1 || role > 2 || stage < 1 || stage > 15) { return }
    try {
        physicalTransportDiagnosticLock.lock()
        try {
            let slot = role * 16 + stage
            if (physicalTransportDiagnosticCounts[slot] >= 4096) { return }
            physicalTransportDiagnosticCounts[slot] += 1
            physicalTransportDiagnosticNanos[slot] += max(0, elapsed)
            physicalTransportDiagnosticBytes[slot] += max(0, bytes)
            let count = physicalTransportDiagnosticCounts[slot]
            if (count <= 4 || count % 16 == 0 || stage == 10 || stage == 11 || stage >= 13 || (stage == 6 && elapsed >= 100000000)) {
                let line = "ISSUE45_PHYSICAL_TRANSPORT role=" + role.toString() + " stage=" + stage.toString() +
                    " ns=" + max(0, elapsed).toString() + " bytes=" + max(0, bytes).toString() +
                    " outcome=" + outcome.toString() + " count=" + count.toString() +
                    " total_ns=" + physicalTransportDiagnosticNanos[slot].toString() +
                    " total_bytes=" + physicalTransportDiagnosticBytes[slot].toString() + "\n"
                getStdErr().write(line.toArray())
            }
        } finally { physicalTransportDiagnosticLock.unlock() }
    } catch (_: Exception) {}
}
public func hostPhysicalTransportDiagnostic<T>(stage: Int64, role: Int64, bytes: Int64, action: () -> T): T {
    if (!physicalTransportDiagnosticEnabled || role < 1 || role > 2) { return action() }
    let started = MonoTime.now()
    try { action() }
    finally { physicalTransportDiagnosticRecord(stage, role, (MonoTime.now() - started).toNanoseconds(), bytes, 0) }
}
public func hostPhysicalTransportDiagnosticOutcome(role: Int64,
    result: JavaScriptHostResult<JavaScriptHostInvocationResult>): Unit {
    if (!physicalTransportDiagnosticEnabled) { return }
    let outcome = match (result) {
        case JavaScriptHostResult.Ok(_) => 0
        case JavaScriptHostResult.Err(error) => match (error.code) {
            case "extension.invocation_timeout" => 1
            case "extension.cancelled" => 2
            case "extension.protocol_failed" => 3
            case "extension.process_failed" => 4
            case "extension.protocol_frame_too_large" => 5
            case "extension.payload_result_limit" => 6
            case "extension.protocol_identity_mismatch" => 7
            case _ => 8
        }
    }
    physicalTransportDiagnosticRecord(11, role, 0, 0, outcome)
}
