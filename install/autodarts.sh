#!/usr/bin/env bash
# AutoDarts Proxmox Einzeiler-Installer (Proxmox VE Community Scripts Stil)
# Aufruf auf dem Proxmox-Host als root:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AutoDartsProxmox/main/install/autodarts.sh)"
#
# Erstellt einen LXC-Container namens "autodarts" mit naechster freier ID,
# installiert darts-hub + Manager-Web-UI, macht alles reboot-sicher.
set -euo pipefail

# ================= Variablen (oben, Community-Scripts-konform) =================
APP="autodarts"                       # Container-Hostname + Anzeigename
REPO="HatchetMan111/AutoDartsProxmox" # GitHub-Repo
BRANCH="main"                         # Branch
REPO_RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

CT_CPU="${CT_CPU:-2}"                 # vCPU (Standard 2; leistungshungrig: 4)
CT_RAM="${CT_RAM:-2048}"              # MB (Standard 2048; bei 3 Cams: 4096)
CT_DISK="${CT_DISK:-8}"               # GB
CT_TEMPLATE="${CT_TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
CT_STORAGE="${CT_STORAGE:-local-lvm}" # Container-Disk-Storage
CT_TMPL_STORAGE="${CT_TMPL_STORAGE:-local}"  # Template-Storage
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"       # Netzwerk-Bridge
CT_IP="${CT_IP:-dhcp}"                # z.B. "dhcp" oder "192.168.1.50/24"
CT_GW="${CT_GW:-}"                    # z.B. "192.168.1.1" (nur bei statischer IP)
CT_PRIVILEGED="${CT_PRIVILEGED:-1}"   # 1=privilegiert (empfohlen f. USB/Video), 0=unprivilegiert
CT_UNPROTECTED="${CT_UNPROTECTED:-1}" # 1=nesting=1 setzen

MANAGER_PORT="${MANAGER_PORT:-8080}"  # eigene Web-UI
BOARD_PORT="${BOARD_PORT:-3180}"      # Board-Manager (Dokulink, aktiv nach Caller-Start)
CALLER_PORT="${CALLER_PORT:-8079}"    # Caller Device-Link (Web-Caller, https)
# Board-ID: per ENV/Flag setzbar, sonst interaktiv am Anfang abgefragt.
# Kein API-Key noetig (neuer Device-Link-Login via :8079 bzw. auth.autodarts.io/link).
BOARD_ID="${BOARD_ID:-}"              # z.B. "abc123..." — leer = spaeter eintragen
# =============================================================================

log() { echo "[${APP}] $*"; }
err() { echo "[${APP}][FEHLER] $*" >&2; }

# Komplette Fehlermeldungskette: Exit-Code, Befehl, Stacktrace, Hinweis auf bash -x
error_handler() {
  local code=$?
  err "Installation abgebrochen. Exit-Code: ${code}"
  err "Fehlgeschlagener Befehl: ${BASH_COMMAND}"
  err "Stacktrace (neueste zuerst):"
  local i=0
  while caller $i >&2; do i=$((i+1)); done
  err "Relevante Logs: 'journalctl -xe', 'pct logs <CTID>', Container: 'pct exec <CTID> -- journalctl -u autodarts-manager -n 100'"
  err "Fuer Voll-Log erneut starten mit: bash -x -c \"\$(wget -qLO - ${REPO_RAW}/install/autodarts.sh)\""
  exit "${code}"
}
trap error_handler ERR

need_root() {
  if [ "$(id -u)" -ne 0 ]; then err "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; fi
}
need_pve() {
  command -v pct >/dev/null || { err "'pct' nicht gefunden — bist du auf einem Proxmox-VE-Host?"; exit 1; }
  command -v pvesh >/dev/null || { err "'pvesh' nicht gefunden — Proxmox-Installation unvollstaendig?"; exit 1; }
}

next_free_id() {
  if [ -n "${CTID:-}" ]; then echo "${CTID}"; return; fi
  pvesh get /cluster/nextid
}

