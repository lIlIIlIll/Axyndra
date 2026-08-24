#!/usr/bin/env python3
"""Generate reproducible PNG evidence from the real axyndra gallery and TUI.

The script deliberately does not build axyndra (or its SDK).  It consumes an
existing executable, runs the repository's headless golden contract, then
captures a real tmux PTY frame.  All terminal pixels originate from axyndra;
HTML is only the transport used to rasterize ANSI output.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = Path("/tmp/axyndra-visuals")
DEFAULT_CANDIDATE = (
    "scripts/pinned_cangjie target/release/bin/agent_app --fixture"
)
GALLERY_OVERVIEW_FILENAME = "gallery-all.png"
DEFAULT_SDK_ROOT = Path(
    "/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260817/cangjie"
)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
HEADLESS_EXPECTED = (
    "tui golden ok sizes=120x36,80x24,60x18 "
    "semantics=welcome,user-strip,composer,status,wide-char"
)
REQUIRED_LIFECYCLES = (
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
    "expired",
)
ANSI_ESCAPE = re.compile(
    r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|.)"
)
SECRET_ENV_NAME = re.compile(
    r"(?:api[_-]?key|token|secret|password|credential|authorization)", re.IGNORECASE
)
PRIVATE_KEY = re.compile(
    r"-----BEGIN [^-\n]*PRIVATE KEY-----.*?-----END [^-\n]*PRIVATE KEY-----",
    re.IGNORECASE | re.DOTALL,
)
BEARER_TOKEN = re.compile(r"(?i)(\bBearer\s+)(?!\[REDACTED\])[^\s\"'<>]{8,}")
NAMED_SECRET = re.compile(
    r"(?i)((?:\"|')?(?:api[_-]?key|token|secret|password|authorization)"
    r"(?:\"|')?\s*[:=]\s*(?:\"|')?)(?!\[REDACTED)[^\s\"',}]{4,}"
)
SK_TOKEN = re.compile(r"\bsk-[A-Za-z0-9_-]{8,}\b")


class ShowcaseError(RuntimeError):
    pass


class DependencyError(ShowcaseError):
    pass


class GalleryCard(NamedTuple):
    index: int
    ansi: str
    plain: str
    category: str
    state: str
    title: str

    @property
    def filename(self) -> str:
        return (
            f"gallery-{self.index:03d}-{slug(self.category)}-"
            f"{slug(self.state)}.png"
        )


class Renderer(NamedTuple):
    kind: str
    executable: str


class TuiShowcaseFrames(NamedTuple):
    hud_composer: str
    completion_popup: str


def strip_ansi(text: str) -> str:
    return ANSI_ESCAPE.sub("", text).replace("\r", "")


def secret_environment_values(
    environment: dict[str, str] | None = None,
) -> list[tuple[str, str]]:
    source = os.environ if environment is None else environment
    values: list[tuple[str, str]] = []
    for name, value in source.items():
        if SECRET_ENV_NAME.search(name) and len(value) >= 8:
            values.append((name, value))
    values.sort(key=lambda item: len(item[1]), reverse=True)
    return values


def redact_secrets(
    text: str,
    environment: dict[str, str] | None = None,
) -> str:
    result = text
    for name, value in secret_environment_values(environment):
        result = result.replace(value, f"[REDACTED ENV:{name}]")
    result = PRIVATE_KEY.sub("[REDACTED PRIVATE KEY]", result)
    result = BEARER_TOKEN.sub(r"\1[REDACTED]", result)
    result = NAMED_SECRET.sub(r"\1[REDACTED]", result)
    result = SK_TOKEN.sub("[REDACTED]", result)
    result = result.replace("gallery-secret", "[REDACTED]")
    return result


def secret_findings(
    text: str,
    environment: dict[str, str] | None = None,
) -> list[str]:
    findings: list[str] = []
    for name, value in secret_environment_values(environment):
        if value in text:
            findings.append(f"environment:{name}")
    for name, pattern in (
        ("private-key", PRIVATE_KEY),
        ("bearer-token", BEARER_TOKEN),
        ("named-secret", NAMED_SECRET),
        ("sk-token", SK_TOKEN),
    ):
        if pattern.search(text):
            findings.append(name)
    if "gallery-secret" in text:
        findings.append("gallery-fixture-secret")
    return findings


def sanitized(
    text: str,
    environment: dict[str, str] | None = None,
) -> str:
    result = redact_secrets(text, environment)
    findings = secret_findings(result, environment)
    if findings:
        raise ShowcaseError(
            "secret redaction was incomplete: " + ", ".join(sorted(set(findings)))
        )
    return result


def slug(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return normalized[:48] or "unknown"


def first_command(names: tuple[str, ...]) -> str | None:
    for name in names:
        resolved = shutil.which(name)
        if resolved:
            return resolved
    return None


def dependency_commands(renderer: str) -> tuple[str, str, list[Renderer]]:
    missing: list[str] = []
    tmux = shutil.which("tmux")
    ansi2html = shutil.which("ansi2html")
    if tmux is None:
        missing.append("tmux")
    if ansi2html is None:
        missing.append("ansi2html")

    chromium = first_command(("chromium", "chromium-browser", "google-chrome"))
    wkhtml = shutil.which("wkhtmltoimage")
    renderers: list[Renderer] = []
    if renderer in ("auto", "chromium") and chromium:
        renderers.append(Renderer("chromium", chromium))
    if renderer in ("auto", "wkhtmltoimage") and wkhtml:
        renderers.append(Renderer("wkhtmltoimage", wkhtml))
    if not renderers:
        if renderer == "chromium":
            missing.append("one of chromium, chromium-browser, google-chrome")
        elif renderer == "wkhtmltoimage":
            missing.append("wkhtmltoimage")
        else:
            missing.append(
                "one of chromium, chromium-browser, google-chrome, wkhtmltoimage"
            )
    if missing:
        raise DependencyError("missing required dependencies: " + ", ".join(missing))
    assert tmux is not None and ansi2html is not None
    return tmux, ansi2html, renderers


def resolve_path_token(token: str, root: Path) -> Path | None:
    if token.startswith("-"):
        return None
    path = Path(token)
    if not path.is_absolute():
        path = root / path
    return path if path.is_file() else None


def candidate_artifact(command: list[str], root: Path) -> Path:
    executable_files: list[Path] = []
    for token in command:
        path = resolve_path_token(token, root)
        if path is not None and os.access(path, os.X_OK):
            executable_files.append(path.resolve())
        elif "/" not in token and not token.startswith("-"):
            resolved = shutil.which(token)
            if resolved:
                executable_files.append(Path(resolved).resolve())
    for path in reversed(executable_files):
        if path.name in ("agent_app", "axyndra"):
            return path
    raise ShowcaseError(
        "candidate must reference an existing executable agent_app/axyndra build artifact"
    )


def verify_candidate_freshness(artifact: Path, root: Path, required: bool) -> None:
    if not required:
        return
    relevant = (
        root / "agent_app/src/gallery_cli.cj",
        root / "agent_tui/src/gallery.cj",
        root / "agent_tui/src/event_cards.cj",
        root / "agent_tui/src/tui.cj",
    )
    newer = [path for path in relevant if path.is_file() and path.stat().st_mtime > artifact.stat().st_mtime]
    if newer:
        names = ", ".join(str(path.relative_to(root)) for path in newer)
        raise ShowcaseError(
            f"--require-fresh-candidate failed: candidate mtime is older than "
            f"visual sources ({names}); this optional check compares timestamps only "
            "and does not reject release-gate copies unless explicitly requested"
        )


def run_checked(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    timeout: float,
    purpose: str,
    input_text: str | None = None,
) -> str:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as error:
        raise DependencyError(f"{purpose}: executable not found: {error.filename}") from error
    except subprocess.TimeoutExpired as error:
        raise ShowcaseError(f"{purpose} timed out after {timeout:.1f}s") from error
    stdout = sanitized(completed.stdout, environment)
    stderr = sanitized(completed.stderr, environment)
    if completed.returncode != 0:
        detail = (stderr or stdout).strip()[-2000:]
        raise ShowcaseError(
            f"{purpose} failed with exit {completed.returncode}"
            + (f": {detail}" if detail else "")
        )
    return stdout


def terminal_environment(sdk_root: Path, state_home: Path) -> dict[str, str]:
    environment = os.environ.copy()
    for name in (
        "AGENT_TUI_HEADLESS",
        "AGENT_TUI_HEADLESS_TODO",
        "AGENT_TUI_HEADLESS_CARDS",
        "NO_COLOR",
    ):
        environment.pop(name, None)
    environment.update(
        {
            "CANGJIE_SDK_ROOT": str(sdk_root),
            "AXYNDRA_SDK_ROOT": str(sdk_root),
            "DISABLE_ZOXIDE": "1",
            "AXYNDRA_HOME": str(state_home),
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        }
    )
    return environment


def gallery_outputs(
    command: list[str],
    root: Path,
    sdk_root: Path,
    state_home: Path,
    width: int,
    timeout: float,
) -> tuple[str, str]:
    environment = terminal_environment(sdk_root, state_home)
    ansi = run_checked(
        [*command, "gallery", "--all", "--width", str(width)],
        cwd=root,
        environment=environment,
        timeout=timeout,
        purpose="gallery --all ANSI capture",
    )
    plain = run_checked(
        [*command, "gallery", "--all", "--width", str(width), "--plain"],
        cwd=root,
        environment=environment,
        timeout=timeout,
        purpose="gallery --all plain capture",
    )
    if "\x1b[" not in ansi:
        raise ShowcaseError("gallery --all emitted no ANSI styling")
    validate_plain_semantics(ansi, plain)
    return ansi.rstrip("\n"), plain.rstrip("\n")


def validate_plain_semantics(ansi: str, plain: str) -> None:
    if "\x1b" in plain:
        raise ShowcaseError("gallery --plain unexpectedly emitted ANSI escapes")
    styled_visible = strip_ansi(ansi).replace("\r", "").rstrip()
    plain_visible = plain.replace("\r", "").rstrip()
    if styled_visible != plain_visible:
        raise ShowcaseError(
            "gallery --plain changed the visible hierarchy instead of only "
            "removing ANSI styles"
        )


def is_border_start(line: str) -> bool:
    return line.lstrip().startswith("╭")


def is_border_end(line: str) -> bool:
    return line.lstrip().startswith("╰")


def extract_title(plain: str) -> str:
    for line in plain.splitlines():
        trimmed = line.strip()
        if not trimmed:
            continue
        if trimmed.startswith("╭─"):
            return trimmed[2:].strip(" ─╮")
        if trimmed.startswith("│"):
            content = trimmed.strip("│ ")
            if content and not set(content) <= set("─├┤ "):
                return content
        if not trimmed.startswith(("╭", "╰", "├")):
            return trimmed
    return "card"


def infer_category(title: str, plain: str, conversation_index: int) -> str:
    if not any(is_border_start(line) for line in plain.splitlines()):
        if conversation_index == 0:
            return "user"
        if conversation_index == 1:
            return "assistant"
        return "conversation"
    lowered = title.lower()
    checks = (
        ("permission", ("approval", "permission")),
        ("ask", ("choose implementation", "question")),
        ("plan", ("implementation plan",)),
        ("subagent", ("subagent",)),
        ("advisor", ("advisor",)),
        ("job", ("background", "job")),
        ("warning", ("context usage", "warning")),
        ("compaction", ("context compacted", "compaction")),
        ("summary", ("run summary", "summary")),
        ("git", ("git ", "git·")),
        ("mcp", ("mcp ", "mcp·")),
        ("http", ("http ", "request ·")),
        ("read", ("read ",)),
        ("search", ("search ",)),
        ("list", ("list ",)),
        ("edit", ("edit ",)),
        ("create", ("create ", "write ")),
        ("error", ("build failed", "error")),
        ("generic", ("custom", "generic")),
    )
    if lowered.startswith(("$", "run ")):
        return "shell"
    for category, needles in checks:
        if any(needle in lowered for needle in needles):
            return category
    first = re.sub(r"^[^A-Za-z0-9]+", "", lowered).split(" ", 1)[0]
    return slug(first or "card")


def infer_state(title: str, plain: str) -> str:
    lines = [line.strip().lower() for line in plain.splitlines() if line.strip()]
    focused = " ".join([title.lower(), *lines[:3], *lines[-4:]])
    checks = (
        ("awaiting_user", ("awaiting your decision", "awaiting_user")),
        ("timed_out", ("timed out", "timed_out", "timeout")),
        ("streaming", ("streaming",)),
        ("running", ("running",)),
        ("queued", ("queued",)),
        ("pending", (" pending", "waiting for approval")),
        ("denied", ("denied",)),
        ("cancelled", ("cancelled", "canceled")),
        ("expired", ("expired",)),
        ("warning", (" warning",)),
    )
    for state, needles in checks:
        if any(needle in focused for needle in needles):
            return state
    without_zero_failures = re.sub(r"\b0 failed\b", "", focused)
    if "failed" in without_zero_failures or re.search(
        r"\bexit(?::|\s)+[1-9][0-9]*\b", focused
    ):
        return "failed"
    if "completed" in focused or "✓" in focused or re.search(
        r"\bexit(?::|\s)+0\b", focused
    ):
        return "completed"
    return "unknown"


def split_gallery_cards(ansi: str) -> list[GalleryCard]:
    ansi_lines = ansi.splitlines()
    plain_lines = [strip_ansi(line) for line in ansi_lines]

    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(plain_lines):
        if not plain_lines[index].strip():
            index += 1
            continue
        if is_border_start(plain_lines[index]):
            end = index
            while end < len(plain_lines) and not is_border_end(plain_lines[end]):
                end += 1
            if end >= len(plain_lines):
                raise ShowcaseError(f"unterminated gallery card at line {index + 1}")
            spans.append((index, end + 1))
            index = end + 1
        else:
            spans.append((index, index + 1))
            index += 1

    cards: list[GalleryCard] = []
    conversation_index = 0
    for ordinal, (start, end) in enumerate(spans, start=1):
        styled = "\n".join(ansi_lines[start:end]) + "\x1b[0m"
        visible = "\n".join(plain_lines[start:end])
        title = extract_title(visible)
        category = infer_category(title, visible, conversation_index)
        if category in ("user", "assistant", "conversation"):
            conversation_index += 1
        state = "completed" if category in ("user", "assistant") else infer_state(title, visible)
        cards.append(GalleryCard(ordinal, styled, visible, category, state, title))
    return cards


def validate_gallery_coverage(cards: list[GalleryCard]) -> None:
    if not cards:
        raise ShowcaseError("gallery --all produced no cards")
    observed = {card.state for card in cards}
    missing = sorted(set(REQUIRED_LIFECYCLES) - observed)
    if missing:
        raise ShowcaseError(
            "gallery lifecycle coverage is incomplete or unreadable: " + ", ".join(missing)
        )


def ansi_to_html_fragment(
    ansi: str,
    ansi2html: str,
    environment: dict[str, str],
    timeout: float,
) -> str:
    fragment = run_checked(
        [ansi2html, "--partial", "--inline", "--scheme", "xterm"],
        cwd=ROOT,
        environment=environment,
        timeout=timeout,
        purpose="ansi2html conversion",
        input_text=ansi,
    )
    return sanitized(fragment, environment)


def terminal_html(fragment: str, title: str, columns: int) -> str:
    safe_title = html.escape(title, quote=True)
    minimum = max(24, columns)
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{safe_title}</title>
<style>
html, body {{ margin: 0; background: #090909; color: #f2f2f2; }}
body {{ display: inline-block; padding: 24px; }}
.terminal {{
  box-sizing: border-box; min-width: {minimum}ch; padding: 18px 20px;
  border: 1px solid #343434; border-radius: 10px; background: #101010;
  box-shadow: 0 12px 32px rgba(0, 0, 0, .45);
}}
pre {{
  margin: 0; white-space: pre; tab-size: 4; font-size: 16px;
  line-height: 1.34; font-family: "Maple Mono NF CN", "Noto Sans Mono CJK SC",
    "DejaVu Sans Mono", monospace; font-variant-ligatures: none;
}}
</style></head><body><div class="terminal"><pre>{fragment}</pre></div></body></html>
"""


