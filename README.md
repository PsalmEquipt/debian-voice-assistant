Home Assistant Voice Using a Quality PC Microphone

Pairing a quality USB microphone with a low-power x86 mini-PC running Linux Voice Assistant on Debian makes it detectable as an ESPHome device. Besides installing an improved voice assistant, this same cleaned microphone stream is also available network-wide (including as a Windows virtual mic), so every device in the house can share your best microphone.

Key Features & Supporting Components
-PC-mic quality audio capture — Quality USB microphone + ALSA / PipeWire
-Real-time noise suppression — PipeWire filter-chain + RNNoise LADSPA plugin (librnnoise_ladspa)
-Native Home Assistant voice integration — Linux Voice Assistant (OHF-Voice) + ESPHome API + custom openWakeWord model
-Network-wide mic & Windows virtual mic — PipeWire RTP sink (UDP 5004) + VB-Audio Virtual Cable + ffplay + SDP
-Headless reliability & monitoring — Systemd user services + loginctl linger + masked sleep targets + lightweight status page

# voice-assistant-debian

Turn a Debian box with a USB microphone into a **network microphone server**:

```
USB mic ──► PipeWire ──► RNNoise noise suppression ──► RTP stream (UDP) ──► your PC
```

It starts by itself at boot (no login needed). Optionally it also runs a Home
Assistant voice satellite ([linux-voice-assistant]) on the same cleaned-up mic.

For setup of all components (except the system monitor webpage) on a fresh Debian environment, run the automated installer directly from your terminal:

```
bash <(curl -sSL https://raw.githubusercontent.com/PsalmEquipt/debian-voice-assistant/main/setup.sh)
```

Home Assistant community: https://community.home-assistant.io/t/voice-assistant-microphone-upgrade/1032909
