package agent_product

import agent_domain.*
import agent_runtime.*

// Authenticated operator request DATA arrives here before Tool resolution,
// normalization, preparation or a Model Run. The concrete owner supplies its
// single actual Product; peers never carry a Prepared invocation or Source.
public interface ProductOwnerFrontend180 {
    func serveOwnerFrontend180(product: ProductRuntime, request: AgentValue,
        peer: ProductOwnerPeer180): Result<Unit>
}

// The concrete connection charges every codec/cursor/worker to its actual
// bank. Its limits stay at the existing broker's request/response bounds.
// Payments and physical connection cleanup confer no execution authority.
public interface ProductOwnerPeer180 {
    func readOwnerFrame180(framePaid: LogicalJsonOwnerReservation): Result<String>
    func writeOwnerFrame180(frame: String): Result<Unit>
    func deriveOwnerFrameData180(bytes: Int64): LogicalJsonOwnerReservation
    func closeOwnerPeer180(): Result<Unit>
    func ownerConfiguration180(): ProductConfig
    func bindOwnerFrontendConsumer180(consumer: ProductOwnerFrontendConsumer180): Result<Unit>
}

// Concrete frontend cleanup executes its original helper/Future joins. The
// private connection controller separately proves the full enclosing return.
public interface ProductOwnerFrontendConsumer180 {
    func closeOwnerFrontendConsumer180(): Result<Unit>
}
public interface ProductOwnerClientFrontend180 {
    func runOwnerClientFrontend180(): Int64
    func closeOwnerClientFrontend180(): Result<Unit>
}