def validate_png(path: Path) -> tuple[int, int]:
    try:
        payload = path.read_bytes()
    except FileNotFoundError as error:
        raise ShowcaseError(f"renderer did not create PNG: {path}") from error
    if len(payload) < 33 or payload[:8] != PNG_SIGNATURE:
        raise ShowcaseError(f"invalid PNG signature or truncated output: {path}")
    if payload[12:16] != b"IHDR":
        raise ShowcaseError(f"PNG is missing its leading IHDR chunk: {path}")
    width, height = struct.unpack(">II", payload[16:24])
    if width <= 0 or height <= 0:
        raise ShowcaseError(f"PNG has zero dimensions: {path}")
    return width, height


def render_html_with(
    renderer: Renderer,
    html_path: Path,
    png_path: Path,
    width: int,
    height: int,
    browser_home: Path,
    timeout: float,
) -> tuple[int, int]:
    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(browser_home),
            "XDG_CONFIG_HOME": str(browser_home / "config"),
            "XDG_CACHE_HOME": str(browser_home / "cache"),
        }
    )
    if renderer.kind == "chromium":
        command = [
            renderer.executable,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--hide-scrollbars",
            f"--window-size={width},{height}",
            f"--screenshot={png_path}",
            html_path.resolve().as_uri(),
        ]
    else:
        command = [
            renderer.executable,
            "--quiet",
            "--format",
            "png",
            "--width",
            str(width),
            "--disable-smart-width",
            str(html_path),
            str(png_path),
        ]
    run_checked(
        command,
        cwd=ROOT,
        environment=environment,
        timeout=timeout,
        purpose=f"{renderer.kind} PNG render",
    )
    return validate_png(png_path)


