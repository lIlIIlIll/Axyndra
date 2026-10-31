# Context content data directories

The operator may create `settingsRoot/plugins/read-scopes.json` with:

```json
{"version":1,"roots":["${settings_root}/managed-skills","${settings_root}/skills"]}
```

This file identifies ordinary content directories inside settings storage. It does not grant a capability or approval. These directories use the existing `outside-workspace.read` review class even when the settings directory is inside the workspace. The actual Run must retain the required WorkspaceRead capability and pass its normal approval policy.

The existing plugin registry supplies exact enabled installed component roots. No provider can add physical roots. The approved canonical read plan binds the full configuration bytes and file witness plus the registry projection revision and records. Removing/replacing the scope file, changing an installed component, or disable/re-enable invalidates a pending read. A new request can obtain a fresh review; old facts cannot restore a revoked classification.

Credential names, protected operating-system paths, `.git` and related control directories, and the Product state directory remain excluded before every scope match. A root cannot be the settings directory, its plugin management directory, or a directory within plugin management. Ordinary process read views retain their existing classifier. Verified handle traversal rejects symlinks and ancestor substitution before any selected content is copied.

Missing configuration supplies no operator data roots. Invalid, oversized, or linked configuration fails explicitly. Existing canonical facts without the new digest remain readable; newly executing Product reads must carry the new digest. This change does not implement cross-process registry locking or general-purpose filesystem read grants.
