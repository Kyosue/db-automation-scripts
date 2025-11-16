#!/bin/bash
set -e
set -o pipefail

# ===============================
# Configuration Variables
# ===============================
BACKUP_DIR="/home/$USER/Laboratory Exercises/Lab8"
LOG_FILE="/var/log/pg_backup.log"
DB_NAME="production_db"
DB_USER="backup_user"
EMAIL="dba-alerts@yourcompany.com"
REMOTE_NAME="gdrive_backups"
RETENTION_DAYS=7

# Get timestamp
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")

# Filenames
LOGICAL_BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump"
PHYSICAL_BACKUP_FILE="$BACKUP_DIR/pg_base_backup_${TIMESTAMP}.tar.gz"

# Status flag
BACKUP_FAILED=0

# ===============================
# Logging Function
# ===============================
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ===============================
# Start Backup Process
# ===============================
log_message "Starting PostgreSQL backup process..."

# -------------------------------
# Task 1: Logical Backup
# -------------------------------
log_message "Starting logical backup..."
if pg_dump -U "$DB_USER" -Fc "$DB_NAME" -f "$LOGICAL_BACKUP_FILE" >> "$LOG_FILE" 2>&1; then
    log_message "Logical backup completed successfully: $LOGICAL_BACKUP_FILE"
else
    log_message "Logical backup FAILED!"
    BACKUP_FAILED=1
fi

# -------------------------------
# Task 2: Physical Backup
# -------------------------------
log_message "Starting physical base backup..."
if pg_basebackup -U "$DB_USER" -D - -Ft -z -Z 9 | tee "$PHYSICAL_BACKUP_FILE" >> "$LOG_FILE" 2>&1; then
    log_message "Physical backup completed successfully: $PHYSICAL_BACKUP_FILE"
else
    log_message "Physical backup FAILED!"
    BACKUP_FAILED=1
fi

# -------------------------------
# Error Handling & Notification
# -------------------------------
if [ "$BACKUP_FAILED" -eq 1 ]; then
    log_message "Backup FAILED, sending alert email..."
    tail -n 15 "$LOG_FILE" | mail -s "FAILURE: PostgreSQL Backup Task" "$EMAIL"
    exit 1
fi

# -------------------------------
# Upload to Google Drive
# -------------------------------
log_message "Uploading backups to Google Drive..."
if rclone copy "$LOGICAL_BACKUP_FILE" "$REMOTE_NAME:" >> "$LOG_FILE" 2>&1 && \
   rclone copy "$PHYSICAL_BACKUP_FILE" "$REMOTE_NAME:" >> "$LOG_FILE" 2>&1; then
    log_message "Upload successful, sending success email..."
    echo "Successfully created and uploaded: $LOGICAL_BACKUP_FILE and $PHYSICAL_BACKUP_FILE" \
        | mail -s "SUCCESS: PostgreSQL Backup and Upload" "$EMAIL"
else
    log_message "Upload FAILED, sending alert email..."
    echo "Backups were created locally but failed to upload to Google Drive. Check rclone logs." \
        | mail -s "FAILURE: PostgreSQL Backup Upload" "$EMAIL"
    exit 1
fi

# -------------------------------
# Cleanup old backups
# -------------------------------
log_message "Cleaning up local backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -name "*.dump" -or -name "*.tar.gz" -exec rm -f {} \;

log_message "Backup process completed successfully."
