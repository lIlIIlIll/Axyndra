# agent_extensions

Extensions contribute typed product objects. A tool contribution must provide a
complete `ToolDescriptor` (schema, capability, side-effect classification) and
a `ToolExecutor`; extensions cannot inject provider JSON or bypass the tool
pipeline.
