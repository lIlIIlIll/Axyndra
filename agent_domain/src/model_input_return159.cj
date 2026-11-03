package agent_domain

// DATA lifecycle result. Returned means the implementing concrete provider's
// request-consuming helpers, registrations and physical input transports have
// all returned without an escaping input alias. It grants no Source or effect.
// A failure with unknown dynamic aliases remains Held with its original result.
public enum ModelInputReturn159 {
    Returned(Result<ModelReply>) | Held(Result<ModelReply>)
    | Pending(Result<ModelReply>, ModelInputReturnWitness159)
}

// A DATA-only derivation from the exact prepaid input owner. It cannot mint a
// bank, authorize a model call, or release the caller's original reservation.
public interface ModelInputDataBudget159 {
    func reserveRetainedModelMetadata159(bytes: Int64): LogicalJsonOwnerReservation
}

// A closed DATA query over the actual provider's retained callback/transport
// cells. It neither invokes producer code nor grants Source, retry or effect.
public interface ModelInputReturnWitness159 {
    func inputAliasesReturned159(): Bool
}
