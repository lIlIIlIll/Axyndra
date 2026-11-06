package agent_tui

import core.*

// Combines actual producer quiescence, completed App/Terminal frames,
// concrete direct stdout physical flush and explicit Screen data clear.
// This conveys no Source/effect/bank grant and contains no copied payload.
public class RetiredOwnedTuiScreenReferences {
    private let producer: Object
    private init(producer: Object) { this.producer = producer }
    static func retire(screen: AgentScreen): ?RetiredOwnedTuiScreenReferences {
        // Screen obtains its own exact output installed by the real native
        // producer. An unrelated empty stdout receipt cannot be composed.
        if (!screen.retireActualNativeOutputAndScreenReferences()) { return None }
        // All old Screen clear-helper locals ended before receipt creation.
        match (screen.actualRegistryProducer167()) {
            case Some(actual) => Some(RetiredOwnedTuiScreenReferences(actual))
            case None => Option<RetiredOwnedTuiScreenReferences>.None } }
    static func retireHeadless180(screen: AgentScreen, actual: HeadlessDisplayProducer180): ?RetiredOwnedTuiScreenReferences {
        // A different concrete producer. It proves its actual TestBackend,
        // noncapturing result helper, async owner and bound stdout lifetime.
        if (!screen.retireActualHeadlessOutputAndScreenReferences180(actual)) { return None }
        match (screen.actualRegistryProducer167()) {
            case Some(producer) => Some(RetiredOwnedTuiScreenReferences(producer))
            case None => Option<RetiredOwnedTuiScreenReferences>.None }
    }
    public func copiedReferencesRetired(): Bool { true }
    public func acknowledgesRegistryProducer167(value: Object): Bool { refEq(producer, value) }
}
