#!/bin/bash
#This script should always be run, as long as the container is deployed.

SCHEDID=$1
STATUS=$2
CONTAINER=monroe-$SCHEDID

BASEDIR=/experiments/user
STATUSDIR=$BASEDIR
USAGEDIR=/monroe/usage/netns

MNS="ip netns exec monroe"
VTAPPREFIX=mvtap-
VM_TMP_FILE=/experiments/virtualization.rd/$SCHEDID.tar_dump

if [ -f $BASEDIR/$SCHEDID.conf ]; then
  CONFIG=$(cat $BASEDIR/$SCHEDID.conf);
  IS_INTERNAL=$(echo $CONFIG | jq -r '.internal // empty');
  STARTTIME=$(echo $CONFIG | jq -r '.start // empty');
  BDEXT=$(echo $CONFIG | jq -r '.basedir // empty');
  EDUROAM_IDENTITY=$(echo $CONFIG | jq -r '._eduroam.identity // empty');
  IS_VM=$(echo $CONFIG | jq -r '.vm // empty');
  NEAT_PROXY=$(echo $CONFIG | jq -r '.neat // empty');
fi
if [ ! -z "$IS_INTERNAL" ]; then
  BASEDIR=/experiments/monroe${BDEXT}
fi

VM_OS_DISK=/var/lib/docker/scratch/virtualization/image-$SCHEDID.qcow2

exec > /tmp/cleanup.log 2>&1

CID=$( docker ps -a | grep $CONTAINER | awk '{print $1}' )

echo "Finalize accounting."
/usr/bin/usage-defaults


echo -n "Stopping container... "
if [ $(docker inspect -f "{{.State.Running}}" $CID 2>/dev/null) ]; then
  RUNNING=$(docker inspect $CID|jq -r .[].State.Status)
  if [ "$RUNNING" == "exited" ]; then
    if [ -z "$STATUS" ]; then
      STATUS="finished"
    fi
  fi

  docker stop --time=10 $CID;
  echo "stopped:"
  docker inspect $CID|jq .[].State
else
  echo "Container is no longer running.";
fi

if [[ -f $BASEDIR/$SCHEDID.pid && -z "$RUNNING" ]]; then 
  echo -n "Killing vm (if any)... "
  PID=$(cat $BASEDIR/$SCHEDID.pid)
  kill -9 $PID  # Should be more graceful maybe
  echo "ok."
fi


if [[ -f $VM_OS_DISK ]]; then # This file should always be here normaly
  echo -n "Deleting OS disk... "
  rm -f $VM_OS_DISK 
  echo "ok."
fi

if [[ -f $VM_TMP_FILE ]]; then # This file should NOT be here normaly 
  echo -n "Deleting ramdisk file... "
  rm -f $VM_TMP_FILE 
  echo "ok."
fi

VMIFHASH="$(cat $BASEDIR/$SCHEDID.vmifhash) 2>/dev/null"
if [[ ! -z "$VMIFHASH" ]]; then
  VTAPS=$($MNS ls /sys/class/net/|grep "${VTAPPREFIX}${VMIFPREFIX}-")
  if [[ ! -z "$VTAPS" ]]; then 
    echo -n "Deleting vtap interfaces in $MNS..."
    for IFNAME in $VTAPS; do
      echo -n "${IFNAME}..."
      $MNS ip link del ${IFNAME}
    done
    echo "ok."
  fi
fi

if [ -f "/usr/bin/ykushcmd" ];then
  # Power off yepkit (assume we use yepkit only for pycom)
  PYCOM_DIR="/dev/pycom"
  if [ -d "$PYCOM_DIR" ]; then
    for port in 1 2 3; do
        /usr/bin/ykushcmd -d $port || echo "Could not down yepkit port : $port"
    done
  fi
fi
## Disable NEAT proxy ###
if [[ ! -z "$NEAT_PROXY" ]]; then # If this is a experiment using the neat-proxy
  rm -f /etc/circle.d/60-*-neat-proxy.rules
  circle start
  ## Stop the neta proxy container 
  docker stop --time=10 monroe-neat-proxy
fi

sysevent -t Scheduling.Task.Stopped -k id -v $SCHEDID

