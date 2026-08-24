package agent_product

import agent_domain.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*

public class ProductWorktreeEntry {
    public let path: String
    public let kind: String
    public let parentRepo: String
    public let branch: String
    public let orphanReason: String

    public init(
        path: String,
        kind: String,
        parentRepo!: String = "",
        branch!: String = "",
        orphanReason!: String = ""
    ) {
        this.path = path
        this.kind = kind
        this.parentRepo = parentRepo
        this.branch = branch
        this.orphanReason = orphanReason
    }
}

public class ProductWorktreeRemoval {
    public let path: String
    public let ok: Bool
    public let error: String

    public init(path: String, ok: Bool, error!: String = "") {
        this.path = path
        this.ok = ok
        this.error = error
    }
}

public class ProductWorktreeClearResult {
    public let kept: Int64
    public let wouldRemove: Array<String>
    public let results: Array<ProductWorktreeRemoval>

    public init(
        kept: Int64,
        wouldRemove!: Array<String> = [],
        results!: Array<ProductWorktreeRemoval> = []
    ) {
        this.kept = kept
        this.wouldRemove = wouldRemove
        this.results = results
    }

    public func removed(): Int64 {
        var count: Int64 = 0
        for (result in results where result.ok) { count++ }
        count
    }

    public func failed(): Int64 {
        var count: Int64 = 0
        for (result in results where !result.ok) { count++ }
        count
    }
}

class ProductWorktreeRuntime {
    private let root: String
    private let processes: LocalProcessPort

    init(settingsRoot: String, processes: LocalProcessPort) {
        this.root = Path(settingsRoot).join("wt").normalize().toString()
        this.processes = processes
    }

    func list(): Result<Array<ProductWorktreeEntry>> {
        if (!exists(Path(root))) { return Result.Ok([]) }
        if (!FileInfo(Path(root)).isDirectory()) {
            return worktreeError<Array<ProductWorktreeEntry>>(
                "worktree.root_not_directory",
                "managed worktree root is not a directory: " + root
            )
        }
        try {
            let entries = ArrayList<ProductWorktreeEntry>()
            for (entry in Directory.readFrom(root)) {
                let directory = Path(root).join(entry.name).toString()
                if (!FileInfo(Path(directory)).isDirectory()) { continue }
                match (classify(directory)) {
                    case Some(value) =>
                        insertWorktreeSorted(entries, value)
                    case None =>
                        var nested: Int64 = 0
                        for (child in Directory.readFrom(directory)) {
                            let childPath = Path(directory)
                                .join(child.name).toString()
                            if (!FileInfo(Path(childPath)).isDirectory()) {
                                continue
                            }
                            match (classify(childPath)) {
                                case Some(value) =>
                                    insertWorktreeSorted(entries, value)
                                    nested++
                                case None => ()
                            }
                        }
                        if (nested == 0) {
                            let empty = directoryIsEmpty(directory)
                            insertWorktreeSorted(
                                entries,
                                ProductWorktreeEntry(
                                    directory,
                                    if (empty) { "empty" } else { "stray" },
                                    orphanReason: if (empty) {
                                        "empty directory"
                                    } else {
                                        "no recognizable worktree contents"
                                    }
                                )
                            )
                        }
                }
            }
            Result.Ok(entries.toArray())
        } catch (error: Exception) {
            worktreeError<Array<ProductWorktreeEntry>>(
                "worktree.scan_failed",
                error.message
            )
        }
    }

