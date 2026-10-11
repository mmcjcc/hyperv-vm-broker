"""Linux guest configuration: the NoCloud seed (docs/design.md 4.3 and 8.4).

Put here: meta-data (instance-id = the registry id, local-hostname), network-config (DHCP on lan, static on an
isolated net), and user-data: users with SSH keys and SHA-512 password hashes (never plain passwords), sudo rules,
packages, ufw rules with the comment "vm-broker", xrdp settings for ubuntu-desktop-xrdp, the consumer scripts as
write_files + runcmd, and a last step that writes /etc/cloud/cloud-init.disabled and then reports done or failed to the
host over KVP (a Hyper-V VM carries Azure's chassis asset tag, so once the seed is gone cloud-init could take the next
boot for a new instance: new host keys, a default user, DHCP on the first NIC). The images also pin
datasource_list: [NoCloud, None].

The router VM's user-data lives here too: one nftables inet table (masquerade out of NIC 1; forward from NIC 2 only to
public IPv4, never to 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, 0/8, 224/4 or 240/4; forward policy drop;
input on NIC 2 only DNS and ICMP echo to 10.77.N.1; on NIC 1 only replies; no IPv6 on NIC 2), IPv4 forwarding turned
on by the nftables unit after its ruleset loads (ExecStartPost, never sysctl.d), dnsmasq for DNS on NIC 2 only (no
DHCP), and no TCP sshd. LF line ends only.
"""
