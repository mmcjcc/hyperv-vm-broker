"""The relay's client: Windows PowerShell 5.1 Invoke-RestMethod against the director's server (fake desktop).

Checks what the relay depends on: Unicode text survives the trip (body sent as UTF-8 bytes), Expect: 100-continue
(Windows PowerShell's default) costs no extra wait, and error answers are 200 with ok=false while protocol refusals
are HTTP errors.
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from director_fakes import FakeClock, FakeDesktop, FakePopen  # noqa: E402

from vm_director.app import Director  # noqa: E402
from vm_director.record import Recorder  # noqa: E402
from vm_director.server import make_server  # noqa: E402

POWERSHELL = shutil.which("powershell.exe")
TOKEN = "ps-client-token-0123456789abcdef"

# ASCII only; non-ASCII characters are built from code points so the script file's encoding cannot matter.
CLIENT = r"""
param([int]$Port, [string]$Token)
$ErrorActionPreference = 'Stop'
$headers = @{ Authorization = "Bearer $Token" }
$base = "http://127.0.0.1:$Port"
function Invoke-Director([string]$Endpoint, $Payload, [switch]$StringBody) {
    $json = ConvertTo-Json -InputObject $Payload -Compress -Depth 5
    if ($StringBody) { $body = $json } else { $body = [System.Text.Encoding]::UTF8.GetBytes($json) }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Method Post -Uri ($base + $Endpoint) -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec 60
        $status = 200
    } catch [System.Net.WebException] {
        $r = $null
        $status = [int]$_.Exception.Response.StatusCode
    }
    $sw.Stop()
    return [pscustomobject]@{ endpoint = $Endpoint; status = $status; ms = $sw.ElapsedMilliseconds; result = $r }
}
$text = 'h' + [char]0xE9 + 'llo ' + [char]0x4E2D + ' ' + [char]::ConvertFromUtf32(0x1F600) + ' <&>"' + "'"
$all = @(
    (Invoke-Director '/health' @{}),
    (Invoke-Director '/type' @{ text = $text; cps = 60 }),
    (Invoke-Director '/type' @{ text = ('str' + [char]0xE9); cps = 60 } -StringBody),
    (Invoke-Director '/key' @{ combo = 'ctrl+shift+p' }),
    (Invoke-Director '/type' @{ text = 'x'; cps = 0 }),
    (Invoke-Director '/nope' @{})
)
$headers = @{ Authorization = 'Bearer wrong-token-0123456789' }
$all += Invoke-Director '/health' @{}
ConvertTo-Json -InputObject $all -Depth 6 -Compress
"""


@unittest.skipUnless(POWERSHELL and sys.platform == "win32", "needs Windows PowerShell")
class PowerShellClient(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vmdir-ps-")
        os.makedirs(os.path.join(self.root, "out"))
        with open(os.path.join(self.root, "token.txt"), "w") as f:
            f.write(TOKEN)
        self.clock = FakeClock()
        self.desk = FakeDesktop(self.clock)
        app = Director(self.root, self.desk, recorder=Recorder(self.root, popen=FakePopen(), clock=self.clock),
                       rng=random.Random(1), sleep=self.clock.sleep, clock=self.clock)
        self.server = make_server(app, self.root, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.script = os.path.join(self.root, "client.ps1")
        with open(self.script, "w", encoding="ascii", newline="\r\n") as f:
            f.write(CLIENT)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(self.root, ignore_errors=True)

    def test_invoke_restmethod(self):
        port = self.server.server_address[1]
        p = subprocess.run(env={k: v for k, v in os.environ.items() if k.upper() != 'PSMODULEPATH'}, args=[POWERSHELL, "-NoProfile", "-NonInteractive", "-File", self.script, "-Port", str(port),
                            "-Token", TOKEN], capture_output=True, timeout=120, stdin=subprocess.DEVNULL)
        self.assertEqual(p.returncode, 0, p.stderr.decode("utf-8", "replace"))
        calls = json.loads(p.stdout.decode("ascii", "replace").strip().splitlines()[-1])
        by = [(c["endpoint"], c["status"]) for c in calls]
        self.assertEqual(by, [("/health", 200), ("/type", 200), ("/type", 200), ("/key", 200), ("/type", 200),
                              ("/nope", 404), ("/health", 401)])
        health = calls[0]["result"]
        self.assertTrue(health["ok"])
        self.assertEqual(health["recording"]["active"], False)
        self.assertEqual(calls[4]["result"]["error"], "bad-request")
        typed = "".join(e[1] for e in self.desk.log if e[0] == "char")
        want = "héllo 中 \U0001F600 <&>\"'"
        self.assertTrue(typed.startswith(want), ascii(typed))
        # a string body is encoded by Windows PowerShell 5.1 itself: UTF-8 only because the content type says so
        self.assertEqual(typed[len(want):], "stré")
        # Expect: 100-continue answered at once: no ~350 ms wait per call
        self.assertLess(min(c["ms"] for c in calls[1:4]), 300, [c["ms"] for c in calls])


if __name__ == "__main__":
    unittest.main()
