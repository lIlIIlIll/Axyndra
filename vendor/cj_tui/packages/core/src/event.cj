package core

import std.collection.*

@FastNative
foreign func read(fd: Int32, buf: CPointer<Unit>, count: UIntNative): IntNative

public interface InputSource {
    func readAvailable(maxBytes: Int64): Array<Byte>
}

public class StdinInputSource <: InputSource {
    public init() {}

    public func readAvailable(maxBytes: Int64): Array<Byte> {
        let capacity = max(1, maxBytes)
        let bytes = Array<Byte>(capacity, repeat: 0)
        unsafe {
            let handle = acquireArrayRawData(bytes)
            let n = read(STDIN_FILENO, CPointer<Unit>(handle.pointer), UIntNative(bytes.size))
            releaseArrayRawData(handle)
            if (n > 0) {
                return bytes[..Int64(n)]
            }
        }
        []
    }
}

public enum KeyCode {
    | Char(Rune)
    | CtrlC
    | Esc
    | Tab
    | BackTab
    | Enter
    | Backspace
    | Delete
    | Insert
    | Up
    | Down
    | Left
    | Right
    | Home
    | End
    | PageUp
    | PageDown
    | F(Int64)
}

public enum KeyProtocol {
    | Basic
    | ModifyOtherKeys
    | Kitty
}

public struct KeyModifier <: Equatable<KeyModifier> {
    public let shift: Bool
    public let alt: Bool
    public let ctrl: Bool
    public let superKey: Bool
    public let meta: Bool
    public let hyper: Bool
    public let capsLock: Bool
    public let numLock: Bool

    public init(
        shift!: Bool = false,
        alt!: Bool = false,
        ctrl!: Bool = false,
        superKey!: Bool = false,
        meta!: Bool = false,
        hyper!: Bool = false,
        capsLock!: Bool = false,
        numLock!: Bool = false
    ) {
        this.shift = shift
        this.alt = alt
        this.ctrl = ctrl
        this.superKey = superKey
        this.meta = meta
        this.hyper = hyper
        this.capsLock = capsLock
        this.numLock = numLock
    }

    public static func none(): KeyModifier {
        KeyModifier()
    }

    public static func fromCsiParam(value: Int64): KeyModifier {
        let encoded = max(1, value) - 1
        if (encoded > 7) {
            return KeyModifier(
                shift: (encoded & 1) != 0,
                alt: (encoded & 2) != 0,
                ctrl: (encoded & 4) != 0,
                superKey: (encoded & 8) != 0,
                hyper: (encoded & 16) != 0,
                meta: (encoded & 32) != 0,
                capsLock: (encoded & 64) != 0,
                numLock: (encoded & 128) != 0
            )
        }
        match (value) {
            case 2 => KeyModifier(shift: true)
            case 3 => KeyModifier(alt: true)
            case 4 => KeyModifier(shift: true, alt: true)
            case 5 => KeyModifier(ctrl: true)
            case 6 => KeyModifier(shift: true, ctrl: true)
            case 7 => KeyModifier(alt: true, ctrl: true)
            case 8 => KeyModifier(shift: true, alt: true, ctrl: true)
            case _ => KeyModifier()
        }
    }

    public operator func ==(other: KeyModifier): Bool {
        shift == other.shift &&
            alt == other.alt &&
            ctrl == other.ctrl &&
            superKey == other.superKey &&
            meta == other.meta &&
            hyper == other.hyper &&
            capsLock == other.capsLock &&
            numLock == other.numLock
    }

    public operator func !=(other: KeyModifier): Bool {
        !(this == other)
    }
}

public struct KeyEvent {
    public let code: KeyCode
    public let modifiers: KeyModifier
    public let text: ?String
    public let protocol: KeyProtocol
    public let nativeRepeat: Bool

    public init(
        code: KeyCode,
        modifiers!: KeyModifier = KeyModifier.none(),
        text!: ?String = None,
        protocol!: KeyProtocol = KeyProtocol.Basic,
        nativeRepeat!: Bool = false
    ) {
        this.code = code
        this.modifiers = modifiers
        this.text = text
        this.protocol = protocol
        this.nativeRepeat = nativeRepeat
    }
}

