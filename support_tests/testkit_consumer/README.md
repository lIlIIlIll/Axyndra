# Frozen Native testkit 3 consumer

This independent source consumer uses NativePluginContractHarness with a genuine NativePluginHandler and checks malformed input and complete output. It has no Host executor, Source, OperationIntent or approval. Its entire old consumer/oracle is retained in legacy_testkit_consumer and executed separately by the SDK gate. Ordinary compatible v3 changes require this actual consumer to remain unchanged.
