# this script deploys the sample app

trap ctrlc SIGINT # signal handler for ctrl-c

set -e # exit upon any error
#set -x # set for debug

# VARS
SETTINGS_FILE="/home/app/sampleproject/settings.py"
VERSION_FILE="/home/app/version"
CURRENT_VERSION=""  # initialized in main
NEXT_VERSION=""     # initialized in main
APP_HOME="/home/app"
APP_ARCHIVE_DIR="/home/app_archives"
PROJECT_NAME="sample-project"
LOG_FILE="/var/log/${PROJECT_NAME}/deployments.log"

MACHINES=(devopstask1 devopstask2)  # MACHINES contains the machines to deploy to. Add more here if needed
declare -A HOST_TO_INSTANCE_ID      # HOST_TO_INSTANCE_ID maps host to its AWS instance-id. Initialized in main

# FUNCTIONS
# initialize instance ids
function initializeInstanceIds()
{
	echoAndLog "initializing instance ids"
	for i in "${MACHINES[@]}"; do
		echoAndLog "initializing instandid for server $i"
		HOST_TO_INSTANCE_ID["$i"]=$(ssh $i wget -q -O - http://169.254.169.254/latest/meta-data/instance-id)
	done
}

# trap ctrc-c and log it
function ctrlc()
{
	echoAndLog "deployment interrupted by ctrl-c"
	exit 1
}

# logger function
function echoAndLog()
{
	TEXT_TO_ECHO_AND_LOG=$1
	
	echo "- ${TEXT_TO_ECHO_AND_LOG}"
	sudo bash -c "echo `date` : ${TEXT_TO_ECHO_AND_LOG} >> ${LOG_FILE}" 
}

# main deploy function
function deploy()
{
	ENV="${1}"

	echoAndLog "deploying app with ENV=${ENV}"

	# replace DEV to $ENV in settings.py
	echoAndLog "injecting $ENV to ${SETTINGS_FILE}"
	setKeyToValInFile "CONFIG" "${ENV}" "${SETTINGS_FILE}" "=" | sudo tee -a $LOG_FILE 2>&1

	# raise version in version file
	echoAndLog "raising version in ${VERSION_FILE} from ${CURRENT_VERSION} to ${NEXT_VERSION}"
	setKeyToValInFile "VERSION" "${NEXT_VERSION}" "${VERSION_FILE}" ":" | sudo tee -a $LOG_FILE 2>&1

	# create an archive of the version
	echoAndLog "creating and archive of the current version"
	createArchive
	
	# deploy app main loop, detach from ELB, clean previous installation, and deploy new app
	echoAndLog "deploying app to deployment servers"
	initializeInstanceIds
	
	# main loop
	for host in "${MACHINES[@]}"; do
		instance_id="${HOST_TO_INSTANCE_ID[$host]}"
		
		# deregister host from ELB
		echoAndLog "deregistering $host with instance-id ${instance_id} from ELB"
		aws elb deregister-instances-from-load-balancer --load-balancer-name devopstask-elb --instances $instance_id --output text | sudo tee -a $LOG_FILE
		sleep 1
		
		# clean previous installation
		echoAndLog "cleaning previous installation of $APP_HOME in $host"		
		ssh $host "sudo rm -rf /home/app/*" | sudo tee -a $LOG_FILE 2>&1 # it's dangerous to use rm -rf $APP_HOME/* since if APP_HOME is empty we lost a server
		
		# deploy new installation
		echoAndLog "deploying to host $host"
		scp -Cr "${APP_ARCHIVE_DIR}/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz" "${host}:/tmp" | sudo tee -a $LOG_FILE 2>&1
		ssh $host "(cd $APP_HOME ; sudo tar xvf /tmp/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz ; rm /tmp/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz)" | sudo tee -a $LOG_FILE 2>&1

		# register host back to ELB
		echoAndLog "registering $host with instance-id $instance_id back to ELB"
		aws elb register-instances-with-load-balancer --load-balancer-name devopstask-elb --instances $instance_id --output text | sudo tee -a $LOG_FILE
		sleep 1
	done
	

}

# archive artifacts
function createArchive()
{
	DATE=$(date "+%Y-%m-%d")
	
	echoAndLog "archiving ${APP_HOME} to ${APP_ARCHIVE_DIR}/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz" 
	sudo bash -c "(cd ${APP_HOME} ; tar --exclude='.git' -zcvf ${APP_ARCHIVE_DIR}/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz . ) | sudo tee -a ${LOG_FILE} 2>&1"
}

# helper function that sets key to val in a file based on a delimiter (some files are in key=val and others are in key:val form)
function setKeyToValInFile()
{
	KEY=$1
	VAL=$2
	FILE=$3
	DELIMITER=$4

	sudo sed -i "s/^\($KEY[ \t]*$DELIMITER[ \t]*\).*\$/\1$VAL/" "${FILE}" | sudo tee -a $LOG_FILE 2>&1
}

# get the version from the version file
function getVersion()
{
	# get version
	VERSION=`grep -o 'VERSION:.*$' ${VERSION_FILE} | cut -d: -f2`
	echo "${VERSION}"
}

# return the next version
function raiseVersion()
{
	# raise version
	echo "${CURRENT_VERSION}" | awk -F. -v OFS=. 'NF==1{print ++$NF}; NF>1{if(length($NF+1)>length($NF))$(NF-1)++; $NF=sprintf("%0*d", length($NF), ($NF+1)%(10^length($NF))); print}' | sudo tee -a $LOG_FILE 2>&1

}

# usage
function usage()
{
cat << EOF
Usage: ${0} (-h | -d ENV)
  OPTIONS:
        -h|--help                       Show this message
	-d|--deploy ENV                 Deploy app to ENV (ENV can be DEV|PROD)
EOF
}

# MAIN
CURRENT_VERSION=$(getVersion)
NEXT_VERSION=$(raiseVersion)

# check number of args is valid
[[ $# == 0 ]] && usage && exit 1

echoAndLog "------------------"
echoAndLog "deployment started"
echoAndLog "------------------"

while [[ $# > 0 ]]
do
case "${1}" in
	-d|--deploy)
	ENV="${2}"
	[[ "$ENV" != "DEV" && "${ENV}" != "PROD" ]] && usage && exit 1
	deploy "${ENV}"
	shift
	;;
	-h|--help)
	usage
	shift
	;;
	*)
	echoAndLog "${1} is not a valid flag, try running: ${0} --help"
	;;
esac
shift
done

echoAndLog "----------------"
echoAndLog "deployment ended"
echoAndLog "----------------"
