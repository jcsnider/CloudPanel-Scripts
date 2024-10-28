# CloudPanel-Scripts

Work in progress scripts to make restoring sites in CloudPanel more manageable. These scripts only work if you are using rclone as your backup method. All of these scripts should be placed in `/scripts`

 - backupCronjobs.sh looks at the cronjobs for each site and stores them in the sites home directory in a cronjobs file so that cronjobs are backed up
 - hijackCloudpanelBackups.sh this looks at the default clp-rclone cron job, steals it's time config, disables it, and injects our own backup job which includes database backups and cronjobs at the time of backup
 - restoreBackup.sh this is a script that you can run to actually restore a php, wordpress, reverse proxy, or static html website. This script needs to be ran from the folder it's contained in.


 I recommend making the following cron entry:
 `* * * * * root /usr/bin/bash /scripts/hijackCloudpanelBackups.sh`

That entry will monitor for changes to the rclone backup config/schedule via the GUI and adapt our custom backups to run at that time and with that config instead.

Note: CloudPanel does not back up database credentials by default. For Wordpress sites this isn't a problem we can randomly create the credentials and the restoreBackup.sh script will automatically update wp-config.php. In other cases you can create a databases.json file in the home directory for each site where it's important for the database credentials to remain the same. The format of the databases.json file is:
```
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