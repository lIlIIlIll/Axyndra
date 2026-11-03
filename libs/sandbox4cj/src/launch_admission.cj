package sandbox4cj

// An additional trusted caller restriction. It never supplies sandbox policy,
// execution permission, process identity or cleanup ownership.
public interface SandboxProcessLaunchLease { func close(): Unit }
