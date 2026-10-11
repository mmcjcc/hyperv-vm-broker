"""v1: the privileged worker on each Hyper-V host (docs/design.md 3.3).

A SYSTEM scheduled task started at boot (the lab-bmc-agent pattern), running the embeddable Python from a code folder
whose ACL has inheritance off (SYSTEM and Administrators full, svc-vmbroker read and execute only).

Creates its named pipe with ctypes CreateNamedPipeW, because Python's own pipe helpers (multiprocessing) take no DACL
and the default DACL gives Everyone read and svc-vmbroker no write: an explicit SDDL (SYSTEM and Administrators full,
svc-vmbroker read and write), FILE_FLAG_FIRST_PIPE_INSTANCE and PIPE_REJECT_REMOTE_CLIENTS.

Re-validates every request with validate.py (the gate is not trusted), runs broker.py with the local Hyper-V backend,
runs jobs (marking every job of its previous run "lost" when it starts), applies leases every hour (shut down at the
lease end, destroy seven days later), runs the memory watcher every minute if the operator turned it on (shut broker VMs
down, newest first, while Available MBytes is below the floor; docs/design.md 6.4), and writes state/events.jsonl.

Not built until the operator answers docs/design.md Q1 and Q2.
"""
