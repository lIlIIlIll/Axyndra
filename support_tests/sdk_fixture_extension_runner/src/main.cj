package sdk_fixture_extension_runner

import sdk_fixture_extension.*

import legacy_sdk_fixture_extension.*

main(): Int64 {
    let nativeResult = runFixtureContract()
    if (nativeResult != 0) { return nativeResult }
    runLegacyFixtureContract()
}