# Fragt die Board-ID EINMAL am Anfang ab (现有 ENV/Flag gewinnt, sonst Prompt).
# Ergebnis: globale Variable BOARD_ID (leer = ueberspringen, spaeter via Manager/API eintragbar).
ask_board_id() {
  # Flag-Parsung (kompatibel zum Einzeiler: .../autodarts.sh --board-id XYZ)
  for arg in "$@"; do
    case "${arg}" in
      --board-id=*) BOARD_ID="${arg#--board-id=}" ;;
      --board-id) shift ;;
    esac
  done
  if [ -n "${BOARD_ID:-}" ]; then
    log "Board-ID via ENV/Flag gesetzt."
    return 0
  fi
  if [ -t 0 ]; then
    echo ""
    echo "--- AutoDarts Einrichtung ---"
    echo "Board-ID von play.autodarts.io (Board anlegen -> ID kopieren)."
    echo "Kein API-Key noetig (Device-Link-Login erfolgt spaeter ueber :${CALLER_PORT})."
    echo "Leer lassen = ueberspringen (Web-UI zeigt dann nur Setup-Hinweis)."
    printf "Board-ID (Enter = spaeter): "
    IFS= read -r BOARD_ID || BOARD_ID=""
    BOARD_ID="$(echo "${BOARD_ID}" | tr -d ' \t\r\n')"
    if [ -z "${BOARD_ID}" ]; then
      log "Keine Board-ID eingegeben — Caller wird ohne -B installiert, spaeter nachtragbar."
    else
      log "Board-ID erfasst (${#BOARD_ID} Zeichen)."
    fi
  else
    log "Nicht-interaktiv ohne BOARD_ID — Caller wird ohne -B installiert (spaeter nachtragbar via BOARD_ID=... Re-Run)."
  fi
}

ensure_template() {
  local tmpl_path="/var/lib/vz/template/cache/${CT_TEMPLATE}"
  if [ -f "${tmpl_path}" ]; then log "Template vorhanden: ${CT_TEMPLATE}"; return; fi
  log "Template fehlt — lade Liste und versuche Download ..."
  pveam update
  # Falls exakter Name nicht existiert, neuestes debian-12-standard nehmen
  if ! pveam list "${CT_TMPL_STORAGE}" | grep -q "${CT_TEMPLATE}"; then
    local newest
    newest="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n 1)"
    if [ -z "${newest}" ]; then err "Kein debian-12 Template gefunden (pveam available leer)."; exit 1; fi
    log "Nutze stattdessen neuestes Template: ${newest}"
    CT_TEMPLATE="${newest}"
  fi
  pveam download "${CT_TMPL_STORAGE}" "${CT_TEMPLATE}"
}

create_container() {
  local ctid="$1"
  if pct status "${ctid}" >/dev/null 2>&1; then
    err "CT ${ctid} existiert bereits. Andere ID via CTID=<frei> Umgebungsvariable waehlen."
    exit 1
  fi
  local feats="nesting=1"
  local unpriv="1"
  if [ "${CT_PRIVILEGED}" = "1" ]; then unpriv="0"; fi
  local ipconf="name=${APP},bridge=${CT_BRIDGE},ip=${CT_IP}"
  if [ -n "${CT_GW}" ]; then ipconf="${ipconf},gw=${CT_GW}"; fi

  log "Erstelle LXC ${ctid} (${APP}): cpu=${CT_CPU} ram=${CT_RAM}MB disk=${CT_DISK}G unprivileged=${unpriv} ip=${CT_IP} ..."
  pct create "${ctid}" "${CT_TMPL_STORAGE}:vztmpl/${CT_TEMPLATE}" \
    --hostname "${APP}" \
    --cores "${CT_CPU}" --memory "${CT_RAM}" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "${ipconf}" \
    --unprivileged "${unpriv}" \
    --features "${feats}" \
    --onboot 1 --start 1
  log "Container ${ctid} erstellt, onboot=1 gesetzt, gestartet."
}

wait_ssh_network() {
  local ctid="$1"
  log "Warte auf Netzwerk im Container ..."
  for i in $(seq 1 30); do
    if pct exec "${ctid}" -- hostname -I >/dev/null 2>&1; then log "Netzwerk bereit (Versuch ${i})."; return 0; fi
    sleep 4
  done
  err "Container-Netzwerk antwortet nicht nach ~120s. 'pct logs ${ctid}' pruefen."
  exit 1
}

run_setup_inside() {
  local ctid="$1"
  log "Kopiere Setup-Dateien in den Container ..."
  pct push "${ctid}" /dev/null /tmp/.autodarts_ping 2>/dev/null || true
  # Dateien direkt aus dem Repo in den Container laden (GitHub-first):
  # BOARD_ID wird durchgereicht und im Container nach /etc/autodarts/board-id preseeded.
  pct exec "${ctid}" -- bash -c "set -euo pipefail; apt-get update -qq; apt-get install -y -qq curl ca-certificates >/dev/null; mkdir -p /tmp/autodarts-install; cd /tmp/autodarts-install; curl -fSL '${REPO_RAW}/src/setup-container.sh' -o setup-container.sh; curl -fSL '${REPO_RAW}/src/manager.py' -o manager.py; curl -fSL '${REPO_RAW}/systemd/autodarts-manager.service' -o autodarts-manager.service; curl -fSL '${REPO_RAW}/systemd/darts-hub.service' -o darts-hub.service; curl -fSL '${REPO_RAW}/systemd/darts-caller.service' -o darts-caller.service; chmod +x setup-container.sh; APP='${APP}' MANAGER_PORT='${MANAGER_PORT}' BOARD_PORT='${BOARD_PORT}' CALLER_PORT='${CALLER_PORT}' BOARD_ID='${BOARD_ID:-}' REPO_RAW='${REPO_RAW}' bash ./setup-container.sh"
}

