package axyndra_agent_testkit

import agent_sdk.*
import std.collection.*
import std.sync.*

// STABLE: a monotonic clock controlled entirely by the test.
public class ManualClock {
    private let lock = Mutex()
    private var value: Int64

    public init(initialMillis!: Int64 = 0) {
        if (initialMillis < 0) {
            throw IllegalArgumentException("manual clock must not start before zero")
        }
        value = initialMillis
    }

    public func nowMillis(): Int64 {
        lock.lock()
        try { value } finally { lock.unlock() }
    }

    public func advance(millis: Int64): Int64 {
        if (millis < 0) {
            throw IllegalArgumentException("manual clock cannot move backward")
        }
        lock.lock()
        try {
            value += millis
            value
        } finally { lock.unlock() }
    }

    public func setMillis(millis: Int64): Int64 {
        lock.lock()
        try {
            if (millis < value) {
                throw IllegalArgumentException("manual clock cannot move backward")
            }
            value = millis
            value
        } finally { lock.unlock() }
    }

    public func deadlineAfter(millis: Int64): InvocationDeadline {
        if (millis < 0) {
            throw IllegalArgumentException("deadline delay must not be negative")
        }
        InvocationDeadline(expiresAtMillis: nowMillis() + millis)
    }
}

// STABLE: deterministic opaque identities. Strings are identities, not Agent
// Run/Operation authority objects.
public class SequenceIds {
    private let lock = Mutex()
    private let prefix: String
    private var sequence: Int64 = 0

    public init(prefix!: String = "test") {
        let normalized = prefix.trimAscii()
        if (normalized == "") {
            throw IllegalArgumentException("sequence ID prefix must not be empty")
        }
        this.prefix = normalized
    }

    public func next(scope!: String = "id"): String {
        let normalized = scope.trimAscii()
        if (normalized == "") {
            throw IllegalArgumentException("sequence ID scope must not be empty")
        }
        lock.lock()
        try {
            sequence += 1
            prefix + "-" + normalized + "-" + sequence.toString()
        } finally { lock.unlock() }
    }
}

// STABLE: the controller half of agent_sdk.InvocationCancellation. It can
// cancel one fixture invocation but has no access to a parent Run.
public class ManualCancellation <: InvocationCancellation {
    private let lock = Mutex()
    private var cancelled = false
    private var cancellationReason = ""

    public init() {}

    public func cancel(reason!: String = "test cancellation"): Bool {
        lock.lock()
        try {
            if (cancelled) { return false }
            cancelled = true
            cancellationReason = reason
            true
        } finally { lock.unlock() }
    }

    public func isCancelled(): Bool {
        lock.lock()
        try { cancelled } finally { lock.unlock() }
    }

    public func reason(): String {
        lock.lock()
        try { cancellationReason } finally { lock.unlock() }
    }
}

// EXPERIMENTAL: deterministic named failure scheduling. It returns a Boolean;
// callers surface failures through the real error type of the port under test.
public class FaultRule {
    public let point: String
    public let occurrence: Int64
    public let repeat: Bool

    public init(point: String, occurrence!: Int64 = 1, repeat!: Bool = false) {
        let normalized = point.trimAscii()
        if (normalized == "" || occurrence < 1) {
            throw IllegalArgumentException("fault rule requires a point and positive occurrence")
        }
        this.point = normalized
        this.occurrence = occurrence
        this.repeat = repeat
    }
}

class FaultCounter {
    let point: String
    var count: Int64 = 0
    init(point: String) { this.point = point }
}

public class FaultPlan {
    private let lock = Mutex()
    private let rules: Array<FaultRule>
    private let counters = ArrayList<FaultCounter>()

    public init(rules!: Array<FaultRule> = []) { this.rules = rules }

    public func shouldFail(point: String): Bool {
        let normalized = point.trimAscii()
        if (normalized == "") {
            throw IllegalArgumentException("fault point must not be empty")
        }
        lock.lock()
        try {
            let counter = counterFor(normalized)
            counter.count += 1
            for (rule in rules where rule.point == normalized) {
                if (counter.count == rule.occurrence ||
                    (rule.repeat && counter.count >= rule.occurrence)) {
                    return true
                }
            }
            false
        } finally { lock.unlock() }
    }

    public func calls(point: String): Int64 {
        lock.lock()
        try {
            for (counter in counters where counter.point == point) { return counter.count }
            0
        } finally { lock.unlock() }
    }

    private func counterFor(point: String): FaultCounter {
        for (counter in counters where counter.point == point) { return counter }
        let created = FaultCounter(point)
        counters.add(created)
        created
    }
}
