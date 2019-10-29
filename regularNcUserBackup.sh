#!/bin/bash

##
## Script for Nextcloud backups to a LUKS disk
## (please prepare LUKS disk before using this script)
##

## ------------------------------------------------------------
##
## Please edit the following variables to fit your environment!
##

luks_key="/root/.secrets/Backup-RAID/luks-keyfile"
mapper_name="cryptbackup"
uuid="36a81eb3-61a0-4cd9-bc4f-8f0321a9fbc9"             # the LUKS' disk uuid

decryption_check_file="/var/Regular-Backups/.is_encrypted"
decryption_check_string="true"

TARGETFOLDER="/var/Regular-Backups/Backup"
SQL_FILE="NC-SQL-Backup_`date '+%Y-%m-%d'`.sql"

NC_PATH="/var/www/nextcloud"
WEBSERVER_USER="http"

LOG="/var/log/NC-Backup.log"

##
## ------------- END OF EDITABLE AREA --------------
##
###############################################################


HAS_ERRORS=0

NC_PATH="${NC_PATH%/}"
NC_USER_DATA_FOLDER=`grep "datadirectory" "${NC_PATH}/config/config.php" | awk '{ print $3 }' | sed "s|[',]||g"`
DB_USER=`grep "dbuser" "${NC_PATH}/config/config.php" | awk '{ print $3 }' | sed "s|[',]||g"`
DB_PW=`grep "dbpassword" "${NC_PATH}/config/config.php" | awk '{ print $3 }' | sed "s|[',]||g"`
DB_NAME=`grep "dbname" "${NC_PATH}/config/config.php" | awk '{ print $3 }' | sed "s|[',]||g"`

## ----- Starting -----

echo "------ `date '+%Y-%m-%d %H:%M:%S'` -- Starting Backup ------" | tee -a $LOG

## ----- Prepare Backup -----