    func clear(
        all: Bool,
        dryRun: Bool
    ): Result<ProductWorktreeClearResult> {
        let entries = match (list()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let targets = ArrayList<ProductWorktreeEntry>()
        for (entry in entries) {
            if (all || entry.orphanReason != "") { targets.add(entry) }
        }
        let kept = entries.size - targets.size
        if (dryRun) {
            let paths = ArrayList<String>()
            for (entry in targets) { paths.add(entry.path) }
            return Result.Ok(ProductWorktreeClearResult(
                kept,
                wouldRemove: paths.toArray()
            ))
        }
        let removals = ArrayList<ProductWorktreeRemoval>()
        let parents = ArrayList<String>()
        for (target in targets) {
            let removal = removeEntry(target)
            removals.add(removal)
            if (removal.ok && target.parentRepo != "") {
                addUniqueString(parents, target.parentRepo)
            }
        }
        for (parent in parents) { prune(parent) }
        Result.Ok(ProductWorktreeClearResult(
            kept,
            results: removals.toArray()
        ))
    }

    private func classify(
        directory: String
    ): ?ProductWorktreeEntry {
        let gitFile = Path(directory).join(".git").toString()
        if (exists(Path(gitFile)) &&
            FileInfo(Path(gitFile)).isRegular()) {
            return Some(classifyGitWorktree(directory, gitFile))
        }
        var isolation = exists(
            Path(directory).join(".omp-isolation-owner.json")
        )
        if (!isolation) {
            for (name in ["m", "merged"]) {
                let path = Path(directory).join(name)
                if (exists(path) && FileInfo(path).isDirectory()) {
                    isolation = true
                    break
                }
            }
        }
        if (!isolation) { return None }
        let live = hasLiveIsolationOwner(directory)
        Some(ProductWorktreeEntry(
            directory,
            "task-isolation",
            orphanReason: if (live) {
                ""
            } else {
                "task-isolation leftover (no live task owns it)"
            }
        ))
    }

    private func classifyGitWorktree(
        directory: String,
        gitFile: String
    ): ProductWorktreeEntry {
        let contents = try {
            String.fromUtf8(File.readFrom(gitFile))
        } catch (error: Exception) {
            return ProductWorktreeEntry(
                directory,
                "pr-checkout",
                orphanReason: "cannot read .git file: " + error.message
            )
        }
        var authoredGitDir = ""
        for (line in contents.split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed.startsWith("gitdir:")) {
                authoredGitDir = trimmed[7..].trimAscii()
                break
            }
        }
        if (authoredGitDir == "") {
            return ProductWorktreeEntry(
                directory,
                "pr-checkout",
                orphanReason: "malformed .git file (no gitdir line)"
            )
        }
        let gitDir = if (Path(authoredGitDir).isAbsolute()) {
            Path(authoredGitDir).normalize()
        } else {
            Path(directory).join(authoredGitDir).normalize()
        }
        let parentRepo = gitDir.parent.parent.parent.toString()
        let branch = readWorktreeBranch(
            gitDir.join("HEAD").toString()
        )
        if (!exists(gitDir) || !FileInfo(gitDir).isDirectory()) {
            return ProductWorktreeEntry(
                directory,
                "pr-checkout",
                parentRepo: parentRepo,
                branch: branch,
                orphanReason: "parent repo no longer tracks this worktree"
            )
        }
        if (!exists(Path(parentRepo)) ||
            !FileInfo(Path(parentRepo)).isDirectory()) {
            return ProductWorktreeEntry(
                directory,
                "pr-checkout",
                parentRepo: parentRepo,
                branch: branch,
                orphanReason: "parent repo missing"
            )
        }
        ProductWorktreeEntry(
            directory,
            "pr-checkout",
            parentRepo: parentRepo,
            branch: branch
        )
    }

    private func removeEntry(
        entry: ProductWorktreeEntry
    ): ProductWorktreeRemoval {
        if (!worktreePathInside(root, entry.path)) {
            return ProductWorktreeRemoval(
                entry.path,
                false,
                error: "refusing to remove a path outside " + root
            )
        }
        if (entry.kind == "pr-checkout" &&
            entry.parentRepo != "" &&
            entry.orphanReason == "") {
            // Trusted product-maintenance boundary: this is initiated by the
            // worktree lifecycle controller after path ownership checks, not
            // by a model ToolCall. It must reach the parent repository, which
            // is intentionally outside the active workspace sandbox.
            let result = processes.execute(ProcessRequest(
                resolveExecutable(
                    ["/usr/bin/git", "/usr/local/bin/git"],
                    "git"
                ),
                operationId: OperationId(
                    "worktree-remove-" + safeOperationPart(entry.path)
                ),
                arguments: [
                    "-C", entry.parentRepo,
                    "worktree", "remove", "--force", entry.path
                ],
                timeoutMillis: 30000
            ))
            match (result) {
                case Result.Ok(value) =>
                    if (value.exitCode == 0) {
                        return ProductWorktreeRemoval(entry.path, true)
                    }
                case Result.Err(_) => ()
            }
        }
        try {
            let removed = removeIfExists(entry.path, recursive: true)
            ProductWorktreeRemoval(
                entry.path,
                removed || !exists(Path(entry.path)),
                error: if (removed || !exists(Path(entry.path))) {
                    ""
                } else {
                    "directory could not be removed"
                }
            )
        } catch (error: Exception) {
            ProductWorktreeRemoval(
                entry.path,
                false,
                error: error.message
            )
        }
    }

