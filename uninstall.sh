#!/bin/bash

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

uninstall_sensor() {
    # An RPM package is present if the sensor was installed in this boot location.
    # If the BIG-IP admin then installs software to a new boot location, the sensor
    # is wired in by functionality in /config/startup, but the RPM is not re-installed.
    if rpm --quiet -q falcon-sensor; then
        mount -o remount,rw /usr
        rpm -e falcon-sensor
        mount -o remount,ro /usr || :
    else
        systemctl --no-reload disable falcon-sensor.service > /dev/null 2>&1 || :
        systemctl stop falcon-sensor.service > /dev/null 2>&1 || :

        if [ -L /opt/CrowdStrike ]; then
            rm -f /opt/CrowdStrike
        fi
        rm -f /etc/systemd/system/falcon-sensor.service /etc/logrotate.d/falcon-sensor
    fi

    rm -rf /shared/CrowdStrike
    sed -i".falcon-uninstall" '/^## BEGIN CrowdStrike falcon sensor/,/^## END CrowdStrike falcon sensor/d' /config/startup
}

protection_armed() {
    local status
    status=$(/opt/CrowdStrike/falconctl -g --protection-status 2>/dev/null || :)
    echo "$status" | grep -qi "Armed=True"
}

if ! [ -f /opt/CrowdStrike/falconctl ]; then
    echo >&2 "Error: CrowdStrike falcon sensor not installed."
    exit 1
fi

if protection_armed; then
    cat >&2 <<-EOF
	ERROR: Unable to proceed with uninstalling sensor.  Please get a maintenance token
	from your Falcon administrator, and then set with
	/opt/CrowdStrike/falconctl -s --maintenance-token=<maintenance_token>

	EOF

    exit 1
fi

uninstall_sensor
echo "All done."
