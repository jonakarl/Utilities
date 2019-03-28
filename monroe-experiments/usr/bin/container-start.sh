#!/bin/bash
set -e

# Default variables
USERDIR="/experiments/user"
SCHEDID=$1
STATUS=$2
STATUSDIR=$USERDIR
CONTAINER_NAME=monroe-$SCHEDID
NEAT_CONTAINER_NAME=monroe-neat-proxy
EXCLUDED_IF="Br|lo|metadata|wwan|ifb|docker"
OPINTERFACES="nlw_|wwan"

URL_NEAT_PROXY=monroe/neat-proxy
NOERROR_CONTAINER_IS_RUNNING=0
ERROR_CONTAINER_DID_NOT_START=10
ERROR_NETWORK_CONTEXT_NOT_FOUND=11
ERROR_IMAGE_NOT_FOUND=12
ERROR_MAINTENANCE_MODE=13

# Update above default variables if needed 
. /etc/default/monroe-experiments

echo -n "Checking for maintenance mode... "
MAINTENANCE=$(cat /monroe/maintenance/enabled || echo 0)
if [ $MAINTENANCE -eq 1 ]; then
   echo 'failed; node is in maintenance mode.' > $STATUSDIR/$SCHEDID.status
   echo "enabled."
   exit $ERROR_MAINTENANCE_MODE
fi
echo "disabled."


if [ -f $USERDIR/$SCHEDID.conf ]; then
  CONFIG=$(cat $USERDIR/$SCHEDID.conf);
  IS_INTERNAL=$(echo $CONFIG | jq -r '.internal // empty');
  IS_SSH=$(echo $CONFIG | jq -r '.ssh // empty');
  BDEXT=$(echo $CONFIG | jq -r '.basedir // empty');
  EDUROAM_IDENTITY=$(echo $CONFIG | jq -r '._eduroam.identity // empty');
  EDUROAM_HASH=$(echo $CONFIG | jq -r '._eduroam.hash // empty');
  IS_VM=$(echo $CONFIG | jq -r '.vm // empty');
  NEAT_PROXY=$(echo $CONFIG | jq -r '.neat // empty');
else
  echo "No config file found ($USERDIR/$SCHEDID.conf )" 
  exit $ERROR_IMAGE_NOT_FOUND
fi

if [ ! -z "$IS_INTERNAL" ]; then
  BASEDIR=/experiments/monroe${BDEXT}
  echo $CONFIG > $BASEDIR/$SCHEDID.conf
else
  BASEDIR=$USERDIR
fi

exec &> >(tee -a $BASEDIR/$SCHEDID/start.log) || {
   echo "Could not create log file $BASEDIR/$SCHEDID/start.log"
   exit $ERROR_IMAGE_NOT_FOUND
}

echo -n "Ensure network and containers are set up... "
systemctl -q is-active monroe-namespace.service 2>/dev/null || {
  echo "Monroe Namespace is down"
  exit $ERROR_NETWORK_CONTEXT_NOT_FOUND
}

IMAGEID=$(docker images -q --no-trunc $CONTAINER_NAME)
if [ -z "$IMAGEID" ]; then
    echo "experiment container not found."
    exit $ERROR_IMAGE_NOT_FOUND;
fi

# check that this container is not running yet
if [ ! -z "$(docker ps | grep $CONTAINER_NAME)" ]; then
    echo "already running."
    exit $NOERROR_CONTAINER_IS_RUNNING;
fi

# check that this container name is not used
if [ ! -z "$(docker ps -a | grep $CONTAINER_NAME)" ]; then
    echo "already exists(stopped)."
    exit $ERROR_CONTAINER_DID_NOT_START;
fi

# Container boot counter and measurement UID

COUNT=$(cat $BASEDIR/${SCHEDID}.counter 2>/dev/null || echo 0)
COUNT=$(($COUNT + 1))
echo $COUNT > $BASEDIR/${SCHEDID}.counter

