package agent_app

import agent_domain.*
import agent_tui.*

// Actual same-bank independent fixed metadata, not a new pool or an original
// full-row derived lease. Every node is prepaid before construction and the
// real App head adopts it before any fallible display projection.
class OwnedTuiDisplayRegistration {
    var next: ?OwnedTuiDisplayRegistration = None
    private var display: ?OwnedTuiToolDisplay = None
    private var metadataPayment: ?LogicalJsonCopiedDisplayAllocation
    init(metadataPayment: LogicalJsonCopiedDisplayAllocation) { this.metadataPayment = Some(metadataPayment) }
    func install(value: OwnedTuiToolDisplay): Unit { display = Some(value) }
    func clearFailedDisplayReference(): Unit { display = None }
    func metadataIsAcknowledged(): Bool { metadataPayment.isNone() || metadataPayment.getOrThrow().isAcknowledged() }
    func retireCopiedData(retired: RetiredOwnedTuiScreenReferences): Result<Unit> {
        match (display) {
            case Some(value) => match (value.closeAfterWholeScreenRetirement(retired)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => display = None; Result.Ok(()) }
            case None => Result.Ok(()) }
    }
    func takeMetadataAfterDataRetirement(): LogicalJsonCopiedDisplayAllocation {
        if (display.isSome()) { throw IllegalStateException("display registry data still live") }
        let paid = metadataPayment.getOrThrow(); metadataPayment = None; paid
    }
    // History/callback/session switches cannot retire this node. Only the
    // actual quiesced whole Screen and bound direct-StdOut receipt permit
    // data clear, node detachment, then independent metadata retirement.
    // Any failed step preserves the still-live owner/debt in actual fields.
}
