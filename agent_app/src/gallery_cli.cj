package agent_app

import agent_tui.*
import std.convert.*

let GALLERY_STATES = [
    "pending",
    "queued",
    "running",
    "streaming",
    "awaiting_user",
    "warning",
    "completed",
    "failed",
    "denied",
    "cancelled",
    "timed_out",
    "expired"
]

func runGalleryCli(arguments: Array<String>): Int64 {
    if (hasArgument(arguments, "--help") || hasArgument(arguments, "-h")) {
        println(
            "axyndra gallery [--tool <name>] [--state <state>] " + "[--width <columns>] [--expanded] [--plain] [--all]")
        println("states: " + galleryStateNames())
        return 0
    }
    match (galleryArgumentError(arguments)) {
        case Some(message) =>
            println("gallery.invalid_arguments: " + message);
            return 2
        case None => ()
    }
    if (hasArgument(arguments, "--png")) {
        println("gallery.png_adapter_unavailable: PNG output requires the optional vhs adapter")
        return 1
    }
    let widthText = argumentValue(arguments, "--width")
    let width = if (widthText == "") {
        80
    } else {
        try {
            Int64.parse(widthText)
        } catch (_: Exception) {
            println("gallery.invalid_width: --width must be an integer")
            return 2
        }
    }
    let state = argumentValueOr(arguments, "--state", "completed")
    if (!galleryState(state)) {
        println("gallery.invalid_state: " + state)
        return 2
    }
    if (hasArgument(arguments, "--all")) {
        println(renderTranscriptGallerySet(width: width, plain: hasArgument(arguments, "--plain")))
    } else {
        println(
            renderTranscriptGallery(
                tool: argumentValueOr(arguments, "--tool", "read"),
                state: state,
                width: width,
                expanded: hasArgument(arguments, "--expanded"),
                plain: hasArgument(arguments, "--plain")
            )
        )
    }
    0
}

func galleryArgumentError(arguments: Array<String>): ?String {
    var expects = ""
    for (argument in arguments) {
        if (expects != "") {
            if (argument.startsWith("-")) {
                return Some(expects + " requires a value")
            }
            expects = ""
            continue
        }
        if (argument == "--tool" || argument == "--state" || argument == "--width") {
            expects = argument
        } else if (argument.startsWith("--tool=") || argument.startsWith("--state=") || argument.startsWith("--width=")) {
            ()
        } else if (argument == "--expanded" || argument == "--plain" || argument == "--all" || argument == "--png" ||
            argument == "--help" || argument == "-h") {
            ()
        } else {
            return Some("unexpected argument: " + argument)
        }
    }
    if (expects != "") {
        Some(expects + " requires a value")
    } else {
        None
    }
}

func galleryState(value: String): Bool {
    for (state in GALLERY_STATES where state == value) {
        return true
    }
    false
}

func galleryStateNames(): String {
    var names = ""
    for (state in GALLERY_STATES) {
        if (names != "") {
            names += ", "
        }
        names += state
    }
    names
}