if [ -e /etc/nodeid.n2 ]; then
  NODEIDFILE="/etc/nodeid.n2"
elif [ -e /etc/nodeid ]; then 
  NODEIDFILE="/etc/nodeid"
else
  NODEIDFILE="/etc/hostname"
fi
NODEID=$(<$NODEIDFILE)

GUID="${IMAGEID}.${SCHEDID}.${NODEID}.${COUNT}"
# replace guid in the configuration

CONFIG=$(echo $CONFIG | jq '.guid="'$GUID'"|.nodeid="'$NODEID'"')
echo $CONFIG > $BASEDIR/$SCHEDID.conf
echo "ok."

# setup eduroam if available

if [ ! -z "$EDUROAM_IDENTITY" ] && [ -x /usr/bin/eduroam-login.sh ] && [ ! -z "$EDUROAM_HASH" ]; then
    /usr/bin/eduroam-login.sh $EDUROAM_IDENTITY $EDUROAM_HASH & 
fi
# TODO: Error code if eduroam does not exist and robustify 

### PYCOM 
if [ -x "/usr/bin/ykushcmd" ];then 
    # Power up all yepkit ports (assume pycom is only used for yepkit)"
    # TODO: detect if yepkit is there and optionally which port a pycom device is attached to
    echo "Power up all ports of the yepkit"
    for port in 1 2 3; do
        /usr/bin/ykushcmd -u $port || echo "Could not power up yepkit port : $port"
    done
    sleep 30 
fi

# Reset pycom devices if they exist
PYCOM_DIR="/dev/pycom"
MOUNT_PYCOM=""
if [ -d "$PYCOM_DIR" ] && [ -x /usr/bin/factory-reset-pycom.py ]; then
    echo "Trying to factory reset the board(s) (timeout 30 seconds per board)"
    for board in $(ls $PYCOM_DIR); do
    	timeout 35 /usr/bin/factory-reset-pycom.py --device $PYCOM_DIR/$board --wait 30 --baudrate 115200 || true
	    MOUNT_PYCOM="${MOUNT_PYCOM} --device $PYCOM_DIR/$board"
    done
fi
###

### NEAT PROXY #################################################
# Cleanup of old existing rules if any 
rm -f /etc/circle.d/60-*-neat-proxy.rules || true
## Stop the neat proxy container if any 
docker stop --time=10 $NEAT_CONTAINER_NAME 2>/dev/null || true

if [ ! -z "$NEAT_PROXY"  ] && [ -x /usr/bin/monroe-neat-init ]; then
  NEAT_PROXY_PATH=$BASEDIR/$SCHEDID/neat-proxy/
  /usr/bin/monroe-neat-init $NEAT_PROXY_PATH
  circle start
fi
##################################################################

### Let modems rest for a while = idle period
MODEMS="$(ls /sys/class/net/|egrep -v $EXCLUDED_IF) | egrep $OPINTERFACES" || true
if [ ! -z "$MODEMS" ]; then   
  # drop all network traffic for 30 seconds (idle period)
  nohup /bin/bash -c 'sleep 35; circle start' > /dev/null &
  iptables -F
  iptables -P INPUT DROP
  iptables -P OUTPUT DROP
  iptables -P FORWARD DROP
  sleep 30
  circle start
fi
###

### START THE CONTAINER/VM ###############################################

echo -n "Starting container... "
if [ -d $BASEDIR/$SCHEDID ]; then
    MOUNT_DISK="-v $BASEDIR/$SCHEDID:/monroe/results -v $BASEDIR/$SCHEDID:/outdir"
fi
if [ -d /experiments/monroe/tstat ]; then
    TSTAT_DISK="-v /experiments/monroe/tstat:/monroe/tstat:ro"
fi

if [ ! -z "$IS_SSH" ]; then
    OVERRIDE_ENTRYPOINT=" --entrypoint=dumb-init "
    OVERRIDE_PARAMETERS=" /bin/bash /usr/bin/monroe-sshtunnel-client.sh "
