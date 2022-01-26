#!/bin/bash

printUsage() {
    echo "Usage: $(basename ${0}) [import|export]"
    echo "    -c [custom resource name (CP4D 4.x) / release name (CP4D 3.5 and earlier)]"
    echo "    -o [import/export directory]"
    echo "    -v [version]: 301 (CP4D3.0.1), 35 (CP4D3.5),  40 (CP4D 4.x)"
    echo "    -p [postgres auth secret name](optional)"
    echo "    -m [minio auth secret name](optional)"
    echo "    -n [namespace](optional)"
    echo "    --no-quiesce Don't quiesce microservices before export (optional)"
    echo "    -h Show this menu"
    exit 1
}

quiesce_services() {
    echo "Quiescing services"
    if [ $CP4D_VERSION == "40" ]
    then
	${LIB_DIR}/cpdbr quiesce ${KUBECTL_ARGS}
	cmd_check
    else
	${LIB_DIR}/quiesce.sh on ${CR_NAME}
	cmd_check
    fi
}

unquiesce_services() {
    echo "Unquiescing services"
    if [ $CP4D_VERSION == "40" ]
    then
	${LIB_DIR}/cpdbr unquiesce ${KUBECTL_ARGS}
	cmd_check
    else
	${LIB_DIR}/quiesce.sh off ${CR_NAME}
	cmd_check
    fi
}

cmd_check(){
    if [ $? -ne 0 ] ; then
	echo "[FAIL] $DBNAME $COMMAND"
	if ! $noquiesce
	then
	    unquiesce_services
	fi
	exit 1
    fi
}

wait_for_async_jobs() {
    sleep_time=2
    active_job_count=1
    while [ $active_job_count -gt 0 ]
    do
	active_job_count=`kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; psql -t -v -d stt-async -U $PG_USERNAME -h ${PG_POD} -p 5432 -c \"SELECT count(status) FROM jobs WHERE status='Waiting' or status='Processing';\""`
	if [ $active_job_count -gt 0 ]; then
	    echo "At least 1 async job is in 'Waiting' or 'Processing' state.. performing exponential backoff to wait for jobs to complete before switching async service to read only"
	    echo "Sleeping for $sleep_time seconds"
	    sleep $sleep_time
	    sleep_time=$(($sleep_time**2))
	fi
    done
}

# if [ $# -lt 7 ] ; then
#     printUsage
# fi

crflag=false
pgsecretflag=false
miniosecretflag=false
exportflag=false
versionflag=false
noquiesce=false


COMMAND=$1
shift
if [[ $COMMAND != "import" ]] && [[ $COMMAND != "export" ]]; then
    printUsage
    exit 1
fi

while getopts "n:c:o:p:m:v:-:h" OPT
do
    case $OPT in
	"-" )
	    case "${OPTARG}" in
		no-quiesce) noquiesce=true ;;
		help) printUsage; exit 1 ;;
	    esac;;
	"h" ) printUsage; exit 1 ;;
	"n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
	"c" ) crflag=true; CR_NAME=$OPTARG ;;
	"p" ) pgsecretflag=true; PG_SECRET_NAME=$OPTARG ;;
	"m" ) miniosecretflag=true; MINIO_SECRET_NAME=$OPTARG ;;
	"o" ) exportflag=true; EXPORT_DIR=$OPTARG ;;
	"v" ) versionflag=true; CP4D_VERSION=$OPTARG ;;
    esac
done

#Validate mandatory arguments
if ! $crflag
then
    echo "ERROR: Custom Resource name must be provided"
    printUsage
    exit 1
elif ! $exportflag
then
    echo "ERROR: Input/Output directory must be provided"
    printUsage
    exit 1
elif ! $versionflag
then
    echo "ERROR: Version must be provided"
    printUsage
    exit 1
fi

if [ $CP4D_VERSION != "301" ] && [ $CP4D_VERSION != "35" ] && [ $CP4D_VERSION != "40" ]
then
    echo "ERROR: Version flag must be one of [301, 35 , 40], was $CP4D_VERSION"
    exit 1
fi

#Use default value for postgres auth secret if not provided
if ! $pgsecretflag
then
    if [ $CP4D_VERSION == "35" ] || [ $CP4D_VERSION == "301" ]
    then
	PG_SECRET_NAME="user-provided-postgressql"
    else
	PG_SECRET_NAME="$CR_NAME-postgres-auth-secret"
    fi
    echo "WARNING: No Postgres auth secret provided, defaulting to: $PG_SECRET_NAME"
