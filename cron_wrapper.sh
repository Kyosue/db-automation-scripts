#!/bin/bash

# Cron Wrapper for PostgreSQL Backup Script
# This ensures proper environment setup for cron execution

# Set environment variables
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/home/raabelgas
export USER=raabelgas
export LOGNAME=raabelgas

# Source system profile
if [ -f /etc/profile ]; then
    . /etc/profile
fi

# Source user profile
if [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

# Change to script directory
cd "$HOME/Laboratory Exercises/Lab8" || exit 1

# Execute the backup script
/bin/bash "./run_pg_backups.sh"

# Capture exit status
EXIT_STATUS=$?

# Log completion
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cron wrapper completed with exit status: ${EXIT_STATUS}" >> /var/log/pg_backup_cron.log

exit ${EXIT_STATUS}
