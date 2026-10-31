package agent_tui

// A concrete Window cache witness, not a history or backend ACK. blit targets,
// widgets, Screen cards and mailbox/App/renderer owners may still retain data.
class RetiredDocumentWindowReferences {
    private init() {}
    static func retire(cache: DocumentWindowCache): ?RetiredDocumentWindowReferences {
        if (!cache.tryRetireInternalWindowReferences()) { return None }
        Some(RetiredDocumentWindowReferences())
    }
    func internalReferencesRetired(): Bool { true }
    func targetBufferReferencesAcknowledged(): Bool { false }
}
