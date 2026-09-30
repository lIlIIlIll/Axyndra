package agent_product

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import std.time.*

@Test
class LocalInfrastructureContractTests {
    @TestCase
    func conditionalPublishRejectsChangedDestination(): Unit {
        let root = localInfrastructureTestTemp("publish-conflict")
        Directory.create(root, recursive: true)
        let path = root + "/target.txt"
        File.writeTo(path, "expected".toArray())
        let replacement = workspaceTemporary(path, "replacement")
        let expected = workspacePlainTemporary(path, "expected")
        try {
            File.writeTo(path, "changed".toArray())
            @Expect(workspacePublishIfMatches(replacement, path, expected),
                WorkspaceConditionalPublishOutcome.Conflict)
            @Expect(String.fromUtf8(File.readFrom(Path(path))), "changed")
            @Expect(String.fromUtf8(File.readFrom(Path(replacement))), "replacement")
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    func conditionalPublishAtomicallyInstallsMatchingReplacement(): Unit {
        let root = localInfrastructureTestTemp("publish-match")
        Directory.create(root, recursive: true)
        let path = root + "/target.txt"
        File.writeTo(path, "expected".toArray())
        let replacement = workspaceTemporary(path, "replacement")
        let expected = workspacePlainTemporary(path, "expected")
        try {
            @Expect(workspacePublishIfMatches(replacement, path, expected),
                WorkspaceConditionalPublishOutcome.Applied)
            @Expect(String.fromUtf8(File.readFrom(Path(path))), "replacement")
            @Expect(String.fromUtf8(File.readFrom(Path(replacement))), "expected")
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    func conditionalPublishRejectsRemovedDestination(): Unit {
        let root = localInfrastructureTestTemp("publish-removed")
        Directory.create(root, recursive: true)
        let path = root + "/target.txt"
        File.writeTo(path, "expected".toArray())
        let replacement = workspaceTemporary(path, "replacement")
        let expected = workspacePlainTemporary(path, "expected")
        try {
            remove(path)
            @Expect(workspacePublishIfMatches(replacement, path, expected),
                WorkspaceConditionalPublishOutcome.Conflict)
            @Expect(exists(Path(path)), false)
        } finally {
            remove(root, recursive: true)
        }
    }

    @TestCase
    func anchoredPublicationDoesNotFollowReplacedParent(): Unit {
        let root = localInfrastructureTestTemp("anchored-parent")
        let workspace = root + "/workspace"
        let parent = workspace + "/parent"
        let moved = workspace + "/moved"
        let external = root + "/external"
        Directory.create(parent, recursive: true)
        Directory.create(external, recursive: true)
        File.writeTo(parent + "/target.txt", "expected".toArray())
        File.writeTo(external + "/target.txt", "expected".toArray())
        let parentFd = workspaceOpenAnchoredParent(workspace, parent + "/target.txt")
        @Expect(parentFd >= 0, true)
        try {
            rename(parent, to: moved)
            SymbolicLink.create(parent, to: external)
            let anchoredPath = "/proc/self/fd/" + parentFd.toString() + "/target.txt"
            let replacement = workspaceTemporary(anchoredPath, "replacement")
            let expected = workspacePlainTemporary(anchoredPath, "expected")
            try {
                @Expect(workspacePublishIfMatches(replacement, anchoredPath, expected),
                    WorkspaceConditionalPublishOutcome.Applied)
                @Expect(String.fromUtf8(File.readFrom(Path(moved + "/target.txt"))), "replacement")
                @Expect(String.fromUtf8(File.readFrom(Path(external + "/target.txt"))), "expected")
                let createdPath = "/proc/self/fd/" + parentFd.toString() + "/created.txt"
                workspacePublish(workspaceTemporary(createdPath, "created"), createdPath, false)
                @Expect(String.fromUtf8(File.readFrom(Path(moved + "/created.txt"))), "created")
                @Expect(exists(Path(external + "/created.txt")), false)
            } finally {
                remove(replacement)
                remove(expected)
            }
        } finally {
            workspaceCloseAnchoredParent(parentFd)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func parentBindingRejectsSymlinkedWorkspaceAncestors(): Unit {
        let root = localInfrastructureTestTemp("anchored-symlink")
        let workspace = root + "/workspace"
        let external = root + "/external"
        Directory.create(workspace, recursive: true)
        Directory.create(external, recursive: true)
        SymbolicLink.create(workspace + "/parent", to: external)
        try {
            @Expect(workspaceOpenAnchoredParent(workspace, workspace + "/parent/file.txt") < 0, true)
            @Expect(workspaceOpenAnchoredParent(workspace, external + "/file.txt") < 0, true)
        } finally {
            remove(root, recursive: true)
        }
    }
}

func localInfrastructureTestTemp(label: String): String {
    let base = homeDirectory() + "/.cache/agent-tmp/axyndra-local-infrastructure-tests"
    if (!exists(Path(base))) { Directory.create(base, recursive: true) }
    base + "/" + label + "-" +
        DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
}
