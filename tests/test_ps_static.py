"""Static checks on the PowerShell backend (docs/design.md 11 and 13.2): every script parses in Windows PowerShell
5.1, is ASCII only, and nothing turns a string into code on the host."""
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
sys.path.insert(0, SRC)

from vm_broker.backend import hyperv  # noqa: E402

BACKEND = Path(SRC) / "vm_broker" / "backend"
SCRIPTS = sorted(BACKEND.rglob("*.ps1"))
POWERSHELL = hyperv.POWERSHELL


class Static(unittest.TestCase):
    def test_ascii_only(self):
        for p in SCRIPTS:
            with self.subTest(script=p.name):
                self.assertTrue(all(b < 128 for b in p.read_bytes()), p.name)

    def test_python_sources_are_ascii(self):
        # invisible and bidi characters belong in escapes (​), never raw in a source line
        for p in sorted(Path(SRC).rglob("*.py")):
            with self.subTest(source=p.name):
                self.assertTrue(all(b < 128 for b in p.read_bytes()), str(p))

    def test_no_string_becomes_code_on_the_host(self):
        for p in SCRIPTS:
            text = p.read_text(encoding="ascii")
            code = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
            with self.subTest(script=p.name):
                self.assertNotRegex(code, r"(?i)\bInvoke-Expression\b|\biex\b")
                self.assertNotRegex(code, r"(?i)-EncodedCommand")
                creates = re.findall(r"(?i)\[scriptblock\]::Create", code)
                if p.name == "runner.ps1":
                    # the one exception: the runner sends our own files' text inline (Get-InlineScript)
                    self.assertEqual(len(creates), 1)
                    self.assertIn("[scriptblock]::Create((Get-InlineScript))", code)
                else:
                    self.assertEqual(creates, [])

    def test_vms_by_id_never_by_name(self):
        for p in SCRIPTS:
            code = p.read_text(encoding="ascii")
            with self.subTest(script=p.name):
                self.assertNotRegex(code, r"(?i)Invoke-Command\s+-VMName|New-PSSession\s+-VMName|Get-VM\s+-Name")

    def test_director_task_runs_at_normal_priority(self):
        # Task Scheduler's default priority 7 means below-normal CPU and low I/O priority for the director and its
        # ffmpeg; at sign-in, behind the guest's disk cap, that starved the director's first instance (2026-10-11).
        text = (BACKEND / "ps" / "VmbGuestBlocks.ps1").read_text(encoding="ascii")
        block = text[text.index("Register-ScheduledTask -TaskName 'LabDirector'") - 600:
                     text.index("Register-ScheduledTask -TaskName 'LabDirector'")]
        self.assertRegex(block, r"New-ScheduledTaskSettingsSet [^\n]*`\n[^\n]*-Priority 4\b")

    def test_inline_script_markers(self):
        main = (BACKEND / "ps" / "Vmb.ps1").read_text(encoding="ascii")
        self.assertIn("#VMB-DOTSOURCE-BEGIN", main)
        self.assertIn("#VMB-DOTSOURCE-END", main)
        modules = re.findall(r"Join-Path \$PSScriptRoot '(Vmb[A-Za-z]+\.ps1)'", main)
        runner = (BACKEND / "runner.ps1").read_text(encoding="ascii")
        for m in modules:
            self.assertIn("'%s'" % m, runner, "runner.ps1 must inline %s too" % m)

    def test_code_version_is_stable(self):
        self.assertEqual(hyperv.code_version(), hyperv.code_version())
        self.assertRegex(hyperv.code_version(), r"^[0-9a-f]{64}$")
        self.assertIn("Vmb.ps1", [p.name for p in hyperv.host_scripts()])
        self.assertNotIn("runner.ps1", [p.name for p in hyperv.host_scripts()])

    @unittest.skipUnless(os.path.exists(POWERSHELL), "Windows PowerShell is not here")
    def test_every_script_parses_in_windows_powershell(self):
        import tempfile
        check = ("$bad = 0\r\nforeach ($f in $args) { $t = $null; $e = $null\r\n"
                 "  [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)\r\n"
                 "  foreach ($x in $e) { $bad++; [Console]::Out.WriteLine($f + ':' + $x.Extent.StartLineNumber + ': ' + $x.Message) } }\r\n"
                 "exit $bad\r\n")
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "parse.ps1"
            f.write_text(check, encoding="ascii")
            r = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(f)]
                               + [str(p) for p in SCRIPTS], capture_output=True, text=True, stdin=subprocess.DEVNULL, env=hyperv.child_env())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
