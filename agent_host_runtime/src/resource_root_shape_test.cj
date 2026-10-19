package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func boundedFileProposal(content: String,digest: String,bytes: AgentValue): AgentValue {
    objectValue([ValueField("schema",textValue(HOST_FILE_APPLICATION_PROPOSAL_SCHEMA)),ValueField("operations",listValue([
        objectValue([ValueField("kind",textValue("replace")),ValueField("path",textValue("file.txt")),
            ValueField("content",textValue(content)),ValueField("expected_sha256",textValue(digest)),ValueField("expected_bytes",bytes)])]))])
}
@Test
class BoundedSingleFileProposalTests {
    @TestCase
    func controlByteContentFitsSingleFileTransportAndMultiOperationLimitIsUnchanged(): Unit {
        let content=String.fromUtf8(Array<Byte>(32768,repeat:1))
        let digest=modelPolicySha256(content.toArray())
        let proposal=boundedFileProposal(content,digest,integerValue(32768))
        @Expect(stringifyUnifiedJson(proposal).size>65536);@Expect(stringifyUnifiedJson(proposal).size<=229376)
        @Expect(hostValidatePluginFilePlanProposal(proposal).isOk())
        let operation=proposal.field("operations").getOrThrow().items[0]
        proposal.put("operations",listValue([operation,operation]))
        @Expect(hostValidatePluginFilePlanProposal(proposal).isError())
    }
    @TestCase
    func digestShapeAndIndependentRawByteCeilingCannotBeReplacedByJsonSize(): Unit {
        let digest=modelPolicySha256("before".toArray())
        for(invalid in [textValue("6"),integerValue(-1),integerValue(65537)]){
            @Expect(hostValidatePluginFilePlanProposal(boundedFileProposal("after",digest,invalid)).isError())
        }
        for(invalid in [digest.toAsciiUpper(),digest+"a","x"]){
            @Expect(hostValidatePluginFilePlanProposal(boundedFileProposal("after",invalid,integerValue(6))).isError())
        }
        let content=String.fromUtf8(Array<Byte>(32769,repeat:1))
        @Expect(hostValidatePluginFilePlanProposal(boundedFileProposal(content,digest,integerValue(6))).isError())
        let mixed=boundedFileProposal("after",digest,integerValue(6))
        mixed.field("operations").getOrThrow().items[0].put("expected_content",textValue("before"))
        @Expect(hostValidatePluginFilePlanProposal(mixed).isError())
    }
}
