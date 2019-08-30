#!/bin/bash

# aws-backup-mysql.sh
# Linux shell script to automate MySQL backups to a local filesystem, aws-s3 bucket, aws-glacier vault. Runs off amazon linux, by default. 
# arg 1  - TODO
# expected input/output - TODO
# usage: ./sh aws-backup-mysql.sh  > aws-backup-mysql.log

# set exec defaults
VERBOSE=true
DEBUG=false
FREQUENCY="daily"
FILE_SUFFIX="awsdb"
MAX_LOCAL_BAKS=2
MAX_S3_BACKUPS=4
MIN_FREE_SPACE=90   # in perc

# param #1 exec_stage param #2 msg param #3 output
function dd(){
    if [ $VERBOSE == true ]
    then
        # format tty o/p        
        bold=$(tput bold)
        normal=$(tput sgr0)

        echo "["$(date +"%Y-%m-%d %T")"] ${bold}"$1"${normal} "$2" => "$3
        
        # append for reporting mail STR_REPORT=$(echo "["$(date +"%Y-%m-%d %T")"] ${bold}"$1"${normal} "$2" => "$3)

    fi
}

# param #1 exec_stage param #2 msg param #3 output
function aa(){
    # echo "<aa>"
    # echo $3
    # echo "</aa>"
    
    if [ $VERBOSE == true ]
    then
        AARRAY=$3
        echo ${AARRAY[@]}
        for i in "${AARRAY[@]}"
        do
            bold=$(tput bold)
            normal=$(tput sgr0)

            echo "["$(date +"%Y-%m-%d %T")"] ${bold}"$1"${normal} "$2" => "$i
        done
    fi
}

# check disk space
DISK_SPACE=($(df -hT /home | awk 'NR==2{print $6}'))
IFS='%' read -ra FREE_SPACE <<< "$DISK_SPACE"
for i in "${FREE_SPACE[@]}"; do
    # process "$i"
    dd "SETUP" "Freespace (%)" $FREE_SPACE
done
if [ $FREE_SPACE -gt $MIN_FREE_SPACE ]
then
    EFREESPACE="Critical free space limit reached. Aborting."
    dd "SETUP" "Freespace (%)" $EFREESPACE
    MAIL_EFREESPACE=$(php /home/ec2-user/awsdb-backup/send-mail.php '<my-email-id@myemail.com>' 'Alert for awsdb-backup on '$FILE_SUFFIX $EFREESPACE)
    dd "REPORT" "Freespace (%)" $MAIL_EFREESPACE
    exit
fi

# process cmd line args, to set archive name suffix
while [ "$1" != "" ]; do
    case $1 in
        -f | --frequency )      shift
                                FREQUENCY=$1
                                ;;
        -s | --suffix )         FILE_SUFFIX=$2
                                ;;
        -d | --debug )          DEBUG=true
                                ;;
    esac
    shift
done
dd "SETUP" "VERBOSE set to" $VERBOSE
dd "SETUP" "DEBUG set to" $DEBUG
dd "SETUP" "FREQUENCY set to" $FREQUENCY
dd "SETUP" "FILE_SUFFIX set to" $FILE_SUFFIX
dd "SETUP" "MAX_LOCAL_BAKS set to" $MAX_LOCAL_BAKS
dd "SETUP" "MAX_S3_BACKUPS set to" $MAX_S3_BACKUPS
dd "SETUP" "MIN_FREE_SPACE set to" $MIN_FREE_SPACE

