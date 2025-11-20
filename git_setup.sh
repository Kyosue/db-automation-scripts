#!/bin/bash

echo "=========================================="
echo "Git Setup for PostgreSQL Backup Scripts"
echo "=========================================="

# Change to project directory
cd "/home/raabelgas/Laboratory Exercises/Lab8" || exit 1

# 1. Initialize git repository
echo "Step 1: Initializing git repository..."
git init

# 2. Configure git
echo "Step 2: Configuring git..."
git config user.name "Your Name"
git config user.email "reymundangelo@gmail.com"

# 3. Create logs directory if not exists
echo "Step 3: Preparing log files..."
mkdir -p logs

# Extract 3 days of logs
for i in {0..2}; do
    DATE=$(date -d "$i days ago" +%Y-%m-%d)
    grep "^\\[${DATE}" /var/log/pg_backup.log > "logs/pg_backup_${DATE}.log" 2>/dev/null || \
    echo "[${DATE}] No backup logs for this date" > "logs/pg_backup_${DATE}.log"
done

echo "Log files created:"
ls -lh logs/

# 4. Stage files
echo "Step 4: Staging files..."
git add run_pg_backups.sh
git add cron_wrapper.sh
git add .gitignore
git add README.md

# 5. Check status
echo "Step 5: Git status:"
git status

# 6. First commit - scripts
echo "Step 6: Creating initial commit..."
git commit -m "feat: Add initial backup automation script"

# 7. Add logs
echo "Step 7: Adding logs..."
git add logs/

# 8. Second commit - logs
echo "Step 8: Committing logs..."
git commit -m "docs: Add 3 days of backup logs"

# 9. Show commit history
echo "Step 9: Commit history:"
git log --oneline --all

# 10. Ready for remote
echo ""
echo "=========================================="
echo "Git repository ready!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Create repository on GitHub: db-automation-scripts"
echo "2. Run these commands:"
echo ""
echo "   git remote add origin https://github.com/YOUR_USERNAME/db-automation-scripts.git"
echo "   git branch -M main"
echo "   git push -u origin main"
echo ""
echo "=========================================="
