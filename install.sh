#!/bin/bash

# v1.0 - 2026-02-11 CrowdStrike GA release
# v1.1 - Added root filesystem free space check before installation

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
SENSOR_RPM="${SENSOR_RPM:-}"
TAGS="${TAGS:-}"

DEFAULT_SENSOR_RPM="/shared/images/falcon-sensor.rpm"
# v1.1 - Minimum free space required on "/" in MB (override via environment variable or --min-space)
MIN_ROOT_SPACE_MB="${MIN_ROOT_SPACE_MB:-500}"

# v1.1 - Check free space on "/" before installing
check_root_free_space() {
    local free_mb
    free_mb=$(df -BM --output=avail / | tail -1 | tr -d '[:space:]M')

    if [[ "$free_mb" -lt "$MIN_ROOT_SPACE_MB" ]]; then
        echo >&2 "Error: Not enough free space on /. Available: ${free_mb}MB, Required: ${MIN_ROOT_SPACE_MB}MB."
        exit 1
    fi

    echo "Free space check passed: ${free_mb}MB available on / (minimum: ${MIN_ROOT_SPACE_MB}MB)."
}


usage()  {
    {
        echo "Usage: $0 [CS_CID] [-r|--rpm SENSOR_RPM] [-t|--tag TAGS] [-t|--tag ...] [-c|--cloud CLOUD] [--aph APH] [--app APP] [--min-space MB]"
        echo
        echo "Arguments/Options:"
        echo "  CS_CID       CrowdStrike Customer ID (or use CS_CID environment variable)"
        echo "  -r, --rpm    Falcon Sensor RPM path (or SENSOR_RPM environment variable)"
        echo "                     Default: $DEFAULT_SENSOR_RPM"
        echo "  -t, --tag    Comma-separated sensor group tags (or TAGS environment variable)"
        echo "                    If used multiple times, a comma will be added between each"
        echo "                    Default: empty (leave the sensor untagged/ungrouped)"
        echo "  -c, --cloud  Specify particular CrowdStrike cloud (or CS_CLOUD environment variable)."
        echo "                      One of us-1, us-2, eu-1, us-gov-1, us-gov-2"
        echo "                      Default: empty (sensor will automatically discover the correct value)."
        echo "        --aph   Specify HTTP proxy host (or CS_PROXY_HOST environment variable)."
        echo "                     Default: empty (directly connect to CrowdStrike cloud)."
        echo "        --app   Specify HTTP proxy port (or CS_PROXY_PORT environment variable)."
        echo "                     Default: empty (directly connect to CrowdStrike cloud)."
		echo " --min-space Minimum free space required on / in MB (or MIN_ROOT_SPACE_MB environment variable)"
		echo " Default: 500"
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
            SENSOR_RPM="$2"
            shift 2
            ;;
        -t|--tag|--tags)
            if [ -n "$TAGS" ]; then
                TAGS="$TAGS,$2"
            else
                TAGS="$2"
            fi
            shift 2
            ;;
        -c|--cloud)
            CS_CLOUD="$2"
            shift 2
            ;;
        --aph)
            CS_PROXY_HOST="$2"
            shift 2
            ;;
        --app)
            CS_PROXY_PORT="$2"
            shift 2
            ;;
        --min-space)
            MIN_ROOT_SPACE_MB="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" 2>&2
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
readonly TAGS
readonly MIN_ROOT_SPACE_MB

if [[ -z "$CS_CID" ]]; then
    echo >&2 "Error: CS_CID must be provided (positional argument or environment variable)."
    usage
fi

if ! [[ -f "$SENSOR_RPM" ]]; then
    echo >&2 "Pre-stage the RPM package to '$SENSOR_RPM' before running the script."
    exit 1
fi

# v1.1 - Verify sufficient free space on "/" before proceeding
check_root_free_space

echo "Installing the sensor..."
mount -o remount,rw /usr
rpm --nodeps -Uvh "$SENSOR_RPM"
mount -o remount,ro /usr || true

echo "Rearranging files into /shared/CrowdStrike..."
mv /opt/CrowdStrike /shared/CrowdStrike
ln -sfT /shared/CrowdStrike /opt/CrowdStrike

cp /usr/lib/systemd/system/falcon-sensor.service /shared/CrowdStrike/f5-falcon-sensor.service
cp /etc/logrotate.d/falcon-sensor /shared/CrowdStrike/f5-logrotate-dropin
cp "$SENSOR_RPM" /shared/CrowdStrike/

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

echo "Adding configuration snippet to /config/startup..."
cat >> /config/startup << "EOF"

## BEGIN CrowdStrike falcon sensor
# Re-register the CrowdStrike falcon sensor on first boot into a new boot location
if ! [ -e /opt/CrowdStrike ]; then
    ln -sfT /shared/CrowdStrike /opt/CrowdStrike
fi

if ! [ -f /etc/systemd/system/falcon-sensor.service ]; then
    cp /shared/CrowdStrike/f5-falcon-sensor.service /etc/systemd/system/falcon-sensor.service
    systemctl enable falcon-sensor.service
    systemctl start falcon-sensor.service
fi

if ! [ -f /etc/logrotate.d/falcon-sensor ]; then
    cp /shared/CrowdStrike/f5-logrotate-dropin /etc/logrotate.d/falcon-sensor
fi
## END CrowdStrike falcon sensor

EOF

systemctl restart falcon-sensor || true