verify() {
  local ctid="$1"
  log "Verifikation ..."
  local state
  state="$(pct exec "${ctid}" -- systemctl is-active autodarts-manager.service)"
  log "systemctl is-active autodarts-manager: ${state}"
  if [ "${state}" != "active" ]; then
    err "Service nicht aktiv. Log:"
    pct exec "${ctid}" -- journalctl -u autodarts-manager.service --no-pager -n 80 >&2 || true
    exit 1
  fi
  pct exec "${ctid}" -- curl -fsS "http://localhost:${MANAGER_PORT}/health" >/dev/null
  log "HTTP-Check localhost:${MANAGER_PORT}/health OK."
  local caller_state
  caller_state="$(pct exec "${ctid}" -- systemctl is-active darts-caller.service 2>&1 || true)"
  log "systemctl is-active darts-caller: ${caller_state}"
  if [ -n "${BOARD_ID:-}" ] && [ "${caller_state}" != "active" ]; then
    err "WARN: Board-ID gesetzt, aber darts-caller nicht aktiv. Log:"
    pct exec "${ctid}" -- journalctl -u darts-caller.service --no-pager -n 40 >&2 || true
  fi
  if [ -n "${BOARD_ID:-}" ]; then
    if pct exec "${ctid}" -- curl -fskS "https://localhost:${CALLER_PORT}/" >/dev/null 2>&1; then
      log "Caller Web-UI https://localhost:${CALLER_PORT}/ erreichbar."
    else
      log "Caller :${CALLER_PORT} noch nicht bereit (Voice-Pack-Download beim Erststart dauert) — Manager ist bereit."
    fi
  fi
  local ip
  ip="$(pct exec "${ctid}" -- hostname -I | awk '{print $1}')"
  echo ""
  echo "================================================================"
  echo " AutoDarts bereit! CTID=${ctid} Name=${APP} IP=${ip}"
  echo " Manager:        http://${ip}:${MANAGER_PORT}"
  if [ -n "${BOARD_ID:-}" ]; then
    echo " Caller:         https://${ip}:${CALLER_PORT} (Login-Banner bestaetigen!)"
    echo " Board-Manager:  http://${ip}:${BOARD_PORT}"
    echo " Naechstes:      1) Caller-URL oeffnen, Device-Link Login via"
    echo "                    auth.autodarts.io/link bestaetigen."
    echo "                 2) Kameras waehlen + kalibrieren, Testspiel."
  else
    echo " Board-ID:       NICHT gesetzt — im Container nachtragen:"
    echo "                 pct exec ${ctid} -- bash -c 'echo DEINE_BOARD_ID > /etc/autodarts/board-id'"
    echo "                 BOARD_ID=DEINE_BOARD_ID bash /tmp/autodarts-install/setup-container.sh"
    echo "                 danach Caller-Login ueber https://${ip}:${CALLER_PORT}"
  fi
  echo " Update:         pct exec ${ctid} -- bash /tmp/autodarts-install/setup-container.sh"
  echo " Deinstallieren: pct stop ${ctid} && pct destroy ${ctid}"
  echo " USB-Kameras:    Host 'lsusb -t' pruefen, dann CT config ergaenzen,"
  echo "                 z.B. in /etc/pve/lxc/${ctid}.conf:"
  echo "                   lxc.cgroup2.devices.allow: c 81:* rwm"
  echo "                   lxc.mount.entry: /dev/video0 dev/video0 none bind,optional,create=file"
  echo "                 (fuer alle 3 Cams wiederholen; danach pct reboot ${ctid})"
  echo "================================================================"
  echo ""
  log "Host-USB-Uebersicht (fuer Passthrough):"
  lsusb -t 2>&1 || lsusb 2>&1 || echo "(lsusb nicht verfuegbar)"
}

main() {
  need_root
  need_pve
  log "== ${APP} Proxmox-Installer (${REPO}@${BRANCH}) =="
  local ctid
  ctid="$(next_free_id)"
  log "Naechste freie CT-ID: ${ctid} | Hostname: ${APP}"
  ask_board_id "$@"
  ensure_template
  create_container "${ctid}"
  wait_ssh_network "${ctid}"
  run_setup_inside "${ctid}"
  verify "${ctid}"
}

main "$@"
