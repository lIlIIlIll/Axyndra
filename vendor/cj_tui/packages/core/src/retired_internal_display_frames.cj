package core

// This witness proves only that the real Terminal's internal Buffer/media
// fields and borrowed draw helper frames have retired. It deliberately does
// not acknowledge backend snapshots, output retention or product data owners.
// A data-only witness is never Source/effect or bank/payment authority.
public class RetiredInternalDisplayFrameReferences {
    private init() {}
    public static func retire(terminal: Terminal): ?RetiredInternalDisplayFrameReferences {
        if (!terminal.tryRetireInternalFrameReferences()) { return None }
        Some(RetiredInternalDisplayFrameReferences())
    }
    public func internalReferencesRetired(): Bool { true }
    public func transportPhysicallyAcknowledged(): Bool { false }
}
