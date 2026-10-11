"""Jobs: long operations that run on the host and outlive the client's connection (docs/design.md 5.3).

create, restore, snapshot and stop are jobs (destroy too, from v0.1). The host runs each as a one-shot SYSTEM
scheduled task, checks "one job per VM" under its lock, and turns a job whose task and process are gone into "lost"
with the step it reached (backend/ps/VmbJobs.ps1). Here: waiting for a job from the client.
"""
import time

from . import schema as S

FINAL = ("done", "failed", "lost", "cancelled")


STATUS_READ_RETRIES = 2   # a failed read of the job's status is retried: it is read-only, and the job goes on


def wait(backend, host, job, consumer, wait_s, poll_s=5.0, clock=time.monotonic, sleep=time.sleep):
    """Polls the host until the job ends or wait_s passes. Returns the job status; exit 4 if it is still running.

    A status read that fails (exit 1 or 255: a dropped WinRM call, the job's file being replaced) is tried again up to
    STATUS_READ_RETRIES times before it ends the wait; a refusal (exit 2: unknown job, not yours) ends it at once."""
    deadline = clock() + max(0, wait_s)
    first = True
    misses = 0
    while True:
        st = backend.call(host, "job", {"consumer": consumer, "job": job})
        if not st.get("ok"):
            if st.get("exit") in (S.EXIT_FAILED, S.EXIT_UNREACHABLE) and misses < STATUS_READ_RETRIES:
                misses += 1
                sleep(2.0)
                continue
            return st
        misses = 0
        if st.get("state") in FINAL:
            return finished(st)
        left = deadline - clock()
        if left <= 0:
            out = dict(st)
            out.update(ok=False, exit=S.EXIT_NOT_DONE, error="running",
                       hint="the job is still running; call job_wait %s" % job)
            return out
        sleep(min(2.0 if first else poll_s, max(0.5, left)))
        first = False


def finished(st):
    """A final job status as a verb's result: done is exit 0; failed, lost and cancelled carry the job's own exit."""
    out = dict(st)
    if st.get("state") == "done":
        out.update(ok=True, exit=S.EXIT_OK)
    else:
        code = st.get("job_exit") or S.EXIT_FAILED
        out.update(ok=False, exit=int(code), error=st.get("error") or st.get("state"),
                   hint=st.get("hint") or "the job %s" % st.get("state"))
    return out
