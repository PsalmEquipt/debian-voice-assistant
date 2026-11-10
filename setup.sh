#!/usr/bin/env bash
#
# setup.sh - PipeWire microphone server for Debian
#
#   USB microphone -> RNNoise noise suppression -> RTP stream (UDP), started at boot.
#   Optionally also runs a Home Assistant voice satellite (linux-voice-assistant).
#
# Developed against Debian 13 "trixie" (PipeWire 1.4, WirePlumber 0.5).
# Run as the normal user that should own the stream - NOT as root. sudo is used
# only for apt and for enabling systemd "linger".
#
# Safe to re-run: unchanged files are skipped, changed files are backed up first
# (as FILE.bak-YYYYMMDD-HHMMSS). Try  ./setup.sh --dry-run  to see what would change.

# Settings reach envsubst by name (see TEMPLATE_VARS), which shellcheck can't follow.
# shellcheck disable=SC2034

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
USER_NAME="$(id -un)"
WORK_DIR="$(mktemp -d)"

DRY_RUN=0
SKIP_APT=0
DO_UPGRADE=0
LIST_DEVICES=0
PW_RESTART=0
UNITS_CHANGED=0
LVA_ACTIVE=0
WARNINGS=()

# Pinned download of the RNNoise LADSPA plugin (upstream: werman/noise-suppression-for-voice).
# There is no Debian package for it. The zip is verified against this checksum.
RNNOISE_VERSION="v1.10"
RNNOISE_ZIP_URL="https://github.com/werman/noise-suppression-for-voice/releases/download/${RNNOISE_VERSION}/linux-rnnoise.zip"
RNNOISE_ZIP_SHA256="811390b6eb6e28dde023c70590c74d26e74ebb2e595bcf4b95af2341db160e99"
RNNOISE_ZIP_MEMBER="linux-rnnoise/ladspa/librnnoise_ladspa.so"

APT_PACKAGES=(
    pipewire pipewire-bin libpipewire-0.3-modules libspa-0.2-modules
    pipewire-pulse pipewire-alsa wireplumber
    pulseaudio-utils alsa-utils iproute2
    gettext-base curl ca-certificates unzip
)

# Variables that may appear as ${NAME} in the *.in template files.
TEMPLATE_VARS=(
    RTP_DEST_IP RTP_DEST_PORT RTP_SESSION_NAME RTP_TARGET_LINES
    MIC_DESCRIPTION MIC_CAPTURE_TARGET_LINE MIC_CARD_NAME MIC_CARD_PROFILE
    RNNOISE_VAD_THRESHOLD RNNOISE_VAD_GRACE_MS LADSPA_USER_DIR
    LVA_DIR LVA_NAME LVA_WAKE_MODEL LVA_INPUT_ARGS LVA_EXTRA_ARGS
)

