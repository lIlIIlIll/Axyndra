package agent_product

import agent_domain.*

// Compatibility with Product.request's original return type. New callers use
// prepareRequest and handle Result. An unavailable selected policy never
// yields an executable request or silently drops its required preparation.
public class ProductRequestPreparationError <: Exception {
    public let error: AgentError
    public init(error: AgentError) { super(error.describe()); this.error = error }
}