def choose_renderer(
    candidates: list[Renderer], temporary: Path, timeout: float
) -> Renderer:
    probe_html = temporary / "renderer-probe.html"
    probe_png = temporary / "renderer-probe.png"
    probe_html.write_text(
        terminal_html("renderer probe", "renderer probe", 24), encoding="utf-8"
    )
    failures: list[str] = []
    for renderer in candidates:
        probe_png.unlink(missing_ok=True)
        try:
            render_html_with(
                renderer,
                probe_html,
                probe_png,
                480,
                180,
                temporary / f"{renderer.kind}-home",
                timeout,
            )
            return renderer
        except ShowcaseError as error:
            failures.append(f"{renderer.kind}: {error}")
    raise DependencyError("no usable HTML-to-PNG renderer; " + "; ".join(failures))


def render_ansi_png(
    ansi: str,
    title: str,
    output: Path,
    columns: int,
    renderer: Renderer,
    ansi2html: str,
    temporary: Path,
    environment: dict[str, str],
    timeout: float,
) -> tuple[int, int]:
    safe_ansi = sanitized(ansi, environment)
    fragment = ansi_to_html_fragment(safe_ansi, ansi2html, environment, timeout)
    html_text = terminal_html(fragment, title, columns)
    if secret_findings(html_text, environment):
        raise ShowcaseError(f"refusing to render an HTML document containing secrets: {title}")
    html_path = temporary / (output.stem + ".html")
    html_path.write_text(html_text, encoding="utf-8")
    lines = max(1, len(strip_ansi(safe_ansi).splitlines()))
    width = max(520, min(2200, columns * 10 + 96))
    height = max(180, min(32000, lines * 24 + 100))
    return render_html_with(
        renderer,
        html_path,
        output,
        width,
        height,
        temporary / "renderer-home",
        timeout,
    )


