#!/bin/bash

# migrate.sh - Convert an existing symlink-based CrowdStrike falcon sensor
#              deployment (install.sh v1.x) to the bind-mount design (v2.0).
#
# This script doesn't make changes to a running system to avoid risks to the
# running deployment.  The staged migration will occur (via systemd unit
# dependencies) on next boot (or if the falcon-sensor systemd unit is
# restarted).
#
# The script will also rewrite the BEGIN/END CrowdStrike falcon sensor block in
# /config/startup.
#
# ACTION REQUIRED: reboot the BIG-IP to complete the migration.
#
# v2.0 - Initial version.

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
CS_STASH="/shared/CrowdStrike-f5"
CS_OPT="/opt/CrowdStrike"

if ! [ -f "$CS_OPT/falconctl" ]; then
    echo >&2 "Error: CrowdStrike falcon sensor does not appear to be installed."
    exit 1
fi

if [ ! -d "$CS_STORE" ]; then
    echo >&2 "Error: data store $CS_STORE not found; this does not look like the"
    echo >&2 "       supported symlink-based deployment. Aborting."
    exit 1
fi

if mountpoint -q "$CS_OPT"; then
    echo "Nothing to do: $CS_OPT is already a bind mount. Already migrated."
    exit 0
fi

if [ ! -L "$CS_OPT" ]; then
    echo >&2 "Error: $CS_OPT is neither a symlink nor a bind mount. Unexpected"
    echo >&2 "       layout; not modifying. Investigate manually."
    exit 1
fi

echo "Staging Falcon Sensor install migration (no changes to the running sensor)..."

if [ ! -d "$CS_STASH" ]; then
    mkdir --mode=0750 "$CS_STASH"
fi

cat > "$CS_STASH/f5-crowdstrike-bindmount-prep.service" << 'UNIT'
# Prepares the /opt/CrowdStrike mountpoint before opt-CrowdStrike.mount binds
# /shared/CrowdStrike onto it.

[Unit]
Description=Prepare /opt/CrowdStrike bind mountpoint (convert legacy symlink)
DefaultDependencies=no
Before=opt-CrowdStrike.mount
RequiresMountsFor=/shared
ConditionPathExists=/shared/CrowdStrike

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if [ -L /opt/CrowdStrike ]; then rm -f /opt/CrowdStrike; fi; if ! [ -d /opt/CrowdStrike ]; then mkdir -m 0750 /opt/CrowdStrike; fi'

[Install]
WantedBy=sysinit.target multi-user.target
UNIT

cat > "$CS_STASH/f5-opt-CrowdStrike.mount" << 'UNIT'
# Bind-mounts the persistent sensor install (/shared/CrowdStrike) onto the
# real mountpoint /opt/CrowdStrike.

[Unit]
Description=Bind mount CrowdStrike data store onto /opt/CrowdStrike
DefaultDependencies=no
RequiresMountsFor=/shared
Requires=crowdstrike-bindmount-prep.service
After=crowdstrike-bindmount-prep.service

[Mount]
What=/shared/CrowdStrike
Where=/opt/CrowdStrike
Type=none
Options=bind

[Install]
WantedBy=sysinit.target multi-user.target
UNIT

cat > "$CS_STASH/f5-10-bindmount.conf" << 'UNIT'
# Declare dependency on opt-CrowdStrike.mount
[Unit]
Requires=opt-CrowdStrike.mount
After=opt-CrowdStrike.mount
UNIT

# Copy the first existing source file to the destination. Returns non-zero if
# none of the candidate sources exist.
stash_first() {
    local dest="$1"; shift
    local src
    for src in "$@"; do
        if [ -f "$src" ]; then
            cp "$src" "$dest"
            return 0
        fi
    done
    return 1
}

# Stash the sensor's systemd unit. Source candidates, in order of preference:
#   1. The v1 install's own stashed copy in the data store.
#   2. The RPM-provided unit in /usr/lib. Present in the initial boot location.
#   3. The /etc copy. Present in subsequent boot locations.
if [ ! -f "$CS_STASH/f5-falcon-sensor.service" ]; then
    if ! stash_first "$CS_STASH/f5-falcon-sensor.service" \
        "$CS_STORE/f5-falcon-sensor.service" \
        /usr/lib/systemd/system/falcon-sensor.service \
        /etc/systemd/system/falcon-sensor.service; then
        echo >&2 "Error: could not locate a falcon-sensor.service unit to stash."
        echo >&2 "       Looked in $CS_STORE, /usr/lib/systemd/system and /etc/systemd/system."
        exit 1
    fi
