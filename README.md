# proxmox-ipset-auto-dns
Automatically update [Proxmox VE](https://www.proxmox.com/en/proxmox-ve) firewall IP sets (ipset) based on domain names in comments.

The script detects IP sets with comments like auto_dns_example.com_github.com, resolves their IPs via DNS, and updates the firewall accordingly — cluster-wide, node, VM, and container levels supported.

---
## ✨ Features
- 🧠 Detects IP sets with comments starting with `auto_dns_`
- 🌐 Resolves both IPv4 (A) and IPv6 (AAAA) records
- 🔁 Clears old IPs and replaces them with current DNS results
- ⚙️ Works at:
  - Cluster level
  - Node level
  - QEMU (VM) level
  - LXC (CT) level
- 🪶 Lightweight — uses only `bash`, `jq`, and `dig`
- 🔍 Optional debug mode for verbose command logging

---

## 📦 Requirements

Install dependencies:
```bash
apt update
apt install -y jq dnsutils
```

---

## Installation as a systemd service
Run the installer script (parameter = update interval, e.g. 6h, 30m, 3600s):
```
curl -fsSL "https://raw.githubusercontent.com/vgdh/proxmox-ipset-auto-dns/refs/heads/main/install.sh" | bash -s -- 6h
```
```
wget -qO- "https://raw.githubusercontent.com/vgdh/proxmox-ipset-auto-dns/refs/heads/main/install.sh" | bash -s -- 6h
```