def run_headless_todo_golden(
    command: list[str],
    root: Path,
    sdk_root: Path,
    state_home: Path,
    timeout: float,
) -> str:
    environment = terminal_environment(sdk_root, state_home)
    environment.update(
        {
            "AGENT_TUI_HEADLESS": "1",
            "AGENT_TUI_HEADLESS_TODO": "1",
            "AGENT_TUI_GOLDEN_TRACE": "1",
        }
    )
    stdout = run_checked(
        command,
        cwd=root,
        environment=environment,
        timeout=timeout,
        purpose="headless todo golden",
    )
    if HEADLESS_EXPECTED not in stdout:
        raise ShowcaseError("headless todo golden did not reach its expected semantic state")
    return HEADLESS_EXPECTED


def tmux_checked(
    tmux: str,
    socket: str,
    arguments: list[str],
    environment: dict[str, str],
    timeout: float,
    purpose: str,
) -> str:
    return run_checked(
        [tmux, "-L", socket, "-f", "/dev/null", *arguments],
        cwd=ROOT,
        environment=environment,
        timeout=timeout,
        purpose=purpose,
    )


def capture_pane(
    tmux: str,
    socket: str,
    session: str,
    environment: dict[str, str],
    timeout: float,
) -> str:
    return tmux_checked(
        tmux,
        socket,
        ["capture-pane", "-p", "-e", "-t", session],
        environment,
        timeout,
        "tmux capture-pane",
    ).rstrip("\n")


