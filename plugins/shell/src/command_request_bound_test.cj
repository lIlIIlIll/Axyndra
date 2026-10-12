package shell_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ShellCommandRequestBoundTests {
    @TestCase
    func oversizedPhysicalUtf8OrEscapedControlRequestRefusesBeforeAnyChannelIntent(): Unit {
        let plain=String.fromUtf8(Array<Byte>(32768,repeat:b'x'))
        let controls=String.fromUtf8(Array<Byte>(8192,repeat:1u8))
        for(command in [plain,controls]){
            var refused=false
            try{let _=ShellPreparedCall("bash",jsonObject([JsonObjectEntry("command",jsonString(command))]),"actual-bound",10000)}
            catch(error:PluginFailure){refused=error.code=="shell_plugin.request_limit"}
            @Expect(refused)
        }
        let accepted=ShellPreparedCall("bash",jsonObject([JsonObjectEntry("command",jsonString("printf supported"))]),"actual-small",10000)
        @Expect(accepted.intents().items.size,1)
    }
}