public enum MouseButton {
    | Left
    | Middle
    | Right
    | WheelUp
    | WheelDown
    | None
}

public enum MouseKind {
    | Down
    | Up
    | Drag
    | Move
    | Scroll
}

public struct MouseEvent {
    public let kind: MouseKind
    public let button: MouseButton
    public let x: Int64
    public let y: Int64
    public let modifiers: KeyModifier
    public init(kind: MouseKind, button: MouseButton, x: Int64, y: Int64, modifiers!: KeyModifier = KeyModifier.none()) {
        this.kind = kind
        this.button = button
        this.x = x
        this.y = y
        this.modifiers = modifiers
    }
}

public struct TickEvent {
    public let deltaMillis: Int64
    public let elapsedMillis: Int64
    public let frameIndex: Int64
    public let droppedFrames: Int64

    public init(deltaMillis!: Int64 = 0, elapsedMillis!: Int64 = 0, frameIndex!: Int64 = 0, droppedFrames!: Int64 = 0) {
        this.deltaMillis = max(0, deltaMillis)
        this.elapsedMillis = max(0, elapsedMillis)
        this.frameIndex = max(0, frameIndex)
        this.droppedFrames = max(0, droppedFrames)
    }
}

public enum TimerMode {
    | OneShot
    | Repeating
}

public enum FrameMissPolicy {
    | Drop
    | CatchUp(Int64)
}

public struct TimerEvent {
    public let id: String
    public let elapsedMillis: Int64
    public let firedCount: Int64
    public let droppedFrames: Int64

    public init(id: String, elapsedMillis!: Int64 = 0, firedCount!: Int64 = 1, droppedFrames!: Int64 = 0) {
        this.id = id
        this.elapsedMillis = max(0, elapsedMillis)
        this.firedCount = max(1, firedCount)
        this.droppedFrames = max(0, droppedFrames)
    }
}

public enum TimerPriority {
    | Immediate
    | Normal
    | Low
}

public enum Event {
    | KeyDown(KeyEvent)
    | KeyUp(KeyEvent)
    | KeyRepeat(KeyEvent)
    | KeyHeld(KeyEvent)
    | Mouse(MouseEvent)
    | FocusIn
    | FocusOut
    | Capabilities(TerminalCapabilities)
    | Paste(String)
    | Message(String)
    | ExecResult(String, Int64, String)
    | TextCompletion(String, TextCompletionResult)
    | PtyStarted(String)
    | PtyOutput(String, PtyOutputStream, Array<Byte>)
    | PtyExited(String, PtyExitStatus)
    | PtyFailed(String, String)
    | AsyncStarted(String)
    | AsyncCompleted(String, Event)
    | AsyncFailed(String, String)
    | AsyncCancelled(String)
    | DataReady(String, Int64)
    | DataFailed(String, Int64, String)
    | DataCancelled(String, Int64)
    | Tick(TickEvent)
    | Timer(TimerEvent)
    | Resize(Rect)
    | Unknown(Array<Byte>)
}

public struct PressedKey {
    public let key: KeyEvent
    public let heldMillis: Int64

    public init(key: KeyEvent, heldMillis!: Int64 = 0) {
        this.key = key
        this.heldMillis = max(0, heldMillis)
    }
}

class InputKeyState {
    var key: KeyEvent
    var heldMillis: Int64 = 0
    var sinceLastEventMillis: Int64 = 0

    init(key: KeyEvent) {
        this.key = key
    }
}

public class InputState {
    private let keys = ArrayList<InputKeyState>()
    private var mods: KeyModifier = KeyModifier.none()
    private let releaseAfterMillis: Int64

    public init(releaseAfterMillis!: Int64 = 180) {
        this.releaseAfterMillis = max(1, releaseAfterMillis)
    }

