"""Windows guest configuration (docs/design.md 4.3).

Put here:
- the unattend.xml for a sysprepped clone: computer name, the admin password in the "hide sensitive data" form (as
  netadmin's New-WindowsVM.ps1 writes it), time zone, DHCP or a static address, RDP on or off, OOBE skipped;
- the in-guest steps sent over PowerShell Direct, in this order: extend C:; MAK activation when approved (the key only
  as an -ArgumentList value, never in a script block's text; then slmgr /cpky and a check that the registry no longer
  holds the key; all before any user or script exists); the "vm-broker" firewall rule group (replaced as a whole);
  local users and their keys (administrators_authorized_keys for admins, with its ACL); sshd (the image sets its
  DefaultShell to Windows PowerShell); WinRM over HTTPS with a self-signed certificate when approved;
  Install-WindowsFeature / Enable-WindowsOptionalFeature; winget and choco installs (winget over PowerShell Direct may
  fail in session 0: fall back to the Microsoft.WinGet.Client module or a one-shot task in a user session); the
  consumer scripts in order. Consumer strings arrive only as arguments;
- for win11-lab: connect as vmbadmin (never student), check that the token is elevated, change vmbadmin's password to
  a per-VM one, write the director token, set the static address;
- the answer-file scrub (reuse New-WindowsVM.ps1's guest block).
"""
