"""The broker's own record of the VMs it made: the authority for ownership (docs/design.md 3.5 and 6.1).

On each host: <VMRoot>/vmb/state/vms/<id>.json, written atomically (temp file, then rename). A record holds the id
(32 hex), the Hyper-V VMId, the VM name, the owner (a consumer name, or "broker" for routers and image builds),
profile, request hash, image version, network, lease end, state (creating, ready, failed, expired, destroyed), and
the time of each change. Destroyed VMs keep a tombstone record. Nets have their own records (nets/<net>.json: owner,
host, subnet, switch, router, members).

Put here: the record type, read and write helpers (through the backend in direct mode, local files in the
executor), owns(record, consumer) plus is_broker_vm(hyperv_vm, record): name prefix, Notes tag and record must all
agree, the denylist always wins, and a name that matches more than one Hyper-V VM is refused (VMs are addressed by
VMId only); and rename_owner for vmb-admin owner.
"""
