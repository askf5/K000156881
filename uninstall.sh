#!/bin/bash

# v2.0 - Bind-mount design. Also able to uninstall a v1 (symlink-based) install.

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

CS_STORE="/shared/CrowdStrike"
# F5 helper/stash directory used by v2.x installs. Absent on a v1 install.
CS_STASH="/shared/CrowdStrike-f5"
CS_OPT="/opt/CrowdStrike"

remove_systemd_units() {
    systemctl --no-reload disable opt-CrowdStrike.mount > /dev/null 2>&1 || :
    systemctl --no-reload disable crowdstrike-bindmount-prep.service > /dev/null 2>&1 || :
    rm -f /etc/systemd/system/opt-CrowdStrike.mount
    rm -f /etc/systemd/system/crowdstrike-bindmount-prep.service
    rm -f /etc/systemd/system/falcon-sensor.service.d/10-bindmount.conf
    rmdir /etc/systemd/system/falcon-sensor.service.d > /dev/null 2>&1 || :
    systemctl daemon-reload > /dev/null 2>&1 || :
}

unmount_store() {
    # Clean up /opt/CrowdStrike if it's a bind mount or symlink after the RPM
    # is uninstalled.
    if mountpoint -q "$CS_OPT"; then
        umount "$CS_OPT" || :
    fi
    if [ -L "$CS_OPT" ]; then
        rm -f "$CS_OPT"
    fi
    # Remove the now-empty real mountpoint directory.
    if [ -d "$CS_OPT" ] && ! mountpoint -q "$CS_OPT"; then
        rmdir "$CS_OPT" > /dev/null 2>&1 || :
    fi
}

uninstall_sensor() {
    # An RPM package is present if the sensor was installed in this boot location.
    # If the BIG-IP admin then installs software to a new boot location, the sensor
    # is wired in by functionality in /config/startup, but the RPM is not re-installed.
    if rpm --quiet -q falcon-sensor; then
        mount -o remount,rw /usr
        # The RPM uninstall will try to remove /opt/CrowdStrike (and has 'rm -rf
        # /opt/CrowdStrike > /dev/null 2>&1 || :' in the postuninstall); those won't
        # fully work if that is a mountpoint), but that is cleaned up in unmount_store.
        if ! rpm -e falcon-sensor; then
            mount -o remount,ro /usr || :
            echo >&2 "Error: RPM uninstallation failed."
            exit 1
        fi
        mount -o remount,ro /usr || :
    else
        systemctl --no-reload disable falcon-sensor.service > /dev/null 2>&1 || :
        systemctl stop falcon-sensor.service > /dev/null 2>&1 || :
        rm -f /etc/systemd/system/falcon-sensor.service /etc/logrotate.d/falcon-sensor
    fi

    remove_systemd_units
    unmount_store

    rm -rf "$CS_STORE"
    rm -rf "$CS_STASH"
    if [ -f /config/startup ]; then
        sed -i".falcon-uninstall" '/^## BEGIN CrowdStrike falcon sensor/,/^## END CrowdStrike falcon sensor/d' /config/startup
    fi
}

protection_armed() {
    local status
    status=$("$CS_OPT/falconctl" -g --protection-status 2>/dev/null || :)
    echo "$status" | grep -qi "Armed=True"
}

if ! [ -f "$CS_OPT/falconctl" ]; then
    echo >&2 "Error: CrowdStrike falcon sensor not installed."
    exit 1
fi

if protection_armed; then
    cat >&2 <<EOF
ERROR: Unable to proceed with uninstalling sensor.  Please get a maintenance token
from your Falcon administrator, and then set with
/opt/CrowdStrike/falconctl -s --maintenance-token=<maintenance_token>

EOF

    exit 1
fi

uninstall_sensor
echo "All done."
