package testkit_consumer
import agent_sdk.*
import yjson.*
import yjson_support.*

public class ConsumerNativePlugin <: NativePluginHandler {
    public func definition(): NativePluginDefinition {
        NativePluginDefinition("example.testkit-consumer", "1.0.0",
            [PluginContributionDefinition("consumer_echo", PluginContributionKind.Provider)])
    }
    public func validate(_kind: PluginContributionKind, _name: String, input: JsonNode): SdkResult<JsonNode> {
        match (input.field("text")) {
            case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Text) { SdkResult.Ok(input) }
                else { invalid("consumer.text_invalid") }
            case None => invalid("consumer.text_required")
        }
    }
    public func invoke(invocation: NativePluginInvocation): SdkResult<JsonNode> {
        validate(invocation.contributionKind, invocation.contribution, invocation.input)
    }
}
func invalid<T>(code: String): SdkResult<T> {
    SdkResult.Err(SdkError(SdkErrorKind.Validation, code, "invalid consumer input"))
}
