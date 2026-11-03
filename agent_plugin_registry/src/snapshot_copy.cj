package agent_plugin_registry

foreign func axyndra_plugin_snapshot_copy(
    source: CString,
    destination: CString
): Int32

public func copyVerifiedPluginSnapshot(source: String, destination: String): Unit {
    unsafe {
        let sourcePath = LibC.mallocCString(source)
        try {
            let destinationPath = LibC.mallocCString(destination)
            try {
                let code = axyndra_plugin_snapshot_copy(sourcePath, destinationPath)
                if (code != 0) {
                    throw Exception(
                        "cannot copy plugin snapshot through verified handles, errno=" +
                            (-code).toString()
                    )
                }
            } finally { LibC.free(destinationPath) }
        } finally { LibC.free(sourcePath) }
    }
}

