# this script builds deploys the sample app

trap ctrlc SIGINT

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

MACHINES=(devopstask1 devopstask2)  # MACHINES contains the machines to deploy to
declare -A HOST_TO_INSTANCE_ID      # HOST_TO_INSTANCE_ID maps host to its AWS instance-id

# FUNCTIONS
function initializeInstanceIds()
{
	for i in "${MACHINES[@]}"; do
		echoAndLog "initializing instandid for server $i"
		HOST_TO_INSTANCE_ID["$i"]=$(ssh $i wget -q -O - http://169.254.169.254/latest/meta-data/instance-id)
	done
}

function ctrlc()
{
	echoAndLog "deployment interrupted by ctrl-c"
	exit 1
}

function echoAndLog()
{
	TEXT_TO_ECHO_AND_LOG=$1
	
	echo "${TEXT_TO_ECHO_AND_LOG}"
	sudo bash -c "echo `date` : ${TEXT_TO_ECHO_AND_LOG} >> ${LOG_FILE}" 
}

function deploy()
{
	ENV="${1}"

	echoAndLog "deploying app to ${ENV}"

	# replace DEV to $ENV in settings.py
	echoAndLog "injecting $ENV to ${SETTINGS_FILE}"
	changeKeyToValInFile "CONFIG" "${ENV}" "${SETTINGS_FILE}" "=" | sudo tee -a $LOG_FILE 2>&1

	# raise version in version file
	echoAndLog "raising version in ${VERSION_FILE} from ${CURRENT_VERSION} to ${NEXT_VERSION}"
	changeKeyToValInFile "VERSION" "${NEXT_VERSION}" "${VERSION_FILE}" ":" | sudo tee -a $LOG_FILE 2>&1

	# create an archive of the version
	echoAndLog "creating and archive of the current version"
	createArchive
	
	# deploy app
	echoAndLog "deploying app to deployment servers"
	initializeInstanceIds
	for host in "${MACHINES[@]}"; do
		instance_id="${HOST_TO_INSTANCE_ID[$host]}"
		
		# clean
		echoAndLog "cleaning $APP_HOME in $host"		
		ssh $host "sudo rm -rf /home/app/*" | sudo tee -a $LOG_FILE 2>&1 # it's dangerous to use rm -rf $APP_HOME/* since if APP_HOME is empty we lost a server
		
		# deploy
		echoAndLog "deploying to host $host"
		scp -Cr "${APP_ARCHIVE_DIR}/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz" "${host}:/tmp" | sudo tee -a $LOG_FILE 2>&1
		ssh $host "(cd $APP_HOME ; sudo tar xvf /tmp/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz ; rm /tmp/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz)" | sudo tee -a $LOG_FILE 2>&1
	done
	

}

function createArchive()
{
	DATE=$(date "+%Y-%m-%d")
	
	echoAndLog "archiving ${APP_HOME} to ${APP_ARCHIVE_DIR}/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz" 
	sudo bash -c "(cd ${APP_HOME} ; tar --exclude='.git' -zcvf ${APP_ARCHIVE_DIR}/${PROJECT_NAME}.${DATE}.${NEXT_VERSION}.tgz . ) | sudo tee -a ${LOG_FILE} 2>&1"
}

function changeKeyToValInFile()
{
	KEY=$1
	VAL=$2
	FILE=$3
	DELIMITER=$4

	sudo sed -i "s/^\($KEY[ \t]*$DELIMITER[ \t]*\).*\$/\1$VAL/" "${FILE}" | sudo tee -a $LOG_FILE 2>&1

}

function getVersion()
{

	VERSION=`grep -o 'VERSION:.*$' ${VERSION_FILE} | cut -d: -f2`
	echo "${VERSION}"
}

function raiseVersion()
{
	# raise version
	echo "${CURRENT_VERSION}" | awk -F. -v OFS=. 'NF==1{print ++$NF}; NF>1{if(length($NF+1)>length($NF))$(NF-1)++; $NF=sprintf("%0*d", length($NF), ($NF+1)%(10^length($NF))); print}' | sudo tee -a $LOG_FILE 2>&1

}


function help_menu ()
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

echoAndLog "deployment started"
sleep 2
# check number of args is valid
[[ $# == 0 ]] && help_menu && exit 1

while [[ $# > 0 ]]
do
case "${1}" in
	-d|--deploy)
	ENV="${2}"
	[[ "$ENV" != "DEV" && "${ENV}" != "PROD" ]] && help_menu && exit 1
	deploy "${2}"
	shift
	;;
	-h|--help)
	help_menu
	shift
	;;
	*)
	echoAndLog "${1} is not a valid flag, try running: ${0} --help"
	;;
esac
shift
done

echoAndLog "deployment ended"
