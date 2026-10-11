"""v1: the SSH forced command on each Hyper-V host (docs/design.md 3.3).

Runs as the domain account svc-vmbroker, which has no rights of its own (read and execute on the code folder,
nothing under <VMRoot>/vmb/). Started by the "restrict,command=..." prefix of each key line in an admin-owned keys
file; the command carries the key's name. sshd's Match block turns off forwarding, tunnels, agent forwarding, X11 and
the TTY, and there is no sftp subsystem.

Reads SSH_ORIGINAL_COMMAND (at most 300 bytes, characters [a-z0-9 @:/._-], single spaces, as in app-broker): the
consumer name and the verb only. Refuses a consumer the key is not bound to. Reads every argument as one JSON document
from stdin (at most 1 MiB; a copy streams the file after it), validates it, and passes it to the executor over the
executor's named pipe; streams the answer (and files, for copy) back on stdout. Serves "contract", "contract skill"
and "whoami" (the key's name and the consumer names it may act as) without a consumer name.

Not built until the operator answers docs/design.md Q1 and Q2.
"""
