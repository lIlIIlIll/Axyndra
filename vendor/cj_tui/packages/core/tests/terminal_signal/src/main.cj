package terminal_signal_smoke

import core.*
import std.time.*

main(): Int64 {
    let backend = AnsiBackend()
    let session = TerminalSession(
        backend,
        mouse: true,
        mouseMove: true,
        focusEvents: true,
        keyboard: KeyboardOptions(mode: KeyboardProtocolMode.Auto, probe: TerminalProbeMode.Active, probeBudgetMillis: 1)
    )
    if (!session.start()) { return 1 }
    backend.write("READY\n")
    backend.flush()
    let input = StdinInputSource()
    while (true) {
        let bytes = input.readAvailable(1)
        if (bytes.size != 0) {
            // Raw Ctrl-C remains input (ISIG disabled), not a native signal.
            if (bytes[0] == 3) {
                backend.write("CTRL-C-INPUT\n")
            } else {
                backend.write("NORMAL-EXIT\n")
            }
            session.stop()
            session.stop()
            return 0
        }
        sleep(Duration.millisecond * 1)
    }
    0
}