    private func prune(parent: String): Unit {
        if (!exists(Path(parent)) ||
            !FileInfo(Path(parent)).isDirectory()) {
            return
        }
        // Trusted product-maintenance boundary paired with removeEntry above;
        // the model-facing tool pipeline never supplies this ProcessRequest.
        let _ = processes.execute(ProcessRequest(
            resolveExecutable(
                ["/usr/bin/git", "/usr/local/bin/git"],
                "git"
            ),
            operationId: OperationId(
                "worktree-prune-" + safeOperationPart(parent)
            ),
            arguments: ["-C", parent, "worktree", "prune"],
            timeoutMillis: 30000
        ))
    }
}

func readWorktreeBranch(path: String): String {
    if (!exists(Path(path))) { return "" }
    try {
        let head = String.fromUtf8(File.readFrom(path)).trimAscii()
        if (head.startsWith("ref: refs/heads/")) {
            return head[16..]
        }
        ""
    } catch (_: Exception) {
        ""
    }
}

func hasLiveIsolationOwner(directory: String): Bool {
    let marker = Path(directory)
        .join(".omp-isolation-owner.json").toString()
    if (!exists(Path(marker))) { return false }
    let value = try {
        match (decodeAgentValue(
            String.fromUtf8(File.readFrom(marker))
        )) {
            case Result.Ok(item) => item
            case Result.Err(_) => return false
        }
    } catch (_: Exception) {
        return false
    }
    let pid = match (value.field("pid")) {
        case Some(field) =>
            if (field.kind != ValueKind.Number) { return false }
            try {
                Int64.parse(field.number)
            } catch (_: Exception) {
                return false
            }
        case None => return false
    }
    if (pid <= 0) { return false }
    let statPath = "/proc/" + pid.toString() + "/stat"
    if (!exists(Path(statPath))) { return false }
    let expected = match (value.field("startToken")) {
        case Some(field) =>
            if (field.kind == ValueKind.Text) {
                field.text
            } else {
                ""
            }
        case None => ""
    }
    if (expected == "") { return true }
    let current = linuxProcessStartToken(statPath)
    current == "" || current == expected
}

func linuxProcessStartToken(path: String): String {
    try {
        let stat = String.fromUtf8(File.readFrom(path)).trimAscii()
        let closing = match (stat.lastIndexOf(")")) {
            case Some(index) => index
            case None => return ""
        }
        let tail = stat[closing + 1..].trimAscii().split(" ")
        if (tail.size <= 19) { return "" }
        tail[19]
    } catch (_: Exception) {
        ""
    }
}

func directoryIsEmpty(path: String): Bool {
    for (_ in Directory.readFrom(path)) { return false }
    true
}

func insertWorktreeSorted(
    values: ArrayList<ProductWorktreeEntry>,
    value: ProductWorktreeEntry
): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 &&
        values[index].path < values[index - 1].path) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index--
    }
}

func addUniqueString(values: ArrayList<String>, value: String): Unit {
    for (item in values where item == value) { return }
    values.add(value)
}

func worktreePathInside(root: String, candidate: String): Bool {
    let canonicalRoot = try {
        canonicalize(Path(root)).toString()
    } catch (_: Exception) {
        Path(root).normalize().toString()
    }
    let canonicalCandidate = try {
        canonicalize(Path(candidate)).toString()
    } catch (_: Exception) {
        Path(candidate).normalize().toString()
    }
    canonicalCandidate.startsWith(canonicalRoot + "/")
}

func worktreeError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Internal,
        code,
        message
    ))
}