fi

#Use default value for minio auth secret if not provided
if ! $miniosecretflag
then
    if [ $CP4D_VERSION == "35" ] || [ $CP4D_VERSION == "301" ]
    then
	MINIO_SECRET_NAME="minio"
    else
	MINIO_SECRET_NAME="$CR_NAME-ibm-minio-auth"
    fi
    echo "WARNING: No MinIO auth secret provided, defaulting to: $MINIO_SECRET_NAME"
fi

SCRIPT_DIR=$(dirname $0)
LIB_DIR=${SCRIPT_DIR}/lib
. ${LIB_DIR}/utils.sh

# check mc
get_mc ${LIB_DIR}
MC=${LIB_DIR}/mc

#CP4D version-specific setup
if [ $CP4D_VERSION == "35" ]
then
    MINIO_RELEASE_LABEL="$CR_NAME-speech-to-text-minio"
    MINIO_CHART_LABEL="helm.sh/chart=ibm-minio"
    PG_PW_TEMPLATE="{{.data.PG_PASSWORD}}"
    PG_USERNAME="enterprisedb"
    PG_COMPONENT_LABEL="app.kubernetes.io/component=postgres"
elif [ $CP4D_VERSION == "301" ]
then
    MINIO_RELEASE_LABEL="$CR_NAME"
    MINIO_CHART_LABEL="helm.sh/chart=minio"
    PG_PW_TEMPLATE="{{.data.pg_su_password}}"
    PG_USERNAME="stolon"
    PG_COMPONENT_LABEL="component=stolon-proxy"
else
    MINIO_RELEASE_LABEL="$CR_NAME"
    MINIO_CHART_LABEL="helm.sh/chart=ibm-minio"
    PG_PW_TEMPLATE="{{.data.password}}"
    PG_USERNAME="postgres"
    PG_COMPONENT_LABEL="app.kubernetes.io/component=postgres"

    if type "cpdbr" > /dev/null 2>&1; then
	CPDBR=cpdbr
    elif type "${LIB_DIR}/cpdbr" > /dev/null 2>&1; then
	CPDBR=${LIB_DIR}/cpdbr
    else
	echo "downloading cpdbr..."
	get_cpdbr ${LIB_DIR}
	CPDBR=${LIB_DIR}/cpdbr
    fi
fi

#MinIO setup
MINIO_LPORT=9001
MINIO_PORT=9000
TMP_FILENAME="spchtmp_`date '+%Y%m%d_%H%M%S'`"

MINIO_ACCESS_KEY=`kubectl ${KUBECTL_ARGS} get secret $MINIO_SECRET_NAME --template '{{.data.accesskey}}' | base64 --decode`
MINIO_SECRET_KEY=`kubectl ${KUBECTL_ARGS} get secret $MINIO_SECRET_NAME --template '{{.data.secretkey}}' | base64 --decode`
MINIO_SVC=`kubectl ${KUBECTL_ARGS} get svc -l release=$MINIO_RELEASE_LABEL,$MINIO_CHART_LABEL -o jsonpath="{.items[*].metadata.name}" | tr '[[:space:]]' '\n' | grep headless`


