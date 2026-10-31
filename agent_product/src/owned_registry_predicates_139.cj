package agent_product

// This private production consumer returns only a Bool. It never takes a
// record out of the list, copies text, or offers a generic caller callback.
// The entire comparison frame returns before the owned list clears its actual
// record backings and retires only the independent list/record payments.
func productRegistryHasEnabledRecord139(records: OwnedPluginRecordList,
    namespace: String, digest: String): Bool {
    try { productRegistryEnabledRecordFrame139(records, namespace, digest) }
    finally { records.close() }
}

private func productRegistryEnabledRecordFrame139(records: OwnedPluginRecordList,
    namespace: String, digest: String): Bool {
    var found = false
    for (index in 0..records.size) {
        let record = records.at(index)
        if (record.enabled && record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace) &&
            record.descriptor.textEquals(PluginDescriptorText.ContentDigest, digest)) { found = true }
    }
    found
}
