#!/usr/bin/env bash

##########################################################
# dbBackupMonitor.sh
#
# This sript was used with ansible.
#
# I was given permission to keep this redacted version of the script by one of my previous employers in order to
# share some of the professional scripts I have worked on.
#
# This script creates metrics that node exporter exposes for prometheus to scrape.
#
# #use would be dbBackupMonitor.sh [cluster] [db]
##################################################################################################


cluster=$1
db=$2

#Clean old backups
/bin/find /adusers/hdp-backups/db/*/*.$(hostname -f).* -type f -mtime +7 -exec /bin/rm {} \;

#Run the backup
/bin/mysqldump --defaults-file=/root/.my.cnf --single-transaction --databases "${db}" | bin/gzip >/adusers/hdp-backups/db/"${db}"/"${db}".$(hostname -f).$(date +"%Y-%m-%d").sql.gz
chmod 600 /adusers/hdp-backups/db/"${db}"/"${db}".*$(hostname -f)*
filename=/adusers/hdp-backups/db/"${db}"/"${db}".$(hostname -f).$(date +"%Y-%m-%d").sql.gz
echo \# HELP daily_job_success_time metric$'\n'daily_job_success_time{cluster_name=\", cron_job=\"db_backup\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"daily_job_success_time\"} $(date +%s) >/var/lib/prometheus/textfilecollector/db_backup-${db}.prom
echo "" >>/var/lib/prometheus/textfilecollector/db_backup-${db}.prom

#Setup backupSize
backupSizeArray=()
fileCount=$(ls -l --file-type | grep -v '/s' | wc -l)
if [ $(find /adusers/hdp-backups/db/"${db}" - prune -empty 2>/dev/null) ]; then
    backupSizeArray+=(0)
else
    for backup in /adusers/hdp-backups/db/"${db}"/"${db}".$(hostname -f).*.sql.gz; do
        backupSize=$(stat -c '%s' $backup)
        backupSizeArray+=(${backupSize})
    done
fi

#GET backupSizeAvg
backupSizeSum=0
for x in ${#backupSizeArray[@]}; do
    let "backupSizeSum+=x"
done
let "avgBackupSize=backupSizeSum/${#backupSizeArray[@]}"

#Check backup size
fileSize=$(stat -c%s "$filename")
minBackupSize=$(echo $avgBackupSize*0.8 | bc | awk '{printf("%.0f \n",$1)}')
if [ ${fileSize} -gt ${minBackupSize} ]; then
    echo \# HELP daily_job_success_status metric $'\n'daily_job_success_status{cluster_name=\"${cluster}\", cron_job=\"db_backup\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"daily_job_success_status\"} 0 >>/var/lib/prometheus/textfilecollector/db_backup-${db}.prom
    echo -e "Success"
    exit 0
else
    echo \# HELP daily_job_success_status metric $'\n'daily_job_success_status{cluster_name=\"${cluster}\", cron_job=\"db_backup\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"daily_job_success_status\"} 1 >>/var/lib/prometheus/textfilecollector/db_backup-${db}.prom
    echo -e "Failure"
    exit 1
fi
