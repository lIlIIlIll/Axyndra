package agent_runtime

import agent_domain.*

// Independently copied numeric DATA only. Receiver Ok/declaration is not an
// input-retirement ACK. The existing sealed Source and all old SQL guards
// still govern actual preparation; this interface does not create a Source.
public interface PreparedOperationPlanDataPort204 {
    func prepareDirectOperationOwnedUtf8204(source: DirectToolCallRef,
        value: PreparedPlanUtf8Owner204): Result<Unit>
}
