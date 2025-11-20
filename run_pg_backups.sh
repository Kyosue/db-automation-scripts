#!/bin/bash
################################################################################
# PostgreSQL Automated Backup System with Cloud Integration
# Purpose: Automated daily backups with Google Drive upload and email alerts
# Author: Database Administration Team
# Version: 1.0
################################################################################

set -e          # Exit immediately if a command exits with a non-zero status
set -o pipefail # Pipeline fails if any command in the pipeline fails

################################################################################
# ENVIRONMENT SETUP FOR CRON
################################################################################

# Set proper PATH for cron environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin

# Set HOME if not set (cron might not set it)
export HOME=${HOME:-/home/raabelgas}

# Ensure we're in the script directory
cd "$(dirname "$0")" || exit 1

# Source profile if it exists (for any custom environment variables)
if [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

################################################################################
# CONFIGURATION SECTION - Modify these variables as needed
################################################################################

# Directories
HOSTNAME=$(hostname)
SCRIPT_USER="${USER:-raabelgas}"
BACKUP_BASE_DIR="/home/${SCRIPT_USER}/Laboratory Exercises/Lab8"
BACKUP_DIR="${BACKUP_BASE_DIR}/backups"
LOG_FILE="/var/log/pg_backup.log"

# Database Configuration
DB_NAME="production_db"
DB_USER="postgres"
DB_HOST="localhost"
DB_PORT="5432"

# Backup File Naming
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
LOGICAL_BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump"
PHYSICAL_BACKUP_FILE="${BACKUP_DIR}/pg_base_backup_${TIMESTAMP}.tar.gz"

# Email Configuration
EMAIL_RECIPIENT="reymundangelo@gmail.com"
EMAIL_FROM="postgres-backup@$(hostname)"

# Cloud Storage Configuration
RCLONE_REMOTE="gdrive_backups:"
RCLONE_DEST_PATH="postgresql_backups"

# Retention Policy
RETENTION_DAYS=7

# Status Tracking
BACKUP_FAILED=0
FAILED_TASK=""

################################################################################
# FUNCTION: log_message
# Purpose: Logs timestamped messages to both console and log file
# Arguments: $1 - Message to log
################################################################################
log_message() {
    local MESSAGE="$1"
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${TIMESTAMP}] ${MESSAGE}" | tee -a "${LOG_FILE}"
}

################################################################################
# FUNCTION: send_email
# Purpose: Sends email notifications
# Arguments: $1 - Subject, $2 - Body
################################################################################
send_email() {
    local SUBJECT="$1"
    local BODY="$2"
    
    # Create a temporary file for the email body
    local TEMP_EMAIL="/tmp/backup_email_$$.txt"
    
    # Write email in proper format
    cat > "${TEMP_EMAIL}" << EOF_EMAIL
To: ${EMAIL_RECIPIENT}
From: ${EMAIL_FROM}
Subject: ${SUBJECT}

${BODY}
EOF_EMAIL
    
    # Send using sendmail with explicit path (more reliable in cron)
    if /usr/sbin/sendmail -t < "${TEMP_EMAIL}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_message "Email notification sent successfully: ${SUBJECT}"
        rm -f "${TEMP_EMAIL}"
        return 0
    else
        log_message "WARNING: Failed to send email via sendmail"
        
        # Try alternative method with mail command and full headers
        if echo "${BODY}" | /usr/bin/mail -s "${SUBJECT}" -a "From: ${EMAIL_FROM}" "${EMAIL_RECIPIENT}" 2>&1 | tee -a "${LOG_FILE}"; then
            log_message "Email sent successfully via mail command"
            rm -f "${TEMP_EMAIL}"
            return 0
        else
            log_message "ERROR: Both sendmail and mail failed"
            
            # Create notification file as backup
            local NOTIFICATION_FILE="${BACKUP_DIR}/email_notification_$(date +%Y%m%d_%H%M%S).txt"
            mv "${TEMP_EMAIL}" "${NOTIFICATION_FILE}"
            log_message "Email content saved to: ${NOTIFICATION_FILE}"
            return 1
        fi
    fi
}

################################################################################
# FUNCTION: cleanup_old_backups
# Purpose: Removes local backup files older than retention period
################################################################################
cleanup_old_backups() {
    log_message "Starting cleanup of backups older than ${RETENTION_DAYS} days..."
    
    local FILES_DELETED=$(find "${BACKUP_DIR}" -type f \( -name "*.dump" -o -name "*.tar.gz" \) -mtime +${RETENTION_DAYS} -print -delete 2>&1 | tee -a "${LOG_FILE}" | wc -l)
    
    if [ $? -eq 0 ]; then
        log_message "Cleanup completed. Removed ${FILES_DELETED} old backup file(s)."
    else
        log_message "WARNING: Cleanup encountered errors. Check log for details."
    fi
}

