package process4cj

import std.io.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Process4CjTests {
    @TestCase
    func deadlineIncludesInheritedPipesAfterLeaderExit() {
        let started = processTestMillis()
        let source = CancellationSource(deadlineMillis: started + 150)
        try {
            let _ = runProcess(ProcessCommand("/bin/sh", arguments: ["-c", "sleep 5 & exit 0"]), cancellation: source.token)
            @Fail("inherited pipe must obey deadline")
        } catch (error: ProcessError) { @Expect(processErrorKindName(error.kind), "deadline") }
        @Expect(processTestMillis() - started < 1500, true)
    }

    @TestCase
    func cancellationIncludesEscapedPipeWriterWithoutReaderLeak() {
        let source = CancellationSource()
        let started = processTestMillis()
        let worker = spawn { runProcess(ProcessCommand("/bin/sh", arguments: ["-c", "setsid sleep 1 & exit 0"]), cancellation: source.token) }
        sleep(Duration.millisecond * 100)
        let _ = source.cancel()
        try { let _ = worker.get(); @Fail("cancel must include output drain") }
        catch (error: ProcessError) { @Expect(processErrorKindName(error.kind), "cancelled") }
        @Expect(processTestMillis() - started < 800, true)
    }

    @TestCase
    func exitedLeaderRetainsOwnershipUntilSingleConcurrentClose() {
        let process = startProcess(ProcessCommand("/bin/sh", arguments: ["-c", "sleep 5 & exit 0"]))
        let unrelated = startProcess(ProcessCommand("/bin/sleep", arguments: ["5"]))
        @Expect(process.wait().code, 0)
        @Expect(exists(Path("/proc/" + process.pid.toString())), true)
        @Expect(process.cancel(CancellationCause(CancellationKind.Explicit, "test.cancel", "stop descendants")), true)
        let first = spawn { process.close() }
        let second = spawn { process.close() }
        @Expect(first.get() != second.get(), true)
        @Expect(exists(Path("/proc/" + process.pid.toString())), false)
        @Expect(process.terminate(force: true), false)
        @Expect(process.close(), false)
        @Expect(process.cancel(CancellationCause(CancellationKind.Explicit, "test.closed", "closed process")), false)
        @Expect(unrelated.isAlive(), true)
        let _ = unrelated.close()
    }

    @TestCase
    func silentReaderCanCloseConcurrentlyWithoutClosingReusedDescriptor() {
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["5"]))
        let stream = process.stdout
        let resource = (stream as Resource).getOrThrow()
        let reading = spawn { stream.read(Array<Byte>(16, repeat: 0)) }
        sleep(Duration.millisecond * 30)
        let started = processTestMillis()
        let first = spawn { resource.close() }
        let second = spawn { resource.close() }
        first.get(); second.get()
        @Expect(reading.get(), 0)
        @Expect(processTestMillis() - started < 1000, true)
        @Expect(process.isAlive(), true)
        let other = startProcess(ProcessCommand("/bin/sh", arguments: ["-c", "printf independent"]))
        resource.close()
        @Expect(decodeProcessOutput(readBounded(other.stdout, BoundedOutputBudget(64))), "independent")
        @Expect(other.wait().code, 0)
        let _ = other.close()
        let _ = process.close()
    }

    @TestCase
    func outputDecodePreservesBinaryAndTruncatedUtf8Metadata() {
        let result = runProcess(ProcessCommand("/bin/sh", arguments: ["-c", "printf '中'; exit 7"], maxOutputBytes: 2))
        @Expect(result.status.code, 7)
        @Expect(result.truncated, true)
        @Expect(decodeProcessOutput(result.stdout), "��")
        @Expect(decodeProcessOutput([UInt8(255), UInt8(65)]), "�A")
        @Expect(decodeProcessOutput("中".toArray()), "中")
    }

    @TestCase
    func rejectsInvalidReadinessPollArguments() {
        @ExpectThrows[IllegalArgumentException](waitReadableFd(-1, 0))
        @ExpectThrows[IllegalArgumentException](waitReadableFd(0, -1))
        @ExpectThrows[IllegalArgumentException](readFdChunk(-1))
        @ExpectThrows[IllegalArgumentException](readFdChunk(0, maxBytes: 0))
    }

    @TestCase
    func framesFragmentedLinesAndContentLengthBodies() {
        let lines = LineFramer(maxFrameBytes: 16)
        @Expect(lines.push("one\r").size, 0)
        let completed = lines.push("\ntwo\n")
        @Expect(completed.size, 2)
        @Expect(completed[0], "one")
        @Expect(completed[1], "two")
        @ExpectThrows[ProcessError](LineFramer(maxFrameBytes: 3).push("four"))
        let oversizedTail = LineFramer(maxFrameBytes: 8)
        @ExpectThrows[ProcessError](oversizedTail.push(
            "ok\n" + String.fromUtf8(Array<Byte>(9, repeat: b'x'))
        ))
        @Expect(oversizedTail.bufferedBytes(), 0)

        let bytes = encodeContentLengthFrame("{\"ok\":true}")
        let stream = ByteBuffer()
        stream.write(bytes)
        @Expect(String.fromUtf8(readContentLengthBody(stream)), "{\"ok\":true}")

        let bounded = BoundedByteBuffer(3)
        @Expect(bounded.append("hello".toArray()), 3)
        @Expect(String.fromUtf8(bounded.snapshot()), "hel")
        @Expect(bounded.wasTruncated(), true)
    }

    @TestCase
    func capturesNormalAndNonZeroExit() {
        let result = runProcess(ProcessCommand(
            "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"],
            maxOutputBytes: 1024
        ))
        @Expect(result.status.code, 7)
        @Expect(String.fromUtf8(result.stdout), "out")
        @Expect(String.fromUtf8(result.stderr), "err")
        @Expect(result.truncated, false)
    }

    @TestCase
    func boundsCombinedOutputWithoutDeadlock() {
        let result = runProcess(ProcessCommand(
            "/bin/sh",
            arguments: ["-c", "i=0; while [ $i -lt 2048 ]; do printf x; printf y >&2; i=$((i+1)); done"],
            maxOutputBytes: 128
        ))
        @Expect(result.status.succeeded, true)
        @Expect(result.stdout.size + result.stderr.size, 128)
        @Expect(result.truncated, true)
    }

    @TestCase
    func distinguishesDeadlineAndExplicitCancellation() {
        let deadline = CancellationSource(deadlineMillis: processTestMillis() + 40)
        try {
            runProcess(ProcessCommand("/bin/sleep", arguments: ["5"]), cancellation: deadline.token)
            @Fail("deadline should stop child")
        } catch (error: ProcessError) {
            @Expect(processErrorKindName(error.kind), "deadline")
        }

        let explicit = CancellationSource()
        let running = spawn {
            runProcess(ProcessCommand("/bin/sleep", arguments: ["5"]), cancellation: explicit.token)
        }
        sleep(Duration.millisecond * 40)
        @Expect(explicit.cancel(), true)
        @Expect(explicit.cancel(), false)
        try {
            let _ = running.get()
            @Fail("explicit cancellation should stop child")
        } catch (error: ProcessError) {
            @Expect(processErrorKindName(error.kind), "cancelled")
        }
    }

    @TestCase
    func terminationIsIdempotentAcrossExitRace() {
        let process = startProcess(ProcessCommand("/bin/sleep", arguments: ["5"]))
        @Expect(process.terminate(), true)
        // TERM may win the exit race before the forced escalation is issued.
        // Either outcome is valid; once observed, another KILL request must be
        // idempotent and the child must still settle.
        let _ = process.terminate(force: true)
        @Expect(process.terminate(force: true), false)
        let _ = process.wait()
        @Expect(process.isAlive(), false)
        @Expect(process.close(), true)
        @Expect(process.close(), false)
    }

    @TestCase
    func reportsBrokenPipeAfterChildClosesStdin() {
        let process = startProcess(ProcessCommand("/bin/true"))
        let _ = process.wait()
        try {
            process.writeStdin("late".toArray())
            @Fail("write after child exit must fail")
        } catch (error: ProcessError) {
            @Expect(processErrorKindName(error.kind), "broken_pipe")
        }
        let _ = process.close()
    }

    @TestCase
    func reportsBrokenPipeWhileChildRemainsAlive() {
        let process = startProcess(ProcessCommand(
            "/bin/sh",
            arguments: ["-c", "exec 0<&-; printf ready; sleep 1"]
        ))
        let ready = Array<Byte>(5, repeat: 0)
        @Expect(process.stdout.read(ready), 5)
        @Expect(String.fromUtf8(ready), "ready")
        try {
            process.writeStdin("late".toArray())
            @Fail("write after the child closes its stdin must fail")
        } catch (error: ProcessError) {
            @Expect(processErrorKindName(error.kind), "broken_pipe")
        }
        let _ = process.terminate(force: true)
        let _ = process.wait()
        @Expect(process.closeInput(), true)
        let _ = process.close()
    }

    @TestCase
    func closesOwnedInputAndDeliversEof() {
        let process = startProcess(ProcessCommand(
            "/bin/sh",
            arguments: ["-c", "input=$(cat); printf '%s' \"$input\""]
        ))
        process.writeStdin("hello".toArray())
        process.flushInput()
        @Expect(process.inputCloseSupported(), true)
        @Expect(process.closeInput(), true)
        @Expect(process.closeInput(), false)
        @Expect(process.inputIsClosed(), true)
        @Expect(process.wait().code, 0)
        let output = Array<Byte>(5, repeat: 0)
        @Expect(process.stdout.read(output), 5)
        @Expect(String.fromUtf8(output), "hello")
        let _ = process.close()
    }

    @TestCase
    func closeAfterExitAndCancelWithOpenInputAreSettled() {
        let exited = startProcess(ProcessCommand("/bin/true"))
        @Expect(exited.wait().code, 0)
        @Expect(exited.inputCloseSupported(), true)
        @Expect(exited.closeInput(), true)
        @Expect(exited.closeInput(), false)

        let waiting = startProcess(ProcessCommand("/bin/cat"))
        let cause = CancellationCause(
            CancellationKind.Explicit,
            "test.cancel",
            "test cancellation"
        )
        @Expect(waiting.cancel(cause), true)
        @Expect(waiting.cancel(cause), false)
        let _ = waiting.wait()
        @Expect(waiting.state().kind, ProcessLifecycleKind.Cancelled)
        @Expect(waiting.inputCloseSupported(), true)
        @Expect(waiting.closeInput(), true)
        @Expect(waiting.closeInput(), false)
        let _ = waiting.close()
        let _ = exited.close()
    }
}

func processErrorKindName(kind: ProcessErrorKind): String {
    match (kind) {
        case ProcessErrorKind.DeadlineExceeded => "deadline"
        case ProcessErrorKind.Cancelled => "cancelled"
        case ProcessErrorKind.BrokenPipe => "broken_pipe"
        case ProcessErrorKind.Io => "io"
        case _ => "other"
    }
}

func processTestMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}