    public func handle(event: Event): Array<Event> {
        let generated = ArrayList<Event>()
        match (event) {
            case Event.KeyDown(key) => press(key)
            case Event.KeyRepeat(key) =>
                press(key)
                generated.add(Event.KeyHeld(key))
            case Event.KeyHeld(key) => press(key)
            case Event.KeyUp(key) => release(key)
            case Event.FocusOut => clear()
            case _ => ()
        }
        generated.toArray()
    }

    public func advance(deltaMillis: Int64): Array<Event> {
        let generated = ArrayList<Event>()
        var i: Int64 = 0
        while (i < keys.size) {
            keys[i].heldMillis += max(0, deltaMillis)
            keys[i].sinceLastEventMillis += max(0, deltaMillis)
            if (keys[i].sinceLastEventMillis >= releaseAfterMillis) {
                keys.remove(at: i)
                continue
            }
            generated.add(Event.KeyHeld(keys[i].key))
            i++
        }
        refreshModifiers()
        generated.toArray()
    }

    public func isPressed(key: KeyEvent): Bool {
        find(key) >= 0
    }

    public func pressedKeys(): Array<PressedKey> {
        let out = ArrayList<PressedKey>()
        for (state in keys) {
            out.add(PressedKey(state.key, heldMillis: state.heldMillis))
        }
        out.toArray()
    }

    public func modifiers(): KeyModifier {
        mods
    }

    public func clear(): Unit {
        while (keys.size > 0) { keys.remove(at: 0) }
        mods = KeyModifier.none()
    }

    private func press(key: KeyEvent): Unit {
        let index = find(key)
        if (index >= 0) {
            keys[index].key = key
            keys[index].sinceLastEventMillis = 0
        } else {
            keys.add(InputKeyState(key))
        }
        refreshModifiers()
    }

    private func release(key: KeyEvent): Unit {
        let index = find(key)
        if (index >= 0) {
            keys.remove(at: index)
        }
        refreshModifiers()
    }

    private func find(key: KeyEvent): Int64 {
        let id = keyIdentity(key)
        for (i in 0..keys.size) {
            if (keyIdentity(keys[i].key) == id) { return i }
        }
        -1
    }

    private func refreshModifiers(): Unit {
        var shift = false
        var alt = false
        var ctrl = false
        var superKey = false
        var meta = false
        var hyper = false
        var capsLock = false
        var numLock = false
        for (state in keys) {
            shift = shift || state.key.modifiers.shift
            alt = alt || state.key.modifiers.alt
            ctrl = ctrl || state.key.modifiers.ctrl
            superKey = superKey || state.key.modifiers.superKey
            meta = meta || state.key.modifiers.meta
            hyper = hyper || state.key.modifiers.hyper
            capsLock = capsLock || state.key.modifiers.capsLock
            numLock = numLock || state.key.modifiers.numLock
        }
        mods = KeyModifier(shift: shift, alt: alt, ctrl: ctrl, superKey: superKey, meta: meta, hyper: hyper, capsLock: capsLock, numLock: numLock)
    }
}

public class EventParser {
    private let inputSource: InputSource
    private var pending = ArrayList<Byte>()
    private var ready = ArrayList<Event>()
    private var lastReadByteCount: Int64 = 0
    private var pendingEscPolls: Int64 = 0
    private var inputDrainPending = false

    public init(inputSource!: InputSource = StdinInputSource()) {
        this.inputSource = inputSource
    }

    public func push(bytes: Array<Byte>): Array<Event> {
        for (b in bytes) {
            pending.add(b)
        }
        if (bytes.size > 0) {
            pendingEscPolls = 0
        }
        let events = parseAvailable()
        for (event in events) {
            ready.add(event)
        }
        drainReady()
    }

