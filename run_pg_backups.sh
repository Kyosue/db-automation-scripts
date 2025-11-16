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
# CONFIGURATION SECTION - Modify these variables as needed
################################################################################

# Directories
HOSTNAME=$(hostname)
BACKUP_BASE_DIR="/home/$USER/Laboratory Exercises/Lab8"
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
    
    echo "${BODY}" | mail -s "${SUBJECT}" -r "${EMAIL_FROM}" "${EMAIL_RECIPIENT}" 2>&1 | tee -a "${LOG_FILE}"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_message "Email notification sent successfully: ${SUBJECT}"
    else
        log_message "WARNING: Failed to send email notification"
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
    
    # Create a temporary directory for the base backup
    local TEMP_BACKUP_DIR="${BACKUP_DIR}/pg_base_backup_temp_${TIMESTAMP}"
    
    # Perform base backup to directory, then tar and compress it
    if pg_basebackup -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -D "${TEMP_BACKUP_DIR}" -Ft -z -Z 9 -P 2>&1 | tee -a "${LOG_FILE}"; then
        # Move the backup files to final location
        # pg_basebackup with -Ft creates base.tar.gz and pg_wal.tar.gz
        if [ -f "${TEMP_BACKUP_DIR}/base.tar.gz" ]; then
            mv "${TEMP_BACKUP_DIR}/base.tar.gz" "${PHYSICAL_BACKUP_FILE}"
            
            # Also handle WAL archive if it exists
            if [ -f "${TEMP_BACKUP_DIR}/pg_wal.tar.gz" ]; then
                local WAL_FILE="${BACKUP_DIR}/pg_wal_backup_${TIMESTAMP}.tar.gz"
                mv "${TEMP_BACKUP_DIR}/pg_wal.tar.gz" "${WAL_FILE}"
                log_message "WAL archive saved to: ${WAL_FILE}"
            fi
            
            # Clean up temp directory
            rm -rf "${TEMP_BACKUP_DIR}"
            
            local FILE_SIZE=$(du -h "${PHYSICAL_BACKUP_FILE}" | cut -f1)
            log_message "SUCCESS: Physical backup completed successfully"
            log_message "Backup file size: ${FILE_SIZE}"
            return 0
        else
            log_message "ERROR: Backup files not found in temporary directory"
            rm -rf "${TEMP_BACKUP_DIR}"
            return 1
        fi
    else
        log_message "ERROR: Physical backup failed"
        rm -rf "${TEMP_BACKUP_DIR}" 2>/dev/null
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
    FAILURE_EMAIL_BODY="PostgreSQL Backup Task Failed

Failed Task: ${FAILED_TASK}
Database: ${DB_NAME}
Hostname: ${HOSTNAME}
Timestamp: $(date)

Error Details:
The ${FAILED_TASK} process encountered an error and did not complete successfully.

Last 15 lines from backup log:
$(tail -n 15 "${LOG_FILE}")

Action Required:
1. Review the error details above
2. Check PostgreSQL server status
3. Verify disk space availability
4. Check database permissions
5. Review full log at: ${LOG_FILE}

Please investigate and resolve this issue immediately."
    
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
    UPLOAD_FAILURE_EMAIL_BODY="PostgreSQL Backup Upload Failed

Database: ${DB_NAME}
Hostname: ${HOSTNAME}
Timestamp: $(date)

Status:
✓ Backups were created successfully locally
✗ Upload to Google Drive failed

Local Backup Files:
- ${LOGICAL_BACKUP_FILE}
- ${PHYSICAL_BACKUP_FILE}

Action Required:
1. Check rclone configuration and credentials
2. Verify Google Drive API access
3. Check network connectivity
4. Review rclone logs for detailed error messages
5. Manually upload backups if necessary

Note: Local backups are available but were not uploaded to cloud storage.

Last 15 lines from log:
$(tail -n 15 "${LOG_FILE}")"
    
    send_email "FAILURE: PostgreSQL Backup Upload" "${UPLOAD_FAILURE_EMAIL_BODY}"
    
    log_message "Upload failure notification sent."
    log_message "=========================================="
    exit 1
fi

################################################################################
# SUCCESS NOTIFICATION
################################################################################
log_message "===== ALL TASKS COMPLETED SUCCESSFULLY ====="

SUCCESS_EMAIL_BODY="PostgreSQL Backup and Upload Completed Successfully

Database: ${DB_NAME}
Hostname: ${HOSTNAME}
Timestamp: $(date)

Backup Files Created and Uploaded:
✓ Logical Backup: $(basename ${LOGICAL_BACKUP_FILE})
  Size: $(du -h "${LOGICAL_BACKUP_FILE}" | cut -f1)

✓ Physical Base Backup: $(basename ${PHYSICAL_BACKUP_FILE})
  Size: $(du -h "${PHYSICAL_BACKUP_FILE}" | cut -f1)

Cloud Storage Location:
${RCLONE_REMOTE}${RCLONE_DEST_PATH}/

Next Actions:
- Backups are stored locally and in Google Drive
- Local backups older than ${RETENTION_DAYS} days will be removed
- Next scheduled backup: Tomorrow at 2:00 AM

Summary:
All backup operations completed without errors. Database backups are secure and available for recovery if needed."

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
