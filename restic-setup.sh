#!/bin/bash

###############################################
#
# Forge → B2 Backup
# Backs up all databases and /home/forge to
# Backblaze B2 using restic.
#
# by Matt Stein <matt@workingconcept.com>
# No warranty provided, use at your own risk!
#
###############################################
# Instructions
###############################################
#
# 1. Create a B2 bucket and application key.
# 2. Run this script as root.
# 3. Run a mysql backup with mysql-backup.sh.
# 4. Run a backup with restic-backup.sh.
# 5. Use restic-mount.sh to mount and verify.
# 6. Enable cron job for restic-backup.sh
#
###############################################

echo ""
echo "----------------------------------------"
echo "Forge → B2 Backup"
echo "----------------------------------------"
echo ""

if [ ! -f /root/restic/conf/b2.conf ]; then
    read -p "Enter B2 application key ID: " B2_ACCOUNT_ID
    read -p "Enter B2 application key: " B2_ACCOUNT_KEY
    read -p "Enter B2 bucket: " B2_BUCKET
fi

# location for local backup data
BACKUP_DIR="/home/forge/backup"

# location of files to back up
BACKUP_TARGET="/home/forge"

# MySQL backup user (password will be generated)
MYSQL_USER="backup"
TIMESTAMP=$(date +"%F")
MYSQL=/usr/bin/mysql
MYSQLDUMP=/usr/bin/mysqldump

echo ""
echo "----------------------------------------"
echo "Installing restic..."
echo "----------------------------------------"
echo ""

apt-get install restic

if [ ! -d /root/restic ]; then
    echo "----------------------------------------"
    echo "Creating /root/restic..."
    echo "----------------------------------------"

    # create directories we'll need
    mkdir -p /root/restic
    mkdir -p /root/restic/conf
    mkdir -p $BACKUP_DIR
    chown -R forge:forge $BACKUP_DIR
fi

echo ""
echo "----------------------------------------"
echo "Confirming MySQL setup..."
echo "----------------------------------------"
echo ""

# create or source backup user MySQL password
if [ ! -f /root/restic/conf/mysql.conf ]; then
    read -p "Enter MySQL password for 'forge': " ROOT_MYSQL_PASSWORD

    # generate random 32 character alphanumeric string (upper and lowercase)
    MYSQL_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    touch /root/restic/conf/mysql.conf
    echo "export MYSQL_PASSWORD=\"$MYSQL_PASSWORD\"" >> /root/restic/conf/mysql.conf
    echo "export MYSQL_USER=\"$MYSQL_USER\"" >> /root/restic/conf/mysql.conf
    echo "export MYSQL=\"$MYSQL\"" >> /root/restic/conf/mysql.conf
    echo "export MYSQLDUMP=\"$MYSQLDUMP\"" >> /root/restic/conf/mysql.conf
    echo "export BACKUP_DIR=\"$BACKUP_DIR\"" >> /root/restic/conf/mysql.conf

    # create read-only mysql backup user and store credentials
    $MYSQL --user="forge" --password="$ROOT_MYSQL_PASSWORD" --execute="CREATE USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
    $MYSQL --user="forge" --password="$ROOT_MYSQL_PASSWORD" --execute="GRANT SELECT, LOCK TABLES ON *.* TO '${MYSQL_USER}'@'localhost';"
    $MYSQL --user="forge" --password="$ROOT_MYSQL_PASSWORD" --execute="FLUSH PRIVILEGES;"

    echo "!! created backup user with password: $MYSQL_PASSWORD"
else
    echo "✓ found MySQL backup password"
    source /root/restic/conf/mysql.conf
fi

echo ""
echo "----------------------------------------"
echo "Confirming restic repository..."
echo "----------------------------------------"
echo ""

# write restic backup exclude file if one doesn't exist
if [ ! -f /root/restic/conf/excludes.conf ]; then
    touch /root/restic/conf/excludes.conf
    echo ".git/*" > /root/restic/conf/excludes.conf
    echo "created /root/restic/conf/excludes.conf"
else
    echo "✓ found backup exclude file"
fi

if [ ! -f /root/restic/conf/b2.conf ]; then
    # create B2 settings file
    touch /root/restic/conf/b2.conf

    echo "export B2_ACCOUNT_ID=\"$B2_ACCOUNT_ID\"" >> /root/restic/conf/b2.conf
    echo "export B2_ACCOUNT_KEY=\"$B2_ACCOUNT_KEY\"" >> /root/restic/conf/b2.conf
    echo "export B2_BUCKET=\"$B2_BUCKET\"" >> /root/restic/conf/b2.conf
    echo "wrote B2 settings"
else
    echo "✓ found B2 settings"
fi

