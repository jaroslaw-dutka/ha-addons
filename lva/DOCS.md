# Assist Satellite for XVF3800

Runs [Linux Voice Assistant (imonlinux fork)](https://github.com/imonlinux/linux-voice-assistant)
on the Home Assistant host with a ReSpeaker XVF3800 connected over USB.

## Setup

1. Connect the XVF3800 and start the add-on.
2. Home Assistant discovers the satellite through the ESPHome integration
   (mDNS, port `6053`). If it does not, add the ESPHome integration manually
   with the host IP and port `6053`.
3. Optional: with MQTT enabled, LED ring effect and color entities (per voice
   state) are created via MQTT discovery. Everything else uses ESPHome.

## Audio

Audio goes through the Home Assistant audio plugin. In the add-on **Audio**
section select the XVF3800 explicitly as input and output (not "Default").

## Data

Preferences (volume, selected sounds, stable MAC address) and downloaded wake
words are stored in the add-on data directory and survive updates.
