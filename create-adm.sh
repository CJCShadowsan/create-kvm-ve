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
  echo "USAGE: $0 -d <VM BASE DIR> -l <PRIMARY BRIDGE> -m <PRI MAC> -M <SEC MAC> -n <VE NAME> -N <GUEST NAME> -p <PRIMARY SUBNET> -g <PRIMARY GATEWAY> -s <SECONDARY SUBNET> -r <REPO URL> [-S <MEM>]"
  echo "  VM BASE DIR: base directory for storing VM disk images"
  echo "  PRIMARY BRIDGE: (default: virbr0) the virtual switch "
  echo "      providing a bridge to a LAN on the host."
  echo "  PRI MAC: 48-bit MAC address for primary network interface
  echo "  SEC MAC: 48-bit MAC address for secondary network interface
  echo "  VE NAME: Name of virtual environment, e.g. st01, ieel, demo"
  echo "  GUEST NAME: Host name suffix, e.g. c1, oss1, mds1"
  echo "  PRIMARY SUBNET: subnet for enp1s0, in CIDR notation, e.g. 10.70.73.0/16"
  echo "  PRIMARY GATEWAY: gateway (IPv4 address) for enp1s0"
  echo "  SECONDARY SUBNET: subnet for enp2s0, in CIDR notation, e.g. 192.168.73.0/24"
  echo "  REPO URL: URL for operating system repository."
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
MEM=3072

while getopts :d:l:m:n:N:p:g:r: opt; do
  case $opt in
    d)
      VMROOT="$OPTARG"
      ;;
    l)
      PRIBRIDGE="$OPTARG"
      ;;
    m)
      PRI_MAC="$OPTARG"
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

# Root directory for disk images
VMROOT="$VMROOT/$VEPREFIX-ve"
mkdir -m 0755 -p $VMROOT

# Strip the last octect from the SUBNET.
# Script will only use the last octet for assigning addresses to hosts.
PRIMARY_SUBNET_MASK=`echo $PRIMARY_NET|awk -F/ '{i=int($NF / 8); for (j=1;j<=i;j++)printf("255."); for (j=1;j<=4-i;j++) if (j<4-i) {printf "0."} else { printf "0"}} END{printf"\n"}'`
SECONDARY_SUBNET_MASK=`echo $SECONDARY_NET|awk -F/ '{i=int($NF / 8); for (j=1;j<=i;j++)printf("255."); for (j=1;j<=4-i;j++) if (j<4-i) {printf "0."} else { printf "0"}} END{printf"\n"}'`
PRIMARY_NET=`echo $PRIMARY_NET|awk -F/ '{print $1}'`
SECONDARY_NET=`echo $SECONDARY_NET|awk -F/ '{print $1}'`

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
cat >/tmp/$USER-$VEPREFIX-adm.ks <<\__KSEOF
text
poweroff
lang en_GB.UTF-8
keyboard --vckeymap=gb --xlayouts='gb'

# Hack needed for reasons unknown:
network  --bootproto=dhcp --device=enp1s0 --ipv6=auto --activate

# The include statement below loads in the static IP address configuration
# generated by the %pre section of the template.
# This replaces the DHCP allocation used during the KS install.
%include /tmp/net-include
__KSEOF

cat >>/tmp/$USER-$VEPREFIX-adm.ks <<__KSEOF
rootpw  --iscrypted $rootpw
__KSEOF
unset rootpw

cat >>/tmp/$USER-$VEPREFIX-adm.ks <<\__KSEOF
firewall --disabled
selinux --disabled
firstboot --disable
skipx
eula --agreed
timezone --utc Europe/London
bootloader --location=mbr --driveorder=vda --append="crashkernel=auto console=ttyS0,115200 rd_NO_PLYMOUTH"
zerombr
clearpart --all --initlabel --drives=vda
autopart

%packages
@^minimal-environment
@standard

createrepo
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
  } \
  if (length(h[2])==0){hn="UNKNOWN"} else {hn=h[2]} \
  if (length(n[2])==0){ip="0.0.0.0";bp="dhcp"} else {ip=n[2];bp="static"} \
  if (length(m[2])==0){mk="255.255.255.0"} else {mk=m[2]} \
  if (length(g[2])==0){gw="0.0.0.0"} else {gw=g[2]} \
  printf "network --hostname=%s --onboot=yes --device=enp1s0 --noipv6 --bootproto=%s --ip=%s --netmask=%s --gateway=%s\n",hn,bp,ip,mk,gw; \
}' /proc/cmdline >/tmp/net-include

