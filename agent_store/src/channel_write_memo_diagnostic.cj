package agent_store

import std.env.*
import std.sync.*
import std.time.*

// TEMPORARY opt-in numeric observations only: no SQL, values, identity or errors.
private let channelWriteMemoDiagnosticOn = getVariable("AXYNDRA_DIAGNOSTIC_CHANNEL_WRITE_MEMO") == Some("1")
private let channelWriteMemoDiagnosticLock = Mutex()
private var channelWriteMemoDiagnosticRecords: Int64 = 0
private let channelWriteMemoDiagnosticCounts = Array<Int64>(15, repeat: 0)
private let channelWriteMemoDiagnosticElapsed = Array<Int64>(15, repeat: 0)
func channelWriteMemoDiagnosticEnabled(): Bool { channelWriteMemoDiagnosticOn }
public func channelWriteMemoDiagnosticStart(): ?MonoTime {
    if (channelWriteMemoDiagnosticOn) { Some(MonoTime.now()) } else { None }
}
public func channelWriteMemoDiagnosticRecord(stage: Int64, started: ?MonoTime,
    a!: Int64 = 0, b!: Int64 = 0, c!: Int64 = 0): Unit {
    if (!channelWriteMemoDiagnosticOn || stage < 1 || stage > 15) { return }
    match (started) {
        case None => ()
        case Some(value) =>
            let elapsed = min(3600000, max(0, (MonoTime.now() - value).toMilliseconds()))
            channelWriteMemoDiagnosticLock.lock()
            try {
                let index = stage - 1
                channelWriteMemoDiagnosticCounts[index] = min(1073741824, channelWriteMemoDiagnosticCounts[index] + 1)
                channelWriteMemoDiagnosticElapsed[index] = min(1073741824, channelWriteMemoDiagnosticElapsed[index] + elapsed)
                if (channelWriteMemoDiagnosticRecords >= 1024) { return }
                channelWriteMemoDiagnosticRecords++
                try {
                    eprintln("ISSUE45_CHANNEL_WRITE_INTERN stage=" + stage.toString() +
                        " elapsed_ms=" + elapsed.toString() + " a=" + min(1073741824, max(0, a)).toString() +
                        " b=" + min(1073741824, max(0, b)).toString() + " c=" + min(1073741824, max(0, c)).toString() +
                        " ordinal=" + channelWriteMemoDiagnosticCounts[index].toString() +
                        " total_ms=" + channelWriteMemoDiagnosticElapsed[index].toString())
                } catch (_: Exception) {}
            } finally { channelWriteMemoDiagnosticLock.unlock() }
    }
}

// Two finite accumulated timings; same record cap and numeric-only output.
func channelWriteMemoDiagnosticMilliseconds(started: ?MonoTime): Int64 {
    match (started) {
        case None => 0
        case Some(value) => min(3600000, max(0, (MonoTime.now() - value).toMilliseconds()))
    }
}
func channelWriteMemoDiagnosticDuration(stage: Int64, milliseconds: Int64,
    a!: Int64 = 0, b!: Int64 = 0, c!: Int64 = 0): Unit {
    if (!channelWriteMemoDiagnosticOn || stage < 14 || stage > 15) { return }
    let elapsed = min(3600000, max(0, milliseconds))
    channelWriteMemoDiagnosticLock.lock()
    try {
        let index = stage - 1
        channelWriteMemoDiagnosticCounts[index] = min(1073741824, channelWriteMemoDiagnosticCounts[index] + 1)
        channelWriteMemoDiagnosticElapsed[index] = min(1073741824, channelWriteMemoDiagnosticElapsed[index] + elapsed)
        if (channelWriteMemoDiagnosticRecords >= 1024) { return }
        channelWriteMemoDiagnosticRecords++
        try {
            eprintln("ISSUE45_CHANNEL_WRITE_INTERN stage=" + stage.toString() +
                " elapsed_ms=" + elapsed.toString() + " a=" + min(1073741824, max(0, a)).toString() +
                " b=" + min(1073741824, max(0, b)).toString() + " c=" + min(1073741824, max(0, c)).toString() +
                " ordinal=" + channelWriteMemoDiagnosticCounts[index].toString() +
                " total_ms=" + channelWriteMemoDiagnosticElapsed[index].toString())
        } catch (_: Exception) {}
    } finally { channelWriteMemoDiagnosticLock.unlock() }
}
