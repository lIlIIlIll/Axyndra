package agent_host_runtime

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HostConfigurationTemporaryDirectoryTests {
    @TestCase
    func AbsoluteConfigurationUsesTheFirstTemporaryVariable(): Unit {
        @Expect(hostConfigurationTemporaryParent204({ name =>
            if (name == "TMPDIR") { Some("/preferred") } else { Some("/later") }
        }), "/preferred")
        @Expect(hostConfigurationTemporaryParent204({ name =>
            if (name == "TMPDIR") { Some("") } else if (name == "TMP") { Some("/second") }
            else { Some("/third") }
        }), "/second")
        @Expect(hostConfigurationTemporaryParent204({ name =>
            if (name == "TEMP") { Some("/third") } else { None<String> }
        }), "/third")
    }

    @TestCase
    func RelativeAndMissingValuesDoNotChooseAWorkspaceDirectory(): Unit {
        @Expect(hostConfigurationTemporaryParent204({ _ => Some("relative-temporary") }), "/tmp")
        @Expect(hostConfigurationTemporaryParent204({ _ => None<String> }), "/tmp")
        // A selected absolute path is not replaced just because creation may
        // fail. The actual caller observes that error at Directory.createTemp.
        @Expect(hostConfigurationTemporaryParent204({ name =>
            if (name == "TMPDIR") { Some("/explicit-unavailable-temporary") }
            else { Some("/fallback-must-not-be-tried") }
        }), "/explicit-unavailable-temporary")
    }

    @TestCase
    func PrivateConfigurationCopyRetainsWitnessChecksAndCleanup(): Unit {
        let temporary = hostConfigurationTemporaryDirectory204()
        try {
            let expectedParent = hostConfigurationTemporaryParent204({ name => getVariable(name) })
            @Expect(canonicalize(temporary.parent), canonicalize(Path(expectedParent)))
            let source = temporary.join("operator-selection")
            let captured = temporary.join("captured-selection")
            let original = "{\"version\":1,\"plugins\":[]}"
            File.writeTo(source, original.toArray())
            let witness = hostReadResourceWitness(source.toString()).value().getOrThrow()
            @Expect(hostReadResourceCopy(source.toString(), witness, captured.toString(),
                original.toArray().size).value().getOrThrow(), original.toArray().size)
            @Expect(String.fromUtf8(File.readFrom(captured)), original)
            File.writeTo(source, "changed-selection-with-different-size".toArray())
            @Expect(hostReadResourceCopy(source.toString(), witness,
                temporary.join("rejected-selection").toString(), 65536).isError(), true)
        } finally { remove(temporary, recursive: true) }
        @Expect(exists(temporary), false)
    }
}
