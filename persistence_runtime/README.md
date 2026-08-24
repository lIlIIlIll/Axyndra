# persistence_runtime

Repository implementations for embedded and test deployments, plus the schema
compatibility policy shared by durable adapters.

Schema mismatch is explicit: callers must migrate offline or archive/reset.
There is no dual-reader compatibility path inside the agent core.
