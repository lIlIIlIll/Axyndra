package native_sdk_fixture

import agent_sdk.*
import pure_provider_runtime.*
import sdk_fixture_extension.*
import yjson.*

main(): Int64 {
    let plugin = ThirdPartyFixturePlugin()
    let definition = plugin.definition()
    runPurePolicyProvider(definition.id, definition.version, ["fixture_echo"],
        { name, input =>
            match (plugin.invoke(NativePluginInvocation("native-provider-data", name, input))) {
                case SdkResult.Ok(value) => value
                case SdkResult.Err(error) => throw PureProviderError(error.code, error.message)
            }
        })
}