    public func readEvents(): Array<Event> {
        // SGR mouse reports are commonly around ten bytes each.  Reading
        // only 64 bytes leaves a fast wheel gesture queued across many app
        // frames, so a later direction reversal appears seconds late.
        // Drain a normal terminal input burst in one pass; parsing remains
        // incremental when a paste or escape sequence exceeds this window.
        var drained: Int64 = 0
        inputDrainPending = false
        while (drained < 65536) {
            let bytes = inputSource.readAvailable(min(4096, 65536 - drained))
            if (bytes.isEmpty()) {
                break
            }
            drained += bytes.size
            for (event in parseBytes(bytes)) {
                ready.add(event)
            }
            pendingEscPolls = 0
            if (drained >= 65536) {
                // A bounded drain keeps input floods fair to timers and PTYs.
                // The App must immediately continue parsing rather than wait
                // for a new EPOLLET edge while stdin may still be readable.
                inputDrainPending = true
            }
        }
        lastReadByteCount = drained
        drainReady()
    }

    public func readEvent(): ?Event {
        if (ready.size == 0) {
            let events = readEvents()
            for (event in events) {
                ready.add(event)
            }
        }
        if (ready.size > 0) {
            let event = ready[0]
            ready.remove(at: 0)
            return Some(event)
        }
        None
    }

    public func lastReadBytes(): Int64 {
        lastReadByteCount
    }

    public func hasPendingInputDrain(): Bool {
        inputDrainPending
    }

    public func flushEsc(): Array<Event> {
        if (pending.size == 1 && pending[0] == 0x1B) {
            pending.remove(at: 0)
            pendingEscPolls = 0
            ready.add(Event.KeyDown(KeyEvent(KeyCode.Esc)))
        }
        drainReady()
    }

    public func flushEscAfterPolls(polls: Int64): Array<Event> {
        if (pending.size == 1 && pending[0] == 0x1B) {
            pendingEscPolls++
            if (pendingEscPolls >= max(1, polls)) {
                return flushEsc()
            }
        } else {
            pendingEscPolls = 0
        }
        drainReady()
    }

    private func parseBytes(bytes: Array<Byte>): Array<Event> {
        for (b in bytes) {
            pending.add(b)
        }
        parseAvailable()
    }

    private func parseAvailable(): Array<Event> {
        let events = ArrayList<Event>()
        while (pending.size > 0) {
            if (pending[0] == 0x09) {
                drop(1)
                events.add(Event.KeyDown(KeyEvent(KeyCode.Tab)))
            } else if (pending[0] == 0x0D || pending[0] == 0x0A) {
                drop(1)
                events.add(Event.KeyDown(KeyEvent(KeyCode.Enter)))
            } else if (pending[0] == 0x7F || pending[0] == 0x08) {
                drop(1)
                events.add(Event.KeyDown(KeyEvent(KeyCode.Backspace)))
            } else if (pending[0] > 0 && pending[0] <= 0x1A) {
                let code = ctrlKeyCode(pending[0])
                drop(1)
                events.add(Event.KeyDown(KeyEvent(code, modifiers: ctrlKeyModifier(code))))
            } else if (pending[0] == 0x1B) {
                if (!parseEscape(events)) { break }
            } else {
                let data = pending.toArray()
                let expected = utf8ExpectedLength(pending[0])
                if (expected < 0) {
                    events.add(Event.Unknown(data[..1]))
                    drop(1)
                } else if (pending.size < expected) {
                    break
                } else {
                    try {
                        let (r, len) = Rune.fromUtf8(data, 0)
                        drop(len)
                        events.add(Event.KeyDown(KeyEvent(KeyCode.Char(r))))
                    } catch (_) {
                        events.add(Event.Unknown(data[..1]))
                        drop(1)
                    }
                }
            }
        }
        events.toArray()
    }

