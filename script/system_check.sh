#!/bin/bash
#
# Check: 
#
# 1. The amount of free disk space
# 2. Whether ActiveMQ is up and on the right ports
# 3. Solr is up
# 4. The workers are running
# 5. The web app is running
# 6. RabbitMQ is up and on the right ports (for alveo-workders:ingest)
#

RET_STATUS=0
REVIVE=$1
ACTIVEMQ_URL="http://localhost:8161/"
ACTIVEMQ_USER="admin:admin"

WEB_URL="http://localhost:3000/version.json"
JAVA_PORT_NUMBER=8983

red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`
#echo "${red}red text ${green}green text${reset}"

if [ ! -z "$RAILS_ENV" -a "$RAILS_ENV" != "development" ]
then
  WEB_URL="https://localhost/version.json"
  JAVA_PORT_NUMBER=8080
fi

JAVA_URL="http://localhost:${JAVA_PORT_NUMBER}/"

echo ""
echo "Checking HCS vLab environment"

echo `date`
echo "Rails env= $RAILS_ENV"
echo "Java Container url= $JAVA_URL"
echo "Web App url= $WEB_URL"
echo "Attempt restart= $REVIVE"

# Disk space

free_disk=`df -hP / | tail -1 | awk '{ print $4 }'`
echo "Free disk space= $free_disk"

# ActiveMQ

echo ""
echo "Checking ActiveMQ..."

let count=0
while [ $count -lt 15 -a "$aqm_status" == "" ]
do
  sleep 2
  aqm_status=`curl -I -u $ACTIVEMQ_USER $ACTIVEMQ_URL 2>/dev/null  | head -1 | awk '{print $2}' `
  let count=count+1
done

if [ "$aqm_status" == "200" ]
then
  echo "${green}+ ActiveMQ is listening on port 8161 (status= $aqm_status)${reset}"
else
  echo "${red}- WARN: It looks like ActiveMQ is not running (status= $aqm_status)${reset}"
  RET_STATUS=1

fi

mq_port=61616
amq_61616=`netstat -an | grep $mq_port | wc -l`

if [ $amq_61616 -eq 0 ]
then
  echo "${red}- WARN: ActiveMQ is not listening on port $mq_port${reset}"
  RET_STATUS=1
else
  echo "${green}+ ActiveMQ is listening on port $mq_port${reset}"
fi

mq_port=61613
amq_61613=`netstat -an | grep $mq_port | wc -l`

if [ $amq_61613 -eq 0 ]
then
  echo "${red}- WARN: ActiveMQ is not listening on port $mq_port${reset}"
  RET_STATUS=1
else
  echo "${green}+ ActiveMQ is listening on port $mq_port${reset}"
fi

if [ $RET_STATUS -eq 1 ] && [ "$REVIVE" == true ]
then
  echo "Reviving ActiveMQ..."
  pkill -9 -f activemq
  cd $ACTIVEMQ_HOME && nohup bin/activemq start > nohup_activemq.out 2>&1
  sleep 30
fi

# Servlet Container - Jetty or Tomcat

echo ""
echo "Checking the Java Container..."

sesame_url="http://10.0.0.11:8080"

let count=0
while [ $count -lt 15 -a "$java_status" == "" ]
do
  sleep 2
  sesame_status=`curl -I ${sesame_url}/openrdf-sesame/home/overview.view 2>/dev/null  | head -1 | awk '{print $2}' `
  let count=count+1
done

# Sesame
if [ "$sesame_status" == "200"  -o "$sesame_status" == "302" ]
then
  echo "${green}+ It looks like Sesame is available (status= $sesame_status)${reset}"
else
  echo "${red}- WARN: It looks like Sesame is not running (status= $sesame_status)${reset}"
  RET_STATUS=2
fi

# Solr
solr_url="http://10.0.0.7:8080"
solr_status=`curl -I ${solr_url}/solr/admin/ping 2>/dev/null  | head -1 | awk '{print $2}' `

if [ "$solr_status" == "200" -o "$solr_status" == "302" ]
then
  echo "${green}+ It looks like Solr is available (status= $solr_status)${reset}"
else
  echo "${red}- WARN: It looks like Solr is not running (status= $solr_status)${reset}"
  RET_STATUS=2
fi

if [ $RET_STATUS -eq 2 ] && [ "$REVIVE" == true ]
then
  echo "Reviving Tomcat..."
  pkill -9 -f catalina
  $CATALINA_HOME/bin/startup.sh
fi


# A13g workers

echo ""
echo "Checking A13g pollers..."

a13g_status=` ps auxw | grep [p]oller | wc -l `

if [ $a13g_status -ge 1 ]
then
  echo "${green}+ It looks like the A13g pollers are running (processes= $a13g_status)${reset}"
else
  echo "${red}- WARN: It looks like something is wrong with the A13g pollers (processes= $a13g_status)${reset}"
  RET_STATUS=3
fi

if [ $RET_STATUS -gt 0 ] && [ "$REVIVE" == true ]
then
  echo "Reviving workers..."
  cd /home/devel/hcsvlab-web/current && nohup bundle exec rake a13g:stop_pollers a13g:start_pollers > nohup_a13g_pollers.out 2>&1
fi

# Check the web app
echo ""
echo "Checking the web app..."

let count=0
while [ $count -lt 15 -a "$web_status" == "" ]
do
  sleep 2
  web_status=`curl -Ik ${WEB_URL} 2>/dev/null  | head -1 | awk '{print $2}' `
  let count=count+1
done

if [ "$web_status" == "200" ]
then
  echo "${green}+ The Web App is listening on port $WEB_PORT_NUMBER (status= $web_status)${reset}"
else
  echo "${red}- WARN: It looks like the Web App is not running (status= $web_status)${reset}"
  RET_STATUS=4
fi

# RabbitMQ

echo ""
echo "Checking RabbitMQ..."

rmq_port=5672

rmq_cmd=`netstat -an | grep $rmq_port | wc -l`

if [ $rmq_cmd -eq 0 ]
then
  echo "${red}- WARN: RabbitMQ is not listening on port $rmq_port${reset}"
  RET_STATUS=5
else
  echo "${green}+ RabbitMQ is listening on port $rmq_port${reset}"
fi

# End
echo ""
echo "Done."

#exit $RET_STATUS
