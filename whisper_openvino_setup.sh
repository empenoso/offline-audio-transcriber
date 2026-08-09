#!/usr/bin/env bash

# Install the Intel GPU/OpenVINO transcription environment on Ubuntu.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VENV_DIR="$SCRIPT_DIR/.venv-openvino"
export PIP_CACHE_DIR="$SCRIPT_DIR/.cache/pip"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

intel_gpu_description() {
    local output=""
    local render_found=false
    if command -v lspci >/dev/null 2>&1; then
        output=$(lspci -nn | awk 'BEGIN {IGNORECASE=1} /VGA compatible controller|3D controller|Display controller/ && /Intel|\[8086:/ {print}')
        [[ -n "$output" ]] && printf '%s\n' "$output"
    else
        local device vendor class
        for device in /sys/bus/pci/devices/*; do
            [[ -r "$device/vendor" && -r "$device/class" ]] || continue
            vendor=$(<"$device/vendor")
            class=$(<"$device/class")
            [[ "$vendor" == "0x8086" && "$class" == 0x03* ]] && printf 'Intel PCI display device at %s\n' "${device##*/}"
        done
    fi

    local node render_vendor
    for node in /sys/class/drm/renderD*/device/vendor; do
        [[ -r "$node" ]] || continue
        render_vendor=$(<"$node")
        if [[ "$render_vendor" == "0x8086" ]]; then
            printf 'Intel GPU render device: /dev/dri/%s\n' "$(basename "$(dirname "$(dirname "$node")")")"
            render_found=true
        fi
    done

    # WSL, containers, and VMs may expose the Intel compute runtime while hiding
    # the underlying PCI device and its sysfs vendor attribute.
    if [[ "$render_found" == false ]] && command -v clinfo >/dev/null 2>&1; then
        if clinfo -l 2>/dev/null | grep -qi intel; then
            printf 'Intel GPU compute runtime reported by clinfo\n'
        fi
    fi
    return 0
}

check_supported_os() {
    [[ -r /etc/os-release ]] || fail 'Cannot identify the operating system.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "$ID" == "ubuntu" ]] || fail 'This installer currently supports Ubuntu only.'
    ok "Detected $PRETTY_NAME"
}

install_intel_driver() {
    log 'Intel GPU compute driver must be installed in the OS before OpenVINO.'
    printf 'Packages to install: intel-opencl-icd, intel-level-zero-gpu, level-zero, clinfo\n'

    local answer
    if [[ ! -t 0 ]]; then
        fail 'Interactive confirmation is required. Run this installer from a terminal.'
    fi
    read -r -p 'Install the Intel GPU driver packages now? [y/N] ' answer
    [[ "$answer" =~ ^[Yy]$ ]] || fail 'Driver installation declined; OpenVINO setup was not started.'

    sudo apt-get update
    sudo apt-get install -y python3 python3-venv ffmpeg pciutils \
        ocl-icd-libopencl1 intel-opencl-icd intel-level-zero-gpu level-zero clinfo
    sudo usermod -aG render "$(id -un)"
    ok 'Intel GPU driver packages are installed.'
    warn 'If render-group membership was new, log out and back in (or reboot) before GPU access will work.'
}

verify_openvino_gpu() {
    "$VENV_DIR/bin/python" - <<'PY'
import openvino as ov

core = ov.Core()
devices = core.available_devices
print("OpenVINO devices:", ", ".join(devices) or "none")
if not any(device == "GPU" or device.startswith("GPU.") for device in devices):
    raise SystemExit("Intel GPU is not visible to OpenVINO. Log out/in (or reboot), then run this installer again.")
PY
}

main() {
    check_supported_os

    local gpu_info
    gpu_info=$(intel_gpu_description)
    [[ -n "$gpu_info" ]] || fail 'No Intel PCI controller, render device, or Intel compute runtime was detected.'
    ok 'Intel GPU interface detected:'
    printf '%s\n' "$gpu_info"

    install_intel_driver

    log "Creating Python environment at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install --upgrade pip
    "$VENV_DIR/bin/python" -m pip install \
        openvino openvino-genai 'optimum-intel[openvino]' numpy

    verify_openvino_gpu
    ok 'OpenVINO Intel GPU environment is ready.'
    printf '\nActivate it with:\n  source %q/bin/activate\n' "$VENV_DIR"
    printf 'Run transcription with:\n  python whisper_transcribe_openvino.py ./audio medium ./results\n'
    printf 'The selected Whisper model is downloaded and converted on its first run.\n'
}

main "$@"
