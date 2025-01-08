#!/bin/bash

printUsage() {
    echo "Usage: $(basename ${0}) [import|export]"
    echo "    -c [custom resource name]"
    echo "    -o [import/export directory]"
    echo "    -v [version]: 4.8 (CP4D 4.8.x), 5.0 (CP4D 5.0.x), 5.1 (CP4D 5.1.x)"
    echo "    -p [postgres auth secret name](optional)"
    echo "    -m [s3 auth secret name](optional)"
    echo "    -n [namespace](optional)"
    echo "    -h/--help Show this menu"
    exit 1
}

cmd_check(){
    if [ $? -ne 0 ] ; then
        echo "[FAIL] $DBNAME $COMMAND"
        exit 1
    fi
}

wait_for_async_jobs() {
    sleep_time=2
    max_sleep_time=1800 #30m
    active_job_count=1
    while [ $active_job_count -gt 0 ]
    do
        active_job_count=`kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; psql -t -v -d stt-async -U $PG_USERNAME -h ${PG_POD} -p 5432 -c \"SELECT count(status) FROM jobs WHERE status='Waiting' or status='Processing';\""`
        if [ ${active_job_count:=0} -gt 0 ]; then
            echo "At least 1 async job is in 'Waiting' or 'Processing' state.. performing exponential backoff to wait for jobs to complete before switching async service to read only"
            echo "Sleeping for $sleep_time seconds"
            sleep $sleep_time
            if [ $(($sleep_time**2)) -gt $max_sleep_time ]; then
                sleep_time=$max_sleep_time
            else
                sleep_time=$(($sleep_time**2))
            fi
        fi
    done
}

if [ $# -lt 6 ] ; then
    printUsage
fi

crflag=false
pgsecretflag=false
ossecretflag=false
exportflag=false
versionflag=false

doasync=true
dosttcust=true
dottscust=true

NAMESPACE=zen

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
                help) printUsage; exit 1 ;;
            esac;;
        "h" ) printUsage; exit 1 ;;
        "n" ) NAMESPACE=$OPTARG; KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$NAMESPACE" ;;
        "c" ) crflag=true; CR_NAME=$OPTARG ;;
        "p" ) pgsecretflag=true; PG_SECRET_NAME=$OPTARG ;;
        "m" ) ossecretflag=true; OS_SECRET_NAME=$OPTARG ;;
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

if [ $CP4D_VERSION != "4.8" ] && [ $CP4D_VERSION != "5.0" ] && [ $CP4D_VERSION != "5.1" ]
then
    echo "ERROR: Version flag must be one of [4.8, 5.0, 5.1], was $CP4D_VERSION"
    exit 1
fi

#Use default value for postgres auth secret if not provided
if [ $pgsecretflag = 'false' ]
then
   PG_SECRET_NAME="$CR_NAME-postgres-auth-secret"
   echo "WARNING: No Postgres auth secret provided, defaulting to: $PG_SECRET_NAME"
fi

#Use default value for minio auth secret if not provided
if [ $ossecretflag = 'false' ]
then
    OS_SECRET_NAME="noobaa-account-watson-speech"
    echo "WARNING: No S3 auth secret provided, defaulting to: $OS_SECRET_NAME"
fi


SCRIPT_DIR=$(dirname $0)
LIB_DIR=${SCRIPT_DIR}/lib
. ${LIB_DIR}/utils.sh

# check mc
get_mc ${LIB_DIR}
MC=${LIB_DIR}/mc

#CP4D version-specific setup
MINIO_RELEASE_LABEL="$CR_NAME"
MINIO_CHART_LABEL="helm.sh/chart=ibm-minio"
PG_PW_TEMPLATE="{{.data.password}}"
PG_USERNAME="postgres"
PG_COMPONENT_LABEL="app.kubernetes.io/component=postgres"

#figure out which components are installed
if [[ $(oc ${KUBECTL_ARGS} get watsonspeech $CR_NAME -o jsonpath="{.status.sttAsyncStatus}") = "Not Installed" ]]; then
    doasync=false
fi
if [[ $(oc ${KUBECTL_ARGS} get watsonspeech $CR_NAME -o jsonpath="{.status.sttCustomizationStatus}") = "Not Installed" ]]; then
    dosttcust=false