if [ $1 -ne 1 ] && [ $1 -ne 2 ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Choose one of the two backup sub-directories please! Exiting." | tee -a $LOG
  exit 1
fi

if [ ! -f "${NC_PATH}/config/config.php" ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Cannot access NC config file. File path given: ${NC_PATH}/config/config.php" | tee -a $LOG
  exit 2
fi

if [ ! -d "${NC_USER_DATA_FOLDER}" ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Cannot access folder for NC user data. Folder given: ${NC_USER_DATA_FOLDER}" | tee -a $LOG
  exit 3
fi

if [ -z $DB_USER ] || [ -z $DB_PW ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Extraction of DB credentials from NC config failed." | tee -a $LOG
  exit 4
fi


TARGETFOLDER="${TARGETFOLDER}_$1"
echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Target folder for backup: ${TARGETFOLDER}" | tee -a $LOG

cryptsetup_output=`cryptsetup status $mapper_name`
ERRCODE=$?

if [ $ERRCODE -ne 0 ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! cryptsetup finished with error code=${ERRCODE}. Backup Device seems not 'active'." | tee -a $LOG
fi

disk_status=`echo ${cryptsetup_output} | head -1 | awk '{ print $3}'`

if [ "$disk_status" == "inactive." ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Encrypted device not mapped to /dev/mapper/$mapper_name - mapping now" | tee -a $LOG
  cryptsetup open "/dev/disk/by-uuid/${uuid}" cryptbackup --key-file "${luks_key}"
  ERRCODE=$?
  if [ $ERRCODE -ne 0 ]; then
    echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! cryptsetup finished with error code=${ERRCODE}." | tee -a $LOG
    HAS_ERRORS=$(($HAS_ERRORS + 1))
  fi

  disk_status=`cryptsetup status $mapper_name | head -1 | awk '{ print $3}'`

  if [ -z "$disk_status" ] || [ "$disk_status" != "active." ]; then
    echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Encrypted disk still not active/ opened. Aborting!" | tee -a $LOG
    exit 5
  fi
fi

if [ ! -f "$decryption_check_file" ] || [ "`cat $decryption_check_file`" != "$decryption_check_string" ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Fatal Error! Something went totally wrong with opening disk. Aborting!" | tee -a $LOG
  exit 6
else
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Disk decrypted. Content of check file: `cat $decryption_check_file`." | tee -a $LOG
fi

echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Enabling Maintenance Mode of NC" | tee -a $LOG

sudo -u $WEBSERVER_USER php ${NC_PATH}/occ maintenance:mode --on

STATUS=`sudo -u $WEBSERVER_USER php ${NC_PATH}/occ maintenance:mode`

if [ "${STATUS}" != "Maintenance mode is currently enabled" ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Fatal Error! Maintenance Mode still disabled! Aborting ..." | tee -a $LOG
  exit 7
fi

echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Copying Data ..." | tee -a $LOG


## ----- Copy the user's data -----


# Double check to avoid copying over files to a filesystem which is not successfully decrypted and mounted
if [ -f "$decryption_check_file" ] && [ "`cat $decryption_check_file`" == "$decryption_check_string" ]; then
  rsync -aAXv --exclude="${NC_USER_DATA_FOLDER}/nextcloud.log**" --exclude="${NC_USER_DATA_FOLDER}/updater.log" --delete --quiet ${NC_USER_DATA_FOLDER} ${TARGETFOLDER}
  ERRCODE=$?
else
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Fatal Error! Previous checks failed, filesystem still not decrypted and mounted successfully." | tee -a $LOG
  exit 255
fi

if [ $ERRCODE -ne 0 ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! rsync failed with error code=${ERRCODE}." | tee -a $LOG
  HAS_ERRORS=$(($HAS_ERRORS + 1))
fi


## ----- Create database dump -----


mysqldump --single-transaction -u ${DB_USER} -p${DB_PW} ${DB_NAME} > /tmp/${SQL_FILE}
ERRCODE=$?

if [ $ERRCODE -ne 0 ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! mysqldump failed with error code=${ERRCODE}." | tee -a $LOG
  HAS_ERRORS=$(($HAS_ERRORS + 1))
fi

if [ -f "/tmp/${SQL_FILE}" ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! SQL dump successful" | tee -a $LOG
else
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Fatal Error! SQL dump FAILED! Check log and re-create backup!" | tee -a $LOG
  HAS_ERRORS=$(($HAS_ERRORS + 1))
fi

echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Disabling Maintenance Mode of NC" | tee -a $LOG
sudo -u $WEBSERVER_USER php ${NC_PATH}/occ maintenance:mode --off

STATUS=`sudo -u $WEBSERVER_USER php ${NC_PATH}/occ maintenance:mode`

if [ "${STATUS}" == "Maintenance mode is currently enabled" ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Fatal Error! Maintenance Mode still enabled! Still continuing to safe DB-backup ..." | tee -a $LOG
  HAS_ERRORS=$(($HAS_ERRORS + 1))
fi


## ----- Copying SQL dump -----


echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Synching DB backup file" | tee -a $LOG

if [ -f "/tmp/${SQL_FILE}" ]; then
  rsync -av --quiet /tmp/${SQL_FILE} ${TARGETFOLDER}
  ERRCODE=$?

  if [ $ERRCODE -ne 0 ]; then
    echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! rsync for mysql dump failed with error code=${ERRCODE}." | tee -a $LOG
    HAS_ERRORS=$(($HAS_ERRORS + 1))
  fi

  rm /tmp/${SQL_FILE}
  if [ -f "/tmp/${SQL_FILE}" ]; then
    echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Deletion of SQL dump /tmp/${SQL_FILE} failed" | tee -a $LOG
    HAS_ERRORS=$(($HAS_ERRORS + 1))
  fi
fi


## ----- Check if number of files in user folders match the number of files in backed up user folders -----


nrFiles=0
nrOldFiles=0

userList=`sudo -u $WEBSERVER_USER php ${NC_PATH}/occ user:list | awk '{print $2}' | sed 's/:$//g'`

for user in $userList; do
  if [ -r "${NC_USER_DATA_FOLDER}/$user" ]; then
    nrOldFiles=`expr $nrOldFiles + $(ls -Rla "${NC_USER_DATA_FOLDER}/$user" | wc -l)`
  fi
done

targetSubFolder=`echo ${NC_USER_DATA_FOLDER} | sed 's|^/.*/||g'`

for user in $userList; do
  if [ -r "${TARGETFOLDER}/${targetSubFolder}/$user" ]; then
    nrFiles=`expr $nrFiles + $(ls -Rla "${TARGETFOLDER}/${targetSubFolder}/$user" | wc -l)`
  fi
done

if [ $nrOldFiles -ne $nrFiles ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Error! Number of files in source folder (${nrOldFiles}) and target folder (${nrFiles}) differ. Check that!" | tee -a $LOG
  HAS_ERRORS=$(($HAS_ERRORS + 1))
fi


## ----- Print the success state and exit -----


if [ $HAS_ERRORS -eq 0 ]; then
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Backup SUCCESSFUL!" | tee -a $LOG
  exit 0
else
  echo "`date '+%Y-%m-%d %H:%M:%S'` -- Info! Backup partially SUCCESSFUL! Number of errors=${HAS_ERRORS}. Please check log!" | tee -a $LOG
  exit ${HAS_ERRORS}
fi

exit 1
