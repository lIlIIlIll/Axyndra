package core

import std.collection.*

public enum MediaKind {
    | Image
    | Animation
    | Video
    | Html
    | Diagram
    | Math
}

public enum MediaProtocol {
    | Text
    | Kitty
    | Sixel
}

public enum MediaFit {
    | Contain
    | Cover
    | Fill
    | Original
}

public class MediaSource {
    public let id: String
    public let uri: String
    public let kind: MediaKind
    public let alt: String

    public init(id: String, uri: String, kind!: MediaKind = MediaKind.Image, alt!: String = "") {
        this.id = id
        this.uri = uri
        this.kind = kind
        this.alt = alt
    }
}

public class MediaFrameData {
    public let protocol: MediaProtocol
    public let payload: String
    public let widthPixels: Int64
    public let heightPixels: Int64
    public let durationMillis: Int64

    public init(
        protocol: MediaProtocol,
        payload: String,
        widthPixels!: Int64 = 0,
        heightPixels!: Int64 = 0,
        durationMillis!: Int64 = 0
    ) {
        this.protocol = protocol
        this.payload = payload
        this.widthPixels = max(0, widthPixels)
        this.heightPixels = max(0, heightPixels)
        this.durationMillis = max(0, durationMillis)
    }

    public static func text(text: String): MediaFrameData {
        MediaFrameData(MediaProtocol.Text, text)
    }

    public static func kitty(rawBytes: Array<Byte>, widthPixels!: Int64 = 0, heightPixels!: Int64 = 0): MediaFrameData {
        MediaFrameData(MediaProtocol.Kitty, base64Encode(rawBytes), widthPixels: widthPixels, heightPixels: heightPixels)
    }

    public static func sixel(payload: String, widthPixels!: Int64 = 0, heightPixels!: Int64 = 0): MediaFrameData {
        MediaFrameData(MediaProtocol.Sixel, payload, widthPixels: widthPixels, heightPixels: heightPixels)
    }
}

public class MediaPlacement {
    public let id: String
    public let source: MediaSource
    public let area: Rect
    public let fit: MediaFit
    public let frameIndex: Int64
    public let frame: MediaFrameData

    public init(
        id: String,
        source: MediaSource,
        area: Rect,
        fit!: MediaFit = MediaFit.Contain,
        frameIndex!: Int64 = 0,
        frame!: ?MediaFrameData = None
    ) {
        this.id = id
        this.source = source
        this.area = area
        this.fit = fit
        this.frameIndex = max(0, frameIndex)
        this.frame = match (frame) {
            case Some(value) => value
            case None => MediaFrameData.text(mediaFallbackText(source))
        }
    }

    public func sameRenderContent(other: MediaPlacement): Bool {
        id == other.id &&
        source.id == other.source.id &&
        source.uri == other.source.uri &&
        area == other.area &&
        sameMediaFit(fit, other.fit) &&
        frameIndex == other.frameIndex &&
        sameMediaFrame(frame, other.frame)
    }
}

public enum MediaOpKind {
    | Draw
    | Clear
}

public class MediaOp {
    public let kind: MediaOpKind
    public let placement: MediaPlacement

    public init(kind: MediaOpKind, placement: MediaPlacement) {
        this.kind = kind
        this.placement = placement
    }
}

public func diffMediaPlacements(previous: Array<MediaPlacement>, next: Array<MediaPlacement>): Array<MediaOp> {
    let ops = ArrayList<MediaOp>()
    for (old in previous) {
        if (!containsMediaPlacementId(next, old.id)) {
            ops.add(MediaOp(MediaOpKind.Clear, old))
        }
    }
    for (item in next) {
        match (findMediaPlacement(previous, item.id)) {
            case Some(old) =>
                if (!item.sameRenderContent(old)) {
                    ops.add(MediaOp(MediaOpKind.Clear, old))
                    ops.add(MediaOp(MediaOpKind.Draw, item))
                }
            case None => ops.add(MediaOp(MediaOpKind.Draw, item))
        }
    }
    ops.toArray()
}

public func mediaFallbackText(source: MediaSource): String {
    if (!source.alt.isEmpty()) { source.alt }
    else if (!source.uri.isEmpty()) { source.uri }
    else { source.id }
}

public func mediaProtocolName(protocol: MediaProtocol): String {
    match (protocol) {
        case MediaProtocol.Text => "text"
        case MediaProtocol.Kitty => "kitty"
        case MediaProtocol.Sixel => "sixel"
    }
}

func sameMediaFit(left: MediaFit, right: MediaFit): Bool {
    match (left) {
        case MediaFit.Contain => match (right) { case MediaFit.Contain => true; case _ => false }
        case MediaFit.Cover => match (right) { case MediaFit.Cover => true; case _ => false }
        case MediaFit.Fill => match (right) { case MediaFit.Fill => true; case _ => false }
        case MediaFit.Original =>
            match (right) {
                case MediaFit.Original => true
                case _ => false
            }
    }
}

func sameMediaFrame(left: MediaFrameData, right: MediaFrameData): Bool {
    sameMediaProtocol(left.protocol, right.protocol) &&
    left.payload == right.payload &&
    left.widthPixels == right.widthPixels &&
    left.heightPixels == right.heightPixels &&
    left.durationMillis == right.durationMillis
}

func sameMediaProtocol(left: MediaProtocol, right: MediaProtocol): Bool {
    match (left) {
        case MediaProtocol.Text => match (right) { case MediaProtocol.Text => true; case _ => false }
        case MediaProtocol.Kitty => match (right) { case MediaProtocol.Kitty => true; case _ => false }
        case MediaProtocol.Sixel => match (right) { case MediaProtocol.Sixel => true; case _ => false }
    }
}

func containsMediaPlacementId(items: Array<MediaPlacement>, id: String): Bool {
    for (item in items) {
        if (item.id == id) { return true }
    }
    false
}

func findMediaPlacement(items: Array<MediaPlacement>, id: String): ?MediaPlacement {
    for (item in items) {
        if (item.id == id) { return Some(item) }
    }
    None
}

func base64Encode(bytes: Array<Byte>): String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var out = ""
    var i: Int64 = 0
    while (i < bytes.size) {
        let b0 = Int64(bytes[i])
        let has1 = i + 1 < bytes.size
        let has2 = i + 2 < bytes.size
        let b1 = if (has1) { Int64(bytes[i + 1]) } else { 0 }
        let b2 = if (has2) { Int64(bytes[i + 2]) } else { 0 }
        let n = (b0 << 16) | (b1 << 8) | b2
        out += base64Char(alphabet, (n >> 18) & 63)
        out += base64Char(alphabet, (n >> 12) & 63)
        out += if (has1) { base64Char(alphabet, (n >> 6) & 63) } else { "=" }
        out += if (has2) { base64Char(alphabet, n & 63) } else { "=" }
        i += 3
    }
    out
}

func base64Char(alphabet: String, index: Int64): String {
    unsafe { String.fromUtf8Unchecked([alphabet[index]]) }
}
