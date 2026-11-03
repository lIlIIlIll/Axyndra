package agent_store

// Both objects are the original actual exceptions. This is cleanup debt,
// never a Known no-effect proof, Source, receipt or user-facing error DTO.
class LiveMemoryRollbackCleanupFailure317 <: Exception {
    let original:Exception
    let cleanup:Exception
    init(original:Exception,cleanup:Exception){
        super(original.message)
        this.original=original;this.cleanup=cleanup
    }
}

// Immutable capture cell holder; the actual exception handle is cleared
// before the original paid owner leaves the distinct transaction frame.
class LiveMemoryRollbackFailureCapture318 {
    var value:?Exception=None<Exception>
}
