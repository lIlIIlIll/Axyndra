# Context and resource contribution boundary

Native executable packages may declare `context_provider` or
`resource_provider` without any Tool. Ready declarations bind a name,
description and the exact `axyndra.context-provider/v1` or
`axyndra.resource-provider/v1` protocol to the enabled package generation.
These are entries in the existing plugin registry, not another catalog.

`ProductRuntime.resolvePluginContext` captures a bounded JSON query and a copy
of the caller's selected IDs before package verification or process scheduling.
The pure query has a thread and fresh nonce, no Run, Operation, model decision,
service calls, UI or execution authority. It may inspect its immutable package
data under the existing sandbox. It cannot read arbitrary workspace paths.
Both sides have a five-second deadline and a 192 KiB data bound. The host
rechecks package bytes and the same enabled generation before publishing data.

The result is exactly `schema: axyndra.context-result/v1` and `contributions`.
Each contribution contains `id`, `content`, and `references`. References contain
`id`, `provider`, and `resource_id`; their ResourceProvider must be declared by
the same installed package. Providers cannot set owner, trust, permissions or
context versions. The host assigns owner and package provenance. Only IDs
explicitly supplied by the host caller receive UserSelected trust; all other
content and lazy resources remain untrusted data. Missing or duplicate host
selections fail. Untrusted markup is escaped by the shared context formatter.

Lazy resource locators pin namespace, package digest, version and contribution.
The resource response contains only `schema: axyndra.resource-result/v1` and
`content`. A disabled, replaced or corrupted package cannot resolve an unloaded
reference. Already frozen bytes remain readable. Reading a resource returns data
without silently modifying a Run or creating a ToolResult. Consumers that need
a durable result must use the existing canonical operation path.

Passing `contextSnapshot` to Product's request builder freezes this data in the
existing Run snapshot and avoids legacy Skill discovery. Durable storage still
uses its historical column name; this does not create another context version
or change the #39 update rules.

This increment does not complete A5. Automatic workspace Skill discovery,
active-Run updates, canonical resource ToolResults, larger content profiles,
JS/TS language bindings and removal of legacy Skill APIs remain dependent work.
Four Runtime and five real-process Product cases are authored here; execution
evidence must be recorded separately after compilation. Static patch checks are
not product validation.