def wait_for_tui_text(
    tmux: str,
    socket: str,
    session: str,
    environment: dict[str, str],
    needles: tuple[str, ...],
    timeout: float,
) -> str:
    deadline = time.monotonic() + timeout
    observed = ""
    while time.monotonic() < deadline:
        observed = capture_pane(
            tmux, socket, session, environment, min(2.0, timeout)
        )
        visible = strip_ansi(observed)
        if all(needle in visible for needle in needles):
            return observed
        time.sleep(0.1)
    raise ShowcaseError(
        "TUI frame did not reach expected text: " + ", ".join(repr(item) for item in needles)
    )


def validate_tui_frame(frame: str, task: str, draft: str) -> None:
    visible = strip_ansi(frame)
    required = ("Todo ", task, "ready", "fixture", draft, "Enter send")
    missing = [value for value in required if value not in visible]
    if missing:
        raise ShowcaseError("TUI showcase frame is missing: " + ", ".join(missing))
    lines = visible.splitlines()
    todo_index = max(index for index, line in enumerate(lines) if "Todo " in line)
    hud_index = max(
        index
        for index, line in enumerate(lines)
        if "ready" in line and "fixture" in line
    )
    draft_index = max(index for index, line in enumerate(lines) if draft in line)
    if not (todo_index < hud_index < draft_index and draft_index - todo_index <= 3):
        raise ShowcaseError("Todo is not pinned directly above the HUD/composer")


