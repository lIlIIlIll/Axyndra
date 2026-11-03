# Independent GitHub plugin

This package owns the GitHub schemas, command construction, repository/URL
handling and result formatting. Its native endpoint uses the generic managed
process-channel service. The package's Python backend invokes explicitly
configured `gh` and `git` executables inside the approved backend sandbox.
There is no host GitHub dispatcher on this new path and no MCP dependency.

The eleven local contribution IDs are `repo_view`, `file_read`, `pr_create`,
`pr_checkout`, `pr_push`, `search_issues`, `search_prs`, `search_code`,
`search_commits`, `search_repos` and `run_watch`. A tool takes the corresponding
legacy GitHub arguments except `op`, which is represented by the contribution
ID. Schemas and actual backend validation reject unknown fields.

Build an independent package on x86_64 Linux with
`bash plugins/github/build-package.sh --output NEW_DIRECTORY`. The artifact
contains its native endpoint, required non-system Cangjie shared libraries,
licenses and the backend Python source. Python 3, `gh` and `git` are explicit
dependencies of this optional backend; the Minimal host does not need them.
The package records the backend SHA alongside the entrypoint and runtime
closure. The source checkout and Cangjie SDK are not runtime requirements.

After importing and enabling the package through the existing plugin manager,
configure a service in the host's `plugins/lifecycle.json`: executable
`/usr/bin/python3`, arguments `-u`, the absolute installed
`backend/github_backend.py` path, `--gh`, the chosen absolute `gh` path,
`--git`, and the chosen absolute `git` path. Bind the actual installed package
digest and selected workspace. Put the backend source and executable paths
under explicitly allowed read-only mounts. Use the plugin configuration
`{"version":1,"request_timeout_ms":10000}` for the initial verified-test
profile. The native service contribution is `session`.

Workspace-changing operations require a `workspace_readwrite` backend grant.
Use a mediated network policy with the intended forge/API egress targets.
Host-network mode, if explicitly granted, permits the backend's wider network
access; it does not make the host enforce GitHub-specific URL checks. Process
and filesystem isolation still apply. Do not grant host networking merely to
avoid configuring intended egress.

Bind `GH_HOST` through an ordinary environment reference when needed. Bind
`GH_TOKEN`, `GITHUB_TOKEN` or enterprise token variables through the generic
opaque credential references and `secret_env`; do not put token text in tool
arguments or plugin configuration. The backend gets only the approved
environment. Its endpoint gets no raw credentials. Static inspection does not
launch Python, gh, git or the service.

The default call effect is conservative. Only an operator's exact
`read_only_tools` list can declare the read operations read-only. Do not place
`pr_create`, `pr_checkout` or `pr_push` on that list. Backend annotations do not
grant permission. Every active call freezes its exact request bytes before
approval, writes them through one canonical child Operation, and requires its
Receipt. Calls are never automatically replayed. Backend failures after command
handoff, incomplete output and cancellation remain unknown.

Push validation inspects all currently resolved push destinations with
`git remote get-url --push --all origin`, including URL rewriting, and rejects
non-HTTPS or mismatched forge destinations. The distinction from fetch URLs is
defined in the [Git remote documentation](https://git-scm.com/docs/git-remote).
This business check does not freeze all repository configuration across
separate Git processes; the mediated egress policy remains the network
enforcement boundary. File paths and branch refs are percent encoded as literal
API values.

Migration is not complete at this source checkpoint. The old built-in GitHub
path remains until actual installation, approval, cancellation and recovery
tests pass and dependency removal is validated. Seventeen backend business and
POSIX process tests have passed. Ten native protocol cases and five actual
Product cases are supplied but have not been compiled or run. The native
endpoint still has the initial 16 KiB preparation / 64 KiB result bounds and a
120-second configuration ceiling; large outputs and the legacy 30-minute
`run_watch` ceiling need the shared capacity/deadline migration. This candidate
does not declare A3-02 complete.
