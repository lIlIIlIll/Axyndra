package agent_ports

import agent_domain.*

// Implementors own the real request-consuming resource lifecycle. Returning a
// callback, requesting cancellation, or reaching a terminal Run is insufficient.
public interface ReturningModelInputPort159 {
    func executeReturningInput159(request: ModelRequest, events: ModelEventSink, funding: ModelInputDataBudget159): ModelInputReturn159
}