# list all local backups, keep latest MAX_LOCAL_BAKS, purge the rest
ARR_LOCAL_BAKS=($(ls -t /home/ec2-user/awsdb-backup/"$(date +%Y)"-??-??_*-"$FILE_SUFFIX".sql.gz))
dd "RUNNING" "Backups found" ${#ARR_LOCAL_BAKS[@]}
# echo ${ARR_LOCAL_BAKS[@]}

CTR_FILES=0
for i in "${ARR_LOCAL_BAKS[@]}"
do
    
    if [[  $i == *$FILE_SUFFIX".sql.gz" ]] && test $CTR_FILES -gt $MAX_LOCAL_BAKS 
    then
        dd "RUNNING" "Deleting" $i
        if [ $DEBUG == false ] 
        then 
            rm $i
        fi
    else
        dd "RUNNING" "Retaining" $i
    fi
    CTR_FILES=$[CTR_FILES+1]
done

# system requirements check, aws-cli, mysqldump
BCHK_MYSQLDUMP=$(which mysqldump)
BCHK_AWS=$(which aws)
DUMP_CURRENT=$(date +"%Y-%m-%d_%H-%M-%S_"$FREQUENCY"-"$FILE_SUFFIX".sql.gz")
dd "RUNNING" "Current dump is" $DUMP_CURRENT

HAS_MYSQLDUMP=${#BCHK_MYSQLDUMP}
HAS_AWS=${#BCHK_AWS}

if [ $HAS_MYSQLDUMP != 0 -a $HAS_MYSQLDUMP > 0 ] 
then
        dd "RUNNING" "mysqldump exists?" "Yes"
else
        dd "RUNNING" "mysqldump exists?"  "No"
fi
if [ $HAS_AWS != 0 -a $HAS_AWS > 0 ] 
then
        dd "RUNNING" "aws-cli exists?"  "Yes"
else
        dd "RUNNING" "aws-cli exists?"  "No"
fi

# take a dump and gzip it
if [ $DEBUG == false ] 
then
    R_MYSQLDUMP=$(mysqldump --opt --events -u <mysql-username> -p<mysql-password> --all-databases|gzip > /home/ec2-user/awsdb-backup/$DUMP_CURRENT)
fi
dd "mysqldump" R_MYSQLDUMP

# # tar dump
# tar -cvf $DUMP_CURRENT DUMP_CURRENT_SQL

# list all S3 backups, keep latest MAX_S3_BAKS, purge the rest. assuming ls,returns in chronological order, oldest first
ARR_S3_BAKS=($(aws s3 ls s3://<s3-bucket-name> --recursive | awk '{print $4}'))
dd "S3" "Existing backups" ${#ARR_S3_BAKS[@]}

CTR_FILES=0
for i in "${ARR_S3_BAKS[@]}"
do
    if [[  $i == *$FILE_SUFFIX".sql.gz" ]] && test $CTR_FILES -gt $MAX_S3_BACKUPS 
    then
        dd "RUNNING" "Deleting" $i
        if [ $DEBUG == false ] 
        then 
            R_S3_DELETE=$(aws s3 rm s3://<s3-bucket-name>/$i)
            dd "RUNNING" "Removing older backup" $R_S3_DELETE
        fi
    else
        dd "RUNNING" "Retaining" $i
    fi
    CTR_FILES=$[CTR_FILES+1]
done

# # s3: upload current backup
if [ $DEBUG == false ] 
then 
    R_S3_UPLOAD=$(aws s3 cp $DUMP_CURRENT s3://<s3-bucket-name>/)
fi
dd "S3" "Upload status" $R_S3_UPLOAD

# # glacier: upload current backup
if [ $DEBUG == false ] 
then 
    R_GLAC_UPLOAD=$(aws glacier upload-archive --account-id - --vault-name <glacier-vault-name> --body $DUMP_CURRENT)
fi
dd "GLACIER" "Upload status" $R_GLAC_UPLOAD


# nothing more to do here
#R_BACKUPLOG=$(cat /home/ec2-user/awsdb-backup/awsdb-backup.log) 
R_BACKUPLOG="Backup complete"
MAIL_ENDTASK=$(php /home/ec2-user/awsdb-backup/send-mail.php '<my-email-id@myemail.com>' 'Progress update for '$FILE_SUFFIX'-backup on '$FILE_SUFFIX $R_BACKUPLOG)
dd "REPORT" "Progress update" $MAIL_ENDTASK