fi

cp /etc/resolv.conf $BASEDIR/$SCHEDID/resolv.conf.tmp

if [ ! -z "$IS_VM" ] && [ -x /usr/bin/vm-deploy.sh ] && [ -x /usr/bin/vm-start.sh ]; then
    echo "Container is a vm, trying to deploy... "
    /usr/bin/vm-deploy.sh $SCHEDID
    echo -n "Copying vm config files..."
    VM_CONF_DIR=$BASEDIR/$SCHEDID.confdir
    mkdir -p $VM_CONF_DIR
    cp $BASEDIR/$SCHEDID/resolv.conf.tmp $VM_CONF_DIR/resolv.conf
    cp $BASEDIR/$SCHEDID.conf $VM_CONF_DIR/config
    cp $NODEIDFILE $VM_CONF_DIR/nodeid
    cp /tmp/dnsmasq-servers-netns-monroe.conf $VM_CONF_DIR/dns
    echo "ok."

    echo "Starting VM... "
    # Kicking alive the vm specific stuff
    /usr/bin/vm-start.sh $SCHEDID $OVERRIDE_PARAMETERS
    echo "vm started." 
    CID=""
    PNAME="kvm"
    CONTAINER_TECHONOLOGY="vm"
    PID="$(cat $BASEDIR/$SCHEDID.pid)" || true
else
    MONROE_NAMESPACE="$(docker ps --no-trunc -qf name=$MONROE_NAMESPACE_CONTAINER_NAME)"
    CID_ON_START=$(docker run -d $OVERRIDE_ENTRYPOINT  \
           --name=$CONTAINER_NAME \
           --net=container:$MONROE_NAMESPACE \
           --cap-add NET_ADMIN \
           --cap-add NET_RAW \
           --shm-size=1G \
           -v $BASEDIR/$SCHEDID/resolv.conf.tmp:/etc/resolv.conf \
           -v $BASEDIR/$SCHEDID.conf:/monroe/config:ro \
           -v ${NODEIDFILE}:/nodeid:ro \
           -v /tmp/dnsmasq-servers-netns-monroe.conf:/dns:ro \
           $MOUNT_PYCOM \
           $MOUNT_DISK \
           $TSTAT_DISK \
           $CONTAINER_NAME $OVERRIDE_PARAMETERS)
	  # CID: the runtime container ID
    echo "ok."
    CID=$(docker ps --no-trunc | grep "$CONTAINER_NAME" | awk '{print $1}' | head -n 1)
    PID=""
    PNAME="docker"
    CONTAINER_TECHONOLOGY="container"
    if [ ! -z "$CID" ]; then
      PID=$(docker inspect -f '{{.State.Pid}}' $CID) || true
      echo $PID > $BASEDIR/$SCHEDID.pid
    fi
fi

if [ -x /usr/bin/usage-defaults ]; then 
  # start accounting
  echo "Starting accounting."
  /usr/bin/usage-defaults 2>/dev/null || true
fi

if [ ! -z "$PID" ]; then
  echo "Started $PNAME process $CID $PID."
else
  echo "failed; $CONTAINER_TECHONOLOGY exited immediately" > $STATUSDIR/$SCHEDID.status
  echo "$CONTAINER_TECHONOLOGY exited immediately."
  if [ -z "$IS_VM" ]; then
    echo "Log output:"
    docker logs -t $CID_ON_START || true
  fi
  exit $ERROR_CONTAINER_DID_NOT_START;  #Different exit code for VM?
fi

if [ -z "$STATUS" ]; then
  echo 'started' > $STATUSDIR/$SCHEDID.status
else
  echo $STATUS > $STATUSDIR/$SCHEDID.status
fi

[ -x /usr/bin/sysevent ] && sysevent -t Scheduling.Task.Started -k id -v $SCHEDID
echo "Startup finished $(date)."
