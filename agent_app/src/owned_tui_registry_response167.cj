package agent_app

import agent_domain.*
import agent_product.*
import agent_tui.*
import logical_json_payload.LogicalJsonCopiedDisplayAllocation as ImportedLogicalJsonCopiedDisplayAllocation

// Installed in the real backend before fallible projection or any response
// reference escapes. Its metadata has a distinct same-bank payment.
class OwnedTuiRegistryRegistration167 {
    var next: ?OwnedTuiRegistryRegistration167 = None
    private var scope: ?OwnedApplicationRegistryResponse161
    private var rawResponse: ?Result<ApplicationResponse> = None
    private var copyPayment: ?LogicalJsonCopiedDisplayAllocation = None
    private var display: ?OwnedTuiRegistryResponseDisplay167 = None
    private var metadata: ?LogicalJsonCopiedDisplayAllocation
    private var projectionFailure: ?AgentError = None
    init(scope: OwnedApplicationRegistryResponse161, metadata: LogicalJsonCopiedDisplayAllocation) {
        this.scope = Some(scope); this.metadata = Some(metadata)
    }
    func installProjection167(producer: Object,
        serializerLifetime180!: ?OwnedTuiSerializerLifetime180 = None): Unit {
        let actual = scope.getOrThrow()
        let invoice = actual.copiedTuiResponseInvoice167()
        match (actual.acquireTuiCopiedDisplay167(invoice)) {
            case Result.Err(error) => rememberProjectionFailure167(error); throw Exception("display.registry_projection_pending")
            case Result.Ok(value) => copyPayment = Some(value) }
        // The field retains the precise ticket if construction is unknown.
        display = Some(OwnedTuiRegistryResponseDisplay167(producer, copyPayment.getOrThrow(), invoice,
            serializerLifetime180: serializerLifetime180))
        match (actual.borrowForTui167({ result =>
            rawResponse = Some(result); Result<Unit>.Ok(()) })) {
            case Result.Err(error) => rememberProjectionFailure167(error); throw Exception("display.registry_projection_pending")
            case Result.Ok(_) => () }
    }
    func originalResult167(): Result<ApplicationResponse> { rawResponse.getOrThrow() }
    func copiedDisplay167(): OwnedTuiRegistryResponseDisplay167 { display.getOrThrow() }
    func rememberProjectionFailure167(error: AgentError): Unit { projectionFailure = Some(error) }
    func retireResponseData167(screen: RetiredOwnedTuiScreenReferences,
        original: OwnedRegistryResponseRetirement161): Result<Unit> {
        match (display) {
            case Some(value) => match (value.closeAfterWholeScreenRetirement167(screen)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => display = None; copyPayment = None }
            case None => match (copyPayment) {
                case Some(value) => match (value.closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => copyPayment = None }
                case None => () } }
        clearRawResponseFrame167()
        match (scope) {
            case Some(value) =>
                if (!value.closeAfterActualCopiedResponse161(original)) {
                    return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "display.registry_original_pending", "maintenance response references remain paid")) }
                scope = None
            case None => () }
        Result<Unit>.Ok(())
    }
    func retireRootSerializedData180(receipt: TuiRootSerializerRetirement180, producer: Object): Result<Unit> {
        if (!receipt.acknowledges180(producer)) { return ownedTuiDisplayError("display.serializer_retirement_unknown") }
        match (display) {
            case Some(value) => match (value.closeAfterUnprojectedSerialization180(producer)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => display = None; copyPayment = None }
            case None => match (copyPayment) {
                case Some(value) => match (value.closeAfterCopiedDisplayRetirement()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => copyPayment = None }
                case None => () } }
        clearRawResponseFrame167()
        match (scope) {
            case Some(value) => if (!value.closeAfterActualCopiedResponse161(receipt)) {
                return ownedTuiDisplayError("display.registry_original_pending") }; scope = None
            case None => () }
        Result<Unit>.Ok(())
    }
    private func clearRawResponseFrame167(): Unit { rawResponse = None; projectionFailure = None }
    func takeMetadataAfterDataRetirement167(): LogicalJsonCopiedDisplayAllocation {
        if (scope.isSome() || rawResponse.isSome() || copyPayment.isSome() || display.isSome()) {
            throw IllegalStateException("maintenance response data still live") }
        let result = metadata.getOrThrow(); metadata = None; result
    }
}
