package process4cj

import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func rejectedNonTreeDuplex(process: ManagedProcess): Bool {
    try { let _ = ManagedProcessDuplexChannel(process); false }
    catch (error: ProcessError) { error.message.startsWith("process.duplex_tree_required:") }
}

@Test
class ProcessDuplexOwnershipTests {
    @TestCase
    func alreadyExitedLeaderOnlyProcessIsRejectedWithoutTakingItsPipes(): Unit {
        let process = startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", "print('caller-owned')"],
            terminateProcessTree: false))
        try {
            let _ = process.wait()
            let before = MonoTime.now()
            @Expect(rejectedNonTreeDuplex(process), true)
            @Expect(MonoTime.now() - before < Duration.millisecond * 500, true)
            @Expect(process.inputIsClosed(), false)
            let bytes = Array<Byte>(64, repeat: 0)
            let count = process.stdout.read(bytes)
            @Expect(String.fromUtf8(bytes[0..count]), "caller-owned\n")
        } finally { let _ = process.close() }
    }

    @TestCase
    func descendantHoldingBackpressuredInputCannotMakeRejectedConstructorCloseTheOwner(): Unit {
        let script = "import os,time,select\n" +
            "print('ready',flush=True)\n" +
            "if not select.select([0],[],[],5)[0]: os._exit(2)\n" +
            "os.read(0,1)\npid=os.fork()\n" +
            "if pid==0:\n time.sleep(2);os._exit(0)\n" +
            "os._exit(0)\n"
        let process = startProcess(ProcessCommand("/usr/bin/python3", arguments: ["-u", "-c", script],
            terminateProcessTree: false))
        let done = AtomicBool(false)
        var writer: ?Future<Unit> = None
        try {
            let line = Array<Byte>(6, repeat: 0)
            @Expect(process.stdout.read(line), 6)
            let task = spawn {
                try { process.writeStdin(Array<Byte>(8388608, repeat: b'x')) } catch (_: Exception) { () }
                finally { done.store(true) }
            }
            writer = Some(task)
            let _ = process.wait()
            @Expect(done.load(), false)
            let before = MonoTime.now()
            @Expect(rejectedNonTreeDuplex(process), true)
            @Expect(MonoTime.now() - before < Duration.millisecond * 500, true)
            @Expect(done.load(), false)
            // This caller deliberately chose leader-only ownership. Its fixture
            // descendant exits independently after two seconds; the adapter
            // neither kills it nor blocks trying to close the caller's writer.
            task.get()
        } finally {
            match (writer) { case Some(task) => task.get(); case None => () }
            let _ = process.close()
        }
    }
}