fi
if [[ $(oc ${KUBECTL_ARGS} get watsonspeech $CR_NAME -o jsonpath="{.status.ttsCustomizationStatus}") = "Not Installed" ]]; then
    dottscust=false
fi

#OS setup
OS_LPORT=8000
TMP_FILENAME="spchtmp_`date '+%Y%m%d_%H%M%S'`"

STT_CUST_BUCKET="stt-customization-icp"

#MinIO setup
MINIO_PORT=9000

#S3 setup
S3_PORT=443
S3_NS="openshift-storage"
S3_SVC="s3"

# ----- S3 -----
echo "----- Using S3 (MCG) Resources -----"
OS_NS=${S3_NS}
OS_PORT=${S3_PORT}
OS_ACCESS_KEY=`kubectl ${KUBECTL_ARGS} get secret $OS_SECRET_NAME --template '{{.data.AWS_ACCESS_KEY_ID}}' | base64 --decode`
OS_SECRET_KEY=`kubectl ${KUBECTL_ARGS} get secret $OS_SECRET_NAME --template '{{.data.AWS_SECRET_ACCESS_KEY}}' | base64 --decode`
OS_SVC=${S3_SVC}

BUCKET_SUFFIX=`$(kubectl ${KUBECTL_ARGS} get watsonspeech $CR_NAME -o jsonpath="{.spec.global.datastores.s3.bucketSuffix}")`
if [[ ${BUCKET_SUFFIX} = '' ]]; then
    BUCKET_SUFFIX="ibm-${CR_NAME}-${NAMESPACE}"
fi
STT_CUST_BUCKET="stt-customization-icp-${BUCKET_SUFFIX}"

