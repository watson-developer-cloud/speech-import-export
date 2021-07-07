printUsage() {
    echo "Usage: $(basename ${0}) [old deployment instance id] [new deployment instance id] [CR Name] [Postgres auth secret name] [-n namespace]"
    exit 1
}

cmd_check(){
  if [ $? -ne 0 ] ; then
    echo "[FAIL] $DBNAME $COMMAND"
    exit 1
  fi
}

convert_instanceid_to_uuid() {
    local slice1=`echo $1 | cut -c1-4`
    local slice2=`echo $1 | cut -c5-`
    local uuid=`printf "00000000-0000-0000-%s-%s" $slice1 $slice2`
    echo "$uuid"
}

if [ $# -lt 4 ] ; then
  printUsage
fi

SOURCE_ID=$1
shift
DEST_ID=$1
shift
CR_NAME=$1
shift
SECRET_NAME=$1
shift
while getopts f:n: OPT
do
  case $OPT in
    "n" ) KUBECTL_ARGS="${KUBECTL_ARGS} --namespace=$OPTARG" ;;
  esac
done

#convert instance id to uuid
source_uuid=$(convert_instanceid_to_uuid ${SOURCE_ID})
dest_uuid=$(convert_instanceid_to_uuid ${DEST_ID})

PG_POD=`kubectl ${KUBECTL_ARGS} get pods -o jsonpath='{.items[0].metadata.name}' -l app.kubernetes.io/component=postgres,app.kubernetes.io/instance=$CR_NAME | head -n 1`
SQL_PASSWORD=`kubectl ${KUBECTL_ARGS} get secret $SECRET_NAME --template '{{.data.password}}' | base64 --decode`

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
