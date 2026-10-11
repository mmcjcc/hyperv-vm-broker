"""tools/Stage-LabDirector.ps1 with small fake zips in a temp folder (Windows PowerShell 5.1)."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, "tools", "Stage-LabDirector.ps1")
SRC_PKG = os.path.join(REPO, "src", "vm_director")
POWERSHELL = shutil.which("powershell.exe")

PTH_ORIGINAL = "python314.zip\r\n.\r\n\r\n# Uncomment to run site.main() automatically\r\n#import site\r\n"


def make_python_zip(path, drop=None):
    with zipfile.ZipFile(path, "w") as z:
        files = {"python.exe": b"MZ python", "pythonw.exe": b"MZ pythonw", "python314.dll": b"MZ dll",
                 "python3.dll": b"MZ dll3", "vcruntime140.dll": b"MZ vc", "_ctypes.pyd": b"MZ ctypes",
                 "python314._pth": PTH_ORIGINAL.encode(), "LICENSE.txt": b"license"}
        for name, data in files.items():
            if name != drop:
                z.writestr(name, data)
        if drop != "python314.zip":
            inner = os.path.join(os.path.dirname(path), "inner-stdlib.zip")
            with zipfile.ZipFile(inner, "w") as zi:
                zi.writestr("os.py", "# fake\n")
            z.write(inner, "python314.zip")


def make_ffmpeg_zip(path, entries=None):
    top = "ffmpeg-9.0.2-essentials_build/"
    entries = entries if entries is not None else {
        top + "bin/ffmpeg.exe": b"MZ ffmpeg " * 100, top + "bin/ffprobe.exe": b"MZ ffprobe",
        top + "bin/ffplay.exe": b"MZ ffplay", top + "doc/ffmpeg.html": b"<html>", top + "LICENSE": b"GPL"}
    with zipfile.ZipFile(path, "w") as z:
        for name, data in entries.items():
            z.writestr(name, data)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


@unittest.skipUnless(POWERSHELL and sys.platform == "win32", "needs Windows PowerShell")
class StageScript(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="vmdir-stage-")
        self.pyzip = os.path.join(self.tmp, "python-3.14.7-embed-amd64.zip")
        self.ffzip = os.path.join(self.tmp, "ffmpeg-9.0.2-essentials_build.zip")
        make_python_zip(self.pyzip)
        make_ffmpeg_zip(self.ffzip)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, out, *extra, pyzip=None, ffzip=None):
        cmd = [POWERSHELL, "-NoProfile", "-NonInteractive", "-File", SCRIPT, "-PythonZip", pyzip or self.pyzip,
               "-FfmpegZip", ffzip or self.ffzip, "-Out", out, *extra]
        env = {k: v for k, v in os.environ.items() if k.upper() != 'PSMODULEPATH'}  # PowerShell 7's path breaks 5.1
        return subprocess.run(cmd, capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL, env=env)

    def test_stages_the_layout(self):
        out = os.path.join(self.tmp, "stage", "LabDirector")
        p = self.run_script(out)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        bin_ = os.path.join(out, "bin")
        for name in ("python.exe", "pythonw.exe", "python314.zip", "python314.dll", "_ctypes.pyd"):
            self.assertTrue(os.path.isfile(os.path.join(bin_, "python", name)), name)
        with open(os.path.join(bin_, "python", "python314._pth"), "rb") as f:
            pth = f.read()
        self.assertFalse(pth.startswith(b"\xef\xbb\xbf"))
        lines = pth.decode("ascii").splitlines()
        self.assertEqual([ln for ln in lines if ln and not ln.startswith("#")], ["python314.zip", ".", "..\\app"])
        self.assertIn("#import site", lines)
        staged = sorted(os.listdir(os.path.join(bin_, "app", "vm_director")))
        want = sorted(n for n in os.listdir(SRC_PKG) if n.endswith(".py"))
        self.assertEqual(staged, want)
        self.assertIn("win32.py", staged)
        self.assertNotIn("__pycache__", staged)
        with zipfile.ZipFile(self.ffzip) as z:
            ff = z.read("ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe")
        with open(os.path.join(bin_, "ffmpeg.exe"), "rb") as f:
            self.assertEqual(f.read(), ff)
        self.assertEqual(sorted(os.listdir(bin_)), ["app", "ffmpeg.exe", "python"])   # no ffprobe, no docs

        with open(os.path.join(out, "manifest.json"), "rb") as f:
            raw = f.read()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
        m = json.loads(raw)
        self.assertEqual(m["version"], "0.1.3")
        self.assertEqual(m["start"], "bin\\python\\pythonw.exe -I -m vm_director")
        self.assertEqual(m["python_zip"]["sha256"], sha256(self.pyzip))
        self.assertEqual(m["ffmpeg_zip"]["entry"], "ffmpeg-9.0.2-essentials_build/bin/ffmpeg.exe")
        on_disk = {}
        for dirpath, _dirs, files in os.walk(out):
            for name in files:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, out)
                if rel != "manifest.json":
                    on_disk[rel] = (os.path.getsize(full), sha256(full))
        listed = {f["path"]: (f["size"], f["sha256"]) for f in m["files"]}
        self.assertEqual(listed, on_disk)

        again = self.run_script(out)   # never over an existing stage
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("not empty", again.stderr + again.stdout)

    def test_whatif_writes_nothing(self):
        out = os.path.join(self.tmp, "whatif")
        p = self.run_script(out, "-WhatIf")
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        self.assertIn("What if", p.stdout)
        self.assertFalse(os.path.exists(out))

    def test_refuses_onedrive(self):
        out = os.path.join(self.tmp, "OneDrive - Fake", "stage")
        p = self.run_script(out)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("OneDrive", p.stderr + p.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "OneDrive - Fake")))

    def test_refuses_bad_zips(self):
        bad_py = os.path.join(self.tmp, "bad-python.zip")
        make_python_zip(bad_py, drop="pythonw.exe")
        p = self.run_script(os.path.join(self.tmp, "o1"), pyzip=bad_py)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("pythonw.exe", p.stderr + p.stdout)
        bad_ff = os.path.join(self.tmp, "bad-ffmpeg.zip")
        make_ffmpeg_zip(bad_ff, {"ffmpeg/ffmpeg.exe": b"MZ", "a/bin/ffmpeg.exe": b"MZ", "b/bin/ffmpeg.exe": b"MZ"})
        p = self.run_script(os.path.join(self.tmp, "o2"), ffzip=bad_ff)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("expected exactly 1", p.stderr + p.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "o1")))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "o2")))


if __name__ == "__main__":
    unittest.main()