    private func parseEscape(events: ArrayList<Event>): Bool {
        if (pending.size == 1) {
            return false
        }
        if (pending.size == 2 && (pending[1] == b'[' || pending[1] == b'O')) {
            return false
        }
        if (pending.size >= 3 && pending[1] == b'[') {
            if (startsWith("\u{1B}[200~")) {
                return parseBracketedPaste(events)
            }
            if (pending[2] == b'<') {
                return parseSgrMouse(events)
            }
            if (pending[2] == b'Z') {
                return dropKey(events, KeyCode.BackTab, 3)
            }
            if (pending[2] == b'I') {
                drop(3)
                events.add(Event.FocusIn)
                return true
            }
            if (pending[2] == b'O') {
                drop(3)
                events.add(Event.FocusOut)
                return true
            }
            return parseCsiKey(events)
        } else if (pending.size >= 3 && pending[1] == b'O') {
            match (pending[2]) {
                case b'P' => dropKey(events, KeyCode.F(1), 3)
                case b'Q' => dropKey(events, KeyCode.F(2), 3)
                case b'R' => dropKey(events, KeyCode.F(3), 3)
                case b'S' => dropKey(events, KeyCode.F(4), 3)
                case _ => emitEsc(events)
            }
        } else {
            return parseAltKey(events)
        }
    }

    private func parseCsiKey(events: ArrayList<Event>): Bool {
        let end = findCsiEnd()
        if (end < 0) { return false }
        let data = pending.toArray()
        let body = unsafe { String.fromUtf8Unchecked(data[2..end]) }
        let parts = splitInts(body)
        if (pending[end] == b'u') {
            return parseKittyKey(events, parts, end)
        }
        if (pending[end] == b'~' && parts.size >= 3 && parts[0] == 27) {
            let modifiers = KeyModifier.fromCsiParam(parts[1])
            let code = keyCodeFromUnicode(parts[2])
            drop(end + 1)
            events.add(Event.KeyDown(KeyEvent(code, modifiers: modifiers, protocol: KeyProtocol.ModifyOtherKeys)))
            return true
        }
        let modifiers = if (parts.size >= 2) {
            KeyModifier.fromCsiParam(parts[parts.size - 1])
        } else {
            KeyModifier.none()
        }
        let code: ?KeyCode = match (pending[end]) {
            case b'A' => Some(KeyCode.Up)
            case b'B' => Some(KeyCode.Down)
            case b'C' => Some(KeyCode.Right)
            case b'D' => Some(KeyCode.Left)
            case b'H' => Some(KeyCode.Home)
            case b'F' => Some(KeyCode.End)
            case b'~' =>
                if (parts.size == 0) { None } else {
                    match (parts[0]) {
                        case 1 => Some(KeyCode.Home)
                        case 2 => Some(KeyCode.Insert)
                        case 3 => Some(KeyCode.Delete)
                        case 4 => Some(KeyCode.End)
                        case 5 => Some(KeyCode.PageUp)
                        case 6 => Some(KeyCode.PageDown)
                        case 15 => Some(KeyCode.F(5))
                        case 17 => Some(KeyCode.F(6))
                        case 18 => Some(KeyCode.F(7))
                        case 19 => Some(KeyCode.F(8))
                        case 20 => Some(KeyCode.F(9))
                        case 21 => Some(KeyCode.F(10))
                        case 23 => Some(KeyCode.F(11))
                        case 24 => Some(KeyCode.F(12))
                        case _ => None
                    }
                }
            case _ => None
        }
        match (code) {
            case Some(k) =>
                drop(end + 1)
                events.add(Event.KeyDown(KeyEvent(k, modifiers: modifiers)))
                true
            case None => emitEsc(events)
        }
    }

    private func parseKittyKey(events: ArrayList<Event>, parts: Array<Int64>, end: Int64): Bool {
        if (parts.size == 0) { return emitEsc(events) }
        let modifiers = if (parts.size >= 2) { KeyModifier.fromCsiParam(parts[1]) } else { KeyModifier.none() }
        let eventType = if (parts.size >= 3) { parts[2] } else { 1 }
        let code = keyCodeFromUnicode(parts[0])
        let text: ?String = match (code) {
            case KeyCode.Char(r) => Some(r.toString())
            case _ => None
        }
        let key = KeyEvent(code, modifiers: modifiers, text: text, protocol: KeyProtocol.Kitty, nativeRepeat: eventType == 2)
        drop(end + 1)
        match (eventType) {
            case 2 => events.add(Event.KeyRepeat(key))
            case 3 => events.add(Event.KeyUp(key))
            case _ => events.add(Event.KeyDown(key))
        }
        true
    }

