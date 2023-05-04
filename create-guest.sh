#!/bin/bash

# MAC Address:
# base=02:EE:22:73: (example)
# MDS: $base:11:XY -- X == MDS number, Y == i/f number for MDS X
# OSS: $base:22:XY -- X == OSS number, Y == i/f number for OSS X
# Compute: $base:33:XY -- X == Client number, Y == i/f number for Client X
# Admin and misc: $base:00:XY -- X == server number, Y == i/f num for server X
#
# Limitations: because of the way in which the MAC address is currently
# generated, and the decimal numbering of the hosts, there is a limit of
# nine of any host type.

function usage {
  echo "USAGE: $0 -d <VM BASE DIR> -l <PRIMARY BRIDGE> -m <PRI MAC> -M <SEC MAC> -n <VE NAME> -N <GUEST NAME> -p <PRIMARY SUBNET> -g <PRIMARY GATEWAY> -s <SECONDARY SUBNET> -r <REPO URL> [-D <DISK SIZE>] [-S <MEM>]"
  echo "  VM BASE DIR: base directory for storing VM disk images"
  echo "  PRIMARY BRIDGE: (default: virbr0) the virtual switch "
  echo "      providing a bridge to a LAN on the host."
  echo "  PRI MAC: 48-bit MAC address for primary network interface
  echo "  SEC MAC: 48-bit MAC address for secondary network interface
  echo "  VE NAME: Name of virtual environment, e.g. st01, ieel, demo"
  echo "  GUEST NAME: Host name suffix, e.g. c1, oss1, mds1"
  echo "  PRIMARY SUBNET: subnet for enp1s0, in CIDR notation, e.g. 10.70.73.0/16"
  echo "  PRIMARY GATEWAY: gateway (IPv4 address) for enp1s0"
  echo "  SECONDARY SUBNET: subnet for eth1, in CIDR notation, e.g. 192.168.73.0/24"
  echo "  REPO URL: URL for operating system repository."
  echo "  DISK SIZE: size of root disk. Default: 10G"
  echo "  MEM: Size of memory allocation for the VM in MB. Default: 3072"
}

VMROOT=""
PRIBRIDGE="virbr0"
MAC=""
VEPREFIX=""
GUESTNM=""
PRIMARY_NET=""
PRIMARY_GW=""
SECONDARY_NET=""
REPO_URL=""
DISKSIZE="10G"
MEM=3072

while getopts :d:l:m:M:n:N:p:g:s:r:D: opt; do
  case $opt in
    d)
      VMROOT="$OPTARG"
      ;;
    D)
      DISKSIZE="$OPTARG"
      ;;
    l)
      PRIBRIDGE="$OPTARG"
      ;;
    m)
      PRI_MAC="$OPTARG"
      ;;
    M)
      SEC_MAC="$OPTARG"
      ;;
    n)
      VEPREFIX="$OPTARG"
      ;;
    N)
      GUESTNM="$OPTARG"
      ;;
    p)
      PRIMARY_NET="$OPTARG"
      ;;
    g)
      PRIMARY_GW="$OPTARG"
      ;;
    s)
      SECONDARY_NET="$OPTARG"
      ;;
    r)
      REPO_URL="$OPTARG"
      ;;
    S)
      MEM="$OPTARG"
      ;;
    ?|:)
      usage
      exit
      ;;
  esac
done

if [ "$VMROOT" = "" ] || [ "$PRIBRIDGE" = "" ] || [ "$PRI_MAC" = "" ] || [ "$VEPREFIX" = "" ] || [ "$PRIMARY_NET" = "" ] || [ "$REPO_URL" = "" ] || [ "$GUESTNM" = "" ]; then
  usage
  exit
fi

if [ "$PRIMARY_GW" = "" ]; then
  PRIMARY_GW="0.0.0.0"
fi

# Full name of Guest VM
VMNM="$VEPREFIX-$GUESTNM"

# Get current state of the host and destroy any pre-existing VM with matching name.
VEDISPLAY=`virsh list --all|awk 'NR == 1 || NR == 2 || $2 ~ /'$VMNM'$/ {print}'`
VELIST=`echo "$VEDISPLAY"| awk '$2~/^'$VMNM'$/{print $2}'`
VECT=`echo "$VELIST"|wc -l`

if [ "$VELIST" != "" ] && [ "$VECT" -gt 0 ]; then
  echo "A VM with name \"$VMNM\" is already configured on the system:"
  echo
  echo "$VEDISPLAY"
  echo
  echo "Continuing with this installation process will destroy and remove this VM."
  echo -n "Continue? [y/N]"
  # read -N 1 c
  read -n 2 c
  echo
  if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
    echo "Removing existing virtual machine \"$VMNM\"..."
      [ "`virsh domstate $VMNM`" != "shut off" ] && virsh destroy $VMNM
      virsh undefine $VMNM
    echo
  else
    echo "Cancelled. Exit."
    exit
  fi
