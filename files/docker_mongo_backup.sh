#!/bin/bash


export AWS_SHARED_CREDENTIALS_FILE=/etc/backup/credentials

usage() { 
    echo "Usage: $0 -n <archive name> -d <destination path> -c <container_name> -b <database_name> [-t <tmp dir>] [-r <retain count>] [-e <exp date>] ; -e example, \"2 min ago\", \"-2 months 5 day ago\" ";
    exit 1; 
}

while getopts ":n:d:t:r:e:c:b:" o; do
    case "${o}" in
        n)
            NAME=${OPTARG}
            ;;
        d)
            DEST=${OPTARG}
            ;;
        t)
            TMP=${OPTARG}
            ;;
        r)
            RETAIN_CNT=${OPTARG}
            ;;
        e)
            EXP_DATE=${OPTARG}
            ;;
        c)
            CONTAINER_NAME=${OPTARG}
            ;;
        b)
            DATABASE=${OPTARG}
            ;;

        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [[ -z "${TMP}" ]]; then
    TMP=/tmp
fi

if [[ -z "${RETAIN_CNT}" ]]; then
    RETAIN_CNT=0
fi

if [ -z "${NAME}" ] || [ -z "${DEST}" ] || [ -z "${CONTAINER_NAME}" ] || [ -z "${DATABASE}" ]; then
    usage
fi

#file lock
LOCKFILE="/var/run/backup_${NAME}.lock"
TIMEOUT=1
touch $LOCKFILE
exec {FD}<>$LOCKFILE

if ! flock -x -w $TIMEOUT $FD; then
    echo "fail to lock"
    exit 1;
fi

send_notification()
{   
    if [ -f "/usr/local/bin/apprise" ] && [ -f "/etc/backup/apprise_config" ]; then
            /usr/local/bin/apprise  -t "${1}" -b "${2}" --config=/etc/backup/apprise_config
    fi
    exit 1
}

#Archivation
CURRENT_DATE=$(date -u +%Y%m%d%H%M%S)
ARCHIVE_FULL_NAME=${TMP}/${NAME}-${CURRENT_DATE}.tar.gz

docker exec -i ${CONTAINER_NAME} /usr/bin/mongodump --db ${DATABASE} --archive=/${NAME}-${CURRENT_DATE}.tar.gz && \
docker cp ${CONTAINER_NAME}:/${NAME}-${CURRENT_DATE}.tar.gz ${ARCHIVE_FULL_NAME} && \
docker exec -i ${CONTAINER_NAME} rm -rf /${NAME}-${CURRENT_DATE}.tar.gz

TAR_RESULT=$?

#Archieve to S3. Notification telegram
if [[ $TAR_RESULT -gt 0 ]]; then
        send_notification "Failed to create tar archive" "Could't to upload tar ${NAME} to ${DEST} with exit code ${TAR_RESULT}" 
fi

#Upload to S3. Notification telegram
aws s3 mv ${ARCHIVE_FULL_NAME} ${DEST}
AWS_RESULT=$?
if [[ $AWS_RESULT  -gt 0 ]];  then
     send_notification "Failed to upload tar archive" "Could't to upload tar ${NAME} to ${DEST} with exit code ${AWS_RESULT}"
fi

#Rotation by count
if [[ $RETAIN_CNT -gt 0 ]]; then
    REMOTE_FILES=$(aws s3 ls ${DEST} | sort | awk '{print $4}' | grep ${NAME}) 
    echo "$REMOTE_FILES" | grep -v "`echo \"$REMOTE_FILES\" | tail -n ${RETAIN_CNT}`" | \
    while read file; do \
        aws s3 rm "${DEST}${file}"; \
    done
    echo "Done"
fi

#Rotation by time
if [[ -n "${EXP_DATE}" ]]; then
     REMOTE_FILES=$(aws s3 ls "${DEST}") 
     echo  "$REMOTE_FILES" | awk '{print $4}'  | \
  while read file; do \
        CURRENT_ARCHIEVE=$(echo $file | sed  "s/[^0-9]//g")  \
        FILTER_DATA=$(echo $(date --date="${EXP_DATE}" +%Y%m%d%H%M%S) | tr -d '-' )  
  if  [[ $CURRENT_ARCHIEVE < $FILTER_DATA  ]]; then  
          aws s3 rm "${DEST}${file}"; 
  fi 
  done
fi
