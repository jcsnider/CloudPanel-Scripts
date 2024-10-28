#!/bin/bash

# Description: This script restores website backups from cloudpanel rclone backups.
# It supports WordPress, PHP, static HTML, and reverse proxy sites, and can handle
# multiple sites simultaneously. The script also restores databases, cron jobs,
# and re-obtains SSL certificates from LetsEncrypt if requested.

# Color definitions for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# Check if jq is installed, if not install it
if ! command -v jq &> /dev/null; then
    echo "jq not found, installing..."
    apt-get update && apt-get install -y jq
fi

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Exit immediately if a command exits with a non-zero status
set -e

# Function to prompt for SSL installation
ask_ssl_installation() {
    while true; do
        echo -e "${GREEN}Would you like to install SSL certificates for the restored sites? (y/n)${NC}"
        read -r response
        case $response in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Main function
main() {
    # Get backup directory from database
    backup_dir=$(sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT value FROM config WHERE key = 'remote_backup_storage_directory'")
    
    # Validate backup directory
    if [ -z "$backup_dir" ]; then
        echo -e "${RED}Error: Could not fetch backup directory from database${NC}"
        exit 1
    fi

    # Get directories from rclone (using $backup_dir instead of Sites)
    echo "Fetching available directories from remote..."
    directories=$(rclone lsf --max-depth 1 "remote:$backup_dir" | grep '/$' | sed 's/\/$//')

    # Check if we got any directories
    if [ -z "$directories" ]; then
        echo "No directories found in remote:$backup_dir"
        exit 1
    fi

    # Display options to user
    echo "Please select a directory to restore from:"
    select dir in $directories; do
        if [ -n "$dir" ]; then
            selected_dir=$dir
            break
        elif [ "$REPLY" = "q" ] || [ "$REPLY" = "Q" ]; then
            echo "Exiting..."
            exit 0
        else
            echo "Invalid selection. Please try again."
        fi
    done

    echo "Selected: $selected_dir"

    # Get times from the selected directory
    echo "Fetching available times from $selected_dir..."
    times=$(rclone lsf --max-depth 1 "remote:$backup_dir/$selected_dir" | grep '/$' | sed 's/\/$//')

    # Check if we got any times
    if [ -z "$times" ]; then
        echo "No times found in remote:$backup_dir/$selected_dir"
        exit 1
    fi

    # Display time options to user
    echo "Please select a time to restore from:"
    select time in $times; do
        if [ -n "$time" ]; then
            selected_time=$time
            break
        elif [ "$REPLY" = "q" ] || [ "$REPLY" = "Q" ]; then
            echo "Exiting..."
            exit 0
        else
            echo "Invalid selection. Please try again."
        fi
    done

    echo "Selected: $selected_time"

    # Get sites from the selected directory and time
    echo "Fetching available sites from $selected_dir/$selected_time..."
    sites=$(rclone lsf --max-depth 1 "remote:$backup_dir/$selected_dir/$selected_time/home/" | sed 's/\/$//')

    # Check if we got any sites
    if [ -z "$sites" ]; then
        echo "No sites found in remote:$backup_dir/$selected_dir/$selected_time/home/"
        exit 1
    fi

    # Display site options to user
    echo "Please select the sites to restore (space-separated numbers for multiple, 'all' for all sites, 'q' to quit, 'c' to continue):"
    select site in $sites "all"; do
        if [ "$REPLY" = "all" ]; then
            selected_sites=$sites
            break
        elif [ "$REPLY" = "c" ] || [ "$REPLY" = "C" ]; then
            break
        elif [ "$REPLY" = "q" ] || [ "$REPLY" = "Q" ]; then
            echo "Exiting..."
            exit 0
        elif [ -n "$site" ]; then
            if [ -z "$selected_sites" ]; then
                selected_sites=$site
            else
                selected_sites="$selected_sites $site"
            fi
            echo "Current selection: $selected_sites"
            echo "Select another site, 'all' for all remaining, or enter c to continue"
        elif [ -z "$REPLY" ]; then
            if [ -n "$selected_sites" ]; then
                break
            else
                echo "No sites selected. Please select at least one site."
            fi
        else
            echo "Invalid selection. Please try again."
        fi
    done

    echo "Selected sites: $selected_sites"

    # Ask about SSL installation
    install_ssl=false
    if ask_ssl_installation; then
        install_ssl=true
    fi

    # Create a timestamped log file for tracking restoration progress
    log_file="restore_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$log_file") 2>&1

    # Arrays to store site credentials for final output
    declare -A site_credentials
    declare -A site_db_credentials

    # Process each selected site
    for site in $selected_sites; do
        # ASCII header for each site
        echo "
═════════════════════════════════════════════════════════════════════════════
                            Restoring Site: $site                           
═════════════════════════════════════════════════════════════════════════════"

        tmp_dir="/tmp/restoring"
        rm -rf "$tmp_dir"
        mkdir -p "$tmp_dir"
        
        echo "Restoring site: $site"
        
        # Clear the temporary directory for each site
        rm -rf "$tmp_dir"/*
        
        # Copy the site files to the temporary directory
        rclone copy "remote:$backup_dir/$selected_dir/$selected_time/home/$site/backup.tar" "$tmp_dir"

        # Untar the backup file
        if ! tar -xf "$tmp_dir/backup.tar" -C "$tmp_dir" > /dev/null 2>&1; then
            echo -e "${RED}Error: Failed to extract backup for $site${NC}"
            exit 1
        fi
        rm "$tmp_dir/backup.tar"

        # Get domain name from site-settings.json
        domain=$(grep -oP '"domainName":\s*"\K[^"]+' "$tmp_dir"/home/*/site-settings.json | head -n1)
        if [ -z "$domain" ]; then
            echo -e "${RED}Error: Unable to extract domain name from site-settings.json for $site${NC} -- this is likely due to the backup being created by a version of CloudPanel < 2.4.2"
            continue
        fi
        echo "Domain name for $site: $domain"
        
        # Determine site type and PHP version
        site_vhost_file=$(find "$tmp_dir/home" -name "site-vhost" | head -n 1)
        site_settings_file=$(find "$tmp_dir/home" -name "site-settings.json" | head -n 1)
        
        # Get PHP version if available (only for PHP-based sites)
        php_version="8.3" # default value
        if [ -f "$site_settings_file" ]; then
            # First check site-settings.json for type
            site_type_setting=$(grep -oP '"type":\s*"\K[^"]+' "$site_settings_file")
            
            # Only check PHP version for PHP-based sites
            if [ "$site_type_setting" = "php" ] || [ "$site_type_setting" = "wordpress" ]; then
                detected_version=$(grep -oP '"version":\s*"\K[^"]+' "$site_settings_file" || echo "")
                if [ -n "$detected_version" ]; then
                    php_version=$detected_version
                fi
            fi
        fi
        
        if [ -f "$site_vhost_file" ] && [ -f "$site_settings_file" ]; then
            # First check site-settings.json for type
            site_type_setting=$(grep -oP '"type":\s*"\K[^"]+' "$site_settings_file")
            
            if [ "$site_type_setting" = "reverse-proxy" ]; then
                site_type="reverse-proxy"
            elif [ "$site_type_setting" = "php" ] && ! grep -q "wp-admin" "$site_vhost_file"; then
                site_type="php"
            elif grep -q "wp-admin" "$site_vhost_file"; then
                site_type="wordpress"
            else
                site_type="static_html"
            fi
        else
            echo -e "${RED}Error: Required configuration files not found for $site${NC}"
            continue
        fi
        echo "Site type for $site: $site_type"

        #delete site if exists
        clpctl site:delete --domainName=$domain --force || true
        sleep 2

        # Extract site user from site-settings.json instead of generating it
        site_user=$(grep -oP '"siteUser":\s*"\K[^"]+' "$site_settings_file")
        if [ -z "$site_user" ]; then
            echo -e "${RED}Error: Could not extract site user from site-settings.json for $site${NC}"
            continue
        fi
        echo "Site user for $site: $site_user"

        # Generate a random password
        password=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c20)
        
        # Truncate site_user if it's longer than 32 characters (MySQL username limit)
        site_path="$tmp_dir"/home/*/htdocs

        rm -rf /home/$site_user
        
        # Choose the appropriate site:add command based on site_type
        case $site_type in
            wordpress)
                echo "Adding WordPress site: $domain with PHP version $php_version"
                clpctl site:add:php --domainName=$domain --phpVersion=$php_version --vhostTemplate='WordPress' --siteUser=$site_user --siteUserPassword=$password
                ;;
            php)
                echo "Adding PHP site: $domain with PHP version $php_version"
                clpctl site:add:php --domainName=$domain --phpVersion=$php_version --vhostTemplate='Generic' --siteUser=$site_user --siteUserPassword=$password
                ;;
            static_html)
                echo "Adding static HTML site: $domain"
                clpctl site:add:static --domainName=$domain --siteUser=$site_user --siteUserPassword=$password
                ;;
            reverse-proxy)
                echo "Adding reverse proxy site: $domain"
                # Extract and unescape the reverse proxy URL
                proxy_url=$(grep -oP '"url":\s*"\K[^"]+' "$site_settings_file" | sed 's/\\\//\//g')
                if [ -z "$proxy_url" ]; then
                    proxy_url='http://127.0.0.1:8000' # fallback default
                fi
                clpctl site:add:reverse-proxy --domainName=$domain --reverseProxyUrl="$proxy_url" --siteUser=$site_user --siteUserPassword=$password
                ;;
            *)
                echo -e "${RED}Error: Unknown site type for $domain${NC}"
                continue
                ;;
        esac

        # Clear htdocs
        rm -rf /home/$site_user/htdocs/*

        # Find the correct home directory path
        home_path=$(find "$tmp_dir/home" -mindepth 1 -maxdepth 1 -type d | head -n 1)

        if [ -z "$home_path" ]; then
            echo -e "${RED}Error: Could not find home directory for $domain${NC}"
            continue
        fi

        # Recursively copy everything from home_path to /home/$site_user/
        cp -R "$home_path"/* "/home/$site_user/" || echo "Warning: Some files may not have been copied for $domain"

        # Update folder and file permissions
        chown -R $site_user:$site_user /home/$site_user/
        find /home/$site_user -type d -exec chmod 755 {} \;
        find /home/$site_user -type f -exec chmod 644 {} \;

        # Only set wp-config.php permissions if it's a WordPress site
        if [ "$site_type" = "wordpress" ]; then
            chmod 600 /home/$site_user/htdocs/$domain/wp-config.php
        fi

        # Find the correct database backup path
        dbs_path="$tmp_dir/home/$site_user/backups/databases"
        
        # Check if dbs_path exists
        if [ -d "$dbs_path" ]; then
            echo "Found database backup path: $dbs_path"
            
            # Check for existing database credentials
            credentials_file="/home/$site_user/databases.json"
            
            # Loop through each database folder
            for db_folder in "$dbs_path"/*; do
                if [ -d "$db_folder" ]; then
                    db=$(basename "$db_folder")
                    echo "Processing database: $db"
                    
                    # Initialize database credentials
                    db_username=$db
                    db_password=$password
                    
                    # Check if we have existing credentials
                    if [ -f "$credentials_file" ]; then
                        echo "Found existing credentials file"
                        if command -v jq &> /dev/null; then
                            # Try to find matching database credentials
                            if jq -e --arg db "$db" '.databases[] | select(.name == $db)' "$credentials_file" > /dev/null; then
                                db_username=$(jq -r --arg db "$db" '.databases[] | select(.name == $db) | .username' "$credentials_file")
                                db_password=$(jq -r --arg db "$db" '.databases[] | select(.name == $db) | .password' "$credentials_file")
                                echo "Using existing credentials for database $db"
                            else
                                echo "No existing credentials found for database $db, using new credentials"
                            fi
                        else
                            echo "jq not found, installing..."
                            apt-get update && apt-get install -y jq
                        fi
                    fi
                    
                    # Find the latest backup file
                    latest_backup=$(find "$db_folder" -name "*.sql.gz" | sort -r | head -n1)
                    
                    if [ -n "$latest_backup" ]; then
                        echo "Found latest backup for database $db: $latest_backup"
                        clpctl db:add --domainName=$domain --databaseName=$db --databaseUserName=$db_username --databaseUserPassword=$db_password
                        
                        # Store site credentials only once
                        if [ -z "${site_credentials[$domain]}" ]; then
                            site_credentials[$domain]="Site Username: $site_user
Site Password: $password"
                        fi

                        # Append database credentials
                        if [ -z "${site_db_credentials[$domain]}" ]; then
                            site_db_credentials[$domain]=""
                        fi
                        site_db_credentials[$domain]+="Database: $db
Database User: $db_username
Database Pass: $db_password

"

                        # Uncompress the .gz file
                        gunzip -c "$latest_backup" > "/tmp/${db}_temp.sql"
                        
                        # Import the uncompressed SQL file
                        clpctl db:import --databaseName=$db --file="/tmp/${db}_temp.sql"
                        
                        # Remove the temporary uncompressed file
                        rm "/tmp/${db}_temp.sql"
                        
                        echo "Imported database $db"
                    else
                        echo "No backup found for $db"
                    fi
                fi
            done
        else
            echo "Database backup path not found in $tmp_dir/home"
        fi

        #Update wp-config.php
        wp_config_file="/home/$site_user/htdocs/$domain/wp-config.php"
        
        # Check if wp-config.php exists and databases.json didn't exist
        if [ -f "$wp_config_file" ] && [ ! -f "$credentials_file" ]; then
            # Update the necessary defines
            sed -i "s/define( *'DB_NAME', *'[^']*' *);/define('DB_NAME', '$site_user');/" "$wp_config_file"
            sed -i "s/define( *'DB_USER', *'[^']*' *);/define('DB_USER', '$site_user');/" "$wp_config_file"
            sed -i "s/define( *'DB_PASSWORD', *'[^']*' *);/define('DB_PASSWORD', '$password');/" "$wp_config_file"
            sed -i "s/define( *'DB_HOST', *'[^']*' *);/define('DB_HOST', 'localhost:3306');/" "$wp_config_file"

            echo "Updated wp-config.php for $domain"
        fi

        #get site id
        # Get the site ID from the SQLite database
        site_id=$(sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT id FROM site WHERE domain_name = '$domain'")
        
        if [ -z "$site_id" ]; then
            echo -e "${RED}Error: Could not find site ID for domain $domain${NC}"
        else
            echo "Found site ID $site_id for domain $domain"
        fi

        # Only handle PHP-FPM port for PHP and WordPress sites
        if [ "$site_type" = "php" ] || [ "$site_type" = "wordpress" ]; then
            # Get PHP-FPM pool port for our site
            php_fpm_port=$(sqlite3 /home/clp/htdocs/app/data/db.sq3 "SELECT pool_port FROM php_settings WHERE site_id = $site_id")
            
            if [ -z "$php_fpm_port" ]; then
                echo -e "${RED}Error: Could not find PHP-FPM pool port for site ID $site_id${NC}"
            else
                echo "Found PHP-FPM pool port $php_fpm_port for site ID $site_id"
            fi
        fi

        # Find the site-vhost file
        vhost_file=$(find "$tmp_dir/home" -name "site-vhost" | head -n 1)
        if [ -f "$vhost_file" ]; then
            vhost_content=$(cat "$vhost_file")
            sqlite3 /home/clp/htdocs/app/data/db.sq3 <<EOF
UPDATE site 
SET vhost_template = '${vhost_content//\'/\'\'}'
WHERE id = $site_id;
EOF
            echo "Updated vhost template for site ID $site_id"
        else
            echo -e "${RED}Error: Could not find site-vhost file for $domain${NC}"
        fi

        # Copy nginx vhost file
        nginx_vhost_file=$(find "$tmp_dir/etc/nginx/sites-enabled" -type f | head -n 1)
        if [ -f "$nginx_vhost_file" ]; then
            # Replace the PHP-FPM port in the nginx vhost file
            sed -i "s/fastcgi_pass 127\.0\.0\.1:[0-9]\+;/fastcgi_pass 127.0.0.1:$php_fpm_port;/" "$nginx_vhost_file"
            
            # Check if PageSpeed is enabled in the nginx config
            if grep -q "pagespeed on;" "$nginx_vhost_file"; then
                # Update the database to enable PageSpeed (using 1 for true in SQLite)
                sqlite3 /home/clp/htdocs/app/data/db.sq3 "UPDATE site SET page_speed_enabled = 1 WHERE id = $site_id;"
                echo "Enabled PageSpeed for site ID $site_id"
            fi
            
            cp "$nginx_vhost_file" /etc/nginx/sites-enabled/
            echo "Copied and updated nginx vhost file for $domain with PHP-FPM port $php_fpm_port"
        else
            echo -e "${RED}Error: Could not find nginx vhost file for $domain${NC}"
        fi

        # Parse site-settings.json
        site_settings_file=$(find "$tmp_dir/home" -name "site-settings.json" | head -n 1)
        if [ -f "$site_settings_file" ]; then
            # Extract required information
            root_directory=$(grep -oP '"rootDirectory":\s*"\K[^"]+' "$site_settings_file")
            # Extract multi-line pageSpeed content and remove all JSON escape characters
            page_speed=$(awk -v RS='pageSpeed": "' -v FS='",' 'NR==2{print $1}' "$site_settings_file" | \
                        sed 's/\\n/\n/g' | \
                        sed 's/\\"/"/g' | \
                        sed 's/\\\\/\\/g')

            # Only process PHP settings for PHP and WordPress sites
            if [ "$site_type" = "php" ] || [ "$site_type" = "wordpress" ]; then
                php_version=$(grep -oP '"version":\s*"\K[^"]+' "$site_settings_file")
                memory_limit=$(grep -oP '"memoryLimit":\s*"\K[^"]+' "$site_settings_file")
                max_execution_time=$(grep -oP '"maxExecutionTime":\s*"\K[^"]+' "$site_settings_file")
                max_input_time=$(grep -oP '"maxInputTime":\s*"\K[^"]+' "$site_settings_file")
                max_input_vars=$(grep -oP '"maxInputVars":\s*"\K[^"]+' "$site_settings_file")
                post_max_size=$(grep -oP '"postMaxSize":\s*"\K[^"]+' "$site_settings_file")
                upload_max_filesize=$(grep -oP '"uploadMaxFileSize":\s*"\K[^"]+' "$site_settings_file")
                # Extract multi-line additionalConfiguration content and remove all JSON escape characters
                additional_configuration=$(awk -v RS='additionalConfiguration": "' -v FS='"' 'NR==2{print $1}' "$site_settings_file" | \
                                         sed 's/\\n/\n/g' | \
                                         sed 's/\\"/"/g' | \
                                         sed 's/\\\\/\\/g')

                #Uncomment these if needed for debugging
                #echo "Extracted PHP settings for $domain:"
                #echo "PHP Version: $php_version"
                #echo "Memory Limit: $memory_limit"
                #echo "Max Execution Time: $max_execution_time"
                #echo "Max Input Time: $max_input_time"
                #echo "Max Input Vars: $max_input_vars"
                #echo "Post Max Size: $post_max_size"
                #echo "Upload Max Filesize: $upload_max_filesize"
                #echo "Additional Configuration: $additional_configuration"

                # Escape special characters for SQL
                additional_configuration_escaped=$(echo "$additional_configuration" | sed "s/'/''/g")
            fi

            echo "Extracted common settings for $domain:"
            echo "Root Directory: $root_directory"
            
            #Uncomment for debugging
            #echo "Page Speed: $page_speed"

            # Escape special characters for SQL
            page_speed_escaped=$(echo "$page_speed" | sed "s/'/''/g")

            # Update the site table for all site types
            sqlite3 /home/clp/htdocs/app/data/db.sq3 <<EOF
UPDATE site 
SET root_directory = '$root_directory',
    page_speed_settings = '$page_speed_escaped'
WHERE id = $site_id;
EOF

            # Only update PHP settings for PHP and WordPress sites
            if [ "$site_type" = "php" ] || [ "$site_type" = "wordpress" ]; then
                sqlite3 /home/clp/htdocs/app/data/db.sq3 <<EOF
UPDATE php_settings
SET php_version = '$php_version',
    memory_limit = '$memory_limit',
    max_execution_time = '$max_execution_time',
    max_input_time = '$max_input_time',
    max_input_vars = '$max_input_vars',
    post_max_size = '$post_max_size',
    upload_max_file_size = '$upload_max_filesize',
    additional_configuration = '$additional_configuration_escaped'
WHERE site_id = $site_id;
EOF
                echo "Updated database with PHP settings for site ID $site_id"
            fi
            echo "Updated database with common settings for site ID $site_id"
        else
            echo -e "${RED}Error: Could not find site-settings.json for $domain${NC}"
        fi

        # Handle cron jobs
        cron_file=$(find "$tmp_dir/home" -name "cronjobs" | head -n 1)
        if [ -f "$cron_file" ]; then
            echo "Found cron file for $domain"
            
            # Copy the cron file to /etc/cron.d with the site_user name
            cp "$cron_file" "/etc/cron.d/$site_user"
            chmod 644 "/etc/cron.d/$site_user"
            
            # Read and process each line of the cron file
            while IFS= read -r line; do
                # Skip empty lines and lines starting with #
                [[ -z "$line" ]] || [[ "$line" =~ ^# ]] || [[ "$line" =~ ^MAILTO ]] && continue
                
                # Extract cron components
                minute=$(echo "$line" | awk '{print $1}')
                hour=$(echo "$line" | awk '{print $2}')
                day=$(echo "$line" | awk '{print $3}')
                month=$(echo "$line" | awk '{print $4}')
                weekday=$(echo "$line" | awk '{print $5}')
                username=$(echo "$line" | awk '{print $6}')
                # Get everything after the username as the command
                command=$(echo "$line" | cut -d' ' -f7-)
                
                # Get current timestamp for created_at and updated_at
                current_time=$(date '+%Y-%m-%d %H:%M:%S')
                
                # Insert into database
                sqlite3 /home/clp/htdocs/app/data/db.sq3 <<EOF
INSERT INTO cron_job (
    site_id, created_at, updated_at, 
    minute, hour, day, month, weekday, command
) VALUES (
    $site_id,
    '$current_time',
    '$current_time',
    '$minute',
    '$hour',
    '$day',
    '$month',
    '$weekday',
    '${command//\'/\'\'}'
);
EOF
                echo "Added cron job for site ID $site_id: $minute $hour $day $month $weekday $command"
            done < "$cron_file"
        else
            echo "No cron file found for $domain"
        fi

        # Reload nginx and cronservice
        service cron restart
        service nginx reload

        # Add this at the end of each site restoration (before the "Finished restoring" message)
        if [ "$install_ssl" = true ]; then
            echo "Installing Let's Encrypt SSL certificate for $domain..."
            if clpctl lets-encrypt:install:certificate --domainName=$domain; then
                echo -e "${GREEN}SSL certificate installed successfully for $domain${NC}"
            else
                echo -e "${RED}Failed to install SSL certificate for $domain${NC}"
            fi
        fi

        echo "Finished restoring $site"
        echo "
════════════════════════════════════════════════════════════════════════════
                          End of Site: $site                          
════════════════════════════════════════════════════════════════════════════

"
    done

    # Clean up the temporary directory
    #rm -rf "$tmp_dir"

    echo "All selected sites have been restored."

    echo -e "${BLUE}
═══════════════════════════════════════════
           Site Credentials                
═════════════════════════════════════════${NC}"

    for domain in "${!site_credentials[@]}"; do
        echo -e "${BLUE}Domain: $domain${NC}"
        echo -e "${BLUE}${site_credentials[$domain]}${NC}"
        echo
        echo -e "${BLUE}${site_db_credentials[$domain]}${NC}"
        echo -e "${BLUE}───────────────────────────────────────────${NC}"
    done

    exit 0
}

# Run the main function
main