    private func emitEsc(events: ArrayList<Event>): Bool {
        drop(1)
        events.add(Event.KeyDown(KeyEvent(KeyCode.Esc)))
        true
    }

    private func parseAltKey(events: ArrayList<Event>): Bool {
        if (pending.size < 2) { return false }
        drop(1)
        if (pending.size == 0) {
            events.add(Event.KeyDown(KeyEvent(KeyCode.Esc)))
            return true
        }
        if (pending[0] > 0 && pending[0] <= 0x1A) {
            let code = ctrlKeyCode(pending[0])
            drop(1)
            events.add(Event.KeyDown(KeyEvent(code, modifiers: altCtrlKeyModifier(code))))
            return true
        }
        let data = pending.toArray()
        let expected = utf8ExpectedLength(pending[0])
        if (expected > 0 && pending.size >= expected) {
            try {
                let (r, len) = Rune.fromUtf8(data, 0)
                drop(len)
                events.add(Event.KeyDown(KeyEvent(KeyCode.Char(r), modifiers: KeyModifier(alt: true))))
                return true
            } catch (_) {
                events.add(Event.Unknown(data[..1]))
                drop(1)
                return true
            }
        }
        if (expected < 0) {
            events.add(Event.Unknown(data[..1]))
            drop(1)
            return true
        }
        false
    }

    private func parseBracketedPaste(events: ArrayList<Event>): Bool {
        if (!startsWith("\u{1B}[200~")) { return false }
        let end = indexOf("\u{1B}[201~", 6)
        if (end < 0) { return false }
        let data = pending.toArray()
        let content = unsafe { String.fromUtf8Unchecked(data[6..end]) }
        drop(end + 6)
        events.add(Event.Paste(content))
        true
    }

    private func parseSgrMouse(events: ArrayList<Event>): Bool {
        let end = findMouseEnd()
        if (end < 0) { return false }
        let data = pending.toArray()
        let seq = unsafe { String.fromUtf8Unchecked(data[3..end]) }
        let release = pending[end] == b'm'
        let parts = splitInts(seq)
        if (parts.size == 3) {
            events.add(Event.Mouse(mouseFrom(parts[0], parts[1] - 1, parts[2] - 1, release)))
        } else {
            events.add(Event.Unknown(data[..end + 1]))
        }
        drop(end + 1)
        true
    }

    private func dropKey(events: ArrayList<Event>, code: KeyCode, n: Int64): Bool {
        drop(n)
        events.add(Event.KeyDown(KeyEvent(code)))
        true
    }

    private func findCsiEnd(): Int64 {
        for (i in 2..pending.size) {
            let b = pending[i]
            if ((b >= b'A' && b <= b'Z') || (b >= b'a' && b <= b'z') || b == b'~') {
                return i
            }
        }
        -1
    }

    private func drop(n: Int64): Unit {
        let count = min(max(0, n), pending.size)
        if (count == 0) { return }
        if (count == pending.size) {
            pending = ArrayList<Byte>()
            return
        }
        let remaining = pending.toArray()[count..]
        pending = ArrayList<Byte>()
        for (byte in remaining) {
            pending.add(byte)
        }
    }

    private func startsWith(prefix: String): Bool {
        let bytes = unsafe { prefix.rawData() }
        if (pending.size < bytes.size) { return false }
        for (i in 0..bytes.size) {
            if (pending[i] != bytes[i]) { return false }
        }
        true
    }

    private func indexOf(needle: String, start: Int64): Int64 {
        let bytes = unsafe { needle.rawData() }
        var i = start
        while (i + bytes.size <= pending.size) {
            var ok = true
            for (j in 0..bytes.size) {
                if (pending[i + j] != bytes[j]) {
                    ok = false
                }
            }
            if (ok) { return i }
            i++
        }
        -1
    }