fi

# Stash the logrotate drop-in, same source ordering.
if [ ! -f "$CS_STASH/f5-logrotate-dropin" ]; then
    stash_first "$CS_STASH/f5-logrotate-dropin" \
        "$CS_STORE/f5-logrotate-dropin" \
        /etc/logrotate.d/falcon-sensor || \
        echo >&2 "Warning: no logrotate drop-in found to stash; continuing."
fi

echo "Installing and enabling systemd units..."

# Install the systemd units into this boot location and enable (but not start) them.
# The activation/migration will occur on next reboot.

install -m 0644 "$CS_STASH/f5-crowdstrike-bindmount-prep.service" /etc/systemd/system/crowdstrike-bindmount-prep.service
install -m 0644 "$CS_STASH/f5-opt-CrowdStrike.mount" /etc/systemd/system/opt-CrowdStrike.mount
install -d -m 0755 /etc/systemd/system/falcon-sensor.service.d
install -m 0644 "$CS_STASH/f5-10-bindmount.conf" /etc/systemd/system/falcon-sensor.service.d/10-bindmount.conf
systemctl daemon-reload
systemctl enable crowdstrike-bindmount-prep.service opt-CrowdStrike.mount

echo "Updating the block in /config/startup..."

# Update the block in /config/startup (delete block, append new block)

if [ -f /config/startup ]; then
    sed -i".falcon-migrate" '/^## BEGIN CrowdStrike falcon sensor/,/^## END CrowdStrike falcon sensor/d' /config/startup
fi
cat >> /config/startup << "EOF"

## BEGIN CrowdStrike falcon sensor
if [ -d /shared/CrowdStrike ]; then
    if ! [ -d /shared/CrowdStrike-f5 ]; then
        logger -p local0.crit -t falcon-on-bigip "CrowdStrike: persistent install location present, but /shared/CrowdStrike-f5 is missing; cannot restore sensor in this boot location"
    else
        # Re-register the CrowdStrike falcon sensor on first boot into a new boot location.
        if [ -L /opt/CrowdStrike ]; then
            rm -f /opt/CrowdStrike
        fi
        if ! [ -d /opt/CrowdStrike ]; then
            mkdir -m 0750 /opt/CrowdStrike
        fi
        if ! mountpoint -q /opt/CrowdStrike; then
            mount --bind /shared/CrowdStrike /opt/CrowdStrike
        fi

        # Restore systemd units for subsequent normal reboots in this boot location.
        units_changed=0
        service_installed=0
        if ! [ -f /etc/systemd/system/crowdstrike-bindmount-prep.service ]; then
            cp /shared/CrowdStrike-f5/f5-crowdstrike-bindmount-prep.service /etc/systemd/system/crowdstrike-bindmount-prep.service
            units_changed=1
        fi
        if ! [ -f /etc/systemd/system/opt-CrowdStrike.mount ]; then
            cp /shared/CrowdStrike-f5/f5-opt-CrowdStrike.mount /etc/systemd/system/opt-CrowdStrike.mount
            units_changed=1
        fi
        if ! [ -f /etc/systemd/system/falcon-sensor.service.d/10-bindmount.conf ]; then
            mkdir -p /etc/systemd/system/falcon-sensor.service.d
            cp /shared/CrowdStrike-f5/f5-10-bindmount.conf /etc/systemd/system/falcon-sensor.service.d/10-bindmount.conf
            units_changed=1
        fi

        if ! [ -f /etc/systemd/system/falcon-sensor.service ]; then
            cp /shared/CrowdStrike-f5/f5-falcon-sensor.service /etc/systemd/system/falcon-sensor.service
            units_changed=1
            service_installed=1
        fi
        if [ "$units_changed" = 1 ]; then
            systemctl daemon-reload
            systemctl enable crowdstrike-bindmount-prep.service opt-CrowdStrike.mount
        fi
        if [ "$service_installed" = 1 ]; then
            systemctl enable falcon-sensor.service
            systemctl start falcon-sensor.service
        fi

        if ! [ -f /etc/logrotate.d/falcon-sensor ]; then
            cp /shared/CrowdStrike-f5/f5-logrotate-dropin /etc/logrotate.d/falcon-sensor
        fi
    fi
fi
## END CrowdStrike falcon sensor

EOF

cat <<EOF

Migration staged successfully. The running sensor and the existing
/opt/CrowdStrike symlink were left untouched.

>>> REBOOT REQUIRED <<<
The conversion occurs during the next boot, when the sensor is not yet running.
EOF
