#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("tui_visual_showcase.py")
SPEC = importlib.util.spec_from_file_location("tui_visual_showcase", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SHOWCASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHOWCASE)


class TuiVisualShowcaseTest(unittest.TestCase):
    def test_redaction_preserves_ansi_but_removes_secret_shapes(self) -> None:
        source = (
            "\x1b[31mAuthorization: Bearer very-secret-token\x1b[0m\n"
            '{"api_key":"sk-example-secret"}\n'
            "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n"
            "-----END OPENSSH PRIVATE KEY-----"
        )
        redacted = SHOWCASE.sanitized(
            source, {"SERVICE_TOKEN": "very-secret-token"}
        )
        self.assertIn("\x1b[31m", redacted)
        self.assertIn("[REDACTED", redacted)
        self.assertNotIn("very-secret-token", redacted)
        self.assertNotIn("sk-example-secret", redacted)
        self.assertNotIn("BEGIN OPENSSH", redacted)
        self.assertEqual(
            SHOWCASE.secret_findings(
                redacted, {"SERVICE_TOKEN": "very-secret-token"}
            ),
            [],
        )

    def test_gallery_split_uses_actual_frame_boundaries(self) -> None:
        plain = (
            "user message\n"
            "assistant reply\n"
            "╭─ ◐ Subagent · running\n"
            "│ current\n"
            "╰─\n"
            "╭─ ! Context usage is high · warning\n"
            "│ 924K tokens used\n"
            "╰─"
        )
        ansi = "\n".join(
            f"\x1b[1m{line}\x1b[0m" for line in plain.splitlines()
        )
        cards = SHOWCASE.split_gallery_cards(ansi)
        self.assertEqual(len(cards), 4)
        self.assertEqual(
            [(card.category, card.state) for card in cards],
            [
                ("user", "completed"),
                ("assistant", "completed"),
                ("subagent", "running"),
                ("warning", "warning"),
            ],
        )
        self.assertEqual(cards[2].filename, "gallery-003-subagent-running.png")

    def test_plain_gallery_preserves_the_styled_visible_hierarchy(self) -> None:
        styled = (
            "\x1b[32m╭─ ✓ Read src/a.cj · completed\x1b[0m\n"
            "│ file\n"
            "│ src/a.cj\n"
            "│ 1  let value = 42\n"
            "╰─"
        )
        plain = SHOWCASE.strip_ansi(styled)
        SHOWCASE.validate_plain_semantics(styled, plain)
        with self.assertRaisesRegex(SHOWCASE.ShowcaseError, "visible hierarchy"):
            SHOWCASE.validate_plain_semantics(styled, plain.replace("╭", "+"))

    def test_gallery_overview_manifest_record_has_stable_name_and_kind(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / SHOWCASE.GALLERY_OVERVIEW_FILENAME
            path.write_bytes(b"rendered-png-fixture")
            record = SHOWCASE.png_record(
                path, 960, 1200, kind="gallery-overview"
            )
        self.assertEqual(record["path"], "gallery-all.png")
        self.assertEqual(record["kind"], "gallery-overview")
        self.assertEqual(len(record["sha256"]), 64)

    def test_state_inference_does_not_treat_zero_failures_as_failed(self) -> None:
        self.assertEqual(
            SHOWCASE.infer_state(
                "$ cargo test",
                "╭──╮\n│ $ cargo test │\n│ 24 passed · 0 failed │\n│ 〈Wall: 2 ms | Exit: 0〉 │\n╰──╯",
            ),
            "completed",
        )
        self.assertEqual(
            SHOWCASE.infer_state(
                "$ cargo test",
                "╭──╮\n│ $ cargo test │\n│ error[E0308] │\n│ 〈Wall: 2 ms | Exit: 101〉 │\n╰──╯",
            ),
            "failed",
        )

    def test_lifecycle_gate_reports_missing_states(self) -> None:
        card = SHOWCASE.GalleryCard(
            1, "completed", "completed", "generic", "completed", "custom"
        )
        with self.assertRaisesRegex(
            SHOWCASE.ShowcaseError, "lifecycle coverage is incomplete"
        ):
            SHOWCASE.validate_gallery_coverage([card])

    def test_png_validation_checks_signature_and_nonzero_ihdr(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "valid.png"
            path.write_bytes(
                SHOWCASE.PNG_SIGNATURE
                + struct.pack(">I", 13)
                + b"IHDR"
                + struct.pack(">II", 640, 480)
                + b"\x08\x06\x00\x00\x00"
                + b"0000"
            )
            self.assertEqual(SHOWCASE.validate_png(path), (640, 480))
            path.write_bytes(b"not a png")
            with self.assertRaisesRegex(SHOWCASE.ShowcaseError, "invalid PNG"):
                SHOWCASE.validate_png(path)

    def test_dependency_failure_lists_every_required_capability(self) -> None:
        with (
            mock.patch.object(SHOWCASE.shutil, "which", return_value=None),
            self.assertRaises(SHOWCASE.DependencyError) as captured,
        ):
            SHOWCASE.dependency_commands("auto")
        message = str(captured.exception)
        self.assertIn("tmux", message)
        self.assertIn("ansi2html", message)
        self.assertIn("chromium", message)
        self.assertIn("wkhtmltoimage", message)

    def test_candidate_must_resolve_a_real_build_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "agent_app"
            artifact.write_text("fixture")
            artifact.chmod(0o755)
            self.assertEqual(
                SHOWCASE.candidate_artifact([str(artifact), "--fixture"], root),
                artifact.resolve(),
            )
            with self.assertRaisesRegex(SHOWCASE.ShowcaseError, "build artifact"):
                SHOWCASE.candidate_artifact(["missing/agent_app"], root)

    def test_tui_frame_requires_pinned_todo_hud_and_composer(self) -> None:
        task = "Capture the complete card gallery"
        draft = "Review every renderer state before release"
        frame = "\n".join(
            [
                "Todo 0/1 · [/] " + task,
                "╭─ ready  ◆ fixture · medium ─╮",
                "│ " + draft + " │",
                "╰─ Enter send · Shift+Enter newline ─╯",
            ]
        )
        SHOWCASE.validate_tui_frame(frame, task, draft)
        with self.assertRaisesRegex(SHOWCASE.ShowcaseError, "missing"):
            SHOWCASE.validate_tui_frame(frame.replace("Todo", "Tasks"), task, draft)

    def test_completion_frame_requires_open_popup_and_preserved_draft(self) -> None:
        task = "Capture the complete card gallery"
        frame = "\n".join(
            [
                "Todo 0/1 · [/] " + task,
                "╭─ ready  ◆ fixture · medium ─╮",
                "│ /help  Show command help │",
                "│ 1 completion │",
                "│ /he │",
                "╰─ Enter send · Shift+Enter newline ─╯",
            ]
        )
        SHOWCASE.validate_completion_frame(frame, task)
        with self.assertRaisesRegex(SHOWCASE.ShowcaseError, "preserve"):
            SHOWCASE.validate_completion_frame(frame.replace("│ /he │", "│ /help │"), task)


if __name__ == "__main__":
    unittest.main()
