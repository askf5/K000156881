#!/bin/bash

# v1.0 - initial release
# v1.2 - Added provisioning token support. Minor error-handling improvements.
#        (Version numbers synced with install.sh. There is no v1.1.)

if test "$BASH" = "" || "$BASH" -uc "a=();true \"\${a[@]}\"" 2>/dev/null; then
    # Bash 4.4, Zsh
    set -euo pipefail
else
    # Bash 4.3 and older chokes on empty arrays with set -u.
    set -eo pipefail
fi
set -o errtrace
shopt -s nullglob globstar

cleanup()
{
    echo "Error on line $1" >&2
}
trap 'cleanup $LINENO' ERR

# Default values (from environment if present)
CS_CID="${CS_CID:-}"
CS_CLOUD="${CS_CLOUD:-}"
CS_PROXY_HOST="${CS_PROXY_HOST:-}"
CS_PROXY_PORT="${CS_PROXY_PORT:-}"
CS_PROVISIONING_TOKEN="${CS_PROVISIONING_TOKEN:-}"
SENSOR_RPM="${SENSOR_RPM:-}"
TAGS="${TAGS:-}"

DEFAULT_SENSOR_RPM="/var/shared/falcon-sensor.rpm"

usage() {
    {
        echo "Usage: $0 [CS_CID] [-r|--rpm SENSOR_RPM] [-t|--tag TAGS] [-t|--tag ...] [-c|--cloud CLOUD] [--aph APH] [--app APP] [--provisioning-token TOKEN]"
        echo
        echo "Arguments/Options:"
        echo "  CS_CID       CrowdStrike Customer ID (or use CS_CID environment variable)"
        echo "  -r, --rpm    Falcon Sensor RPM path (or SENSOR_RPM environment variable)"
        echo "               Default: $DEFAULT_SENSOR_RPM"
        echo "  -t, --tag    Comma-separated sensor group tags (or TAGS environment variable)"
        echo "               If used multiple times, a comma will be added between each"
        echo "               Default: empty (leave the sensor untagged/ungrouped)"
        echo "  -c, --cloud  Specify particular CrowdStrike cloud (or CS_CLOUD environment variable)."
        echo "               One of us-1, us-2, eu-1, us-gov-1, us-gov-2"
        echo "               Default: empty (sensor will automatically discover the correct cloud)"
        echo "      --aph    Specify HTTP proxy host (or CS_PROXY_HOST environment variable)"
        echo "               Default: empty (directly connect to CrowdStrike cloud)"
        echo "      --app    Specify HTTP proxy port (or CS_PROXY_PORT environment variable)"
        echo "               Default: empty (directly connect to CrowdStrike cloud)"
        echo "      --provisioning-token Specify installation token (or CS_PROVISIONING_TOKEN environment variable)."
        echo "               Default: empty (specify when required)."
        echo "  -h, --help   Show this help message"
        echo
        echo "If no arguments are passed, environment variables are used."
    } >&2
    exit 1
}

# If first arg looks like an option, skip positional handling
if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    CS_CID="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--rpm)
            [[ $# -ge 2 ]] || { echo >&2 "Error: $1 requires a value"; usage; }
            SENSOR_RPM="$2"
            shift 2
            ;;
        -t|--tag|--tags)
            [[ $# -ge 2 ]] || { echo >&2 "Error: $1 requires a value"; usage; }
            if [ -n "$TAGS" ]; then
                TAGS="$TAGS,$2"
            else
                TAGS="$2"
            fi
            shift 2
            ;;
        -c|--cloud)
            [[ $# -ge 2 ]] || { echo >&2 "Error: $1 requires a value"; usage; }
            CS_CLOUD="$2"
            shift 2
            ;;
        --aph)
            [[ $# -ge 2 ]] || { echo >&2 "Error: $1 requires a value"; usage; }
            CS_PROXY_HOST="$2"
            shift 2
            ;;
        --app)
            [[ $# -ge 2 ]] || { echo >&2 "Error: $1 requires a value"; usage; }
            CS_PROXY_PORT="$2"
            shift 2
            ;;
        --provisioning-token)
            [[ $# -ge 2 ]] || { echo >&2 "Error: $1 requires a value"; usage; }
            CS_PROVISIONING_TOKEN="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Fail early if falcon-sensor is already installed.
if [[ -f /opt/CrowdStrike/falconctl ]]; then
    echo >&2 "Error: CrowdStrike sensor is already installed."
    exit 1
fi

# Default sensor RPM if not given
if [[ -z "$SENSOR_RPM" ]]; then
    SENSOR_RPM="$DEFAULT_SENSOR_RPM"
fi

readonly SENSOR_RPM
readonly CS_CID
readonly CS_CLOUD
readonly CS_PROXY_HOST
readonly CS_PROXY_PORT
readonly CS_PROVISIONING_TOKEN
readonly TAGS

if [[ -z "$CS_CID" ]]; then
    echo >&2 "Error: CS_CID must be provided (positional argument or environment variable)."
    usage
fi

if ! [[ -f "$SENSOR_RPM" ]]; then
    echo >&2 "Pre-stage the RPM package to '$SENSOR_RPM' before running the script."
    exit 1
fi

echo "Installing the sensor..."
mount -o remount,rw /usr
if ! rpm --nodeps -Uvh "$SENSOR_RPM"; then
    mount -o remount,ro /usr || true
    echo >&2 "Error: RPM installation failed."
    exit 1
fi
mount -o remount,ro /usr || true

echo "Registering the sensor with given CID and tags..."
if [[ -n "$TAGS" ]]; then
    /opt/CrowdStrike/falconctl -s --tags="$TAGS"
fi
/opt/CrowdStrike/falconctl -s --cid="$CS_CID"
if [[ -n "$CS_CLOUD" ]]; then
    /opt/CrowdStrike/falconctl -s --cloud="$CS_CLOUD"
fi
if [[ -n "$CS_PROXY_HOST" ]]; then
    /opt/CrowdStrike/falconctl -s --aph="$CS_PROXY_HOST"
fi
if [[ -n "$CS_PROXY_PORT" ]]; then
    /opt/CrowdStrike/falconctl -s --app="$CS_PROXY_PORT"
fi
if [[ -n "$CS_PROVISIONING_TOKEN" ]]; then
    /opt/CrowdStrike/falconctl -s --provisioning-token="$CS_PROVISIONING_TOKEN"
fi

if ! [ -f /etc/systemd/system/falcon-sensor.service ]; then
    cp /usr/lib/systemd/system/falcon-sensor.service /etc/systemd/system/falcon-sensor.service
    systemctl enable falcon-sensor.service || true
    systemctl start falcon-sensor.service
fi

systemctl restart falcon-sensor || true
