# Context content data directories

Fresh Coding and Full installations discover Skills only in `${workspace_root}/.omp/skills`. In version 4 of `plugins/context.json`, `component_sources: false` excludes installed plugin components and `query.include_packaged: false` excludes Skills bundled with the provider itself. Minimal installs no Skills provider. Updating the distribution preserves existing operator selections and read scopes.

The workspace-only recipe requires a provider that accepts `include_packaged`. An older provider can still serve its existing configuration. If it rejects the new recipe, update it explicitly; do not remove the field to make the request succeed, since that would re-enable packaged Skills.

To include a settings directory, add it to `settingsRoot/plugins/context.json` as a resource and add its logical `path` to `query.resource_roots`. Keep the installed provider's namespace and package digest. For example, copy the workspace resource, change `source` to `${settings_root}/skills`, and change `path` to `user`. Add `user` to `query.resource_roots`.

List the settings directories you select in `settingsRoot/plugins/read-scopes.json`. For example, an operator who selects both managed and user Skills can use:

```json
{"version":1,"roots":["${settings_root}/managed-skills","${settings_root}/skills"]}
```

This file identifies ordinary content directories inside settings storage. It does not grant a capability or approval. These directories use the existing `outside-workspace.read` review class even when the settings directory is inside the workspace. The actual Run must retain the required WorkspaceRead capability and pass its normal approval policy.

The existing plugin registry supplies exact enabled installed component roots. No provider can add physical roots. The approved canonical read plan binds the full configuration bytes and file witness plus the registry projection revision and records. Removing/replacing the scope file, changing an installed component, or disable/re-enable invalidates a pending read. A new request can obtain a fresh review; old facts cannot restore a revoked classification.

Credential names, protected operating-system paths, `.git` and related control directories, and the Product state directory remain excluded before every scope match. A root cannot be the settings directory, its plugin management directory, or a directory within plugin management. Ordinary process read views retain their existing classifier. Verified handle traversal rejects symlinks and ancestor substitution before any selected content is copied.

Missing configuration supplies no operator data roots. Invalid, oversized, or linked configuration fails explicitly. Existing canonical facts without the new digest remain readable; newly executing Product reads must carry the new digest. This change does not implement cross-process registry locking or general-purpose filesystem read grants.