    private func findMouseEnd(): Int64 {
        for (i in 3..pending.size) {
            if (pending[i] == b'M' || pending[i] == b'm') {
                return i
            }
        }
        -1
    }

    private func drainReady(): Array<Event> {
        let events = ready.toArray()
        ready = ArrayList<Event>()
        events
    }
}

func utf8ExpectedLength(first: Byte): Int64 {
    if (first < 0x80) { return 1 }
    if (first >= 0xC2 && first <= 0xDF) { return 2 }
    if (first >= 0xE0 && first <= 0xEF) { return 3 }
    if (first >= 0xF0 && first <= 0xF4) { return 4 }
    -1
}

func ctrlKeyCode(value: Byte): KeyCode {
    if (value == 0x03) {
        return KeyCode.CtrlC
    }
    KeyCode.Char(Rune(UInt32(b'a' + value - 1)))
}

func ctrlKeyModifier(code: KeyCode): KeyModifier {
    match (code) {
        case KeyCode.CtrlC => KeyModifier.none()
        case _ => KeyModifier(ctrl: true)
    }
}

func altCtrlKeyModifier(code: KeyCode): KeyModifier {
    match (code) {
        case KeyCode.CtrlC => KeyModifier(alt: true)
        case _ => KeyModifier(alt: true, ctrl: true)
    }
}

func keyCodeFromUnicode(value: Int64): KeyCode {
    match (value) {
        case 9 => KeyCode.Tab
        case 13 => KeyCode.Enter
        case 27 => KeyCode.Esc
        case 127 => KeyCode.Backspace
        case 57358 => KeyCode.Insert
        case 57359 => KeyCode.Delete
        case 57360 => KeyCode.Left
        case 57361 => KeyCode.Right
        case 57362 => KeyCode.Up
        case 57363 => KeyCode.Down
        case 57364 => KeyCode.PageUp
        case 57365 => KeyCode.PageDown
        case 57366 => KeyCode.Home
        case 57367 => KeyCode.End
        case _ =>
            if (value >= 57376 && value <= 57399) {
                KeyCode.F(value - 57375)
            } else {
                KeyCode.Char(Rune(UInt32(max(0, value))))
            }
    }
}

func keyIdentity(key: KeyEvent): String {
    let code = match (key.code) {
        case KeyCode.Char(r) => "char:" + r.toString()
        case KeyCode.CtrlC => "ctrl-c"
        case KeyCode.Esc => "esc"
        case KeyCode.Tab => "tab"
        case KeyCode.BackTab => "backtab"
        case KeyCode.Enter => "enter"
        case KeyCode.Backspace => "backspace"
        case KeyCode.Delete => "delete"
        case KeyCode.Insert => "insert"
        case KeyCode.Up => "up"
        case KeyCode.Down => "down"
        case KeyCode.Left => "left"
        case KeyCode.Right => "right"
        case KeyCode.Home => "home"
        case KeyCode.End => "end"
        case KeyCode.PageUp => "pageup"
        case KeyCode.PageDown => "pagedown"
        case KeyCode.F(n) => "f:${n}"
    }
    code
}

func mouseFrom(code: Int64, x: Int64, y: Int64, release: Bool): MouseEvent {
    let button = match (code & 0x43) {
        case 0 => MouseButton.Left
        case 1 => MouseButton.Middle
        case 2 => MouseButton.Right
        case 64 => MouseButton.WheelUp
        case 65 => MouseButton.WheelDown
        case _ => MouseButton.None
    }
    let kind = if (code >= 64) {
        MouseKind.Scroll
    } else if (release) {
        MouseKind.Up
    } else if ((code & 35) == 35) {
        MouseKind.Move
    } else if ((code & 32) != 0) {
        MouseKind.Drag
    } else {
        MouseKind.Down
    }
    MouseEvent(kind, button, x, y, modifiers: KeyModifier(
        shift: (code & 4) != 0,
        alt: (code & 8) != 0,
        ctrl: (code & 16) != 0
    ))
}
