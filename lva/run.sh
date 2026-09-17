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
  --argjson event_sounds "$(opt event_sounds_enabled)" \
  --argjson listen_during_wake "$(opt listen_during_wake_sound)" \
  --argjson debug "$(opt debug)" \
  --argjson volume_sync "$(opt volume_sync)" \
  --argjson max_volume "$(opt max_volume_percent)" \
  --arg wake_word "$(opt wake_word)" \
  --argjson threshold "$(opt wake_word_threshold)" \
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
      event_sounds_enabled: $event_sounds,
      listen_during_wake_sound: $listen_during_wake,
      preferences_file: "/data/preferences.json",
      debug: $debug
    },
    audio: {
      volume_sync: $volume_sync,
      max_volume_percent: $max_volume
    },
    wake_word: {
      model: $wake_word,
      openwakeword_threshold: $threshold,
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
  }' > "$CONFIG"

# Board reboot on startup breaks USB detection (no hotplug inside the container)
if [ "$(opt xvf3800_startup_reboot)" = "true" ]; then
  export LVA_XVF3800_STARTUP_REBOOT=1
else
  export LVA_XVF3800_STARTUP_REBOOT=0
fi

# --- Audio ------------------------------------------------------------------
# Devices come from the HA audio plugin, selected in the add-on "Audio" section
pactl list short sources || true
pactl list short sinks || true

cd /opt/lva
exec .venv/bin/python -m linux_voice_assistant -c "$CONFIG"
