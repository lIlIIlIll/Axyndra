package model_adapters

import agent_domain as domain

// Reuse the existing HTTP classification and Retry-After parser. The caller
// supplies an already bounded, credential-filtered exchange; this function
// performs no I/O, credential lookup, retry, or Attempt admission.
public func modelProviderHttpFailure(status: Int64, body: String, providerId: String,
    retryAfter: String): domain.AgentError {
    providerFailure(22, status, body.trimAscii(), providerId,
        retryAfterMillis: extractRetryAfterHeader("retry-after: " + retryAfter + "\n"))
}
