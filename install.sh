#!/bin/bash

# v1.0 - works on an appliance
# v1.1 - expects files to be copied to /shared/images, not /var/tmp (so that
#        they're synced between blades in a VIPRION or bladed guest or bladed
#        tenant)
# v1.25 - updated to accept RPM, CID and TAGS environment or arguments
# v1.26 - add begin/end markers to snippet added to /config/startup (to
#         facilitate uninstall)

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
SENSOR_RPM="${SENSOR_RPM:-}"
TAGS="${TAGS:-}"

DEFAULT_SENSOR_RPM="/shared/images/falcon-sensor.rpm"

usage() {
    {
        echo "Usage: $0 [CS_CID] [-r|--rpm SENSOR_RPM] [-t|--tag TAGS] [-t|--tag ...]"
        echo
        echo "Arguments/Options:"
        echo "  CS_CID       CrowdStrike Customer ID (or use CS_CID environment variable)"
        echo "  -r, --rpm    Falcon Sensor RPM path (or SENSOR_RPM environment variable)"
        echo "               Default: $DEFAULT_SENSOR_RPM"
        echo "  -t, --tag    Comma-separated sensor group tags (or TAGS environment variable)"
        echo "               If used multiple times, a comma will be added between each"
        echo "               Default: empty (leave the sensor untagged/ungrouped)"
        echo "  -h, --help   Show this help message"
        echo
        echo "If no arguments are passed, environment variables are used."
    } >&2
    exit 1
}

# Fail early if falcon-sensor is already installed.
if [[ -f /opt/CrowdStrike/falconctl ]]; then
    echo >&2 "Error: CrowdStrike sensor is already installed."
    exit 1
fi

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
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" 2>&2
            usage
            ;;
    esac
done

# Default sensor RPM if not given
if [[ -z "$SENSOR_RPM" ]]; then
    SENSOR_RPM="$DEFAULT_SENSOR_RPM"
fi

readonly SENSOR_RPM
readonly CS_CID
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
rpm --force --oldpackage --nodeps -Uvh "$SENSOR_RPM"
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

echo "Adding configuration snippet to /config/startup..."
cat >> /config/startup << "EOF"

## BEGIN CrowdStrike falcon sensor
# Re-register the CrowdStrike falcon sensor on first boot into a new boot location
if ! [ -e /opt/CrowdStrike ]; then
    ln -sfT /shared/CrowdStrike /opt/CrowdStrike
fi

if ! [ -f /etc/systemd/system/falcon-sensor.service ]; then
    # TODO: Restore selinux context? (doesn't currently seem necessary)
    cp /shared/CrowdStrike/f5-falcon-sensor.service /etc/systemd/system/falcon-sensor.service
    systemctl enable falcon-sensor.service
    systemctl start falcon-sensor.service
fi

if ! [ -f /etc/logrotate.d/falcon-sensor ]; then
    # TODO: restore selinux context? (doesn't currently seem necessary)
    cp /shared/CrowdStrike/f5-logrotate-dropin /etc/logrotate.d/falcon-sensor
fi
## END CrowdStrike falcon sensor

EOF

systemctl restart falcon-sensor || true
