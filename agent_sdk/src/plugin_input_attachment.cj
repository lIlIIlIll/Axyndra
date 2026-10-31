package agent_sdk

// Optional native Tool metadata, with no callback, registry or authority.
// Missing metadata preserves the old protocol and stores no input artifact.
public func validPluginInputAttachmentDeclaration(field: String, maximum: Int64): Bool {
    if (field == "") { return maximum == 0 }
    if (field.size > 64 || maximum < 1 || maximum > 262144 || field == "host_plan" ||
        field == "_axyndra_context_read") { return false }
    let bytes = field.toArray()
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            byte == b'_' || (index > 0 && byte >= b'0' && byte <= b'9'))) { return false }
    }
    true
}