#Postgres setup
SQL_PASSWORD=`kubectl ${KUBECTL_ARGS} get secret $PG_SECRET_NAME --template $PG_PW_TEMPLATE | base64 --decode`
PG_POD=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath='{.items[0].metadata.name}' -l $PG_COMPONENT_LABEL,app.kubernetes.io/instance=$CR_NAME | head -n 1`


if [ ${COMMAND} = 'export' ] ; then
    echo "PG_POD:$PG_POD"
    # In pod
    echo "make export dir"
    mkdir -p ${EXPORT_DIR}
    mkdir -p "${EXPORT_DIR}/postgres"
    mkdir -p "${EXPORT_DIR}/s3"

    # block until there are no more jobs in Waiting or Processing state
    if [ $doasync = 'true' ]; then
        wait_for_async_jobs
    fi

    # ----- POSTGRES -----
    echo "----- Exporting PostgreSQL Database -----"

    # ----- STT CUST -----
    if [ $dosttcust = 'true' ]; then
        echo "run pg_dump on stt-customization (1/3)"
        DBNAME="stt-customization"
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump --data-only --format=custom -h ${PG_POD} -p 5432 -d stt-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/stt-customization.export.dump
        cmd_check
        #Silently dump a human-readable (hidden) version with schema
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump -h ${PG_POD} -p 5432 -d stt-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/.sttcust-hr.sql 2>/dev/null
        echo "[SUCCESS] $DBNAME $COMMAND"
    else
        echo "STT Customization is not installed, skipping database."
    fi

    # ----- TTS CUST -----
    if [ $dottscust = 'true' ]; then
        echo "run pg_dump on tts-customization (2/3)"
        DBNAME="tts-customization"
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump --data-only --format=custom -h ${PG_POD} -p 5432 -d tts-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/tts-customization.export.dump
        cmd_check
        #Silently dump a human-readable (hidden) version with schema
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump -h ${PG_POD} -p 5432 -d tts-customization -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/.ttscust-hr.sql 2>/dev/null
        echo "[SUCCESS] $DBNAME $COMMAND"
    else
        echo "TTS Customization is not installed, skipping database."
    fi

    # ----- ASYNC -----
    if [ $doasync = 'true' ]; then
        echo "run pg_dump on stt-async (3/3)"
        DBNAME="stt-async"
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump --data-only --format=custom -h ${PG_POD} -p 5432 -d stt-async -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/stt-async.export.dump
        cmd_check
        #Silently dump a human-readable (hidden) version with schema
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_dump -h ${PG_POD} -p 5432 -d stt-async -U $PG_USERNAME" > ${EXPORT_DIR}/postgres/.sttasync-hr.sql 2>/dev/null
        echo "[SUCCESS] $DBNAME $COMMAND"
    else
        echo "STT Async is not installed, skipping database."
    fi

    # ----- S3 / MCG -----
    echo "----- Exporting MCG Data -----"
    start_os_port_forward $OS_SVC $OS_LPORT $OS_PORT $OS_NS $TMP_FILENAME

    $MC --insecure config host add speech-s3 https://localhost:$OS_LPORT ${OS_ACCESS_KEY} ${OS_SECRET_KEY}
    cmd_check


    $MC --insecure cp -r speech-s3/${STT_CUST_BUCKET} ${EXPORT_DIR}/s3
    cmd_check

    stop_os_port_forward $TMP_FILENAME
    echo "[SUCCESS] MCG export"

elif [ ${COMMAND} = 'import' ] ; then

    if [ ! -d "${EXPORT_DIR}" ] ; then
        echo "no export directory: ${EXPORT_DIR}" >&2
        echo "failed to restore" >&2
        exit 1
    fi

    # ----- POSTGRES -----
    echo "----- Importing PostgreSQL Database -----"

    # ----- STT CUST -----
    if [ $dosttcust = 'true' ]; then
        echo "import data to stt-customization (1/3)"
        DBNAME="stt-customization"
        kubectl ${KUBECTL_ARGS} cp ${EXPORT_DIR}/postgres/stt-customization.export.dump ${PG_POD}:/run/stt-customization.export.dump
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_restore --data-only --format=custom -d stt-customization -U $PG_USERNAME -h ${PG_POD} -p 5432 /run/stt-customization.export.dump"
        cmd_check
        echo "[SUCCESS] $DBNAME $COMMAND"
    else
        echo "STT Customization is not installed, skipping database."
    fi

    # ----- TTS CUST -----
    if [ $dottscust = 'true' ]; then
        echo "import data to tts-customization (2/3)"
        DBNAME="tts-customization"
        kubectl ${KUBECTL_ARGS} cp ${EXPORT_DIR}/postgres/tts-customization.export.dump ${PG_POD}:/run/tts-customization.export.dump
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_restore --data-only --format=custom -d tts-customization -U $PG_USERNAME -h ${PG_POD} -p 5432 /run/tts-customization.export.dump"
        cmd_check
        echo "[SUCCESS] $DBNAME $COMMAND"
    else
        echo "TTS Customization is not installed, skipping database."
    fi

    # ----- STT ASYNC -----
    if [ $doasync = 'true' ]; then
        echo "import data to stt-async (3/3)"
        DBNAME="stt-async"
        kubectl ${KUBECTL_ARGS} cp ${EXPORT_DIR}/postgres/stt-async.export.dump ${PG_POD}:/run/stt-async.export.dump
        kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- bash -c "export PGPASSWORD=$SQL_PASSWORD; pg_restore --data-only --format=custom -d stt-async -U $PG_USERNAME -h ${PG_POD} -p 5432 /run/stt-async.export.dump"
        cmd_check
        echo "[SUCCESS] $DBNAME $COMMAND"
    else
        echo "STT Async is not installed, skipping database."
    fi

    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /run/stt-customization.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /run/tts-customization.export.dump
    kubectl ${KUBECTL_ARGS} exec ${PG_POD} -- rm /run/stt-async.export.dump

    echo "[SUCCESS] postgres import"

    # ----- S3 / MCG -----
    echo "----- Importing MCG Database -----"
    start_os_port_forward $OS_SVC $OS_LPORT $OS_PORT $OS_NS $TMP_FILENAME

    $MC --insecure config host add speech-s3 https://localhost:$OS_LPORT ${OS_ACCESS_KEY} ${OS_SECRET_KEY}
    cmd_check

    $MC --insecure cp -r ${EXPORT_DIR}/s3/$(ls ${EXPORT_DIR}/s3)/customizations speech-s3/${STT_CUST_BUCKET}
    cmd_check

    stop_os_port_forward $TMP_FILENAME
    echo "[SUCCESS] MCG import"

fi
