#!/bin/bash

# Loop through each folder in /home/
for user_dir in /home/*; do
    # Extract the username from the directory path
    username=$(basename "$user_dir")
    
    # Check if a matching cron file exists in /etc/cron.d/
    if [ -f "/etc/cron.d/$username" ]; then
        # Copy the cron file to the user's home directory
        cp "/etc/cron.d/$username" "$user_dir/cronjobs"
        
        # Set file permissions to 0770
        chmod 0770 "$user_dir/cronjobs"
        
        # Change owner to $username:$username
        chown "$username:$username" "$user_dir/cronjobs"
        
        echo "Backed up cron file for $username with permissions 0770 and owner $username:$username"
    else
        echo "No cron file found for $username"
    fi
done
