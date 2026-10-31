package agent_store

// Mechanical typed delegation only. No binding, grant, fact, version/enum or
// business decision is converted. Every original caller keeps its checks.
func latestJournalOriginalWindowBackend(value:PluginDocumentStorageBackend):?SqliteOpaqueRowJournalWindowBackend{
    match(value as SqliteOpaqueRowJournalWindowBackend){case Some(actual)=>return Some(actual);case None=>()}
    match(value as SqliteOpaqueRowJournalLatestStreamBackend){case Some(actual)=>return Some(actual.windowBackend());case None=>()}
    match(value as SqliteOpaqueRowJournalStreamBackend){case Some(actual)=>return Some(actual.windowBackend());case None=>()}
    None
}
