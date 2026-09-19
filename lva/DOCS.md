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

Audio goes through the Home Assistant audio plugin. The add-on picks the
XVF3800 source and sink automatically, the **Audio** section is not used.

All voice processing (echo cancellation, noise suppression, gain, beamforming)
is done by the XVF3800 DSP. No software processing is applied: the source
volume is set to 100% (0 dB, samples unchanged) and Home Assistant receives
audio with noise suppression and auto gain disabled.

## reSpeaker Console

The **reSpeaker** sidebar panel is a web build of
[reSpeaker Console](https://github.com/respeaker/respeaker-console) for tuning
the XVF3800 DSP: live monitoring (direction of arrival, voice activity, AEC),
audio and LED controls and the full parameter catalog with export/import.

- Changes are live and lost when the board reboots or is re-plugged. Use
  **Save to Flash** in the parameter catalog to keep them.
- Linux Voice Assistant routes the processed ASR beam to both USB channels
  (`AUDIO_MGR_OP_L`/`AUDIO_MGR_OP_R` = `7, 3`) and drives the LED ring, so it
  overrides those settings on every start.
- Rebooting the board from the console restarts Linux Voice Assistant.
- Firmware flashing (DFU) is not available in the add-on.

## Data

Preferences (volume, selected sounds, stable MAC address) and downloaded wake
words are stored in the add-on data directory and survive updates.
