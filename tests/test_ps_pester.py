"""Runs the Pester tests of the PowerShell backend (tests/ps/*.Tests.ps1) under Windows PowerShell 5.1 with the
Pester 3.4 that ships with Windows (docs/design.md 13.2). Every Hyper-V, task, certificate, registry and remoting
command is a stub there (tests/ps/VmbTestHelpers.ps1), so nothing on this machine or on a host changes.

Skipped where Windows PowerShell 5.1 or Pester 3.4.0 is not installed. Started without PowerShell 7's PSModulePath,
which would make 5.1 load the wrong module versions."""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RUNNER = os.path.join(HERE, "ps", "Run-Tests.ps1")
POWERSHELL = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0",
                          "powershell.exe")
PESTER = os.path.join(os.environ.get("ProgramW6432") or os.environ.get("ProgramFiles", r"C:\Program Files"),
                      "WindowsPowerShell", "Modules", "Pester", "3.4.0", "Pester.psd1")


@unittest.skipUnless(sys.platform == "win32" and os.path.exists(POWERSHELL), "needs Windows PowerShell 5.1")
@unittest.skipUnless(os.path.exists(PESTER), "needs Pester 3.4.0 (ships with Windows)")
class PesterBackend(unittest.TestCase):
    def test_backend_pester_suite_passes(self):
        env = {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}
        p = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", RUNNER],
                           capture_output=True, text=True, errors="replace", stdin=subprocess.DEVNULL, env=env,
                           timeout=1800)
        tail = (p.stdout[-8000:] + "\n" + p.stderr[-4000:]).strip()
        self.assertEqual(p.returncode, 0, tail)
        self.assertIn("0 failed", p.stdout, tail)


if __name__ == "__main__":
    unittest.main()