fi

# Root directory for disk images
VMROOT="$VMROOT/$VEPREFIX-ve"
mkdir -m 0755 -p $VMROOT

# Strip the last octect from the SUBNET.
# Script will only use the last octet for assigning addresses to hosts.
PRIMARY_SUBNET_MASK=`echo $PRIMARY_NET|awk -F/ '{i=int($NF / 8); for (j=1;j<=i;j++)printf("255."); for (j=1;j<=4-i;j++) if (j<4-i) {printf "0."} else { printf "0"}} END{printf"\n"}'`
PRIMARY_NET=`echo $PRIMARY_NET|awk -F/ '{print $1}'`
if [ "$SECONDARY_NET" != "" ]; then
  SECONDARY_SUBNET_MASK=`echo $SECONDARY_NET|awk -F/ '{i=int($NF / 8); for (j=1;j<=i;j++)printf("255."); for (j=1;j<=4-i;j++) if (j<4-i) {printf "0."} else { printf "0"}} END{printf"\n"}'`
  SECONDARY_NET=`echo $SECONDARY_NET|awk -F/ '{print $1}'`
fi

# Create the base directory that will contain the VE storage
mkdir -m 0755 -p $VMROOT

#
# NB There is effectively an 11 character limit
# on the bridge name. If exceeded, the bridge NIC
# name will be truncated, creating a potential
# conflict.
#
# Use "brctl show" to see the effect.
#
# Example 1: good behaviour (bridge name and interface name match):
# bridge name	bridge id		STP enabled	interfaces
# ieel-m0102	8000.525400b6f9be	yes		ieel-m0102-nic
#
# Example 2: bad behaviour (notice that interface name is truncated):
# bridge name	  bridge id		STP enabled	interfaces
# 09-mds01-mds02  8000.52540062888b	yes		09-mds01s02-nic
#

# Cluster-wide data network (ostensibly for LNet).
# Attach this network to all of the servers and clients on eth1
# Only define if a secondary network has been defined in CLI arguments
if [ "$SECONDARY_NET" != "" ]; then
echo "Define: LNet network"
NETLIST=`virsh net-list|awk '$1 ~ /^'$VEPREFIX-lnet'/'`
if [ "$NETLIST" = "" ]; then
cat >/tmp/ln.xml <<__EOF
<network>
  <name>$VEPREFIX-lnet</name>
  <bridge name='$VEPREFIX-lnet' stp='on' delay='0' />
</network>
__EOF
echo "(Network management commands require super-user privileges."
echo " Commands will be executed using sudo, which may ask for a pasword)."
sudo virsh net-define /tmp/ln.xml
sudo virsh net-autostart $VEPREFIX-lnet
sudo virsh net-start $VEPREFIX-lnet
rm -f /tmp/ln.xml
else
  echo "Network already defined. Skipping."
fi
fi

#
# Create the temporary Kickstart template used by the servers and clients
# The template is generic across Lustre servers and clients.
# A separate template is used for the Admin server, as it contains an
# SSH key
#

# Capture a root password to use for all the VMs
# This method is crude but should be sufficient for creating
# test environments.
#
# Relies on Python being installed.
pw1=""
pw2=""
match=0
echo ""
echo "= Root Password for VMs ="
while read -p "Enter root password for VMs: " -s pw1 ; do
  echo
  read -p "Confirm: " -s pw2
  echo
  if [ "$pw1" = "$pw2" ] && [ -n "$pw1" ]; then
    unset pw2
    # This is supported in RHEL, CentOS Fedora.
    # Also supported by vanilla Python 3.x
    rootpw=`python -c 'import crypt; print(crypt.crypt("'$pw1'",salt=crypt.METHOD_SHA512))'`
    # Alternative invocation that works for older versions of Python:
    # rootpw=`python -c "import crypt,random,string; print crypt.crypt('"$pw1"', '\$6\$' + ''.join([random.choice(string.ascii_letters + string.digits) for _ in range(16)]))"`
    # The following pseudo one-liner for python tries the first technique,
    # then the 2nd if the 1st fails:
    # rootpw=`python -c 'import crypt; exec "try: print \"ONE\"; print(crypt.crypt(\"'$pw1'\",salt=crypt.METHOD_SHA512));\nexcept: import random,string; print \"TWO\"; print crypt.crypt(\"'$pw1'\", \"$6$\" + \"\".join([random.choice(string.ascii_letters + string.digits) for _ in range(16)]))"'`
    unset pw1
    break
  else
    echo "Error: password does not match or is empty"
    continue
  fi
done

if [ -z "$rootpw" ]; then 
  echo "Error: root password for VMs has not been set. Exiting."
  exit -1
fi
echo ""

# The Kickstart template

cat >/tmp/$USER-$VMNM.ks <<\__KSEOF
text
poweroff
lang en_GB.UTF-8
keyboard --vckeymap=gb --xlayouts='gb'

