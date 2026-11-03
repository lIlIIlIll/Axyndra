package sandbox4cj

import process4cj.*
import std.sync.*

// Caller prepays this DATA carrier and its complete input extent before
// construction. It grants no spawn, path, process, or cancellation authority.
// Only WorkspaceSandbox.execute can install/return a concrete writer frame.
public class SandboxStdinReturn159f {
    private let lock = Mutex()
    private var input: ?String = None<String>
    private var process: ?ManagedProcess = None<ManagedProcess>
    private var installed = false
    private var returned = false
    private let reserveScheduler159j: ?() -> Unit
    public init(reserveScheduler159j!: ?() -> Unit = None<() -> Unit>) {
        this.reserveScheduler159j = reserveScheduler159j
    }
    func beforeActualWriterSpawn159j(): Unit {
        match (reserveScheduler159j) { case Some(value) => value(); case None => () }
    }
    public func resetReturnedInput159j(): Unit {
        lock.lock()
        try {
            if (input.isSome() || process.isSome() || (installed && !returned)) {
                throw IllegalStateException("actual input writer has not returned")
            }
            installed = false; returned = false
        } finally { lock.unlock() }
    }
    func installWriter159f(value: String, actual: ManagedProcess): Unit {
        lock.lock()
        try {
            if (installed) { throw IllegalStateException("sandbox input writer is already installed") }
            installed = true
            input = Some(value); process = Some(actual)
        } finally { lock.unlock() }
    }
    func writeInputFrame159f(): Unit {
        // No clearing occurs concurrently: the sole production clearing
        // path is after this whole input helper returned to execute. A throw
        // preserves both private references and the original paid phase.
        let actual = process.getOrThrow()
        actual.writeStdin(input.getOrThrow().toArray())
        actual.flushInput()
        let _ = actual.closeInput()
    }
    func clearReturnedWriter159f(): Unit {
        lock.lock()
        try {
            if (!installed || returned) { throw IllegalStateException("sandbox input writer has not returned") }
            input = None<String>; process = None<ManagedProcess>
            returned = true
        } finally { lock.unlock() }
    }
    public func inputDataRetained159f(): Bool {
        lock.lock(); try { installed && (!returned || input.isSome() || process.isSome()) }
        finally { lock.unlock() }
    }
    public func inputDataReturned159f(): Bool {
        lock.lock(); try { installed && returned && input.isNone() && process.isNone() }
        finally { lock.unlock() }
    }
}

func joinSandboxInputWriter159f(writer: Future<Unit>): Unit { writer.get() }
