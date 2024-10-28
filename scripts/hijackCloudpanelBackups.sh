#!/bin/bash

# Extract timing from clp-rclone cron file - simplified to just take the exact timing
TIMING=$(grep -E "^#?[[:space:]]*[0-9*/-].*remote-backup:create" /etc/cron.d/clp-rclone | head -n1 | sed -E 's/^#?[[:space:]]*([0-9*/-]+ [0-9*/-]+ [0-9*/-]+ [0-9*/-]+ [0-9*/-]+).*/\1/')

# Check for remote-backup:create line in clp-rclone and add comment if not already commented
if grep -q "^#\{0,1\}[[:space:]]*.*remote-backup:create" /etc/cron.d/clp-rclone; then
    sed -i '/^[[:space:]]*[^#].*remote-backup:create/s/^/#/' /etc/cron.d/clp-rclone
    service cron restart
fi

# If no timing found, use default
if [ -z "$TIMING" ]; then
    TIMING="0 2 * * *"
fi

# Construct the new cron line - combined into single root command
NEW_CRON_LINES="${TIMING} root /scripts/backupCronjobs.sh && sudo -u clp /usr/bin/bash -c '/usr/bin/clpctl db:backup --ignoreDatabases=\"db1,db2\" --retentionPeriod=7 && /usr/bin/clpctl remote-backup:create --delay=true' &> /dev/null"

# Check if custom-backup exists and compare content
NEEDS_UPDATE=1
if [ -f "/etc/cron.d/custom-backup" ]; then
    CURRENT_CONTENT=$(cat /etc/cron.d/custom-backup)
    if [ "$CURRENT_CONTENT" == "$NEW_CRON_LINES" ]; then
        NEEDS_UPDATE=0
    fi
fi

# Update cron file if needed
if [ $NEEDS_UPDATE -eq 1 ]; then
    echo "$NEW_CRON_LINES" > /etc/cron.d/custom-backup
    service cron restart
fi
