#!/usr/bin/env python3
"""Actual backend-process env parity, separate from the unchanged original15."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

BACKEND=None
class ShellEnvironmentParityTests(unittest.TestCase):
    def execute(self, inputs, readonly=False):
        with tempfile.TemporaryDirectory(prefix="shell-env-native-") as root:
            frames=[dict(schema="axyndra.shell-backend/v1",id=str(n),action="call",tool="bash_readonly" if readonly else "bash",input=value)
                    for n,value in enumerate(inputs)]
            command=[sys.executable,str(BACKEND),"--workspace",root]+(["--readonly"] if readonly else [])
            result=subprocess.run(command,input=b"".join(json.dumps(f,ensure_ascii=False).encode()+b"\n" for f in frames),capture_output=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            return [json.loads(line) for line in result.stdout.splitlines()]
    def test_real_env_literal_cannot_execute_substitution_and_persists_in_same_owned_shell(self):
        literal="雪'\"; $(printf forged)\nline"
        values=self.execute([dict(command='printf %s "$PARITY"',env={"PARITY":literal}),dict(command='printf %s "$PARITY"')])
        self.assertEqual([v["result"]["stdout"] for v in values],[literal,literal])
        self.assertTrue(all(v["status"]=="complete" and v["result"]["exitCode"]==0 for v in values))
    def test_invalid_environment_never_starts_a_shell_then_valid_original_command_runs(self):
        bad=[[],{"1BAD":"x"},{"GOOD":1},{"GOOD":"a\x00b"},{"BAD; touch escaped":"x"}]
        values=self.execute([dict(command="printf forbidden",env=e) for e in bad]+[dict(command="printf original")])
        self.assertTrue(all(v["error"]=="shell.env_invalid" and v["status"]=="complete" and v["result"] is None for v in values[:-1]))
        self.assertEqual(values[-1]["result"]["stdout"],"original")
    def test_pty_env_is_one_shot_while_readonly_exports_preserve_readonly_command_checks(self):
        values=self.execute([dict(command='test -t 1 && printf %s "$LOCAL"',pty=True,env={"LOCAL":"pty"}),dict(command='printf %s "${LOCAL-unset}"')])
        self.assertIn("pty",values[0]["result"]["stdout"])
        self.assertEqual(values[1]["result"]["stdout"],"unset")
        reads=self.execute([dict(command='printf %s "$READ"',env={"READ":"bounded"}),dict(command="touch forbidden",env={"READ":"bounded"})],readonly=True)
        self.assertEqual(reads[0]["result"]["stdout"],"bounded")
        self.assertEqual(reads[1]["error"],"tool.readonly_rejected")

    def test_actual_millisecond_deadline_refuses_ambiguous_values_then_kills_owned_command(self):
        with tempfile.TemporaryDirectory(prefix="shell-millisecond-native-") as root:
            bad=[dict(command="printf forbidden",timeout_ms=False),
                 dict(command="printf forbidden",timeout_ms=0),
                 dict(command="printf forbidden",timeout_ms=600001),
                 dict(command="printf forbidden",timeout_ms=100,timeout=1)]
            values=bad+[dict(command="sleep 0.05; printf milliseconds",timeout_ms=250),
                        dict(command="printf retained; sleep 1; printf forbidden > escaped.txt",timeout_ms=100)]
            frames=[dict(schema="axyndra.shell-backend/v1",id=str(n),action="call",tool="bash",input=v)
                    for n,v in enumerate(values)]
            started=time.monotonic()
            result=subprocess.run([sys.executable,str(BACKEND),"--workspace",root],
                input=b"".join(json.dumps(f).encode()+b"\n" for f in frames),capture_output=True,timeout=5)
            elapsed=time.monotonic()-started
            self.assertEqual(result.returncode,1,result.stderr)
            replies=[json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(len(replies),6)
            self.assertTrue(all(v["error"]=="shell.timeout_invalid" for v in replies[:4]))
            self.assertEqual(replies[4]["result"]["stdout"],"milliseconds")
            self.assertEqual(replies[5]["status"],"unknown")
            self.assertEqual(replies[5]["error"],"shell.command_timeout")
            self.assertGreaterEqual(elapsed,0.12)
            self.assertLess(elapsed,2.0)
            self.assertFalse((Path(root)/"escaped.txt").exists())

    def test_timeout_keeps_actual_partial_utf8_nul_bytes_without_changing_unknown_or_replaying(self):
        with tempfile.TemporaryDirectory(prefix="shell-partial-native-") as root:
            body=dict(command="printf 'out\\377\\000tail'; printf err-tail >&2; sleep 1; touch escaped",timeout_ms=100)
            frame=dict(schema="axyndra.shell-backend/v1",id="partial",action="call",tool="bash",input=body)
            run=subprocess.run([sys.executable,str(BACKEND),"--workspace",root],input=json.dumps(frame).encode()+b"\n",capture_output=True,timeout=3)
            self.assertEqual(run.returncode,1,run.stderr)
            reply=json.loads(run.stdout)
            self.assertEqual((reply["status"],reply["error"]),("unknown","shell.command_timeout"))
            observed=reply["result"]
            self.assertTrue(observed["timedOut"])
            self.assertEqual(observed["exitCode"],124)
            self.assertEqual(observed["workingDirectory"],"")
            self.assertEqual(observed["stdout"],"out\ufffd\x00tail")
            self.assertEqual(observed["stderr"],"err-tail")
            self.assertFalse((Path(root)/"escaped").exists())

    def test_terminal_result_reports_actual_pty_and_persistent_pipe_is_distinct(self):
        values=self.execute([dict(command="test -t 1 && printf actual-pty",pty=True),dict(command="printf actual-pipe")])
        self.assertTrue(values[0]["result"]["pty"])
        self.assertFalse(values[1]["result"]["pty"])
        self.assertEqual(values[0]["result"]["exitCode"],0)
        self.assertIn("actual-pty",values[0]["result"]["stdout"])

    def test_streamed_large_output_retains_every_actual_byte_with_original_bounded_frames(self):
        import base64,hashlib
        with tempfile.TemporaryDirectory(prefix="shell-stream-parity-") as root:
            frame=dict(schema="axyndra.shell-backend/v1",id="stream",action="call",tool="bash",
                       input=dict(command="head -c 131072 /dev/zero | tr '\\000' z; printf large-output-tail"))
            run=subprocess.run([sys.executable,str(BACKEND),"--workspace",root,"--stream-output"],input=json.dumps(frame).encode()+b"\n",capture_output=True,timeout=5)
            self.assertEqual(run.returncode,0,run.stderr)
            rows=[json.loads(raw) for raw in run.stdout.splitlines()]
            start=rows[0];self.assertEqual(start["type"],"output_begin")
            data=bytearray()
            for item in rows[1:-2]:
                self.assertEqual(item["type"],"output_chunk")
                self.assertEqual(item["offset"],len(data))
                data.extend(base64.b64decode(item["data_base64"],validate=True) if "data_base64" in item else item["text"].encode())
            self.assertEqual(rows[-2]["type"],"output_end")
            self.assertEqual(bytes(data),b"z"*131072+b"large-output-tail")
            self.assertEqual((start["bytes"],start["sha256"]),(len(data),hashlib.sha256(data).hexdigest()))
            self.assertTrue(all(len(raw)<60000 for raw in run.stdout.splitlines()))
            self.assertEqual(rows[-1]["status"],"complete")
            self.assertTrue(rows[-1]["result"]["truncated"])

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--backend",type=Path,required=True)
    options,other=parser.parse_known_args();BACKEND=options.backend.resolve(strict=True)
    unittest.main(argv=[sys.argv[0],*other],verbosity=2)
