package agent_rpc

import agent_domain.*
import agent_runtime.*

// Concrete stdio owns the only write/flush acknowledgement. Implementations
// borrow the supplied output child, call render and write/flush inside that
// borrow, then ACK only AFTER all render/helper/borrow frames have returned.
// An ordinary (String)->Unit callback does not implement this contract.
public interface OwnedRpcFailureOutput113 {
    func writeFailureFrame113(value: OwnedFailureRunPublication113,
        render: (AgentError, (Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit>
    func writeFailureFrame113(value: OwnedFailureDataConsumer113,
        render: (AgentError, (Int64)->Result<Unit>)->Result<String>): OwnedFailureDataOutcome113<Unit>
}

