"""The backend interface (v0 spec section 8: a class, so another backend can be added without changing the tools).

A backend has one method, call(host, verb, args, ...): it runs one host verb (backend/ps/Vmb.ps1) and returns the
host's answer as a dict with "ok" and "exit". The host verbs are the interface: inventory, baseline, install,
install-code, stage-new, stage-rm, stage-director, create, resume, status, list, start, stop, snapshot, restore,
snapshots, snapshot-rm, run, copy-to, copy-from, director, console, job, job-cancel, activate, password, fwmon,
fwmon-summary, copy-iso, set-policy. VMs are addressed by name in the call; the host resolves the name to its
registry record and the VMId, and re-checks ownership itself.

Implementations: fake.FakeBackend (unit tests, in memory) and hyperv.HyperVBackend (WinRM from the laptop).
"""

HOSTS = {
    "servera": {"fqdn": "servera.corp.example", "vmb_root": "C:\\VMs\\vmb"},
    "serverd": {"fqdn": "serverd.corp.example", "vmb_root": "D:\\VMs\\vmb"},
}


class Backend:
    """call() modes: "call" (installed code), "inline" (scripts sent from the laptop, before the code folder exists),
    "upload" (files into a new stage folder, then the verb with args["stage"]), "download" (the verb, then the staged
    file to download_to), "iso" (copy-iso in a disconnected session)."""

    def call(self, host, verb, args, mode="call", upload=None, download_to=None, stage_inline=False, whatif=False,
             timeout_s=None):
        raise NotImplementedError

    def code_version(self):
        return ""
