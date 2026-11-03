package agent_domain

import std.sync.*

// Process-local operator DATA only. The actual frontend pays for this carrier
// before construction; it retains no request, Context, Runtime or callback.
public class ModelStreamFaultCounters180 {
    private let lock = Mutex()
    private var ordinal: Int64 = 0
    private var injected: Int64 = 0

    public init(prepaid: LogicalJsonOwnerReservation) {
        prepaid.ensureRetainedPeak(4096)
    }

    public func claim180(trigger: Int64, maximum: Int64): Result<(Int64, Bool)> {
        lock.lock()
        try {
            if (trigger < 1 || maximum < 1 || ordinal == Int64.Max) {
                return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                    "model.controlled_fault_counter_invalid", "invalid controlled fault counter extent"))
            }
            ordinal += 1
            let selected = ordinal >= trigger && injected < maximum
            if (selected) { injected += 1 }
            Result.Ok((ordinal, selected))
        } finally { lock.unlock() }
    }
}