################################################################################
# FUNCTION: perform_logical_backup
# Purpose: Creates a full logical backup using pg_dump
# Returns: 0 on success, 1 on failure
################################################################################
perform_logical_backup() {
    log_message "===== Starting Logical Backup (pg_dump) ====="
    log_message "Database: ${DB_NAME}"
    log_message "Output file: ${LOGICAL_BACKUP_FILE}"
    
    if pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -Fc -f "${LOGICAL_BACKUP_FILE}" "${DB_NAME}" 2>&1 | tee -a "${LOG_FILE}"; then
        local FILE_SIZE=$(du -h "${LOGICAL_BACKUP_FILE}" | cut -f1)
        log_message "SUCCESS: Logical backup completed successfully"
        log_message "Backup file size: ${FILE_SIZE}"
        return 0
    else
        log_message "ERROR: Logical backup failed"
        return 1
    fi
}

################################################################################
# FUNCTION: perform_physical_backup
# Purpose: Creates a full physical base backup using pg_basebackup
# Returns: 0 on success, 1 on failure
################################################################################
perform_physical_backup() {
    log_message "===== Starting Physical Base Backup (pg_basebackup) ====="
    log_message "Output file: ${PHYSICAL_BACKUP_FILE}"

    if pg_basebackup \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -F t \
        -X none \
        -D - 2>> "${LOG_FILE}" \
        | gzip > "${PHYSICAL_BACKUP_FILE}"; then

        local FILE_SIZE=$(du -h "${PHYSICAL_BACKUP_FILE}" | cut -f1)
        log_message "SUCCESS: Physical backup completed successfully"
        log_message "Backup file size: ${FILE_SIZE}"
        return 0
    else
        log_message "ERROR: Physical backup failed"
        rm -f "${PHYSICAL_BACKUP_FILE}"
        return 1
    fi
}
################################################################################
# FUNCTION: upload_to_cloud
# Purpose: Uploads backup files to Google Drive using rclone
# Returns: 0 on success, 1 on failure
################################################################################
upload_to_cloud() {
    log_message "===== Starting Cloud Upload to Google Drive ====="
    log_message "Remote: ${RCLONE_REMOTE}${RCLONE_DEST_PATH}"
    
    local UPLOAD_SUCCESS=0
    
    # Upload logical backup
    log_message "Uploading logical backup: $(basename ${LOGICAL_BACKUP_FILE})"
    if rclone copy "${LOGICAL_BACKUP_FILE}" "${RCLONE_REMOTE}${RCLONE_DEST_PATH}/" -P 2>&1 | tee -a "${LOG_FILE}"; then
        log_message "SUCCESS: Logical backup uploaded to Google Drive"
    else
        log_message "ERROR: Failed to upload logical backup"
        UPLOAD_SUCCESS=1
    fi
    
    # Upload physical backup
    log_message "Uploading physical backup: $(basename ${PHYSICAL_BACKUP_FILE})"
    if rclone copy "${PHYSICAL_BACKUP_FILE}" "${RCLONE_REMOTE}${RCLONE_DEST_PATH}/" -P 2>&1 | tee -a "${LOG_FILE}"; then
        log_message "SUCCESS: Physical backup uploaded to Google Drive"
    else
        log_message "ERROR: Failed to upload physical backup"
        UPLOAD_SUCCESS=1
    fi
    
    # Upload WAL backup if it exists
    local WAL_FILE="${BACKUP_DIR}/pg_wal_backup_${TIMESTAMP}.tar.gz"
    if [ -f "${WAL_FILE}" ]; then
        log_message "Uploading WAL backup: $(basename ${WAL_FILE})"
        if rclone copy "${WAL_FILE}" "${RCLONE_REMOTE}${RCLONE_DEST_PATH}/" -P 2>&1 | tee -a "${LOG_FILE}"; then
            log_message "SUCCESS: WAL backup uploaded to Google Drive"
        else
            log_message "ERROR: Failed to upload WAL backup"
            UPLOAD_SUCCESS=1
        fi
    fi
    
    return ${UPLOAD_SUCCESS}
}

################################################################################
# MAIN EXECUTION
################################################################################

# Script start
log_message "=========================================="
log_message "PostgreSQL Backup Script Started"
log_message "=========================================="
log_message "Hostname: ${HOSTNAME}"
log_message "Database: ${DB_NAME}"
log_message "Backup Directory: ${BACKUP_DIR}"

# Create backup directory if it doesn't exist
if [ ! -d "${BACKUP_DIR}" ]; then
    mkdir -p "${BACKUP_DIR}"
    log_message "Created backup directory: ${BACKUP_DIR}"
fi

# Verify PostgreSQL is running
if ! pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" > /dev/null 2>&1; then
    log_message "CRITICAL ERROR: PostgreSQL server is not running or not accessible"
    BACKUP_FAILED=1
    FAILED_TASK="PostgreSQL server connectivity check"
    
    # Send failure email
    FAILURE_EMAIL_BODY="CRITICAL: PostgreSQL server is not running or not accessible.
    
