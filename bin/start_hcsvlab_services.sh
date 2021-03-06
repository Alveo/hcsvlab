#!/bin/bash

#
# This script is intended to start all the services required by HCSVLAB to work after a system reboot
# In CentOS linux add the following line at the end of the file /etc/rc.d/rc.local:
#
# su - devel -c '<PATH_TO_THIS_SCRIPT>/start_hcsvlab_services.sh &'
#
#

PATH=/home/devel/.rvm/gems/ruby-2.1.4/bin:/home/devel/.rvm/gems/ruby-2.1.4@global/bin:/home/devel/.rvm/rubies/ruby-2.1.4/bin:/home/devel/.rvm/bin:/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH
export $PATH

# Starting ActiveMQ
cd $ACTIVEMQ_HOME && nohup bin/activemq start > nohup_activemq.out 2>&1
sleep 5

# Starting Apache Tomcat
$CATALINA_HOME/bin/startup.sh
sleep 5

# Starting Solr Workers
cd /home/devel/hcsvlab-web/current/
/home/devel/.rvm/gems/ruby-2.1.4\@global/bin/rake a13g:start_pollers

# Start Galaxy
cd $GALAXY_HOME
./galaxy start