# create or source restic password
if [ ! -f /root/restic/conf/password.conf ]; then
    # generate random 32 character alphanumeric string (upper and lowercase)
    RESTIC_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

    touch /root/restic/conf/password.conf
    echo $RESTIC_PASSWORD > /root/restic/conf/password.conf
    echo "!! generated restic repository password: $RESTIC_PASSWORD"
else
    echo "✓ found restic password"
fi

# save MySQL backup script
cat >/root/restic/mysql-backup.sh <<'EOL'
#! /bin/bash

echo ""
echo "----------------------------------------"
echo "Running MySQL backup routine..."
echo "----------------------------------------"
echo ""

source /root/restic/conf/mysql.conf

DATESTAMP=$(date +"%F")
TIMESTAMP=$(date +"%H%M%S")

mkdir -p $BACKUP_DIR/mysql/$DATESTAMP

databases=`$MYSQL --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --execute="SHOW DATABASES;" | grep -Ev "(Database|information_schema)"`

for db in $databases; do
if [ $db != "performance_schema" ]&&[ $db != "mysql" ];then
    FILENAME=$BACKUP_DIR/mysql/$DATESTAMP/$db-$TIMESTAMP.gz

    echo -e "backing up '$db' → $FILENAME"
    # with GZIP
    $MYSQLDUMP --force --opt --user=$MYSQL_USER -p$MYSQL_PASSWORD --databases $db | gzip > "$FILENAME"
    chown forge:forge $FILENAME
    # without GZIP
    #$MYSQLDUMP --force --opt --user=$MYSQL_USER -p$MYSQL_PASSWORD --databases $db > "$FILENAME"
fi
done

echo ""
echo "----------------------------------------"
echo "Pruning old backups..."
echo "----------------------------------------"
echo ""

# prune files more than 15 days old
# https://askubuntu.com/questions/589210/removing-files-older-than-7-days

#find $BACKUP_DIR/mysql/ -type f -mtime +7 -name '*.gz' -execdir rm -- '{}' \;
find $BACKUP_DIR/mysql/ -mtime +7 -name '*.gz' -execdir rm -- '{}' \;

echo "Done."
EOL

# save restic backup script
cat >/root/restic/restic-backup.sh <<'EOL'
#/bin/bash

# load b2.conf environment variables into our session
. /root/restic/conf/b2.conf
. /root/restic/conf/mysql.conf

echo ""
echo "----------------------------------------"
echo "Running restic backup → $B2_BUCKET..."
echo "----------------------------------------"
echo ""

# create a mysql backup
/root/restic/mysql-backup.sh

/usr/bin/restic -r b2:$B2_BUCKET:/ backup /home/forge --exclude-file=/root/restic/conf/excludes.conf --password-file=/root/restic/conf/password.conf
/usr/bin/restic -r b2:$B2_BUCKET:/ --password-file=/root/restic/conf/password.conf forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 2
/usr/bin/restic -r b2:$B2_BUCKET:/ --password-file=/root/restic/conf/password.conf prune
/usr/bin/restic -r b2:$B2_BUCKET:/ --password-file=/root/restic/conf/password.conf check
EOL

# save restic mount script
cat >/root/restic/restic-mount.sh <<'EOL'
#/bin/bash

echo "----------------------------------------"
echo "Mounting backup at /mnt/restic..."
echo "----------------------------------------"

mkdir /mnt/restic
. /root/restic/conf/b2.conf
restic -r b2:$B2_BUCKET mount /mnt/restic --password-file=/root/restic/conf/password.conf
echo "Unmount with 'umount /mnt/restic' when you're done!"
EOL

# make scripts executable
chmod +x /root/restic/mysql-backup.sh
chmod +x /root/restic/restic-backup.sh
chmod +x /root/restic/restic-mount.sh

# add a commented-out crontab line to enable later
crontab -l > crontemp
echo "" >> crontemp
echo "# daily Restic server backup to B2" >> crontemp
echo "# 0 3 * * * /root/restic/restic-backup.sh >/dev/null 2>&1" >> crontemp
crontab crontemp
rm crontemp

# init backup
# ```
# source /root/restic/conf/b2.conf
# restic -r b2:$B2_BUCKET:/ init
# ```
while true; do
    echo ""
    read -p "Do you want to initialize the restic repo now? " yn
    echo ""
    case $yn in
        [Yy]* ) source /root/restic/conf/b2.conf && restic -r b2:$B2_BUCKET:/ init; break;;
        [Nn]* ) exit;;
        * ) echo "Please answer yes or no.";;
    esac
done

echo ""
echo "----------------------------------------"
echo "Looking good."
echo "Don't forget to finish setting up restic!"
echo ""
echo "- [ ] run a backup"
echo "- [ ] uncomment line in crontab"
echo "- [ ] mount and verify backups"
echo "----------------------------------------"

