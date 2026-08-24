package agent_testkit

import agent_domain.*
import agent_ports.*
import std.sync.*

public class DeterministicIds <: IdGenerator {
    private let lock = Mutex()
    private let prefix: String
    private var runSequence: Int64 = 0
    private var sessionSequence: Int64 = 0
    private var operationSequence: Int64 = 0

    public init(prefix!: String = "test") {
        if (prefix.trimAscii() == "") {
            throw IllegalArgumentException("deterministic ID prefix must not be empty")
        }
        this.prefix = prefix.trimAscii()
    }

    public func nextRunId(): RunId {
        lock.lock()
        try {
            runSequence += 1
            RunId(prefix + "-run-" + runSequence.toString())
        } finally {
            lock.unlock()
        }
    }

    public func nextSessionId(): SessionId {
        lock.lock()
        try {
            sessionSequence += 1
            SessionId(prefix + "-session-" + sessionSequence.toString())
        } finally {
            lock.unlock()
        }
    }

    public func nextOperationId(): OperationId {
        lock.lock()
        try {
            operationSequence += 1
            OperationId(prefix + "-operation-" + operationSequence.toString())
        } finally {
            lock.unlock()
        }
    }
}

public class ManualClock <: ClockPort {
    private let lock = Mutex()
    private var now: Int64

    public init(initialMillis!: Int64 = 0) {
        this.now = initialMillis
    }

    public func monotonicMillis(): Int64 {
        lock.lock()
        try { now } finally { lock.unlock() }
    }

    public func advance(millis: Int64): Int64 {
        if (millis < 0) {
            throw IllegalArgumentException("manual clock cannot move backward")
        }
        lock.lock()
        try {
            now += millis
            now
        } finally {
            lock.unlock()
        }
    }
}
