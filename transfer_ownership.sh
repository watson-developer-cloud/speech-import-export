#!/bin/bash

printUsage() {
    echo "Usage: $(basename ${0}) [old deployment instance id] [new deployment instance id]"
    echo "    -c [custom resource name]"
    echo "    -v [version]: 4.8 (CP4D 4.8.x), 5.0 (CP4D 5.0.x), 5.1 (CP4D 5.1.x)"
    echo "    -p [postgres auth secret name](optional)"
    echo "    -n [namespace](optional)"
    echo "    -h/--help (optional)"
}

cmd_check(){
    if [ $? -ne 0 ] ; then
	echo "[FAIL] $DBNAME $COMMAND"
	exit 1
    fi
}

convert_instanceid_to_uuid() {
    echo `printf "%032d\n" $1 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'`
}

if [ $# -lt 6 ] ; then
    printUsage
    exit 1
fi

crflag=false
pgsecretflag=false
versionflag=false

SOURCE_ID=$1
shift
DEST_ID=$1
shift

while getopts n:c:p:v:h-: OPT
do
    case $OPT in
	"-")
	    case "${OPTARG}" in
		help) printUsage; exit 1 ;;
	    esac;;
	"h" ) printUsage; exit 1 ;;
	"n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
	"c" ) crflag=true; CR_NAME=$OPTARG ;;
	"p" ) pgsecretflag=true; PG_SECRET_NAME=$OPTARG ;;
	"v" ) versionflag=true; CP4D_VERSION=$OPTARG ;;
    esac
done

if ! $crflag
then
    echo "ERROR: Custom Resource name must be provided"
    printUsage
    exit 1
elif ! $versionflag
then
    echo "ERROR: Version must be provided"
    printUsage
    exit 1
fi

if [ $CP4D_VERSION != "4.8" ] && [ $CP4D_VERSION != "5.0" ] && [ $CP4D_VERSION != "5.1" ]
then
    echo "ERROR: Version flag must be one of [4.8, 5.0, 5.1], was $CP4D_VERSION"
    exit 1
fi

#Use default value for postgres auth secret if not provided
if ! $pgsecretflag
then
    if [ $CP4D_VERSION == "3.5" ]
    then
	PG_SECRET_NAME="user-provided-postgressql"
    else
	PG_SECRET_NAME="$CR_NAME-postgres-auth-secret"
    fi
    echo "WARNING: No Postgres auth secret provided, defaulting to: $PG_SECRET_NAME"
fi

#convert instance id to uuid
source_uuid=$(convert_instanceid_to_uuid ${SOURCE_ID})
dest_uuid=$(convert_instanceid_to_uuid ${DEST_ID})

#CP4D version-specific setup
if [ $CP4D_VERSION == "3.5" ]
then
    PG_PW_TEMPLATE="{{.data.PG_PASSWORD}}"
    PG_USERNAME="enterprisedb"
    PG_COMPONENT_LABEL="app.kubernetes.io/component=postgres"
else
    PG_PW_TEMPLATE="{{.data.password}}"
    PG_USERNAME="postgres"
    PG_COMPONENT_LABEL="app.kubernetes.io/component=postgres"
fi

#get a postgres pod and the database password
SQL_PASSWORD=`kubectl ${KUBECTL_ARGS} get secret $PG_SECRET_NAME --template $PG_PW_TEMPLATE | base64 --decode`
PG_POD=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath='{.items[0].metadata.name}' -l $PG_COMPONENT_LABEL,app.kubernetes.io/instance=$CR_NAME | head -n 1`

# ----- STT CUST -----
DB_NAME="stt-customization"
echo "transfer ownership of STT custom models to new instance ID"

kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; psql -v -d stt-customization -U postgres -h ${PG_POD} -p 5432 -c \"UPDATE customizations SET owner='${dest_uuid}'::uuid WHERE owner='${source_uuid}'::uuid;\""
cmd_check

# ----- TTS CUST -----
DB_NAME="tts-customization"
echo "transfer ownership of TTS custom models to new instance ID"
kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; psql -v -d tts-customization -U postgres -h ${PG_POD} -p 5432 -c \"UPDATE customizations SET owner='${dest_uuid}'::uuid WHERE owner='${source_uuid}'::uuid;\""
kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; psql -v -d tts-customization -U postgres -h ${PG_POD} -p 5432 -c \"UPDATE speakers SET owner='${dest_uuid}'::uuid WHERE owner='${source_uuid}'::uuid;\""
cmd_check

# ----- STT ASYNC -----
DB_NAME="stt-async"
echo "transfer ownership of Async notification urls to new instance ID"
kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; psql -v -d stt-async -U postgres -h ${PG_POD} -p 5432 -c \"UPDATE notification_urls SET instanceid='${dest_uuid}' WHERE instanceid='${source_uuid}';\""
cmd_check