%end

%post
# Add in a hosts table.

VEPREFIX=`awk '{for (i=1;i<=NF;i++)if ($i~/^veprefix=/){split($i,p,"=")}; if (length(p[2])==0){print "UNKNOWN"} else {print p[2]}}' /proc/cmdline`
VEIPNET=`awk '{for (i=1;i<=NF;i++){if($i~/^ve1st_net=/){split($i,n,"=")}}; if (length(n[2])==0){print "10.0.0"} else {split(n[2],p,".");printf "%s.%s.%s",p[1],p[2],p[3]}}' /proc/cmdline`
VECLIENTS=`awk '{for (i=1;i<=NF;i++)if ($i~/^veclients=/){split($i,p,"=")}; if (length(p[2])==0){print "UNKNOWN"} else {print p[2]}}' /proc/cmdline`

cat >>/etc/hosts<<__EOF
$VEIPNET.10  $VEPREFIX-adm.lfs.intl $VEPREFIX-adm
$VEIPNET.11 $VEPREFIX-mds1.lfs.intl $VEPREFIX-mds1
$VEIPNET.12 $VEPREFIX-mds2.lfs.intl $VEPREFIX-mds2
$VEIPNET.21 $VEPREFIX-oss1.lfs.intl $VEPREFIX-oss1
$VEIPNET.22 $VEPREFIX-oss2.lfs.intl $VEPREFIX-oss2
$VEIPNET.23 $VEPREFIX-oss3.lfs.intl $VEPREFIX-oss3
$VEIPNET.24 $VEPREFIX-oss4.lfs.intl $VEPREFIX-oss4
__EOF

i=1
j=`expr $VECLIENTS + 0`
[ "$j" = "" ] && j=1
[ $j -gt 9 ] && j=9
while [ $i -le $j ]; do
cat >>/etc/hosts<<__EOF
$VEIPNET.3$i $VEPREFIX-c$i.lfs.intl $VEPREFIX-c$i
__EOF
let i++
done

# SSH key for root user to allow access from Admin to Lustre servers.
mkdir -m 0700 -p /root/.ssh
cat > /root/.ssh/id_rsa <<\__EOF
__KSEOF
cat /tmp/$USER-$VEPREFIX-rsa >> /tmp/$USER-$VEPREFIX-adm.ks
cat >>/tmp/$USER-$VEPREFIX-adm.ks <<__KSEOF
__EOF
chmod 0600 /root/.ssh/id_rsa

# Install the public key
cat > /root/.ssh/id_rsa.pub <<\__EOF
__KSEOF
cat /tmp/$USER-$VEPREFIX-rsa.pub >> /tmp/$USER-$VEPREFIX-adm.ks
cat >>/tmp/$USER-$VEPREFIX-adm.ks <<__KSEOF
__EOF

cat >/root/.ssh/config <<\__EOF
StrictHostKeyChecking=no
__EOF

%end
__KSEOF

rm -f /tmp/$USER-$VEPREFIX-rsa /tmp/$USER-$VEPREFIX-rsa.pub



#
# END OF Kickstart template definitions
###

#
# Create Admin Server
#

# OS LVM Volume
echo "Create ADM OS volume..."
rm -f $VMROOT/$VMNM
qemu-img create -f raw $VMROOT/$VMNM 10G
echo "done."
virt-install --name $VMNM \
  --ram $MEM --vcpus 2 --check-cpu --hvm \
  --graphics none \
  --initrd-inject="/tmp/$USER-$VEPREFIX-adm.ks" \
  --extra-args "inst.ks=file:/$USER-$VEPREFIX-adm.ks console=tty0 console=ttyS0,115200 vehostname=$VMNM ve1st_net=$PRIMARY_NET ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW veprefix=$VEPREFIX veclients=4" \
  --disk "$VMROOT/$VMNM,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
  --network bridge=$PRIBRIDGE,mac=$PRI_MAC \
  --location "$REPO_URL" \
  --noreboot
