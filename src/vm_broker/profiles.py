"""The profile catalogue (docs/design.md 4.2). Data only.

Per-host facts that change (image versions, expiry dates, whether an image has winget) come from the host at run
time, not from this file. v0.R builds win11-lab once, from the Server 2025 ISO (lab_os win2025), as the one kept
recording VM on serverd; its host policy holds the ISO, the image name and the memory.
"""

PROFILES = {
    "win2025-core": {
        "from": "v0.1", "os": "windows", "server": True, "gui": False,
        "image": "win2025-core", "what": "Windows Server 2025 Standard, Server Core",
        "default": {"cpu": 2, "memory_mb": 4096, "disk_gb": 60}, "min": {"cpu": 1, "memory_mb": 2048, "disk_gb": 40},
        "access": ("ssh", "rdp", "winrm"), "default_access": ("ssh",), "packages": ("features", "winget", "choco"),
        "checkpoints": "production", "activation": ("none", "mak"), "networks": ("lan", "isolated"),
        "users": True, "hostname": True, "director": False,
        "secure_boot": "MicrosoftWindows", "vtpm": False,
    },
    "win2025-desktop": {
        "from": "v1", "os": "windows", "server": True, "gui": True,
        "image": "win2025-desktop", "what": "Windows Server 2025 Standard, Desktop Experience",
        "default": {"cpu": 2, "memory_mb": 6144, "disk_gb": 80}, "min": {"cpu": 1, "memory_mb": 4096, "disk_gb": 60},
        "access": ("rdp", "ssh", "winrm"), "default_access": ("rdp", "ssh"), "packages": ("features", "winget", "choco"),
        "checkpoints": "production", "activation": ("none", "mak"), "networks": ("lan", "isolated"),
        "users": True, "hostname": True, "director": False,
        "secure_boot": "MicrosoftWindows", "vtpm": False,
    },
    "win11-lab": {
        "from": "v0.2", "os": "windows", "server": False, "gui": True,
        "image": "win11-lab", "what": "the CS 101 clean student PC (auto-logon student, the director); "
                                      "v0.R: one kept VM on Windows Server 2025 Desktop Experience, on serverd",
        "default": {"cpu": 3, "memory_mb": 6144, "disk_gb": 80}, "min": {"cpu": 2, "memory_mb": 4096, "disk_gb": 64},
        "access": (), "default_access": (), "packages": ("winget", "choco"),
        "checkpoints": "standard", "activation": ("none", "mak"), "networks": ("isolated",),
        "users": False, "hostname": False, "director": True,
        "secure_boot": "MicrosoftWindows", "vtpm": True,     # for the Windows 11 image; v0.R's win2025 build adds none
    },
    "ubuntu-server": {
        "from": "v0.1", "os": "linux", "server": True, "gui": False,
        "image": "ubuntu-server", "what": "Ubuntu 24.04 LTS",
        "default": {"cpu": 2, "memory_mb": 2048, "disk_gb": 30}, "min": {"cpu": 1, "memory_mb": 1024, "disk_gb": 10},
        "access": ("ssh",), "default_access": ("ssh",), "packages": ("apt",),
        "checkpoints": "production", "activation": (), "networks": ("lan", "isolated"),
        "users": True, "hostname": True, "director": False,
        "secure_boot": "MicrosoftUEFICertificateAuthority", "vtpm": False,
    },
    "ubuntu-desktop-xrdp": {
        "from": "v1", "os": "linux", "server": True, "gui": True,
        "image": "ubuntu-desktop-xrdp", "what": "Ubuntu 24.04 with an Xfce desktop over RDP (xrdp)",
        "default": {"cpu": 2, "memory_mb": 4096, "disk_gb": 40}, "min": {"cpu": 1, "memory_mb": 2048, "disk_gb": 20},
        "access": ("ssh", "xrdp"), "default_access": ("ssh", "xrdp"), "packages": ("apt",),
        "checkpoints": "production", "activation": (), "networks": ("lan", "isolated"),
        "users": True, "hostname": True, "director": False,
        "secure_boot": "MicrosoftUEFICertificateAuthority", "vtpm": False,
    },
}

STAGE_ORDER = ("v0.R", "v0.1", "v0.2", "v1")