def validate_completion_frame(frame: str, task: str) -> None:
    visible = strip_ansi(frame)
    # The popup may cover the compact HUD row at short terminal heights.  The
    # companion composer frame proves HUD/model state; this frame proves the
    # pinned Todo, popup, and untouched draft without requiring obscured text.
    required = ("Todo ", task, "/help", "completion", "Enter send")
    missing = [value for value in required if value not in visible]
    if missing:
        raise ShowcaseError(
            "TUI completion frame is missing: " + ", ".join(missing)
        )
    lines = visible.splitlines()
    if not any("/he" in line and "/help" not in line for line in lines):
        raise ShowcaseError("TUI completion frame does not preserve the /he draft")


def capture_real_tui(
    command: list[str],
    root: Path,
    sdk_root: Path,
    state_home: Path,
    workspace: Path,
    tmux: str,
    width: int,
    height: int,
    timeout: float,
) -> TuiShowcaseFrames:
    environment = terminal_environment(sdk_root, state_home)
    socket = f"axyndra-visual-{os.getpid()}-{time.time_ns() % 1_000_000_000}"
    session = "showcase"
    task = "Capture the complete card gallery"
    draft = "Review every renderer state before release"
    shell_command = shlex.join(
        [
            "env",
            "-u",
            "AGENT_TUI_HEADLESS",
            "-u",
            "AGENT_TUI_HEADLESS_TODO",
            "-u",
            "NO_COLOR",
            f"AXYNDRA_HOME={state_home}",
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            f"CANGJIE_SDK_ROOT={sdk_root}",
            f"AXYNDRA_SDK_ROOT={sdk_root}",
            "DISABLE_ZOXIDE=1",
            *command,
            "--cwd",
            str(workspace),
        ]
    )
    started = False
    try:
        tmux_checked(
            tmux,
            socket,
            [
                "new-session",
                "-d",
                "-x",
                str(width),
                "-y",
                str(height),
                "-c",
                str(root),
                "-s",
                session,
                shell_command,
            ],
            environment,
            timeout,
            "tmux TUI launch",
        )
        started = True
        wait_for_tui_text(
            tmux, socket, session, environment, ("fixture", "Enter send"), timeout
        )
        tmux_checked(
            tmux,
            socket,
            ["send-keys", "-t", session, "-l", f"/todo append Showcase {task}"],
            environment,
            timeout,
            "tmux todo input",
        )
        tmux_checked(
            tmux,
            socket,
            ["send-keys", "-t", session, "Enter"],
            environment,
            timeout,
            "tmux todo submit",
        )
        wait_for_tui_text(
            tmux, socket, session, environment, ("Todo ", task, "Enter send"), timeout
        )
        tmux_checked(
            tmux,
            socket,
            ["send-keys", "-t", session, "-l", draft],
            environment,
            timeout,
            "tmux composer input",
        )
        frame = wait_for_tui_text(
            tmux,
            socket,
            session,
            environment,
            ("Todo ", task, draft, "Enter send"),
            timeout,
        )
        frame = sanitized(frame, environment)
        validate_tui_frame(frame, task, draft)
        tmux_checked(
            tmux,
            socket,
            ["send-keys", "-t", session, *(["BSpace"] * len(draft))],
            environment,
            timeout,
            "tmux clear composer draft",
        )
        tmux_checked(
            tmux,
            socket,
            ["send-keys", "-t", session, "-l", "/he"],
            environment,
            timeout,
            "tmux slash completion input",
        )
        tmux_checked(
            tmux,
            socket,
            ["send-keys", "-t", session, "Tab"],
            environment,
            timeout,
            "tmux open completion popup",
        )
        completion_frame = wait_for_tui_text(
            tmux,
            socket,
            session,
            environment,
            ("Todo ", task, "/help", "completion", "Enter send"),
            timeout,
        )
        completion_frame = sanitized(completion_frame, environment)
        validate_completion_frame(completion_frame, task)
        return TuiShowcaseFrames(frame, completion_frame)
    finally:
        if started:
            subprocess.run(
                [tmux, "-L", socket, "kill-server"],
                cwd=root,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=min(3.0, timeout),
                check=False,
            )


