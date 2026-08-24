package worktree_contract

import agent_domain.*
import agent_product.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        let settings = root + "/settings"
        let product = openProduct(config: ProductConfig(
            settingsRoot: settings,
            stateRoot: root + "/state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        let session = product.applicationSession()
        expect(
            session.managedWorktrees().value().getOrThrow().isEmpty(),
            "missing worktree root is an empty collection"
        )

        let wt = settings + "/wt"
        Directory.create(wt + "/empty", recursive: true)
        Directory.create(wt + "/stray", recursive: true)
        File.writeTo(
            wt + "/stray/note.txt",
            "unrecognized\n".toArray()
        )
        Directory.create(wt + "/dead/m", recursive: true)
        File.writeTo(
            wt + "/dead/.omp-isolation-owner.json",
            "{\"pid\":9223372036854775807,\"id\":\"dead\"}".toArray()
        )
        Directory.create(wt + "/live/m", recursive: true)
        File.writeTo(
            wt + "/live/.omp-isolation-owner.json",
            "{\"pid\":1,\"id\":\"live\"}".toArray()
        )

        let parent = root + "/repo"
        let gitDir = parent + "/.git/worktrees/pr-7"
        Directory.create(gitDir, recursive: true)
        File.writeTo(
            gitDir + "/HEAD",
            "ref: refs/heads/pr-7\n".toArray()
        )
        let checkout = wt + "/checkout"
        Directory.create(checkout, recursive: true)
        File.writeTo(
            checkout + "/.git",
            ("gitdir: " + gitDir + "\n").toArray()
        )

        let entries = session.managedWorktrees()
            .value().getOrThrow()
        expect(entries.size == 5, "all managed directory kinds are scanned")
        expectEntry(
            entries,
            wt + "/empty",
            "empty",
            "empty directory"
        )
        expectEntry(
            entries,
            wt + "/stray",
            "stray",
            "no recognizable worktree contents"
        )
        expectEntry(
            entries,
            wt + "/dead",
            "task-isolation",
            "task-isolation leftover (no live task owns it)"
        )
        expectEntry(entries, wt + "/live", "task-isolation", "")
        let pr = entry(entries, checkout)
        expect(
            pr.kind == "pr-checkout" &&
            pr.parentRepo == parent &&
            pr.branch == "pr-7" &&
            pr.orphanReason == "",
            "git tracking file resolves parent and branch"
        )

        let preview = session.clearManagedWorktrees(false, true)
            .value().getOrThrow()
        expect(
            preview.wouldRemove == [
                wt + "/dead",
                wt + "/empty",
                wt + "/stray"
            ] &&
            exists(Path(wt + "/dead")) &&
            exists(Path(wt + "/empty")) &&
            exists(Path(wt + "/stray")),
            "dry-run returns stable orphan targets without mutation"
        )
        let cleared = session.clearManagedWorktrees(false, false)
            .value().getOrThrow()
        expect(
            cleared.removed() == 3 &&
            cleared.failed() == 0 &&
            !exists(Path(wt + "/dead")) &&
            !exists(Path(wt + "/empty")) &&
            !exists(Path(wt + "/stray")) &&
            exists(Path(wt + "/live")) &&
            exists(Path(checkout)),
            "default clear removes only orphaned entries"
        )
        let all = session.clearManagedWorktrees(true, false)
            .value().getOrThrow()
        expect(
            all.removed() == 2 &&
            all.failed() == 0 &&
            !exists(Path(wt + "/live")) &&
            !exists(Path(checkout)),
            "all clear removes live isolation and checkout entries"
        )
        expect(
            session.managedWorktrees().value().getOrThrow().isEmpty(),
            "worktree list is empty after complete cleanup"
        )
        println("worktree contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func expectEntry(
    entries: Array<ProductWorktreeEntry>,
    path: String,
    kind: String,
    reason: String
): Unit {
    let value = entry(entries, path)
    expect(
        value.kind == kind && value.orphanReason == reason,
        "entry classification matches for " + path
    )
}

func entry(
    entries: Array<ProductWorktreeEntry>,
    path: String
): ProductWorktreeEntry {
    for (value in entries where value.path == path) { return value }
    throw IllegalStateException("missing worktree entry: " + path)
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
