# CloudPanel-Scripts

⚠️ **WARNING: IMPORTANT LIMITATIONS** ⚠️
- These scripts are experimental and may not work in all scenarios
- **TAKE A SNAPSHOT** of your server before testing
- **Not Compatible** with:
  - NodeJS sites
  - Python sites
- The following items are **NOT** restored:
  - SSH users
  - FTP users
  - Log files
  - Security settings:
    - IP Blocking rules
    - Bot Blocking configurations
    - Basic Authentication
    - Cloudflare IP allowlist settings

A collection of utility scripts to enhance backup and restoration capabilities in CloudPanel when using rclone as your backup method.

## 🚀 Quick Start

1. Clone this repository to your server
2. Copy all scripts to `/scripts` directory
3. chmod +x /scripts/*.sh
4. Set up the monitoring cron job:
```bash
* * * * * root /usr/bin/bash /scripts/hijackCloudpanelBackups.sh
```

## 📦 Scripts Overview

### backupCronjobs.sh
Backs up site-specific cronjobs by:
- Scanning each site's cron configuration
- Storing configurations in the site's home directory
- Ensuring cronjobs are included in backups

### hijackCloudpanelBackups.sh
Enhances CloudPanel's default backup system by:
- Intercepting the default clp-rclone cron configuration
- Disabling the default backup job
- Implementing an improved backup solution that includes:
  - Database backups at time of backup
  - Cronjob configurations
  - Original backup timing

### restoreBackup.sh
Comprehensive site restoration tool supporting:
- PHP applications
- WordPress sites
- Reverse proxy configurations
- Static HTML websites

## 💾 Database Credentials

CloudPanel doesn't backup database credentials by default. There are two scenarios:

### WordPress Sites
No action required - the restoration script will:
- Generate new credentials automatically
- Update wp-config.php accordingly

### Other Applications
Create a `databases.json` file in the site's home directory with the following structure:

```json
{
  "databases": [
    {
      "name": "dbName1",
      "username": "dbUser1",
      "password": "dbPass1"
    },
    {
      "name": "dbName2",
      "username": "dbUser2",
      "password": "dbPass2"
    }
  ]
}
```

## ⚙️ Installation

1. Download the scripts:
```bash
git clone https://github.com/yourusername/CloudPanel-Scripts.git
```

2. Move scripts to the correct location:
```bash
cp CloudPanel-Scripts/*.sh /scripts/
chmod +x /scripts/*.sh
```

3. Set up the monitoring cron job:
```bash
echo "* * * * * root /usr/bin/bash /scripts/hijackCloudpanelBackups.sh" >> /etc/cron.d/hijack-backups
```

4. After your next backup runs try restoring a site with:
```bash
/scripts/restoreBackup.sh
```

5. Follow the prompts on screen.

## 📝 Notes

- All scripts must be placed in the `/scripts` directory
- Requires rclone backup method configured in CloudPanel
- The monitoring cron job ensures backup timing stays synchronized with CloudPanel's GUI settings
