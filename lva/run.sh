#!/bin/bash
set -euo pipefail

OPTIONS=/data/options.json
CONFIG=/tmp/lva/config.json

# Read an option; keeps false/0 values, prints nothing for missing/null
opt() {
  jq -r --arg k "$1" 'if .[$k] == null then empty else .[$k] end' "$OPTIONS"
}

# --- MQTT (manual settings or the Mosquitto add-on via Supervisor) ----------
MQTT_HOST=""
MQTT_PORT=""
MQTT_USER=""
MQTT_PASS=""
if [ "$(opt mqtt_enabled)" = "true" ]; then
  MQTT_HOST=$(opt mqtt_host)
  MQTT_PORT=$(opt mqtt_port)
  MQTT_USER=$(opt mqtt_username)
  MQTT_PASS=$(opt mqtt_password)

  if [ -z "$MQTT_HOST" ]; then
    SVC=$(curl -sS -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
      http://supervisor/services/mqtt || true)
    if [ "$(jq -r '.result // empty' <<<"$SVC" 2>/dev/null)" = "ok" ]; then
      MQTT_HOST=$(jq -r '.data.host // empty' <<<"$SVC")
      MQTT_PORT=${MQTT_PORT:-$(jq -r '.data.port // empty' <<<"$SVC")}
      MQTT_USER=${MQTT_USER:-$(jq -r '.data.username // empty' <<<"$SVC")}
      MQTT_PASS=${MQTT_PASS:-$(jq -r '.data.password // empty' <<<"$SVC")}
      echo "MQTT: using broker from Supervisor ($MQTT_HOST)"
    else
      REASON=$(jq -r '.message // empty' <<<"$SVC" 2>/dev/null || true)
      echo "MQTT: no mqtt_host set and no broker from Supervisor (${REASON:-no response})," \
        "MQTT disabled"
    fi
  fi
fi

# --- LVA config -------------------------------------------------------------
mkdir -p /tmp/lva /data/wakewords
jq -n \
  --arg name "$(opt name)" \
  --argjson listen_during_wake "$(opt listen_during_wake_sound)" \
  --argjson debug "$(opt debug)" \
  --argjson max_volume "$(opt max_volume_percent)" \
  --argjson esphome_port "$(opt esphome_port)" \
  --argjson led "$(opt led_enabled)" \
  --argjson button "$(opt button_enabled)" \
  --arg mqtt_host "$MQTT_HOST" \
  --arg mqtt_port "${MQTT_PORT:-1883}" \
  --arg mqtt_user "$MQTT_USER" \
  --arg mqtt_pass "$MQTT_PASS" \
  '{
    app: {
      name: $name,
      listen_during_wake_sound: $listen_during_wake,
      preferences_file: "/data/preferences.json",
      debug: $debug
    },
    audio: {
      volume_sync: true,
      max_volume_percent: $max_volume
    },
    wake_word: {
      download_dir: "/data/wakewords"
    },
    esphome: {
      host: "0.0.0.0",
      port: $esphome_port
    },
    led: {
      enabled: $led,
      led_type: "xvf3800",
      interface: "usb"
    },
    button: {
      enabled: $button,
      mode: "xvf3800"
    },
    mqtt: {
      host: (if $mqtt_host == "" then null else $mqtt_host end),
      port: ($mqtt_port | tonumber),
      username: (if $mqtt_user == "" then null else $mqtt_user end),
      password: (if $mqtt_pass == "" then null else $mqtt_pass end)
    }
  }' > "$CONFIG.base"

# --- XVF3800 supervision ----------------------------------------------------
# LED/button controllers keep a USB handle that goes stale when the board is
# re-plugged, and the board loses its runtime config, so LVA is restarted then.
USB_DEVICES=${USB_DEVICES:-/sys/bus/usb/devices}

# Prints "<bus>:<dev>" of the XVF3800 - changes on every re-plug
xvf_usb_id() {
  local d
  for d in "$USB_DEVICES"/*; do
    if [ "$(cat "$d/idVendor" 2>/dev/null)" = "2886" ] \
      && [ "$(cat "$d/idProduct" 2>/dev/null)" = "001a" ]; then
      echo "$(cat "$d/busnum"):$(cat "$d/devnum")"
      return
    fi
  done
}

xvf_ready() {
  [ -n "$(xvf_usb_id)" ] && pactl list short sources 2>/dev/null | grep -q 'alsa_input.*XVF3800'
}

stop_lva() {
  kill -TERM "$LVA_PID" 2>/dev/null || true
  for _ in $(seq 20); do
    kill -0 "$LVA_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill -KILL "$LVA_PID" 2>/dev/null || true
  wait "$LVA_PID" 2>/dev/null || true
}

LVA_PID=""
trap '[ -n "$LVA_PID" ] && stop_lva; exit 0' TERM INT

# reSpeaker Console (HA ingress panel), independent of LVA restarts
(cd /opt/console && exec /opt/lva/.venv/bin/python server.py) &

cd /opt/lva
while true; do
  if ! xvf_ready; then
    echo "Waiting for XVF3800 (USB device and HA audio source)..."
    until xvf_ready; do
      sleep 1
    done
    sleep 2
  fi
  USB_ID=$(xvf_usb_id)

  pactl list short sources || true
  pactl list short sinks || true

  # Use the XVF3800 directly instead of the plugin default from the Audio section
  IN_DEV=$(pactl list short sources | awk '$2 ~ /^alsa_input\..*XVF3800/ { print $2; exit }')
  OUT_DEV=$(pactl list short sinks | awk '$2 ~ /^alsa_output\..*XVF3800/ { print $2; exit }')
  echo "Input: ${IN_DEV:-default}, output: ${OUT_DEV:-default}"
  jq --arg in "$IN_DEV" --arg out "$OUT_DEV" '
    .audio.input_device = (if $in == "" then null else $in end)
    | .audio.output_device = (if $out == "" then null else "pulse/" + $out end)
  ' "$CONFIG.base" > "$CONFIG"

  # 100% = 0 dB: PulseAudio passes samples unchanged (XVF3800 does AEC/NS/AGC in hardware)
  pactl set-source-volume "${IN_DEV:-@DEFAULT_SOURCE@}" 100% \
    || echo "WARNING: failed to set microphone volume" >&2

  .venv/bin/python -m linux_voice_assistant -c "$CONFIG" &
  LVA_PID=$!

  while kill -0 "$LVA_PID" 2>/dev/null; do
    if [ "$(xvf_usb_id)" != "$USB_ID" ]; then
      echo "XVF3800 USB device changed ($USB_ID -> $(xvf_usb_id)), restarting LVA"
      stop_lva
      continue 2
    fi
    sleep 2
  done

  # LVA exited on its own - let the Supervisor handle it
  wait "$LVA_PID" && RC=0 || RC=$?
  echo "LVA exited with code $RC"
  exit "$RC"
done
