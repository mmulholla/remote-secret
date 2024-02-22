#!/bin/bash
# Script stress tests creating remote secrets and secrets
# It takes 3 positional parameters
# - number of namespaces to use (default 5)
# - number of remote secret, secret pairs to create for each namespace (default 10)
# - seed value. If running script simultaneously from several windows use a different
#     seed value in each (default 1). Used to ensure namespaces, remote secret and
#     secret names are not duplicated in different windows.
# The script creates the namespace, and then iterates through the secret pairs creating
# the secrets and then waiting for status in the remote secret.

create_resource() {
  RESP=$(kubectl apply -f "$1")
  echo -e "\n$RESP"
}

delete_resource() {
  RESP=$(kubectl delete "$1")
}

check_resource() {
  STATUS=$(kubectl get "$1" -n "$2" -o  json | jq -r .status)
  REASON="null"
  for index in {1..2};
  do
    type=$(echo "$STATUS" | jq -r .conditions[$(($index-1))].type)
    if [[ "$type" == "DataObtained" ]]; then
      REASON=$(echo "$STATUS" | jq -r .conditions[$(($index-1))].reason)
      break
    fi
  done
  echo "$REASON"
}

set_remote_secret_name_and_namespace() {
  RES_FILE=$1
  NAMESPACE=$2
  NAME=$3
  NEW_DIR=$4

  while IFS= read -r line
    do
      if [[ "$line" == *"namespace: "* ]]; then
        ORIG_NAMESPACE=$(echo $line | sed -e 's/^[ -]*//' | sed -e 's/\ *$//g')
      fi
      if [[ "$line" == *"name: "* ]]; then
        ORIG_NAME=$(echo $line | sed -e 's/^[ ]*//' | sed -e 's/\ *$//g')
      fi
    done < "$RES_FILE"

    NEW_FILE="$NEW_DIR/$NAME.yaml"

    sed "s/$ORIG_NAMESPACE/namespace: $NAMESPACE/g" "$RES_FILE" > $NEW_FILE
    sed -i "s/$ORIG_NAME/name: $NAME/" $NEW_FILE
}

set_secret_name_and_namespace() {
  RES_FILE=$1
  NAMESPACE=$2
  NAME=$3
  RS_NAME=$4
  NEW_DIR=$5

  while IFS= read -r line
    do
      if [[ "$line" == *" name: "* ]]; then
        ORIG_NAME=$(echo $line | sed -e 's/^[ ]*//' | sed -e 's/\ *$//g')
      fi
      if [[ "$line" == *"remotesecret-name: "* ]]; then
        ORIG_RS_NAME=$(echo $line | sed -e 's/^[ ]*//' | sed -e 's/\ *$//g')
      fi
    done < "$RES_FILE"

    NEW_RS_NAME="appstudio.redhat.com/remotesecret-name: $RS_NAME"
    NEW_FILE="$NEW_DIR/$NAME.yaml"
    sed "s!$ORIG_NAME!namespace: $NAMESPACE\n  name: $NAME!g" "$RES_FILE" > $NEW_FILE
    sed -i "s!$ORIG_RS_NAME!$NEW_RS_NAME!" $NEW_FILE
}

time_in_mins_and_seconds() {
  total_seconds=$1
  minutes=$(($total_seconds / 60))
  seconds=$(($total_seconds-$(($minutes * 60))))
  echo "$minutes minutes $seconds seconds"
}

