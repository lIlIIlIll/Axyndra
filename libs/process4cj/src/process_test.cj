package process4cj

import std.io.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Process4CjTests {
    @TestCase
    func framesFragmentedLinesAndContentLengthBodies() {
        let lines = LineFramer(maxFrameBytes: 16)
        @Expect(lines.push("one\r").size, 0)
        let completed = lines.push("\ntwo\n")
        @Expect(completed.size, 2)
        @Expect(completed[0], "one")
        @Expect(completed[1], "two")
        @ExpectThrows[ProcessError](LineFramer(maxFrameBytes: 3).push("four"))

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
