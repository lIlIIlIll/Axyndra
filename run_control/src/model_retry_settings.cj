package run_control

import std.sync.*

// Application setting only. Core remains the sole retry/Attempt authority;
// aborting an active request goes through its real Run cancellation path.
public class ModelRetrySettings {
    private let enabled: AtomicBool
    public init(enabled!: Bool = true) { this.enabled = AtomicBool(enabled) }
    public func setEnabled(value: Bool): Unit { enabled.store(value) }
    public func isEnabled(): Bool { enabled.load() }
}
