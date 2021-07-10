#!/bin/bash

function restart_deployment () {
    #rollout
    kubectl $KUBECTL_ARGS rollout restart deploy $1

    #wait for rollout to complete
    n=0
    succeeded=0
    echo "Waiting for deployment to rollout..."
    sleep 5

    until [ "$n" -ge 15 ]; do
	UNAVAIL_REPS=$(kubectl $KUBECTL_ARGS get deploy $1 -o jsonpath={.status.unavailableReplicas})
	if [[ -z $UNAVAIL_REPS && $(kubectl $KUBECTL_ARGS get deploy $1 -o jsonpath={.status.readyReplicas}) == 1 ]]; then
	    echo "Deployment successfully rolled out"
	    succeeded=1
	    break
	fi
	n=$((n+1))
	echo "attempt $n"
	sleep 20
    done
    if [ $succeeded -eq 0 ]; then
	echo "Deployment failed to roll out!"
	exit 1
    fi
}

function quiesce_async () {

    if [[ ${READONLY_ENABLED} == "true" ]]; then
	echo "Beginning quiesce of async service"
    else
	echo "Beginning unquiesce of async service"
    fi

    ASYNC_CM_NAME=`kubectl $KUBECTL_ARGS get cm -l release=$RELEASE_NAME,helm.sh/chart=sttAsync -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n'`
    ASYNC_DEPLOY_NAME=`kubectl $KUBECTL_ARGS get deploy -l release=$RELEASE_NAME,helm.sh/chart=sttAsync -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n'`

    kubectl $KUBECTL_ARGS get cm $ASYNC_CM_NAME -o yaml > async_cm.tmp.yaml

    #edit configmaps to readonly mode and do a rollout restart
    #async
    if [[ $(grep -c "maintenance.readOnlyMode" async_cm.tmp.yaml) -ge 1 ]]; then
	#flag already exists
	sed -i "s/maintenance\.readOnlyMode\s=.*/maintenance.readOnlyMode = ${READONLY_ENABLED}/g" async_cm.tmp.yaml
    else
	#flag must be inserted
	sed -i "0,/stt-async.properties.*/s/stt-async.properties.*/&\n    maintenance.readOnlyMode = ${READONLY_ENABLED}/g" async_cm.tmp.yaml
    fi

    kubectl $KUBECTL_ARGS apply -f async_cm.tmp.yaml

    restart_deployment $ASYNC_DEPLOY_NAME
}

function quiesce_stt_cust () {

    if [[ ${READONLY_ENABLED} == "true" ]]; then
	echo "Beginning quiesce of stt-customization service"
    else
	echo "Beginning unquiesce of stt-customzation service"
    fi

    STT_CUST_CM_NAME=`kubectl $KUBECTL_ARGS get cm -l release=$RELEASE_NAME,helm.sh/chart=sttCustomization -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep configmap`
    STT_CUST_DEPLOY_NAME=`kubectl $KUBECTL_ARGS get deploy -l release=$RELEASE_NAME,helm.sh/chart=sttCustomization -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n'`

    kubectl $KUBECTL_ARGS get cm $STT_CUST_CM_NAME -o yaml > stt_cust_cm.tmp.yaml

    #edit configmaps to readonly mode and do a rollout restart
    #async
    if [[ $(grep -c "read_only" stt_cust_cm.tmp.yaml) -ge 1 ]]; then
	#flag already exists
	sed -i "s/read_only\s=.*/read_only = ${READONLY_ENABLED}/g" stt_cust_cm.tmp.yaml
    else
	#flag must be inserted
	sed -i "0,/stt-customization.properties.*/s/stt-customization.properties.*/&\n    read_only = ${READONLY_ENABLED}/g" stt_cust_cm.tmp.yaml
    fi

    kubectl $KUBECTL_ARGS apply -f stt_cust_cm.tmp.yaml

    restart_deployment $STT_CUST_DEPLOY_NAME
}

function quiesce_tts_cust () {

    if [[ ${READONLY_ENABLED} == "true" ]]; then
	echo "Beginning quiesce of tts-customization service"
    else
	echo "Beginning unquiesce of tts-customzation service"
    fi

    TTS_CUST_CM_NAME=`kubectl $KUBECTL_ARGS get cm -l release=$RELEASE_NAME,helm.sh/chart=ttsCustomization -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep configmap`
    TTS_CUST_DEPLOY_NAME=`kubectl $KUBECTL_ARGS get deploy -l release=$RELEASE_NAME,helm.sh/chart=ttsCustomization -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n'`

    kubectl $KUBECTL_ARGS get cm $TTS_CUST_CM_NAME -o yaml > tts_cust_cm.tmp.yaml

    #edit configmaps to readonly mode and do a rollout restart
    #async
    if [[ $(grep -c "read_only" tts_cust_cm.tmp.yaml) -ge 1 ]]; then
	#flag already exists
	sed -i "s/read_only\s=.*/read_only = ${READONLY_ENABLED}/g" tts_cust_cm.tmp.yaml
    else
	#flag must be inserted
	sed -i "0,/tts-customization.properties.*/s/tts-customization.properties.*/&\n    read_only = ${READONLY_ENABLED}/g" tts_cust_cm.tmp.yaml
    fi

    kubectl $KUBECTL_ARGS apply -f tts_cust_cm.tmp.yaml

    restart_deployment $TTS_CUST_DEPLOY_NAME
}

function print_usage () {
    echo -e "USAGE: ./quiesce.sh <on|off> <release-name>"
    exit 1
}

if [ $# -ne 2 ] ; then
    print_usage
fi

STATE=$1
shift
RELEASE_NAME=$1
shift
while getopts n:asth OPT
do
  case $OPT in
      "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done


READONLY_ENABLED=false
if [[ $STATE != "on" && $STATE != "off" ]]; then
    echo "First argument must be [on/off]"
elif [[ $STATE == "on" ]]; then
    READONLY_ENABLED=true
fi

quiesce_async
quiesce_stt_cust
quiesce_tts_cust
