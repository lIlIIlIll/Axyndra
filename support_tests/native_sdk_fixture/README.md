# Independent Native SDK executable

Cold-build this package against current SDK 3 source and the current bounded
provider runtime, then stage the produced executable as bin/native-sdk-fixture
beside axyndra.plugin.json. Import/enable through the normal Registry and invoke
provider fixture_echo through the real Host. No old compiled artifact is input.

The adjacent SDK sample's pure contract checks NUL/Unicode full output, malformed
input, duplicate contribution rejection, cancellation and deadlines. It does
not substitute for InstalledRoot approval/Source/Receipt/physical close tests.
