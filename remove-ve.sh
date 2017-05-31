#!/bin/bash

if [ "$1" = "" ]; then
  echo "ERROR: please supply a VE name."
  echo "USAGE: $0 <VE NAME>"
  exit
fi
VEPREFIX=$1

# Get current state of the host
VEDISPLAY=`virsh list --all|awk 'NR == 1 || NR == 2 || $2 ~ /'$VEPREFIX'/ {print}'`
VNETDISPLAY=`virsh net-list --all|awk 'NR == 1 || NR == 2 || $1 ~ /'$VEPREFIX'/ {print}'`
VELIST=`echo "$VEDISPLAY"| awk '$2~/^'$VEPREFIX'-/{print $2}'`
VNETS=`echo "$VNETDISPLAY" | awk '$1 ~ /^'$VEPREFIX'-/{print $1}'`
VECT=`echo "$VELIST"|wc -l`
if [ "$VELIST" != "" ] && [ "$VECT" -gt 0 ] || [ "$VNETS" != "" ]; then
  echo "The following VMs for virtual environment \"$VEPREFIX\" are currently configured on the system:"
  echo "$VEDISPLAY"
  echo ""
  echo "The following networks for virtual environment \"$VEPREFIX\" are currently configured on the system:"
  echo "$VNETDISPLAY"
  echo "Continuing with this installation process will destroy and remove these VMs."
  echo -n "Continue? [y/N]"
  # read -N 1 c
  read -n 2 c
  echo
  if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
    echo "Removing existing virtual environment \"$VEPREFIX\"..."
    for i in $VELIST; do
      [ "`virsh domstate $i`" != "shut off" ] && virsh destroy $i
      virsh undefine $i
    done
    echo
    echo "Removing virtual network bridges for VMs..."
    for i in m0102 o0102 o0304 lnet; do
      virsh net-destroy $VEPREFIX-$i
      virsh net-undefine $VEPREFIX-$i
    done
  else
    echo "Cancelled. Exit."
    exit
  fi
fi

