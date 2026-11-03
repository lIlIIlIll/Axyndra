package agent_product

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func metadataProjectionRow(kind: String, path: String, source: String, witness: String): AgentValue {
    objectValue([ValueField("kind", textValue(kind)), ValueField("path", textValue(path)),
        ValueField("source", textValue(source)), ValueField("witness", textValue(witness)),
        ValueField("entries", listValue([]))])
}
@Test
class ContextMetadataProjectionTests {
    @TestCase
    func exactWitnessedDirectoryRefinementHasOneLogicalPathAndRetainsOtherRows(): Unit {
        let directory = metadataProjectionRow("directory", "component/references", "/owned/references", "d:exact")
        let metadata = metadataProjectionRow("metadata", "component/references", "/owned/references", "d:exact")
        let file = metadataProjectionRow("file", "component/SKILL.md", "/owned/SKILL.md", "f:exact")
        let absent = metadataProjectionRow("absence", "another/references", "/another/references", "a:exact")
        let value = lifecycleTestRequire(mergeInitialContextMetadataProjection([directory, file], [metadata, absent]))
        @Expect(value.size, 3)
        @Expect(canonicalAgentValue(value[0]), canonicalAgentValue(metadata))
        @Expect(canonicalAgentValue(value[1]), canonicalAgentValue(file))
        @Expect(canonicalAgentValue(value[2]), canonicalAgentValue(absent))
        @Expect(httpIntentText(directory, "kind"), "directory")
    }
    @TestCase
    func changedSourceWitnessKindAndDuplicateRowsNeverRefineAnOldDirectory(): Unit {
        let directory = metadataProjectionRow("directory", "component/references", "/owned/references", "d:exact")
        let metadata = metadataProjectionRow("metadata", "component/references", "/owned/references", "d:exact")
        for (changed in [
            metadataProjectionRow("metadata", "component/references", "/other/references", "d:exact"),
            metadataProjectionRow("metadata", "component/references", "/owned/references", "d:replaced"),
            metadataProjectionRow("absence", "component/references", "/owned/references", "d:exact"),
            metadataProjectionRow("file", "component/references", "/owned/references", "d:exact")]) {
            @Expect(mergeInitialContextMetadataProjection([directory], [changed]).isError())
        }
        @Expect(mergeInitialContextMetadataProjection([metadata], [metadata]).isError())
        @Expect(mergeInitialContextMetadataProjection([directory, directory], [metadata]).isError())
        @Expect(mergeInitialContextMetadataProjection([directory], [metadata, metadata]).isError())
        @Expect(mergeInitialContextMetadataProjection([
            metadataProjectionRow("directory", "component/references", "", "")], [
            metadataProjectionRow("metadata", "component/references", "", "")]).isError())
    }
}
