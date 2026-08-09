#!/usr/bin/env bash

# Remove files and system packages installed by whisper_openvino_setup.sh.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VENV_DIR="$SCRIPT_DIR/.venv-openvino"
STATE_DIR="$SCRIPT_DIR/.openvino-install-state"
PACKAGE_FILE="$STATE_DIR/apt-packages.txt"
MODEL_DIR="$SCRIPT_DIR/.openvino_models"
CACHE_DIR="$SCRIPT_DIR/.cache"
REMOVE_DATA=false
ASSUME_YES=false

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    printf 'Usage: %s [--yes] [--remove-data]\n' "${0##*/}"
    printf '  --yes          skip the main confirmation\n'
    printf '  --remove-data  also delete downloaded models and caches\n'
}

confirm() {
    local prompt=$1 answer
    [[ "$ASSUME_YES" == true ]] && return 0
    [[ -t 0 ]] || fail 'Interactive confirmation is required; use --yes for non-interactive execution.'
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

delete_tree() {
    local target=$1
    [[ "$target" == "$SCRIPT_DIR/"* ]] || fail "Refusing to delete path outside the repository: $target"
    [[ -d "$target" ]] || return 0
    find "$target" -depth -delete
    log "Removed $target"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --yes) ASSUME_YES=true ;;
            --remove-data) REMOVE_DATA=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; fail "Unknown option: $1" ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    printf 'This will remove the OpenVINO virtual environment and only APT packages\n'
    printf 'recorded as newly installed by whisper_openvino_setup.sh.\n'
    [[ "$REMOVE_DATA" == true ]] && printf 'Downloaded models and repository-local caches will also be deleted.\n'
    confirm 'Continue?' || { printf 'Cancelled.\n'; return 0; }

    delete_tree "$VENV_DIR"

    if [[ -s "$PACKAGE_FILE" ]]; then
        mapfile -t packages < <(while IFS= read -r package; do
            [[ -n "$package" ]] && dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii' && printf '%s\n' "$package"
        done < "$PACKAGE_FILE")
        if ((${#packages[@]})); then
            log "Removing recorded APT packages: ${packages[*]}"
            sudo apt-get remove --purge -y "${packages[@]}"
        fi
    else
        warn 'No recorded APT package list was found; no system packages will be removed.'
        warn 'This is expected for installations made before package tracking was added.'
    fi

    if [[ -f "$STATE_DIR/render-group-added" ]] && getent group render >/dev/null 2>&1; then
        log "Removing $(id -un) from the render group (the setup script added it)."
        sudo gpasswd -d "$(id -un)" render || warn 'Could not remove render-group membership.'
    fi

    if [[ "$REMOVE_DATA" == true ]]; then
        delete_tree "$MODEL_DIR"
        delete_tree "$CACHE_DIR"
    fi

    delete_tree "$STATE_DIR"
    printf 'OpenVINO transcription environment was removed.\n'
    [[ "$REMOVE_DATA" == false ]] && printf 'Models and caches were kept. Use --remove-data to delete them too.\n'
}

main "$@"