Host: ${DB_HOST}:${DB_PORT}
Time: $(date)

Please check the PostgreSQL service immediately.

Last 15 lines from log:
$(tail -n 15 "${LOG_FILE}")"
    
    send_email "FAILURE: PostgreSQL Backup Task" "${FAILURE_EMAIL_BODY}"
    exit 1
fi

log_message "PostgreSQL server is accessible and ready"

################################################################################
# TASK 1: Logical Backup (pg_dump)
################################################################################
if ! perform_logical_backup; then
    BACKUP_FAILED=1
    FAILED_TASK="Logical Backup (pg_dump)"
fi

################################################################################
# TASK 2: Physical Base Backup (pg_basebackup)
################################################################################
if [ ${BACKUP_FAILED} -eq 0 ]; then
    if ! perform_physical_backup; then
        BACKUP_FAILED=1
        FAILED_TASK="Physical Base Backup (pg_basebackup)"
    fi
fi

################################################################################
# ERROR HANDLING AND NOTIFICATION
################################################################################
if [ ${BACKUP_FAILED} -eq 1 ]; then
    log_message "===== BACKUP FAILED ====="
    log_message "Failed Task: ${FAILED_TASK}"
    
    # Prepare failure email
    FAILURE_EMAIL_BODY="FAILURE: PostgreSQL Backup Task

The backup process encountered an error.

Failed Backup Type:
${FAILED_TASK}

Database: ${DB_NAME}
Server: ${HOSTNAME}
Timestamp: $(date)

Summary:
The ${FAILED_TASK} did NOT complete successfully.  
No upload to Google Drive was attempted.

Error Context (Last 15 log lines):
$(tail -n 15 "${LOG_FILE}")

Next Steps:
- Review the detailed error log: ${LOG_FILE}
- Check PostgreSQL server status and user permissions
- Confirm available disk space
- Re-run the backup manually after resolving the issue
"
    
    send_email "FAILURE: PostgreSQL Backup Task" "${FAILURE_EMAIL_BODY}"
    
    log_message "Failure notification sent. Exiting without upload."
    log_message "=========================================="
    exit 1
fi

################################################################################
# CLOUD UPLOAD (Only if backups succeeded)
################################################################################
log_message "All backups completed successfully. Proceeding to cloud upload..."

if ! upload_to_cloud; then
    log_message "===== UPLOAD FAILED ====="
    
    # Prepare upload failure email
    UPLOAD_FAILURE_EMAIL_BODY="FAILURE: PostgreSQL Backup Upload

Backups were created locally but failed to upload to Google Drive.

Database: ${DB_NAME}
Server: ${HOSTNAME}
Timestamp: $(date)

Local Backup Files:
- $(basename ${LOGICAL_BACKUP_FILE})
- $(basename ${PHYSICAL_BACKUP_FILE})

Error:
Backups were created successfully but Google Drive upload using rclone failed.
Check rclone logs and cloud storage configuration.

Error Context (Last 15 log lines):
$(tail -n 15 "${LOG_FILE}")
"
    
    send_email "FAILURE: PostgreSQL Backup Upload" "${UPLOAD_FAILURE_EMAIL_BODY}"
    
    log_message "Upload failure notification sent."
    log_message "=========================================="
    exit 1
fi

################################################################################
# SUCCESS NOTIFICATION
################################################################################
log_message "===== ALL TASKS COMPLETED SUCCESSFULLY ====="

LOGICAL_BASENAME=$(basename "${LOGICAL_BACKUP_FILE}")
PHYSICAL_BASENAME=$(basename "${PHYSICAL_BACKUP_FILE}")

SUCCESS_EMAIL_BODY="SUCCESS: PostgreSQL Backup and Upload

The backup and cloud upload completed successfully.

Database: ${DB_NAME}
Server: ${HOSTNAME}
Timestamp: $(date)

Uploaded Files:
- ${LOGICAL_BASENAME}
- ${PHYSICAL_BASENAME}

Status:
✓ Logical backup created
✓ Physical base backup created
✓ Files uploaded to Google Drive (rclone)

Cloud Destination:
${RCLONE_REMOTE}${RCLONE_DEST_PATH}/

Backup retention policy:
Local backups older than ${RETENTION_DAYS} days will be removed automatically.

No issues were encountered.
"

send_email "SUCCESS: PostgreSQL Backup and Upload" "${SUCCESS_EMAIL_BODY}"

################################################################################
# LOCAL CLEANUP
################################################################################
cleanup_old_backups

################################################################################
# SCRIPT COMPLETION
################################################################################
log_message "PostgreSQL Backup Script Completed Successfully"
log_message "=========================================="

exit 0