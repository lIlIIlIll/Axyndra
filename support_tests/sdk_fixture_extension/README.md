# Frozen Native SDK 3 consumer

The actual public NativePluginHandler exercises complete NUL/Unicode output, validation, duplicate declaration rejection, cancellation and deadline observations. The separate native_sdk_fixture wrapper uses the current bounded Native wire loop. Original cooperative source and assertions remain in legacy_sdk_fixture_extension and still run from sdk_fixture_extension_runner. Ordinary compatible v3 changes must not rewrite these consumer checks to conceal a break.
