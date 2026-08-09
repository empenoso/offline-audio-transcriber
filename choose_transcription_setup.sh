#!/usr/bin/env bash

# Detect supported GPU hardware and tell the user which transcription installer to run.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NVIDIA_SETUP="$SCRIPT_DIR/whisper_transcribe_setup.sh"
INTEL_SETUP="$SCRIPT_DIR/whisper_openvino_setup.sh"

has_pci_display_vendor() {
    local vendor_name=$1
    local vendor_id=$2
    local device vendor class

    if command -v lspci >/dev/null 2>&1; then
        lspci -nn | awk -v name="$vendor_name" -v id="$vendor_id" '
            BEGIN { IGNORECASE=1; found=0 }
            /VGA compatible controller|3D controller|Display controller/ && ($0 ~ name || $0 ~ "\\[" id ":") { found=1 }
            END { exit !found }
        '
        return
    fi

    for device in /sys/bus/pci/devices/*; do
        [[ -r "$device/vendor" && -r "$device/class" ]] || continue
        vendor=$(<"$device/vendor")
        class=$(<"$device/class")
        [[ "$vendor" == "0x$vendor_id" && "$class" == 0x03* ]] && return 0
    done
    return 1
}

relative_name() {
    printf './%s' "${1##*/}"
}

has_intel_render_device() {
    local node vendor
    for node in /sys/class/drm/renderD*/device/vendor; do
        [[ -r "$node" ]] || continue
        vendor=$(<"$node")
        [[ "$vendor" == "0x8086" ]] && return 0
    done
    if command -v clinfo >/dev/null 2>&1; then
        clinfo -l 2>/dev/null | grep -qi intel && return 0
    fi
    return 1
}

main() {
    local has_nvidia=false
    local has_intel=false
    local nvidia_driver=false
    local intel_driver=false

    has_pci_display_vendor NVIDIA 10de && has_nvidia=true
    has_pci_display_vendor Intel 8086 && has_intel=true
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && nvidia_driver=true
    has_intel_render_device && intel_driver=true

    printf 'GPU transcription setup advisor\n'
    printf '===============================\n'
    printf 'NVIDIA display hardware: %s\n' "$has_nvidia"
    printf 'NVIDIA CUDA driver usable: %s\n' "$nvidia_driver"
    printf 'Intel display hardware:  %s\n' "$has_intel"
    printf 'Intel render device present: %s\n\n' "$intel_driver"

    if [[ "$has_nvidia" == true && "$has_intel" == true ]]; then
        printf 'Both supported GPU types were detected.\n'
        if [[ "$nvidia_driver" == true ]]; then
            printf 'Recommended: NVIDIA/CUDA (its driver is already usable):\n  %s\n' "$(relative_name "$NVIDIA_SETUP")"
        elif [[ "$intel_driver" == true ]]; then
            printf 'Recommended: Intel/OpenVINO (an Intel render device is already present):\n  %s\n' "$(relative_name "$INTEL_SETUP")"
        else
            printf 'Recommended default: NVIDIA/CUDA:\n  %s\n' "$(relative_name "$NVIDIA_SETUP")"
        fi
        printf 'Alternative Intel/OpenVINO setup:\n  %s\n' "$(relative_name "$INTEL_SETUP")"
    elif [[ "$has_nvidia" == true ]]; then
        printf 'Use the NVIDIA/CUDA setup:\n  %s\n' "$(relative_name "$NVIDIA_SETUP")"
    elif [[ "$has_intel" == true ]]; then
        printf 'Use the Intel/OpenVINO setup:\n  %s\n' "$(relative_name "$INTEL_SETUP")"
    else
        printf 'No supported Intel or NVIDIA GPU was detected.\n'
        printf 'GPU setup cannot be recommended; check that the GPU is enabled and visible to the OS.\n'
        return 1
    fi

    printf '\nThis advisor only reports a recommendation; it does not install anything.\n'
}

main "$@"
