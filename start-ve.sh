#!/bin/bash

if [ "$1" = "" ]; then
  echo "ERROR: please supply a VE name."
  echo "USAGE: $0 <VE NAME>"
  exit
fi

for i in `virsh list --all | awk '$2 ~ /^'$1'-/{print $2}'`; do  virsh start $i; done