#Postgres setup
SQL_PASSWORD=`kubectl ${KUBECTL_ARGS} get secret $PG_SECRET_NAME --template $PG_PW_TEMPLATE | base64 --decode`
PG_POD=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath='{.items[0].metadata.name}' -l $PG_COMPONENT_LABEL,app.kubernetes.io/instance=$CR_NAME | head -n 1`


if [ ${COMMAND} = 'export' ] ; then
    echo "PG_POD:$PG_POD"
    # In pod
    echo "make export dir"
    mkdir -p ${EXPORT_DIR}
    mkdir -p "${EXPORT_DIR}/postgres"
    mkdir -p "${EXPORT_DIR}/minio"

    # block until there are no more jobs in Waiting or Processing state
    wait_for_async_jobs

    if ! $noquiesce
    then
	quiesce_services
    fi

    # ----- POSTGRES -----
    echo "----- Exporting PostgreSQL Database -----"

    # ----- STT CUST -----
    echo "run pg_dump on stt-customization (1/3)"
    DBNAME="stt-customization"
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump --data-only --format=custom -h ${PG_POD} -p 5432 -d stt-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/stt-customization.export.dump
    cmd_check
    #Silently dump a human-readable (hidden) version with schema
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump -h ${PG_POD} -p 5432 -d stt-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/.sttcust-hr.sql 2>/dev/null
    echo "[SUCCESS] $DBNAME $COMMAND"

    # ----- TTS CUST -----
    echo "run pg_dump on tts-customization (2/3)"
    DBNAME="tts-customization"
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump --data-only --format=custom -h ${PG_POD} -p 5432 -d tts-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/tts-customization.export.dump
    cmd_check
    #Silently dump a human-readable (hidden) version with schema
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump -h ${PG_POD} -p 5432 -d tts-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/.ttscust-hr.sql 2>/dev/null
    echo "[SUCCESS] $DBNAME $COMMAND"

    # ----- ASYNC -----
    echo "run pg_dump on stt-async (3/3)"
    DBNAME="stt-async"
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump --data-only --format=custom -h ${PG_POD} -p 5432 -d stt-async -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/stt-async.export.dump
    cmd_check
    #Silently dump a human-readable (hidden) version with schema
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump -h ${PG_POD} -p 5432 -d stt-async -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/.sttasync-hr.sql 2>/dev/null
    echo "[SUCCESS] $DBNAME $COMMAND"

    # ----- MinIO -----
    echo "----- Exporting MinIO Database -----"
    start_minio_port_forward $MINIO_SVC $MINIO_LPORT $MINIO_PORT $TMP_FILENAME

    $MC --insecure config host add speech-minio https://localhost:$MINIO_LPORT ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
    cmd_check

    $MC --insecure cp -r speech-minio/stt-customization-icp ${EXPORT_DIR}/minio
    cmd_check

    stop_minio_port_forward $TMP_FILENAME
    echo "[SUCCESS] minio export"

    if ! $noquiesce
    then
	unquiesce_services
    fi


elif [ ${COMMAND} = 'import' ] ; then

    if [ ! -d "${EXPORT_DIR}" ] ; then
	echo "no export directory: ${EXPORT_DIR}" >&2
	echo "failed to restore" >&2
	exit 1
    fi

    if ! $noquiesce
    then
	quiesce_services
    fi

    # ----- POSTGRES -----
    echo "----- Importing PostgreSQL Database -----"

    # ----- STT CUST -----
    echo "import data to stt-customization (1/3)"
    DBNAME="stt-customization"
    kubectl ${KUBECTL_ARGS} cp ${EXPORT_DIR}/postgres/stt-customization.export.dump ${PG_POD}:/run/stt-customization.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_restore --data-only --format=custom -d stt-customization -U $PG_USERNAME -h ${PG_POD} -p 5432 /run/stt-customization.export.dump"
    cmd_check
    echo "[SUCCESS] $DBNAME $COMMAND"

    # ----- TTS CUST -----
    echo "import data to tts-customization (2/3)"
    DBNAME="tts-customization"
    kubectl ${KUBECTL_ARGS} cp ${EXPORT_DIR}/postgres/tts-customization.export.dump ${PG_POD}:/run/tts-customization.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_restore --data-only --format=custom -d tts-customization -U $PG_USERNAME -h ${PG_POD} -p 5432 /run/tts-customization.export.dump"
    cmd_check
    echo "[SUCCESS] $DBNAME $COMMAND"

    # ----- STT ASYNC -----
    echo "import data to stt-async (3/3)"
    DBNAME="stt-async"
    kubectl ${KUBECTL_ARGS} cp ${EXPORT_DIR}/postgres/stt-async.export.dump ${PG_POD}:/run/stt-async.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_restore --data-only --format=custom -d stt-async -U $PG_USERNAME -h ${PG_POD} -p 5432 /run/stt-async.export.dump"
    cmd_check
    echo "[SUCCESS] $DBNAME $COMMAND"

    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /run/stt-customization.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /run/tts-customization.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /run/stt-async.export.dump

    echo "[SUCCESS] postgres import"

    # ----- MinIO -----
    echo "----- Importing MinIO Database -----"
    start_minio_port_forward $MINIO_SVC $MINIO_LPORT $MINIO_PORT $TMP_FILENAME

    $MC --insecure config host add speech-minio https://localhost:$MINIO_LPORT ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}
    cmd_check

    $MC --insecure cp -r ${EXPORT_DIR}/minio/stt-customization-icp/customizations speech-minio/stt-customization-icp
    cmd_check

    stop_minio_port_forward $TMP_FILENAME
    echo "[SUCCESS] minio import"

    if ! $noquiesce
    then
	unquiesce_services
    fi
fi
