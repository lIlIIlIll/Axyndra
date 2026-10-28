package agent_product

import agent_domain.*
import agent_runtime.*
import std.time.MonoTime

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
    func readOwnerFrame180(framePaid: LogicalJsonOwnerReservation, deadline: ?MonoTime): Result<String>
    func writeOwnerFrame180(frame: String, deadline: ?MonoTime): Result<Unit>
    func deriveOwnerFrameData180(bytes: Int64): LogicalJsonOwnerReservation
    func closeOwnerPeer180(): Result<Unit>
    func ownerConfiguration180(): ProductConfig
    func bindOwnerFrontendConsumer180(consumer: ProductOwnerFrontendConsumer180): Result<Unit>
}

// Concrete frontend cleanup executes its original helper/Future joins. The
// private connection controller separately proves the full enclosing return.
public interface ProductOwnerFrontendConsumer180 {
    func observeOwnerFrontendFailure180(receipt: ProductOwnerFrontendFailureConsumed180): Unit
    func closeOwnerFrontendConsumer180(): Result<Unit>
}

// Only the actual broker writer can mint this after its complete failure
// encoder, physical write and owned error consumer have acknowledged return.
// It is DATA-consumption evidence, never execution or refund authority.
public class ProductOwnerFrontendFailureConsumed180 {
    private let recipient: ProductOwnerFrontendConsumer180
    private let original: AgentError
    init(recipient: ProductOwnerFrontendConsumer180, original: AgentError) {
        this.recipient = recipient; this.original = original
    }
    public func matches180(actual: Object, error: AgentError): Bool {
        match (recipient as Object) {
            case Some(owner) => refEq(owner, actual) && refEq(original, error)
            case None => false
        }
    }
}
public interface ProductOwnerClientFrontend180 {
    func runOwnerClientFrontend180(): Int64
    func closeOwnerClientFrontend180(): Result<Unit>
}
