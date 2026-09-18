# AutoDartsProxmox

Lokale AutoDarts-Installation als **Proxmox LXC-Container** im Stil der **Proxmox VE Community Scripts** — mit **Einzeiler-Installation** auf dem Proxmox-Host.

Installiert wird:
- **darts-hub** (upstream `lbormann/darts-hub`, ehemals autodarts-desktop) inkl. `darts-caller`, `cam-loader` etc.
- **AutoDarts Manager Web-UI** (Python stdlib, keine Deps) auf Port **8080** mit Links zu Board-Manager (`:3180`) und Caller Device-Link (`:8079`)
- systemd-Services (`Restart=always`, `enable`), Container mit `onboot: 1` → **reboot-sicher**

> Hinweis: `Semtexmagix/autodarts-desktop` ist **deprecated** — dieses Repo nutzt ausschließlich `lbormann/darts-hub`.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AutoDartsProxmox/main/install/autodarts.sh)"
```

Der Installer:
- nimmt **immer die nächste freie CT-ID** (`pvesh get /cluster/nextid`, über `CTID=<id>` überschreibbar),
- vergibt den Containernamen **`autodarts`**,
- erstellt Standard **2 vCPU / 2 GB RAM / 8 GB Disk** (Debian 12),
- ist **idempotent** (Setup im Container mehrfach lauffähig) und mit `set -euo pipefail` + vollständigem Fehler-Stacktrace abgesichert.

### Optionen per ENV

```bash
CTID=150 CT_CPU=4 CT_RAM=4096 CT_DISK=12 CT_IP="192.168.1.50/24" CT_GW="192.168.1.1" \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AutoDartsProxmox/main/install/autodarts.sh)"
```

| Variable | Default | Beschreibung |
|---|---|---|
| `CTID` | nächste freie ID | Container-ID erzwingen |
| `CT_CPU` | `2` | vCPUs (bei 3 Kameras: `4`) |
| `CT_RAM` | `2048` | RAM in MB (bei 3 Kameras: `4096`) |
| `CT_DISK` | `8` | Disk in GB |
| `CT_IP` / `CT_GW` | `dhcp` | z. B. statisch `192.168.1.50/24` + Gateway |
| `CT_PRIVILEGED` | `1` | `1` = privilegiert (empfohlen für USB/Video), `0` = unprivilegiert |
| `MANAGER_PORT` | `8080` | Manager Web-UI |

### Erwartete Ausgabe am Ende

```
[autodarts] Verifikation ...
[autodarts] systemctl is-active autodarts-manager: active
[autodarts] HTTP-Check localhost:8080/health OK.

================================================================
 AutoDarts bereit! CTID=100 Name=autodarts IP=192.168.1.100
 Manager:        http://192.168.1.100:8080
 Board-Manager:  http://192.168.1.100:3180 (nach Caller-Start)
 Caller-Link:    http://192.168.1.100:8079
 ...
================================================================
```

Web-UI danach: `http://<LXC-IP>:8080` (bind `0.0.0.0`), Health: `/health`, Status: `/api/status`.

## USB-Kameras durchreichen (Pflicht für Scoring)

Der Host muss **physisch am Board** stehen (USB ≤ 3–5 m, sonst aktiver Hub/LWL).

1. Am Host prüfen:
   ```bash
   lsusb -t
   lsusb -v | grep -E "Bus|iProduct|bInterfaceClass.*Video"
   ls /dev/video*
   ```
2. Container stoppen, in `/etc/pve/lxc/<CTID>.conf` ergänzen (Beispiel 3 Cams):
   ```
   lxc.cgroup2.devices.allow: c 81:* rwm
   lxc.cgroup2.devices.allow: c 189:* rwm
   lxc.mount.entry: /dev/video0 dev/video0 none bind,optional,create=file
   lxc.mount.entry: /dev/video1 dev/video1 none bind,optional,create=file
   lxc.mount.entry: /dev/video2 dev/video2 none bind,optional,create=file
   ```
   Alternativ ganze USB-Geräte per `pct set <CTID> -usb0 host=XXXX:YYYY`.
3. `pct start <CTID>`, im Container prüfen: `v4l2-ctl --list-devices`, `ls /dev/video*`.
4. Leistungs-hungrig? Dann lieber **VM mit PCIe-Passthrough des ganzen USB-Controllers** oder 4 vCPU / 4 GB RAM für den LXC.

## Update / Deinstallieren

```bash
# Update im Container erneut laufen lassen:
pct exec <CTID> -- bash /tmp/autodarts-install/setup-container.sh

# Deinstallieren:
pct stop <CTID> && pct destroy <CTID>
```

## Debugging (komplette Kette, nie nur letzte Zeile)

```bash
# Installer mit Voll-Log:
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AutoDartsProxmox/main/install/autodarts.sh)"

# Im Container:
pct exec <CTID> -- systemctl status autodarts-manager --no-pager --full
pct exec <CTID> -- journalctl -u autodarts-manager -n 100 --no-pager
pct exec <CTID> -- journalctl -u darts-hub -n 100 --no-pager
pct exec <CTID> -- curl -v http://localhost:8080/health
```

## Repo-Struktur

```
install/autodarts.sh        Proxmox-Host-Installer (Einzeiler, Community-Scripts-Stil)
src/setup-container.sh      Setup im Container (idempotent)
src/manager.py              Manager Web-UI (Python stdlib, :8080)
systemd/autodarts-manager.service
systemd/darts-hub.service
README.md
```

## Sicherheitshinweis

Falls du ein GitHub-PAT in einem Chat/Terminal geteilt hast: **sofort unter GitHub → Settings → Developer settings → Personal access tokens → Revoke** widerrufen und ein neues, minimal-scoped Token (`repo`) erzeugen. Token niemals committen.
