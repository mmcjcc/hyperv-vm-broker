"""Host policy: budgets, floors, quotas and the capacity check (docs/design.md 6.4 to 6.7).

The policy file lives on each host (<VMRoot>\vmb\policy.json; v0.R: hostctl set-policy). In v0.R the host's
VmbCommon.ps1 (Test-VmbCapacity) does the capacity check; this module is for v0.1. The policy holds: the
budget and floor per host; the per-consumer quotas (proposed: 3 VMs, 9g running memory, 400g disk counting checkpoint
files, 40 checkpoints per VM, 30-day leases, 6 creates per hour, 3 pending approvals); the broker VMs' CPU limit (75)
and disk IOPS cap; the copy window for image builds and keep copies (default 01:00 to 06:00); whether the memory
watcher is on (v1); whether netadmin's OPNsense rule for router VMs is in place (until then internet: true needs
approval, or is refused before v1); whether win11-lab may run on lan for a recording period (Q16's interim).

Budget: safe = RAM - production - floor, where production counts each production VM's static memory or its Dynamic
Memory maximum (servera today: 32 - 28 - 3 = about 1 GB). A budget above safe is allowed only by the operator's typed
confirmation; until the watcher exists it can starve production.

Put here:
- load_policy(path) via yamlstrict and validate.validate_policy;
- capacity(host_inventory, policy) -> production, safe, budget, used, free, floor (routers count; Running, Starting,
  Paused and Saved VMs count, and so do registry records in "creating");
- check_create(request, inventory, policy, usage) and check_start(...) -> ok, or exit 6 with a finding. On the host
  they run inside one script that holds the lock file state/lock (opened with no sharing, released if the process
  dies) while it checks and writes the reservation, so two clients cannot both pass; the client's own call only makes
  errors early;
- disk quota arithmetic: disk sizes plus checkpoint files (.avhdx and memory .vmrs; a standard checkpoint counts the
  VM's memory before it is taken);
- lease arithmetic: lease end, expiry, destroy-after date, and the image expiry check (no lease past it).
"""
