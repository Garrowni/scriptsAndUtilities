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
# #use would be dbReplicationMonitor.sh[cluster] [db]
##################################################################################################


cluster=$1
db=$2

#remove old files
/bin/find /REDACTED/db-rmon-logs/"${db}"/"${db}".$(hostname -f).* -type f -mtime +7 -exec /bin/rm

#check db replication
function check_replication() {
    touch /REDACTED/db-rmon-logs/"${db}"/"${db}"_rmon.$(hostname -f).$(date +"%Y-%m-%d").txt
    chmod 755 /REDACTED/db-rmon-logs/"${db}"/"${db}"_rmon.$(hostname -f).$(date +"%Y-%m-%d").txt
    rmonFile="/var/log/repl_mon$(date +"%H_%M").txt"

    if [ -f /root/.my.cnf ]; then
        mysql --defaults-file=/root/.my.cnf -e 'exit'
        if [ $? == 0 ]; then
            mysql --defaults-file=/root/.my.cnf -e "SHOW SLAVE STATUS\G;" | egrep -w "Salve_SQL_Running|Slave_IO_Running|Relay_Master_Log_File|Slave_IO_State|Last_SQL_Error|Last_IO_Error" >${rmonFile}
            echo \# HELP hourly_job_success_time metric$'\n'hourly_job_success_time{cluster_name=\"${cluster}\", cron_job=\"db_replication_monitor\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"hourly_job_success_time\"} $(date +%s) >/REDACTED/REDACTED/prometheus/textfilecollector/db_replication_monitor-${db}.prom
            echo " " >>/REDACTED/REDACTED/prometheus/textfilecollector/db_replication_monitor-${db}.prom
            if [ -s ${rmonFile} ]; then
                io_stat=$(grep -w Slave_IO_Running ${rmonFile} | awk '{print $2}')
                sql_stat=$(grep -w Slave_SQL_Running ${rmonFile} | awk '{print $2}')
                if [ ${io_stat} == "Yes" ] && [ ${sql_Stat} == "Yes" ]; then
                    echo \# HELP hourly_job_success_status metric$'\n'hourly_job_success_status{cluster_name=\"${cluster}\", cron_job=\"db_replication_monitor\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"hourly_job_success_status\"} 0 >>/REDACTED/REDACTED/prometheus/textfilecollector/db_replication_monitor-${db}.prom
                    echo -e "$(date +"%Y-%m-%d %H:%M")\tSuccess: DB replication success.\n " >>/REDACTED/db-rmon-logs/"${db}"/"${db}"_rmon.$(hostname -f).$(date + "%Y-%m-%d").txt
                else
                    echo \# HELP hourly_job_success_status metric$'\n'hourly_job_success_status{cluster_name=\"${cluster}\", cron_job=\"db_replication_monitor\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"hourly_job_success_status\"} 1 >>/REDACTED/REDACTED/prometheus/textfilecollector/db_replication_monitor-${db}.prom
                    echo -e "$(date +"%Y-%m-%d %H:%M")\tError: DB replication failed.\n " >>/REDACTED/db-rmon-logs/"${db}"/"${db}"_rmon.$(hostname -f).$(date + "%Y-%m-%d").txt
                    exit 1
                fi
            else
                echo \# HELP hourly_job_success_status metric$'\n'hourly_job_success_status{cluster_name=\"${cluster}\", cron_job=\"db_replication_monitor\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"hourly_job_success_status\"} 1 >>/REDACTED/REDACTED/prometheus/textfilecollector/db_replication_monitor-${db}.prom
                echo -e "$(date +"%Y-%m-%d %H:%M")\tError: Unable to connect to mysql.\n " >>/REDACTED/db-rmon-logs/"${db}"/"${db}"_rmon.$(hostname -f).$(date + "%Y-%m-%d").txt
                exit 1
            fi
        else
            echo \# HELP hourly_job_success_status metric$'\n'hourly_job_success_status{cluster_name=\"${cluster}\", cron_job=\"db_replication_monitor\",db=\"${db}\", instance=\"$(hostname -f)\", job=\"hourly_job_success_status\"} 1 >>/REDACTED/REDACTED/prometheus/textfilecollector/db_replication_monitor-${db}.prom
            echo -e "$(date +"%Y-%m-%d %H:%M")\tError: Unable to connect to mysql. Mysql defaults-file not found.\n " >>/REDACTED/db-rmon-logs/"${db}"/"${db}"_rmon.$(hostname -f).$(date + "%Y-%m-%d").txt
            exit 1
        fi
        exit 1
    fi
}

#Set up for prometheus textfilecolelctor
mkdir -p /REDACTED/REDACTED/prometheus/textfilecollector/
chmod 755 /REDACTED/REDACTED/prometheus/textfilecollector/

#set up place for logs
if [ ! -d /REDACTED/db-rmon-logs/"${db}"/ ]; then #if directory exists
    mkdir -p /REDACTED/db-rmon-logs/"${db}"/
    chmod 755 /REDACTED/db-rmon-logs/"${db}"/
fi
check_replication
