#!/usr/bin/env bash
# Setup-Script INNEN im LXC-Container. Wird vom Host-Installer via pct exec aufgerufen.
# Idempotent: kann mehrfach laufen. Gibt bei Fehlern die komplette Kette aus.
set -euo pipefail

# --- Variablen (per ENV vom Host-Installer ueberschreibbar) ---
APP="${APP:-autodarts}"
MANAGER_PORT="${MANAGER_PORT:-8080}"
BOARD_PORT="${BOARD_PORT:-3180}"
CALLER_PORT="${CALLER_PORT:-8079}"
DARTS_HUB_DIR="${DARTS_HUB_DIR:-/opt/darts-hub}"
MANAGER_DIR="${MANAGER_DIR:-/opt/autodarts-manager}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/HatchetMan111/AutoDartsProxmox/main}"
MANAGER_VERSION="${MANAGER_VERSION:-1.0.0}"

log()  { echo "[setup] $*"; }
fail() {
  local code=$?
  echo "[setup][FEHLER] Exit-Code: ${code}" >&2
  echo "[setup][FEHLER] Fehlgeschlagener Befehl: ${BASH_COMMAND}" >&2
  echo "[setup][FEHLER] Stacktrace:" >&2
  local i=0
  while caller $i >&2; do i=$((i+1)); done
  echo "[setup][FEHLER] Tipp: erneut mit 'bash -x $0' starten fuer Voll-Log." >&2
  exit "${code}"
}
trap fail ERR

export DEBIAN_FRONTEND=noninteractive

log "== AutoDarts Container-Setup v${MANAGER_VERSION} =="
log "APP=${APP} MANAGER_PORT=${MANAGER_PORT} DARTS_HUB_DIR=${DARTS_HUB_DIR}"

log "(1/6) APT-Abhaengigkeiten installieren ..."
apt-get update
apt-get install -y --no-install-recommends \
  curl wget unzip ca-certificates python3 \
  v4l-utils usbutils iproute2 procps systemd-sysv \
  libicu-dev libssl-dev 2>&1 | tail -n 5
log "APT OK."

log "(2/6) Architektur erkennen ..."
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) DH_ARCH="X64" ;;
  aarch64|arm64) DH_ARCH="ARM64" ;;
  armv7l|armhf)  DH_ARCH="ARM" ;;
  *) echo "[setup][FEHLER] Architektur '${ARCH}' wird von darts-hub nicht unterstuetzt." >&2; exit 1 ;;
esac
log "ARCH=${ARCH} -> darts-hub-linux-${DH_ARCH}"

log "(3/6) darts-hub installieren nach ${DARTS_HUB_DIR} ..."
mkdir -p "${DARTS_HUB_DIR}"
ZIP_URL="https://github.com/lbormann/darts-hub/releases/latest/download/darts-hub-linux-${DH_ARCH}.zip"
TMP_ZIP="/tmp/darts-hub.zip"
if ! curl -fSL "${ZIP_URL}" -o "${TMP_ZIP}"; then
  echo "[setup][FEHLER] Download fehlgeschlagen: ${ZIP_URL}" >&2
  echo "[setup][FEHLER] curl-Exit: $? — stderr/stdout siehe oben. Pruefe Netzwerk/DNS im Container." >&2
  exit 1
fi
unzip -o "${TMP_ZIP}" -d "${DARTS_HUB_DIR}" | tail -n 3
rm -f "${TMP_ZIP}"
chmod +x "${DARTS_HUB_DIR}/darts-hub" || true
ls -l "${DARTS_HUB_DIR}/darts-hub"
log "darts-hub OK."

log "(4/6) Manager-Web-UI installieren nach ${MANAGER_DIR} ..."
mkdir -p "${MANAGER_DIR}"
if [ -f "./manager.py" ]; then
  cp ./manager.py "${MANAGER_DIR}/manager.py"
elif [ -f "/tmp/manager.py" ]; then
  cp /tmp/manager.py "${MANAGER_DIR}/manager.py"
else
  log "Lade manager.py von ${REPO_RAW}/src/manager.py ..."
  curl -fSL "${REPO_RAW}/src/manager.py" -o "${MANAGER_DIR}/manager.py"
fi
python3 -m py_compile "${MANAGER_DIR}/manager.py"
log "manager.py OK."

log "(5/6) systemd-Units installieren ..."
for unit in autodarts-manager.service darts-hub.service; do
  SRC=""
  for cand in "./${unit}" "/tmp/${unit}"; do
    if [ -f "${cand}" ]; then SRC="${cand}"; break; fi
  done
  if [ -z "${SRC}" ]; then
    log "Lade ${unit} von ${REPO_RAW}/systemd/${unit} ..."
    curl -fSL "${REPO_RAW}/systemd/${unit}" -o "/etc/systemd/system/${unit}"
  else
    cp "${SRC}" "/etc/systemd/system/${unit}"
  fi
done
# Platzhalter in Units mit echten Pfaden/Ports fuellen
sed -i "s|@MANAGER_DIR@|${MANAGER_DIR}|g; s|@DARTS_HUB_DIR@|${DARTS_HUB_DIR}|g; s|@MANAGER_PORT@|${MANAGER_PORT}|g; s|@BOARD_PORT@|${BOARD_PORT}|g; s|@CALLER_PORT@|${CALLER_PORT}|g" \
  /etc/systemd/system/autodarts-manager.service /etc/systemd/system/darts-hub.service
systemctl daemon-reload
systemctl enable autodarts-manager.service
# darts-hub braucht Display/GUI — Service wird installiert aber nur gestartet wenn Binary lauffaehig;
# Manager ist der garantierte Web-Endpoint fuer die Verifikation.
systemctl enable darts-hub.service || true
systemctl restart autodarts-manager.service
# darts-hub Start nicht hart failen lassen (headless ohne X kann GUI crashen) — Status loggen
if ! systemctl restart darts-hub.service; then
  echo "[setup][WARN] darts-hub.service startet nicht (erwartbar headless ohne Display). Manager laeuft trotzdem." >&2
  systemctl status darts-hub.service --no-pager --full 2>&1 | head -n 30 >&2 || true
fi
log "systemd OK."

log "(6/6) Verifikation im Container ..."
echo "--- systemctl is-active ---"
systemctl is-active autodarts-manager.service
echo "--- HTTP-Check localhost:${MANAGER_PORT} ---"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://localhost:${MANAGER_PORT}/health" >/dev/null; then
    echo "Web UI antwortet (Versuch ${i})."
    break
  fi
  if [ "$i" = "10" ]; then
    echo "[setup][FEHLER] Web UI antwortet nicht auf localhost:${MANAGER_PORT}." >&2
    echo "--- journalctl autodarts-manager (letzte 50) ---" >&2
    journalctl -u autodarts-manager.service --no-pager -n 50 >&2 || true
    exit 1
  fi
  sleep 2
done
CT_IP="$(hostname -I | awk '{print $1}')"
echo "CT-IP: ${CT_IP}"
echo "Manager: http://${CT_IP}:${MANAGER_PORT} (Health: /health, Status: /api/status)"
echo "Board-Manager (nach Caller-Start): http://${CT_IP}:${BOARD_PORT}"
echo "Caller Device-Link: http://${CT_IP}:${CALLER_PORT}"
log "Setup erfolgreich."