# ---------------------------------------------------------------- output helpers
if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_OFF=$'\e[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
info() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_OK" "$*" "$C_OFF"; }
warn() { printf '%sWARNING:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '%sERROR:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'printf "ERROR: setup.sh failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Run a command, or just print it in --dry-run mode.
run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./setup.sh [options]

Stream:
  --dest-ip IP           where to send the microphone (default: 224.0.0.56, multicast)
  --dest-port PORT       UDP port (default: 5004)
  --session-name NAME    RTP session name (default: this host's name)

Microphone:
  --mic-source NAME      capture source to stream (default: system default source)
  --mic-card NAME        pin this sound card to a profile that has a mic input
  --no-rnnoise           skip noise suppression
  --list-devices         print capture sources and sound cards, then exit

Optional parts:
  --with-lva             also run the Home Assistant voice satellite
                         (linux-voice-assistant must already be installed)
  --lva-name NAME        satellite name shown in Home Assistant
  --wake-model NAME      satellite wake word model (default: okay_nabu)
  --no-alsa              don't install ~/.asoundrc

Run control:
  --skip-apt             don't touch packages (they must already be installed)
  --upgrade              also run "apt-get upgrade" (everything installed, not just ours)
  --dry-run              show what would change, change nothing
  -h, --help             this text

All defaults live in config/voice-assistant.env. Flags override that file.
EOF
}

# ---------------------------------------------------------------- settings
CONFIG_FILE="${VOICE_CONFIG:-$SCRIPT_DIR/config/voice-assistant.env}"
[[ -r $CONFIG_FILE ]] || die "Settings file not found: $CONFIG_FILE"
# shellcheck source=config/voice-assistant.env
source "$CONFIG_FILE"

need_arg() { [[ $# -ge 2 ]] || die "Option $1 needs a value (try --help)"; }

parse_args() {
    while (( $# )); do
        case $1 in
            --dest-ip)       need_arg "$@"; RTP_DEST_IP=$2; shift 2 ;;
            --dest-port)     need_arg "$@"; RTP_DEST_PORT=$2; shift 2 ;;
            --session-name)  need_arg "$@"; RTP_SESSION_NAME=$2; shift 2 ;;
            --mic-source)    need_arg "$@"; MIC_SOURCE=$2; shift 2 ;;
            --mic-card)      need_arg "$@"; MIC_CARD_NAME=$2; shift 2 ;;
            --no-rnnoise)    ENABLE_RNNOISE=0; shift ;;
            --no-alsa)       INSTALL_ALSA_CONFIG=0; shift ;;
            --with-lva)      ENABLE_LVA=1; shift ;;
            --lva-name)      need_arg "$@"; LVA_NAME=$2; shift 2 ;;
            --wake-model)    need_arg "$@"; LVA_WAKE_MODEL=$2; shift 2 ;;
            --skip-apt)      SKIP_APT=1; shift ;;
            --upgrade)       DO_UPGRADE=1; shift ;;
            --dry-run)       DRY_RUN=1; shift ;;
            --list-devices)  LIST_DEVICES=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Unknown option: $1 (try --help)" ;;
        esac
    done
}