NUM_NAMESPACES=5
NUM_SECRETS=10
SEED=1
if [ $# -gt 0 ]; then
  NUM_NAMESPACES=$1
  if [ $# -gt 1 ]; then
    NUM_SECRETS=$2
    if [ $# -gt 2 ]; then
      SEED=$3
    fi
  fi
fi

RS_NAME_PREFIX="test-remote-secret-$SEED-"
S_NAME_PREFIX="test-remote-secret-secret-$SEED-"

RS_FILE="samples/remote-secret.yaml"
S_FILE="samples/remote-secret-secret.yaml"
NS_PREFIX="test-secrets-$SEED-"
TEST_DIR="./.tmp/test"

echo -e "\n\n\n1. Clean up old yaml files if needed"
echo "delete files if needed $TEST_DIR/$RS_NAME_PREFIX*.yaml"
rm "$TEST_DIR/$RS_NAME_PREFIX"*.yaml
echo "delete files if needed $TEST_DIR/$S_NAME_PREFIX*.yaml"
rm "$TEST_DIR/$S_NAME_PREFIX"*.yaml


echo -e "\n2. Create namespaces and yaml files for testing"
for i in $(seq $NUM_NAMESPACES)
do
  NS=$NS_PREFIX$i
  if [[ "$(kubectl get namespace $NS 2>&1)" != *"Error from server (NotFound):"* ]]; then
    kubectl delete namespace $NS 2>&1
  fi
  kubectl create namespace $NS 2>&1
  for j in $(seq $NUM_SECRETS)
  do
    RS_NAME="$RS_NAME_PREFIX$i-$j"
    S_NAME="$S_NAME_PREFIX$i-$j"
    set_remote_secret_name_and_namespace $RS_FILE $NS $RS_NAME $TEST_DIR
    set_secret_name_and_namespace $S_FILE $NS $S_NAME $RS_NAME $TEST_DIR
  done
done

FAILS=()
echo -e "\n3. Create resources in kubernetes"
for j in $(seq $NUM_SECRETS)
do
  for i in $(seq $NUM_NAMESPACES)
  do
    RS_FILE="$TEST_DIR/$RS_NAME_PREFIX$i-$j.yaml"
    S_NAME="$TEST_DIR/$S_NAME_PREFIX$i-$j.yaml"
    create_resource $S_NAME
    create_resource $RS_FILE
    sleep 1
    RS_NAME="remotesecret/$RS_NAME_PREFIX$i-$j"
    tries=0
    REASON="null"
    while [[ "$REASON" == "null" ]]
    do
        REASON=$(check_resource "$RS_NAME" "$NS_PREFIX$i")
        if [[ "$REASON" == "DataFound" ]]; then
            echo "PASS: $RS, Reason: $REASON"
        elif [[ "$REASON" != "null" ]]; then
            FAIL="Reason:$REASON, Namespace:$NS_PREFIX$i, resource:$RS_NAME"
            echo "!!!FAIL: $FAIL"
            FAILS+=( $FAIL )
        elif [ $tries -gt 10 ]; then
            FAIL="Reason:$REASON, Namespace:$NS_PREFIX$i, resource:$RS_NAME"
            echo "!!!FAIL: $FAIL"
            FAILS+=( $FAIL )
            REASON="Not Found"
        else
            tries=$((tries+1))
            sleep 1
        fi
    done
  done
done

if [[ ${#FAILS[@]} > 0 ]]; then
  echo "!!!!There were $(( ${#FAILS[@]} / 3 )) failures - resources will not be deleted"
  for fail in ${FAILS[@]};
  do
    if [[ "$fail" == "Reason"* ]]; then
      if [[ "$fail" == "Reason:null"* ]]; then
        echo -e "\t$fail"
        NULLS=$((NULLS+1))
      else
        OTHERS=$((OTHERS+1))
        echo -e "\n\t!!!!!!!\n\t$fail"
      fi
    else
      echo -e "\t\t$fail"
    fi
  done
  if [ $NULLS -gt 0 ]; then
      echo "$NULLS of ${#FAILS[@]} were due to no status in the remote secret - need longer waits"
  fi
  if [ $OTHERS -gt 0 ]; then
        echo "$OTHERS of ${#FAILS[@]} were due to wrong status in the remote secret - need to investigate"
  fi
else
  echo -e "\n6. All passed so clean up namespaces and yaml files"
  for i in $(seq $NUM_NAMESPACES)
  do
    kubectl delete namespace "$NS_PREFIX$i"
  done
  echo "delete files $TEST_DIR/$RS_NAME_PREFIX*.yaml"
  rm "$TEST_DIR/$RS_NAME_PREFIX"*.yaml
  echo "delete files $TEST_DIR/$S_NAME_PREFIX*.yaml"
  rm "$TEST_DIR/$S_NAME_PREFIX"*.yaml
fi