# Hack needed for RHEL 6.8 for reasons unknown:
network  --bootproto=dhcp --device=enp1s0 --ipv6=auto --activate

# The include statement below loads in the static IP address configuration
# generated by the %pre section of the template.
# This replaces the DHCP allocation used during the KS install.
%include /tmp/net-include
__KSEOF

cat >>/tmp/$USER-$VMNM.ks <<__KSEOF
rootpw  --iscrypted $rootpw
__KSEOF

cat >>/tmp/$USER-$VMNM.ks <<\__KSEOF
firewall --disabled
selinux --disabled
firstboot --disable
skipx
eula --agreed
timezone --utc Europe/London
bootloader --location=mbr --driveorder=vda --append="crashkernel=auto console=ttyS0,115200 rd_NO_PLYMOUTH"
zerombr
clearpart --all --initlabel --drives=vda
# autopart
part /boot --fstype=ext4 --asprimary --size=512 --ondisk=vda
part swap --recommended --asprimary --ondisk=vda
part / --fstype=ext4 --asprimary --size=3084 --grow --ondisk=vda

%packages
@^minimal-environment
@standard
%end

%pre
# Attempt to set the hostname based on information supplied in the kernel command-line

# Set the hostname and the static IP address allocation
awk '{ \
  for (i=1;i<=NF;i++){ \
    if ($i~/^vehostname=/){split($i,h,"=")} \
    else if($i~/^ve1st_net=/){split($i,n,"=")} \
    else if($i~/^ve1st_netmask=/){split($i,m,"=")} \
    else if($i~/^ve1st_gw=/){split($i,g,"=")} \
    else if($i~/^ve2nd_net=/){split($i,sn,"=")} \
    else if($i~/^ve2nd_netmask=/){split($i,sm,"=")} \
  } \
  if (length(h[2])==0){hn="UNKNOWN"} else {hn=h[2]} \
  if (length(n[2])==0){ip="0.0.0.0";bp="dhcp"} else {ip=n[2];bp="static"} \
  if (length(m[2])==0){mk="255.255.255.0"} else {mk=m[2]} \
  if (length(g[2])==0){gw="0.0.0.0"} else {gw=g[2]} \
  if (length(sn[2])==0){sip="";sbp=""} else {sip=sn[2];sbp="static"} \
  if (length(sm[2])==0){smk="255.255.255.0"} else {smk=sm[2]} \
  printf "network --hostname=%s --onboot=yes --device=enp1s0 --noipv6 --bootproto=%s --ip=%s --netmask=%s --gateway=%s\n",hn,bp,ip,mk,gw; \
  if (length(sip)>0) {printf "network --onboot=yes --device=enp2s0 --noipv6 --gateway=0.0.0.0 --bootproto=%s --ip=%s --netmask=%s\n",sbp,sip,smk} \
}' /proc/cmdline >/tmp/net-include

%end

%post
# fix Bash shell tab completion so that it behaves in a manner consistent with
# the previous 27 years or so of behaviour.
cat >> /etc/profile.d/bash_completion <<__EOF
shopt -s direxpand
__EOF

%end
__KSEOF


#
# END OF Kickstart template definitions
###

# Create VM
# Create OS LVM Volume
echo "Create client $CLIENT OS volume..."
rm -f $VMROOT/$VMNM
qemu-img create -f raw $VMROOT/$VMNM $DISKSIZE
echo "done."

if [ "$SECONDARY_NET" == "" ]; then
  virt-install --name $VMNM \
    --ram $MEM --vcpus 2 --check-cpu --hvm \
    --graphics none \
    --initrd-inject="/tmp/$USER-$VMNM.ks" \
    --extra-args "inst.ks=file:/$USER-$VMNM.ks console=tty0 console=ttyS0,115200 vehostname=$VMNM ve1st_net=$PRIMARY_NET ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW veprefix=$VEPREFIX" \
    --disk "$VMROOT/$VMNM,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
    --network bridge=$PRIBRIDGE,mac=$PRI_MAC \
    --location "$REPO_URL" --noreboot
else
  virt-install --name $VMNM \
    --ram 2048 --vcpus 2 --check-cpu --hvm \
    --graphics none \
    --initrd-inject="/tmp/$USER-$VMNM.ks" \
    --extra-args "inst.ks=file:/$USER-$VMNM.ks console=tty0 console=ttyS0,115200 vehostname=$VMNM ve1st_net=$PRIMARY_NET ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW ve2nd_net=$SECONDARY_NET ve2nd_netmask=$SECONDARY_SUBNET_MASK veprefix=$VEPREFIX" \
    --disk "$VMROOT/$VMNM,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
    --network bridge=$PRIBRIDGE,mac=$PRI_MAC \
    --network bridge=$VEPREFIX-lnet,mac=$SEC_MAC \
    --location "$REPO_URL" --noreboot
fi
