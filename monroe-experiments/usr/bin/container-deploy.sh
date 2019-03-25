#!/bin/bash

echo "redirecting all output to the following locations:"
echo " - /tmp/container-deploy until an experiment directory is created"
echo " - experiment/deploy.log after that."

rm /tmp/container-deploy 2>/dev/null
exec > /tmp/container-deploy 2>&1
set -e

SCHEDID=$1
CONTAINER_URL=$2 # may be empty, just for convenience of starting manually.

BASEDIR=/experiments/user
STATUSDIR=$BASEDIR
mkdir -p $BASEDIR

ERROR_CONTAINER_NOT_FOUND=100
ERROR_INSUFFICIENT_DISK_SPACE=101
ERROR_QUOTA_EXCEEDED=102
ERROR_MAINTENANCE_MODE=103
ERROR_CONTAINER_DOWNLOADING=104
ERROR_EXPERIMENT_IN_PROGRESS=105

echo -n "Checking for maintenance mode... "
MAINTENANCE=$(cat /monroe/maintenance/enabled || echo 0)
if [ $MAINTENANCE -eq 1 ]; then
  echo "enabled."
  exit $ERROR_MAINTENANCE_MODE;
fi
echo "disabled."


# Check if we have sufficient resources to deploy this container.
# If not, return an error code to delay deployment.

if [ -f $BASEDIR/$SCHEDID.conf ]; then
  CONFIG=$(cat $BASEDIR/$1.conf);
  QUOTA_DISK=$(echo $CONFIG | jq -r .storage);
  [ -z $CONTAINER_URL ] && CONTAINER_URL=$(echo $CONFIG | jq -r .script);
  IS_INTERNAL=$(echo $CONFIG | jq -r '.internal // empty');
  BDEXT=$(echo $CONFIG | jq -r '.basedir // empty');
  #VM_PRE_DEPLOY=$(echo $CONFIG | jq -r '.vm_pre_deploy // empty');
fi
if [ ! -z "$IS_INTERNAL" ]; then
  BASEDIR=/experiments/monroe${BDEXT}
fi
mkdir -p $BASEDIR

if [ -z "$QUOTA_DISK" ]; then
  QUOTA_DISK=10000000;
fi;
QUOTA_DISK_KB=$(( $QUOTA_DISK / 1000 ))

echo -n "Checking for disk space... "
DISKSPACE=$(df /var/lib/docker --output=avail|tail -n1)
if (( "$DISKSPACE" < $(( 100000 + $QUOTA_DISK_KB )) )); then
    exit $ERROR_INSUFFICIENT_DISK_SPACE;
fi
echo "ok."

echo -n "Checking for running experiments... "
/usr/bin/experiments && exit $ERROR_EXPERIMENT_IN_PROGRESS
echo "ok."

echo -n "Checking if a deployment is ongoing... "
DEPLOYMENT=$(ps ax|grep docker|grep pull||true)
if [ -z "$DEPLOYMENT" ]; then
  echo -n "no."

  if [ -z "$(iptables-save | grep -- '-A OUTPUT -p tcp -m tcp --dport 443 -m owner --gid-owner 0 -j ACCEPT')" ]; then
    iptables -w -I OUTPUT 1 -p tcp --destination-port 443 -m owner --gid-owner 0 -j ACCEPT
    iptables -w -Z OUTPUT 1
    iptables -w -I INPUT 1 -p tcp --source-port 443 -j ACCEPT
    iptables -w -Z INPUT 1
  fi

elif [[ "$DEPLOYMENT" == *"$CONTAINER_URL"* ]]; then
  echo -n "yes, this container is being loaded in the background"
else
  echo -n "yes, delaying the download"
  exit $ERROR_CONTAINER_DOWNLOADING
fi

# FIXME: quota monitoring does not work with a background process

sysevent -t Scheduling.Task.Deploying -k id -v $SCHEDID

echo -n "Pulling container..."
# try for 30 minutes to pull the container, send to background
timeout 1800 docker pull $CONTAINER_URL &
PROC_ID=$!

# check results every 10 seconds for 60 seconds, or continue next time
for i in $(seq 1 6); do
  sleep 10
  if kill -0 "$PROC_ID" >/dev/null 2>&1; then
    echo -n "."
    continue
  fi
  break
done

if kill -0 "$PROC_ID" >/dev/null 2>&1; then
  echo -n ". delayed; continuing in background.";
  exit $ERROR_CONTAINER_DOWNLOADING;
fi

# the download finished. Do accounting and clear iptables rules
if [ ! -z "$(iptables-save | grep -- '-A OUTPUT -p tcp -m tcp --dport 443 -m owner --gid-owner 0 -j ACCEPT')" ]; then
  SENT=$(iptables -vxL OUTPUT 1 | awk '{print $2}')
  RECEIVED=$(iptables -vxL INPUT 1 | awk '{print $2}')
  SUM=$(($SENT + $RECEIVED))

  iptables -w -D OUTPUT -p tcp --destination-port 443 -m owner --gid-owner 0 -j ACCEPT   || true
  iptables -w -D INPUT  -p tcp --source-port 443 -j ACCEPT                               || true
else
  echo "debug: could not find acounting rule"
  iptables-save | grep 443 || true
fi

# these two are acceptable:
# exit code 0   = successful wait
# exit code 127 = PID does not exist anymore.

wait $PROC_ID || {
  EXIT_CODE=$?;
  echo "exit code $EXIT_CODE";
  if [ $EXIT_CODE -ne 127 ]; then
      exit $ERROR_CONTAINER_NOT_FOUND;
  fi
}

#retag container image with scheduling id and remove the URL tag
docker tag $CONTAINER_URL monroe-$SCHEDID
docker rmi $CONTAINER_URL

# check if storage quota is exceeded - should never happen
if [ ! -z "$SUM" ]; then
  if [ "$SUM" -gt "$QUOTA_DISK" ]; then
    docker rmi monroe-$SCHEDID || true;
    echo  "quota exceeded ($SUM)."
    exit $ERROR_QUOTA_EXCEEDED;
  fi
fi
echo  "ok."

echo -n "Creating file system... "

EXPDIR=$BASEDIR/$SCHEDID
if [ ! -d $EXPDIR ]; then
    mkdir -p $EXPDIR;
    dd if=/dev/zero of=$EXPDIR.disk bs=1000 count=$QUOTA_DISK_KB;
    mkfs.ext4 $EXPDIR.disk -F -L $SCHEDID;
fi
mountpoint -q $EXPDIR || {
    mount -t ext4 -o loop,data=journal,nodelalloc,barrier=1 $EXPDIR.disk $EXPDIR;
}

# We have a VM that wants to be pre-deployed
# Default off as the conversion might consume too much diskpace
if [ ! -z "$VM_PRE_DEPLOY" ]; then
    /usr/bin/vm-deploy.sh $SCHEDID
fi

if [[ ! -z "$SUM" ]]; then
  JSON=$( echo '{}' | jq .deployment=$SUM )
  echo $JSON > $STATUSDIR/$SCHEDID.traffic
fi
echo "ok."

echo "Deployment finished $(date)".
sysevent -t Scheduling.Task.Deployed -k id -v $SCHEDID
# moving deployment files and switching redirects
cat /tmp/container-deploy >> $EXPDIR/deploy.log
rm /tmp/container-deploy