if [ -d $BASEDIR/$SCHEDID ]; then
  if [ -z "$IS_VM" ]; then 
    echo "Retrieving container logs:"
    if [ ! -z "$CID" ]; then
      docker logs -t $CID &> $STATUSDIR/$SCHEDID/container.log;
    else
      echo "CID not found for $CONTAINER." > $STATUSDIR/$SCHEDID/container.log;
    fi
    echo ""
  fi
  if [ ! -z "$STARTTIME" ]; then
    echo "Retrieving dmesg events:"
    dmesg|awk '{time=0 + substr($1,2,length($1)-2); if (time > '$STARTTIME') print $0}'
    echo ""
  fi

  echo -n "Syncing traffic statistics... "
  monroe-user-experiments;
  TRAFFIC=$(cat $STATUSDIR/$SCHEDID.traffic)

  for i in $(ls $USAGEDIR/$SCHEDID/*.rx.total|sort); do
    MACICCID=$(basename $i | sed -e 's/\..*//g')
    TRAFFIC=$(echo "$TRAFFIC" | jq ".interfaces.\"$MACICCID\"=$(cat $USAGEDIR/$SCHEDID/$MACICCID.total)")
  done;
  if [ ! -z "$TRAFFIC" ]; then
    echo "$TRAFFIC" > $STATUSDIR/$SCHEDID.traffic
    echo "$TRAFFIC" > $STATUSDIR/$SCHEDID/container.stat
  fi
  echo "ok."
fi

if [ -z "$STATUS" ]; then
  echo 'stopped' > $STATUSDIR/$SCHEDID.status;
else
  echo $STATUS > $STATUSDIR/$SCHEDID.status;
fi

echo -n "Untagging container image... "
REF=$( docker images | grep $CONTAINER | awk '{print $3}' )
if [ -z "$REF" ]; then
  echo "Container is no longer deployed.";
else
  docker rmi -f $CONTAINER
fi
echo "ok."

echo -n "Cleaning unused container images... "
# remove all stopped containers (remove all, ignore errors when running)
docker rm $(docker ps -aq) 2>/dev/null
# clean any untagged containers without dependencies (unused layers)
docker rmi $(docker images -a|grep '^<none>'|awk "{print \$3}") 2>/dev/null
echo "ok."

if [ ! -z "$EDUROAM_IDENTITY" ]; then
    echo -n "Deleting EDUROAM credentials... "
    rm /etc/wpa_supplicant/wpa_supplicant.eduroam.conf
    pkill wpa_supplicant
    iwconfig wlan0 ap 00:00:00:00:00:00
    ifconfig wlan0 0.0.0.0 down
    echo "ok."
fi

echo -n "Syncing results... "
if [ ! -z "$IS_INTERNAL" ]; then
    monroe-rsync-results;
    rm $BASEDIR/$SCHEDID/container.*
else
    cat /tmp/cleanup.log > $BASEDIR/$SCHEDID/cleanup.log
    echo "(end of public log)"
    monroe-user-experiments;  #rsync all remaining files
fi
echo "ok."

echo -n "Cleaning files... "
# any other file should be rsynced by now

umount $BASEDIR/$SCHEDID
rmdir  $BASEDIR/$SCHEDID
# .traffic and .status should be kept (are deleted by external scripts after read)
mv     $STATUSDIR/${SCHEDID}.traffic  $STATUSDIR/${SCHEDID}-traffic
mv     $STATUSDIR/${SCHEDID}.status  $STATUSDIR/${SCHEDID}-status
rm -rf $BASEDIR/${SCHEDID}.*
mv     $STATUSDIR/${SCHEDID}-traffic  $STATUSDIR/${SCHEDID}.traffic_
mv     $STATUSDIR/${SCHEDID}-status  $STATUSDIR/${SCHEDID}.status
rm -r  $USAGEDIR/monroe-${SCHEDID}
echo "ok."

echo -n "restorting firewall and modem state"
circle restart
for ip4table in $(modems|jq .[].ip4table); do
  curl -s -X POST http://localhost:88/modems/${ip4table}/usbreset;
done
echo "ok."

echo "Cleanup finished $(date)."
