FROM debian:trixie-slim

# Fork has no own releases (its v1.1.0 tag mirrors upstream without MQTT/XVF3800),
# so the source is pinned to a commit. Bump the add-on version after changing it.
ARG LVA_REPO=https://github.com/imonlinux/linux-voice-assistant.git
ARG LVA_REF=4c67ec4f335e375f9e45ba1ab7f4d7c36ac94f51

# Audio goes through the HA audio plugin (PulseAudio). libmpv also probes PipeWire,
# which logs missing client.conf errors, so force pulse and silence libpipewire.
# XVF3800 reboot on startup breaks USB detection (no hotplug inside the container).
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    LVA_AO=pulse \
    PIPEWIRE_DEBUG=0 \
    LVA_XVF3800_STARTUP_REBOOT=0

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git tini jq curl \
        python3 python3-venv \
        pulseaudio-utils \
        libmpv2 libusb-1.0-0 libpulse0 \
        build-essential python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git init -q /opt/lva \
    && cd /opt/lva \
    && git remote add origin "${LVA_REPO}" \
    && git fetch -q --depth 1 origin "${LVA_REF}" \
    && git checkout -q FETCH_HEAD \
    && rm -rf .git

WORKDIR /opt/lva

# Bug fixes (idempotent - no-op once fixed upstream)
RUN python3 - <<'EOF'
import pathlib, re

# 1) Missing Optional import in util.py
p = pathlib.Path("linux_voice_assistant/util.py")
s = p.read_text()
if "Optional[" in s and not re.search(r"^from typing import .*\bOptional\b", s, re.M):
    lines = s.splitlines(keepends=True)
    idx = 0
    for i, line in enumerate(lines):
        if line.startswith("from __future__"):
            idx = i + 1
    lines.insert(idx, "from typing import Optional\n")
    p.write_text("".join(lines))
    print("patch: added 'from typing import Optional' to util.py")

# 2) Renamed mpv option (mpv >= 0.40: audio-stream-silence)
p = pathlib.Path("linux_voice_assistant/mpv_player.py")
s = p.read_text()
new = re.sub(r"\bstream_silence=", "audio_stream_silence=", s)
if new != s:
    p.write_text(new)
    print("patch: stream_silence -> audio_stream_silence in mpv_player.py")
EOF

RUN script/setup \
    && apt-get purge -y build-essential python3-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /root/.cache

COPY run.sh /run.sh
RUN chmod a+x /run.sh

LABEL org.opencontainers.image.source=https://github.com/imonlinux/linux-voice-assistant

ENTRYPOINT [ "/usr/bin/tini", "-g", "--" ]
CMD [ "/run.sh" ]