validate_settings() {
    local v o
    local -a octets

    for v in ENABLE_RNNOISE INSTALL_ALSA_CONFIG ENABLE_LVA; do
        [[ ${!v} == [01] ]] || die "$v must be 0 or 1 (got '${!v}')"
    done

    [[ $RTP_DEST_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "RTP_DEST_IP must be an IPv4 address (got '$RTP_DEST_IP')"
    IFS=. read -r -a octets <<<"$RTP_DEST_IP"
    for o in "${octets[@]}"; do
        if (( 10#$o > 255 )); then die "RTP_DEST_IP is not a valid IPv4 address (got '$RTP_DEST_IP')"; fi
    done
    RTP_DEST_IP="$((10#${octets[0]})).$((10#${octets[1]})).$((10#${octets[2]})).$((10#${octets[3]}))"

    [[ $RTP_DEST_PORT =~ ^[0-9]{1,5}$ ]] || die "RTP_DEST_PORT must be a number from 1 to 65535 (got '$RTP_DEST_PORT')"
    RTP_DEST_PORT=$((10#$RTP_DEST_PORT))
    if (( RTP_DEST_PORT < 1 || RTP_DEST_PORT > 65535 )); then
        die "RTP_DEST_PORT must be a number from 1 to 65535 (got '$RTP_DEST_PORT')"
    fi
    [[ $RNNOISE_VAD_THRESHOLD =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || die "RNNOISE_VAD_THRESHOLD must be a number (got '$RNNOISE_VAD_THRESHOLD')"
    [[ $RNNOISE_VAD_GRACE_MS =~ ^[0-9]{1,6}$ ]] \
        || die "RNNOISE_VAD_GRACE_MS must be a whole number (got '$RNNOISE_VAD_GRACE_MS')"
    RNNOISE_VAD_GRACE_MS=$((10#$RNNOISE_VAD_GRACE_MS))

    # These end up inside quoted strings in config files, so keep them plain.
    for v in RTP_SESSION_NAME MIC_SOURCE MIC_CARD_NAME MIC_CARD_PROFILE MIC_DESCRIPTION LVA_NAME LVA_WAKE_MODEL; do
        if [[ ${!v} == *[\"\\\$\`%]* || ${!v} == *$'\n'* ]]; then
            die "$v must not contain quotes, backslashes, \$, backticks, % or line breaks"
        fi
    done
    if [[ $LVA_EXTRA_ARGS == *[\$\`%]* || $LVA_EXTRA_ARGS == *$'\n'* ]]; then
        die "LVA_EXTRA_ARGS must not contain \$, backticks, % or line breaks"
    fi
    [[ $LVA_WAKE_MODEL != *[[:space:]]* ]] || die "LVA_WAKE_MODEL must not contain spaces"
    for v in LVA_DIR LADSPA_USER_DIR; do
        [[ ${!v} == /* ]] || die "$v must be an absolute path (got '${!v}')"
        [[ ${!v} != *[[:space:]\"\'\$\`%\\]* ]] || die "$v must not contain spaces or quote characters"
    done
}

# Work out the values that the templates need.
compute_derived() {
    local indent="                " target=""    # 16 spaces: lines up inside the .conf templates

    if [[ -z $RTP_SESSION_NAME ]]; then RTP_SESSION_NAME="$(hostname -s)"; fi

    MIC_CAPTURE_TARGET_LINE=""
    if [[ -n $MIC_SOURCE ]]; then
        MIC_CAPTURE_TARGET_LINE="${indent}target.object = \"$MIC_SOURCE\""
    fi

    # What the RTP stream reads: the denoised mic, else the chosen source, else the default.
    if (( ENABLE_RNNOISE )); then
        target="mic_cleaned"
    elif [[ -n $MIC_SOURCE ]]; then
        target=$MIC_SOURCE
    fi
    RTP_TARGET_LINES=""
    if [[ -n $target ]]; then
        RTP_TARGET_LINES="${indent}target.object      = \"$target\""$'\n'"${indent}node.dont-fallback = true"
    fi

    # The satellite listens to the denoised mic when there is one, else the default input.
    LVA_INPUT_ARGS=""
    if (( ENABLE_RNNOISE )); then
        LVA_INPUT_ARGS="--audio-input-device \"$MIC_DESCRIPTION\""
    fi

    local v
    ENVSUBST_VARS=""
    for v in "${TEMPLATE_VARS[@]}"; do ENVSUBST_VARS+="\${$v} "; done
    export "${TEMPLATE_VARS[@]}"
}

# ---------------------------------------------------------------- checks
setup_user_bus() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [[ -S $XDG_RUNTIME_DIR/bus ]]; then
        export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    fi
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        local msg="Cannot reach your systemd user manager. Log in normally (console or ssh), or run 'sudo loginctl enable-linger $USER_NAME' and log in again."
        if (( DRY_RUN )); then warn "$msg"; else die "$msg"; fi
    fi
}

preflight() {
    step "Preflight"
    local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""

    if [[ $EUID -eq 0 ]]; then
        die "Run this as your normal user, not root: the audio services are per-user. (sudo is used only where needed.)"
    fi
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) ;;
        *) die "This script is for Debian and its derivatives (found: ${PRETTY_NAME:-unknown})" ;;
    esac
    info "System: ${PRETTY_NAME:-unknown}, user: $USER_NAME"
    if [[ ${ID:-} != debian || ${VERSION_ID:-} != 13 ]]; then
        warn "Developed on Debian 13 (trixie); you have ${PRETTY_NAME:-something else}. It should work, but it is untested there."
    fi

    setup_user_bus
    if systemctl --user is-active --quiet pulseaudio.service 2>/dev/null; then
        warn "Classic PulseAudio is running and will fight with pipewire-pulse. Disable it: systemctl --user mask --now pulseaudio.service pulseaudio.socket"
    fi
}

need_sudo() {
    command -v sudo >/dev/null 2>&1 \
        || die "sudo is needed for apt. Install the packages as root and re-run with --skip-apt."
    if (( DRY_RUN )); then return 0; fi
    if ! sudo -n true 2>/dev/null; then
        info "sudo will ask for your password (used for apt and linger only)."
        sudo -v || die "sudo authentication failed"
    fi
}

pkg_installed() {
    # shellcheck disable=SC2016  # ${db:...} is dpkg-query syntax, not shell
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

have_file() {
    [[ -n "$(find /usr/lib /usr/local/lib -name "$1" -print -quit 2>/dev/null)" ]]
}

install_packages() {
    step "Packages"
    local p
    local -a missing=()
    for p in "${APT_PACKAGES[@]}"; do
        pkg_installed "$p" || missing+=("$p")
    done

    if (( SKIP_APT )); then
        if (( ${#missing[@]} )); then warn "--skip-apt given, but these packages are missing: ${missing[*]}"; fi
        return 0
    fi
    if (( ${#missing[@]} == 0 && DO_UPGRADE == 0 )); then
        info "All required packages are already installed."
        return 0
    fi

    need_sudo
    run sudo apt-get update
    if (( DO_UPGRADE )); then
        run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    fi
    if (( ${#missing[@]} )); then
        info "Installing: ${missing[*]}"
        run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

check_dependencies() {
    step "Dependency check"
    local c
    local -a absent=()
    for c in envsubst systemctl loginctl pw-dump wpctl pactl find cmp diff install sha256sum; do
        command -v "$c" >/dev/null 2>&1 || absent+=("$c")
    done
    if (( ${#absent[@]} )); then
        if (( DRY_RUN )) && [[ ${#absent[@]} -eq 1 && ${absent[0]} != envsubst ]]; then
            warn "Not installed yet (a real run installs them): ${absent[*]}"
        else
            die "Missing commands: ${absent[*]}. Install the packages (drop --skip-apt), or in --dry-run: sudo apt-get install gettext-base"
        fi
    fi

    local m
    for m in libpipewire-module-rtp-sink.so libpipewire-module-filter-chain.so; do
        have_file "$m" || warn "PipeWire module $m not found - is libpipewire-0.3-modules installed?"
    done
    if (( ENABLE_RNNOISE )) && ! have_file libspa-filter-graph-plugin-ladspa.so; then
        warn "PipeWire's LADSPA filter plugin not found - is libspa-0.2-modules installed?"
    fi
    info "OK"
}

# ---------------------------------------------------------------- RNNoise plugin
ensure_rnnoise() {
    step "RNNoise LADSPA plugin"
    local dest="$LADSPA_USER_DIR/librnnoise_ladspa.so"

    if [[ -f $dest ]] || have_file librnnoise_ladspa.so; then
        info "Already present - nothing to download."
        return 0
    fi
    [[ $(uname -m) == x86_64 ]] \
        || die "The prebuilt RNNoise plugin is x86_64 only. Build it from https://github.com/werman/noise-suppression-for-voice, copy librnnoise_ladspa.so into $LADSPA_USER_DIR, or use --no-rnnoise."

    info "Downloading RNNoise $RNNOISE_VERSION (~35 MB zip; only the 5 MB LADSPA plugin is kept)"
    if (( DRY_RUN )); then
        info "    [dry-run] would download $RNNOISE_ZIP_URL, check its sha256, extract to $dest"
        return 0
    fi
    command -v curl  >/dev/null 2>&1 || die "curl is missing"
    command -v unzip >/dev/null 2>&1 || die "unzip is missing"

    local zip="$WORK_DIR/linux-rnnoise.zip"
    curl -fsSL --retry 3 -o "$zip" "$RNNOISE_ZIP_URL"
    echo "$RNNOISE_ZIP_SHA256  $zip" | sha256sum -c --quiet - \
        || die "Checksum mismatch on the RNNoise download - refusing to install it."
    unzip -p "$zip" "$RNNOISE_ZIP_MEMBER" > "$WORK_DIR/librnnoise_ladspa.so"
    mkdir -p -- "$LADSPA_USER_DIR"
    install -m 0644 -- "$WORK_DIR/librnnoise_ladspa.so" "$dest"
    info "  installed  $dest"
    PW_RESTART=1
}

# ---------------------------------------------------------------- file placement
# place_file SRC DEST MODE KIND
#   *.in sources are rendered with envsubst; others are copied as-is.
#   KIND: pw = PipeWire must restart to see it, units = systemd needs a reload, none.
place_file() {
    local src=$1 dest=$2 mode=$3 kind=$4
    local tmp="$WORK_DIR/render.$RANDOM.$RANDOM"

    if [[ $src == *.in ]]; then
        envsubst "$ENVSUBST_VARS" <"$src" >"$tmp"
    else
        cp -- "$src" "$tmp"
    fi

    if [[ -e $dest ]] && cmp -s -- "$tmp" "$dest"; then
        info "  unchanged  $dest"
        rm -f -- "$tmp"
        return 0
    fi

    if (( DRY_RUN )); then
        if [[ -e $dest ]]; then
            info "  would update  $dest"
            diff -u --label "current: $dest" --label "new" -- "$dest" "$tmp" | sed 's/^/      /' || true
        else
            info "  would create  $dest"
        fi
        rm -f -- "$tmp"
        return 0
    fi

    mkdir -p -- "$(dirname -- "$dest")"
    if [[ -e $dest ]]; then
        cp -p -- "$dest" "$dest.bak-$STAMP"
        info "  backup     $dest.bak-$STAMP"
    fi
    install -m "$mode" -- "$tmp" "$dest"
    info "  installed  $dest"
    case $kind in
        pw)    PW_RESTART=1 ;;
        units) UNITS_CHANGED=1 ;;
        *)     ;;
    esac
    rm -f -- "$tmp"
}

place_configs() {
    step "Configuration files"
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"

    if (( ENABLE_RNNOISE )); then
        place_file "$SCRIPT_DIR/config/environment.d/ladspa.conf.in" \
                   "$cfg/environment.d/ladspa.conf" 0644 none
        place_file "$SCRIPT_DIR/config/pipewire/pipewire.conf.d/99-input-denoising.conf.in" \
                   "$cfg/pipewire/pipewire.conf.d/99-input-denoising.conf" 0644 pw
    elif [[ -e $cfg/pipewire/pipewire.conf.d/99-input-denoising.conf ]]; then
        warn "--no-rnnoise: an existing 99-input-denoising.conf was left in place. Remove it yourself if you don't want the denoised virtual mic."
    fi

    place_file "$SCRIPT_DIR/config/pipewire/pipewire.conf.d/50-rtp-mic-send.conf.in" \
               "$cfg/pipewire/pipewire.conf.d/50-rtp-mic-send.conf" 0644 pw

    if [[ -n $MIC_CARD_NAME ]]; then
        place_file "$SCRIPT_DIR/config/wireplumber/wireplumber.conf.d/50-usb-mic-profile.conf.in" \
                   "$cfg/wireplumber/wireplumber.conf.d/50-usb-mic-profile.conf" 0644 pw
    fi

    if (( INSTALL_ALSA_CONFIG )); then
        if [[ -e $HOME/.asoundrc ]] && ! grep -q 'managed by voice-assistant-debian' "$HOME/.asoundrc"; then
            warn "$HOME/.asoundrc already exists and isn't ours, so it was left alone (pipewire-alsa already routes ALSA programs to PipeWire system-wide)."
        else
            place_file "$SCRIPT_DIR/config/alsa/asoundrc" "$HOME/.asoundrc" 0644 none
        fi
    fi

    place_file "$SCRIPT_DIR/systemd/wait-for-network.sh" \
               "$HOME/.local/bin/voice-wait-network" 0755 units
    place_file "$SCRIPT_DIR/systemd/audio-ready.service" \
               "$cfg/systemd/user/audio-ready.service" 0644 units

    if (( ENABLE_LVA )); then
        if [[ -x $LVA_DIR/.venv/bin/python3 ]]; then
            LVA_ACTIVE=1
            place_file "$SCRIPT_DIR/systemd/linux-voice-assistant.service.in" \
                       "$cfg/systemd/user/linux-voice-assistant.service" 0644 units
        else
            warn "linux-voice-assistant not found in $LVA_DIR (no .venv/bin/python3). Install it first (https://github.com/OHF-Voice/linux-voice-assistant), then re-run with --with-lva."
        fi
    fi
}

# ---------------------------------------------------------------- services
ensure_linger() {
    local state
    state="$(loginctl show-user "$USER_NAME" -p Linger --value 2>/dev/null || true)"
    if [[ $state == yes ]]; then
        info "Linger already enabled (services start at boot without a login)."
        return 0
    fi
    info "Enabling linger, so the stream starts at boot without anyone logging in."
    need_sudo
    run sudo loginctl enable-linger "$USER_NAME"
}

enable_services() {
    step "Services"
    run systemctl --user daemon-reload

    if (( ENABLE_RNNOISE )); then
        # environment.d is only read when the user manager starts; set it now too.
        run systemctl --user set-environment "LADSPA_PATH=$LADSPA_USER_DIR:/usr/lib/ladspa:/usr/local/lib/ladspa"
    fi

    run systemctl --user enable pipewire.socket pipewire-pulse.socket \
        pipewire.service wireplumber.service pipewire-pulse.service
    run systemctl --user enable audio-ready.service
    if (( LVA_ACTIVE )); then
        run systemctl --user enable linux-voice-assistant.service
    fi
    ensure_linger

    if (( PW_RESTART )); then
        info "Configuration changed - restarting PipeWire (audio drops for a few seconds)."
        run systemctl --user restart pipewire.service wireplumber.service pipewire-pulse.service
    else
        info "PipeWire configuration unchanged - no restart needed."
    fi

    if (( LVA_ACTIVE )); then
        if (( PW_RESTART || UNITS_CHANGED )); then
            run systemctl --user restart linux-voice-assistant.service
        else
            run systemctl --user start linux-voice-assistant.service
        fi
    fi
}

verify() {
    step "Verification"
    if (( DRY_RUN )); then info "(skipped in --dry-run)"; return 0; fi

    local tries=20 dump="" have_rtp=0 have_clean=0
    if (( ENABLE_RNNOISE == 0 )); then have_clean=1; fi
    while (( tries-- > 0 )); do
        dump="$(pw-dump 2>/dev/null || true)"
        if [[ $dump == *'"node.name": "rtp-mic-send"'* ]]; then have_rtp=1; fi
        if (( ENABLE_RNNOISE )) && [[ $dump == *'"node.name": "mic_cleaned"'* ]]; then have_clean=1; fi
        if (( have_rtp && have_clean )); then break; fi
        sleep 1
    done

    if (( have_rtp )); then
        info "OK    RTP stream is up -> $RTP_DEST_IP:$RTP_DEST_PORT"
    else
        warn "The RTP stream node 'rtp-mic-send' did not appear. See: journalctl --user -u pipewire -n 50"
    fi
    if (( ENABLE_RNNOISE )); then
        if (( have_clean )); then
            info "OK    Denoised microphone 'mic_cleaned' is up"
        else
            warn "The denoised mic 'mic_cleaned' did not appear (is librnnoise_ladspa.so on LADSPA_PATH?). See: journalctl --user -u pipewire | grep -i ladspa"
        fi
    fi
    if systemctl --user is-enabled --quiet audio-ready.service 2>/dev/null; then
        info "OK    audio-ready.service is enabled (starts at boot)"
    else
        warn "audio-ready.service is not enabled"
    fi
}

list_devices() {
    command -v pactl >/dev/null 2>&1 || die "pactl not found. Run the installer first (it installs pulseaudio-utils)."
    setup_user_bus
    echo "Capture sources (NAME -> --mic-source):"
    pactl list short sources 2>/dev/null | awk '$2 !~ /\.monitor$/ { printf "  %s\n", $2 }' || true
    echo
    echo "Sound cards (NAME -> --mic-card):"
    pactl list short cards 2>/dev/null | awk '{ printf "  %s\n", $2 }' || true
    echo
    echo "(Empty lists usually mean PipeWire isn't running yet.)"
}

summary() {
    step "Summary"
    if (( DRY_RUN )); then
        info "Dry run complete - nothing was changed."
    else
        info "Done. The microphone is streaming to $RTP_DEST_IP:$RTP_DEST_PORT"
        info "as RTP L16 (16-bit PCM), 48 kHz, mono, and will start again on every boot."
        info "Check it any time with:  pw-dump | grep -E '\"node.name\": \"(rtp-mic-send|mic_cleaned)\"'"
    fi
    if (( ${#WARNINGS[@]} )); then
        printf '\n%d warning(s):\n' "${#WARNINGS[@]}"
        local w
        for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
    fi
}

main() {
    parse_args "$@"
    if (( LIST_DEVICES )); then list_devices; exit 0; fi
    validate_settings
    compute_derived

    if (( DRY_RUN )); then info "DRY RUN: nothing will be installed or changed."; fi
    preflight
    install_packages
    check_dependencies
    if (( ENABLE_RNNOISE )); then ensure_rnnoise; fi
    place_configs
    enable_services
    verify
    summary
}

main "$@"