def png_record(path: Path, width: int, height: int, **metadata: object) -> dict[str, object]:
    result: dict[str, object] = {
        "path": path.name,
        "width": width,
        "height": height,
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    result.update(metadata)
    return result


def publish(staging: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    generated = {path.name for path in staging.iterdir() if path.is_file()}
    for stale in output.glob("gallery-*.png"):
        if stale.name not in generated:
            stale.unlink()
    for path in staging.iterdir():
        if path.is_file():
            os.replace(path, output / path.name)


def generate(args: argparse.Namespace) -> dict[str, object]:
    root = ROOT
    command = shlex.split(args.candidate)
    if not command:
        raise ShowcaseError("--candidate must not be empty")
    artifact = candidate_artifact(command, root)
    verify_candidate_freshness(artifact, root, args.require_fresh_candidate)
    sdk_root = args.sdk_root.resolve()
    if not sdk_root.is_dir():
        raise ShowcaseError(f"fixed SDK root does not exist: {sdk_root}")

    tmux, ansi2html, renderer_candidates = dependency_commands(args.renderer)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="axyndra-visual-showcase-", dir=args.output.parent
    ) as temporary_name:
        temporary = Path(temporary_name)
        staging = temporary / "staging"
        state_root = temporary / "state"
        workspace = temporary / "workspace"
        staging.mkdir()
        state_root.mkdir()
        workspace.mkdir()
        environment = terminal_environment(sdk_root, state_root)
        renderer = choose_renderer(renderer_candidates, temporary, args.timeout)

        ansi, plain = gallery_outputs(
            command,
            root,
            sdk_root,
            state_root / "gallery",
            args.gallery_width,
            args.timeout,
        )
        cards = split_gallery_cards(ansi)
        validate_gallery_coverage(cards)
        artifacts: list[dict[str, object]] = []
        overview_target = staging / GALLERY_OVERVIEW_FILENAME
        overview_width, overview_height = render_ansi_png(
            ansi,
            "axyndra complete card gallery",
            overview_target,
            args.gallery_width,
            renderer,
            ansi2html,
            temporary,
            environment,
            args.timeout,
        )
        artifacts.append(
            png_record(
                overview_target,
                overview_width,
                overview_height,
                kind="gallery-overview",
                category="all",
                state="all",
            )
        )
        for card in cards:
            target = staging / card.filename
            width, height = render_ansi_png(
                card.ansi,
                card.title,
                target,
                args.gallery_width,
                renderer,
                ansi2html,
                temporary,
                environment,
                args.timeout,
            )
            artifacts.append(
                png_record(
                    target,
                    width,
                    height,
                    kind="gallery-card",
                    category=card.category,
                    state=card.state,
                    title=card.title,
                )
            )

        golden = run_headless_todo_golden(
            command,
            root,
            sdk_root,
            state_root / "headless-golden",
            args.timeout,
        )
        tui_frames = capture_real_tui(
            command,
            root,
            sdk_root,
            state_root / "pty",
            workspace,
            tmux,
            args.tui_width,
            args.tui_height,
            args.timeout,
        )
        tui_target = staging / "tui-hud-todo-composer.png"
        tui_width, tui_height = render_ansi_png(
            tui_frames.hud_composer,
            "axyndra HUD, pinned Todo, and composer",
            tui_target,
            args.tui_width,
            renderer,
            ansi2html,
            temporary,
            environment,
            args.timeout,
        )
        artifacts.append(
            png_record(
                tui_target,
                tui_width,
                tui_height,
                kind="tui-frame",
                semantics=["hud", "pinned-todo", "composer", "prompt"],
            )
        )
        completion_target = staging / "tui-completion-popup.png"
        completion_width, completion_height = render_ansi_png(
            tui_frames.completion_popup,
            "axyndra live Tab completion popup",
            completion_target,
            args.tui_width,
            renderer,
            ansi2html,
            temporary,
            environment,
            args.timeout,
        )
        artifacts.append(
            png_record(
                completion_target,
                completion_width,
                completion_height,
                kind="tui-completion",
                semantics=[
                    "first-tab-opens-popup",
                    "slash-command",
                    "draft-preserved",
                    "pinned-todo",
                ],
            )
        )
        manifest: dict[str, object] = {
            "schema": 1,
            "generator": "scripts/tui_visual_showcase.py",
            "candidate_artifact": str(artifact),
            "candidate_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
            "commands": {
                "candidate": sanitized(shlex.join(command), environment),
                "gallery_ansi": sanitized(
                    shlex.join(
                        [
                            *command,
                            "gallery",
                            "--all",
                            "--width",
                            str(args.gallery_width),
                        ]
                    ),
                    environment,
                ),
                "gallery_plain": sanitized(
                    shlex.join(
                        [
                            *command,
                            "gallery",
                            "--all",
                            "--width",
                            str(args.gallery_width),
                            "--plain",
                        ]
                    ),
                    environment,
                ),
                "headless_todo_golden": sanitized(shlex.join(command), environment),
                "tui_pty_candidate": sanitized(
                    shlex.join([*command, "--cwd", str(workspace)]), environment
                ),
            },
            "sdk_root": str(sdk_root),
            "renderer": renderer.kind,
            "gallery_card_count": len(cards),
            "gallery_lifecycles": sorted({card.state for card in cards}),
            "gallery_ansi_plain_visible_equal": True,
            "gallery_visible_sha256": hashlib.sha256(
                strip_ansi(ansi).rstrip().encode("utf-8")
            ).hexdigest(),
            "gallery_plain_sha256": hashlib.sha256(
                plain.replace("\r", "").rstrip().encode("utf-8")
            ).hexdigest(),
            "headless_golden": golden,
            "artifacts": artifacts,
        }
        manifest_text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
        if secret_findings(manifest_text, environment):
            raise ShowcaseError("refusing to publish a manifest containing secrets")
        (staging / "manifest.json").write_text(manifest_text, encoding="utf-8")
        publish(staging, args.output)
        return manifest


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate real axyndra gallery and TUI PNG acceptance artifacts."
    )
    parser.add_argument("--candidate", default=DEFAULT_CANDIDATE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--sdk-root", type=Path, default=DEFAULT_SDK_ROOT)
    parser.add_argument(
        "--renderer",
        choices=("auto", "chromium", "wkhtmltoimage"),
        default="auto",
    )
    parser.add_argument("--gallery-width", type=int, default=96)
    parser.add_argument("--tui-width", type=int, default=100)
    parser.add_argument("--tui-height", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument(
        "--require-fresh-candidate",
        action="store_true",
        help="optionally reject an artifact whose mtime predates visual sources",
    )
    args = parser.parse_args(argv)
    if args.gallery_width < 24 or args.gallery_width > 240:
        parser.error("--gallery-width must be between 24 and 240")
    if args.tui_width < 60 or args.tui_height < 18:
        parser.error("--tui-width/--tui-height must be at least 60x18")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        manifest = generate(args)
    except DependencyError as error:
        print(f"tui_visual_showcase: {error}", file=sys.stderr)
        return 2
    except ShowcaseError as error:
        print(f"tui_visual_showcase: {error}", file=sys.stderr)
        return 1
    print(
        f"tui visual showcase generated {len(manifest['artifacts'])} PNGs in "
        f"{args.output} with {manifest['renderer']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
