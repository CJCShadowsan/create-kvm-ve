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
  echo "USAGE: $0 -d <VM BASE DIR> -l <PRIMARY BRIDGE> -b <BASE MAC> -n <VE NAME> -p <PRIMARY SUBNET> -g <PRIMARY GATEWAY> -s <SECONDARY SUBNET> -r <REPO URL> -c <CLIENTS> [-o <OSTSIZE>] [-O OSTCT] [-A <AMEM>] [-S <SMEM>] [-C <CLMEM>]"
  echo "  VM BASE DIR: base directory for storing VM disk images"
  echo "  PRIMARY BRIDGE: (default: virbr0) the virtual switch "
  echo "      providing a bridge to a LAN on the host."
  echo "  BASE MAC: 4-byte MAC prefix, e.g. 02:EE:22:73"
  echo "  VE NAME: Name of virtual environment, e.g. el73, demo"
  echo "  PRIMARY SUBNET: subnet for enp1s0, in CIDR notation, e.g. 10.70.73.0/16"
  echo "  PRIMARY GATEWAY: gateway (IPv4 address) for enp1s0"
  echo "  SECONDARY SUBNET: subnet for eth1, in CIDR notation, e.g. 192.168.73.0/24"
  echo "  REPO URL: URL for operating system repository."
  echo "  CLIENTS: Number of Lustre clients to create. Default: 0; Max: 9"
  echo "  OSTSIZE: Size in GB of each OST volume. Default: 10GB"
  echo "  OSTCT: Number of OST volumes. Default: 2; Min: 2, Max: 52"
  echo "  AMEM: Size of memory allocation for Admin VM in MB. Default: 3072"
  echo "  SMEM: Size of memory allocation for Lustre server VMs in MB. Default: 3072"
  echo "  CLMEM: Size of memory allocation for client VMs in MB. Default: 2048"
}

VMROOT=""
PRIBRIDGE="virbr0"
BASEMAC=""
VEPREFIX=""
PRIMARY_SUBNET=""
PRIMARY_GW=""
SECONDARY_SUBNET=""
REPO_URL=""
CLIENTS=0
OSTSIZE=10
OSTCT=2
AMEM=3072
SMEM=3072
CLMEM=2048

while getopts :l:d:b:n:p:g:s:r:c:o:O:A:S:C: opt; do
  case $opt in
    d)
      VMROOT="$OPTARG"
      ;;
    l)
      PRIBRIDGE="$OPTARG"
      ;;
    b)
      BASEMAC="$OPTARG"
      ;;
    n)
      VEPREFIX="$OPTARG"
      ;;
    p)
      PRIMARY_SUBNET="$OPTARG"
      ;;
    g)
      PRIMARY_GW="$OPTARG"
      ;;
    s)
      SECONDARY_SUBNET="$OPTARG"
      ;;
    r)
      REPO_URL="$OPTARG"
      ;;
    c)
      CLIENTS=`awk 'BEGIN{print int("'$OPTARG'")}'`
      ;;
    o)
      OSTSIZE="$OPTARG"
      ;;
    O)
      OSTCT=`awk 'BEGIN{print int("'$OPTARG'")}'`
      ;;
    A)
      AMEM=`awk 'BEGIN{print int("'$OPTARG'")}'`
      ;;
    S)
      SMEM=`awk 'BEGIN{print int("'$OPTARG'")}'`
      ;;
    C)
      CLMEM=`awk 'BEGIN{print int("'$OPTARG'")}'`
      ;;
    ?|:)
      usage
      exit
      ;;
  esac
done

if [ "$VMROOT" = "" ] || [ "$PRIBRIDGE" = "" ] || [ "$BASEMAC" = "" ] || [ "$VEPREFIX" = "" ] || [ "$PRIMARY_SUBNET" = "" ] || [ "$SECONDARY_SUBNET" = "" ] || [ "$REPO_URL" = "" ] || [ "$CLIENTS" = "0" ] || [ "$CLIENTS" -gt 9 ] || [ "$OSTCT" = "" ] || [ "$OSTCT" -lt 2 ] || [ "$OSTCT" -gt 52 ]; then
  usage
  exit
fi

if [ "$PRIMARY_GW" = "" ]; then
  PRIMARY_GW="0.0.0.0"
fi

# Root directory for disk images
VMROOT="$VMROOT/$VEPREFIX-ve"
mkdir -m 0755 -p $VMROOT

# Strip the last octect from the SUBNET.
# Script will only use the last octet for assigning addresses to hosts.
PRIMARY_NET_PREFIX=`echo $PRIMARY_SUBNET|awk -F. '{printf "%s.%s.%s",$1,$2,$3}'`
PRIMARY_SUBNET_MASK=`echo $PRIMARY_SUBNET|awk -F/ '{i=int($NF / 8); for (j=1;j<=i;j++)printf("255."); for (j=1;j<=4-i;j++) if (j<4-i) {printf "0."} else { printf "0"}} END{printf"\n"}'`
SECONDARY_NET_PREFIX=`echo $SECONDARY_SUBNET|awk -F. '{printf "%s.%s.%s",$1,$2,$3}'`
SECONDARY_SUBNET_MASK=`echo $SECONDARY_SUBNET|awk -F/ '{i=int($NF / 8); for (j=1;j<=i;j++)printf("255."); for (j=1;j<=4-i;j++) if (j<4-i) {printf "0."} else { printf "0"}} END{printf"\n"}'`
# 3rd octect will be saved for configuring other interfaces.
NETID_OCTET=`echo $PRIMARY_SUBNET|awk -F. '{printf "%s",$3}'`

# Get current state of the host and destroy any pre-existing
# virtual environment.
VEDISPLAY=`virsh list --all|awk 'NR == 1 || NR == 2 || $2 ~ /'$VEPREFIX'-/ {print}'`
VELIST=`echo "$VEDISPLAY"| awk '$2~/^'$VEPREFIX'-/{print $2}'`
VECT=`echo "$VELIST"|wc -l`
if [ "$VELIST" != "" ] && [ "$VECT" -gt 0 ]; then
  echo "The following VMs for virtual environment \"$VEPREFIX\" are currently configured on the system:"
  echo "$VEDISPLAY"
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
    echo "(Network management commands require super-user privileges."
    echo " Commands will be executed using sudo, which may ask for a pasword)."
    for i in lnet m0102 o0102 o0304; do
      sudo virsh net-destroy $VEPREFIX-$i
      sudo virsh net-undefine $VEPREFIX-$i
    done
    echo "Deleting virtual storage for VMs..."
    rm -rf $VMROOT
  else
    echo "Cancelled. Exit."
    exit
  fi
fi

# Create the base directory that will contain the VE storage
mkdir -m 0755 -p $VMROOT

#
# Create the virtual networks for each 
# HA server pair
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

# MDS Heartbeat network
echo "Define: MDS Heartbeat network"
echo "(Network management commands require super-user privileges."
echo " Commands will be executed using sudo, which may ask for a pasword)."
cat >/tmp/hbn.xml <<__EOF
<network>
  <name>$VEPREFIX-m0102</name>
  <bridge name='$VEPREFIX-m0102' stp='on' delay='0' />
</network>
__EOF
sudo virsh net-define /tmp/hbn.xml
sudo virsh net-autostart $VEPREFIX-m0102
sudo virsh net-start $VEPREFIX-m0102
rm -f /tmp/hbn.xml

# OSS1-2 Heartbeat network
echo "Define: OSS1-2 Heartbeat network"
echo "(Network management commands require super-user privileges."
echo " Commands will be executed using sudo, which may ask for a pasword)."
cat >/tmp/hbn.xml <<__EOF
<network>
  <name>$VEPREFIX-o0102</name>
  <bridge name='$VEPREFIX-o0102' stp='on' delay='0' />
</network>
__EOF
sudo virsh net-define /tmp/hbn.xml
sudo virsh net-autostart $VEPREFIX-o0102
sudo virsh net-start $VEPREFIX-o0102
rm -f /tmp/hbn.xml

# OSS3-4 Heartbeat network
echo "Define: OSS3-4 Heartbeat network"
echo "(Network management commands require super-user privileges."
echo " Commands will be executed using sudo, which may ask for a pasword)."
cat >/tmp/hbn.xml <<__EOF
<network>
  <name>$VEPREFIX-o0304</name>
  <bridge name='$VEPREFIX-o0304' stp='on' delay='0' />
</network>
__EOF
sudo virsh net-define /tmp/hbn.xml
sudo virsh net-autostart $VEPREFIX-o0304
sudo virsh net-start $VEPREFIX-o0304
rm -f /tmp/hbn.xml

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

# Create SSH keys to allow admin host to access the other hosts
# without requiring a password.
#
# It is acknowledged that this is not a strong practice for production
# clusters, but is useful in training and testing environments.
ssh-keygen -t rsa -N '' -f /tmp/$USER-$VEPREFIX-rsa

# The Kickstart template

cat >/tmp/$USER-$VEPREFIX-nodes.ks <<\__KSEOF
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

cat >>/tmp/$USER-$VEPREFIX-nodes.ks <<__KSEOF
rootpw  --iscrypted $rootpw
__KSEOF

cat >>/tmp/$USER-$VEPREFIX-nodes.ks <<\__KSEOF
firewall --disabled
selinux --disabled
firstboot --disable
skipx
eula --agreed
timezone --utc Europe/London
bootloader --location=mbr --driveorder=vda --append="crashkernel=auto console=ttyS0,115200 rd_NO_PLYMOUTH"
zerombr
clearpart --all --initlabel --drives=vda
#autopart
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
  if (length(sn[2])==0){sip="0.0.0.0";sbp="dhcp"} else {sip=sn[2];sbp="static"} \
  if (length(sm[2])==0){smk="255.255.255.0"} else {smk=sm[2]} \
  printf "network --hostname=%s --onboot=yes --device=enp1s0 --noipv6 --bootproto=%s --ip=%s --netmask=%s --gateway=%s\n",hn,bp,ip,mk,gw; \
  printf "network --onboot=yes --device=enp2s0 --noipv6 --gateway=0.0.0.0 --bootproto=%s --ip=%s --netmask=%s\n",sbp,sip,smk; \
  # printf "network --onboot=no --device=enp3s0 --noipv6\n"; \
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

# fix Bash shell tab completion so that it behaves in a manner consistent with
# the previous 27 years or so of behaviour.
cat >> /etc/profile.d/bash_completion <<__EOF
shopt -s direxpand
__EOF

# Install a consistent public key to allow SSH access from the Admin server
mkdir -m 0700 -p /root/.ssh
cat > /root/.ssh/authorized_keys <<\__EOF
__KSEOF
cat /tmp/$USER-$VEPREFIX-rsa.pub >> /tmp/$USER-$VEPREFIX-nodes.ks
cat >>/tmp/$USER-$VEPREFIX-nodes.ks <<__KSEOF
__EOF
chmod 0600 /root/.ssh/authorized_keys
%end
__KSEOF

#
# The ADM server definition is very similar but is printed separately.
# This prevents the Admin server's private SSH key being propagated to
# all of the VMs in the cluster during installation (Anaconda will
# write the KS template into /root/anaconda.ks when the installation
# is finished).
#
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

# fix Bash shell tab completion so that it behaves in a manner consistent with
# the previous 27 years or so of behaviour.
cat >> /etc/profile.d/bash_completion <<__EOF
shopt -s direxpand
__EOF

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
# Metadata Servers
#

# MGT Volume for MDS cluster
echo "Create MGT volume..."
rm -f $VMROOT/$VEPREFIX-mgs
qemu-img create -f raw $VMROOT/$VEPREFIX-mgs 1G
echo "done."

# MDT Volume for MDS cluster
echo "Create MDT volume..."
rm -f $VMROOT/$VEPREFIX-mdt0
qemu-img create -f raw $VMROOT/$VEPREFIX-mdt0 10G
echo "done."

# Create an HA MDS cluster pair
 for MDS in 1 2; do
  BASEMDSMAC=$BASEMAC":11:"$MDS
  # OS LVM Volume
  echo  "Create MDS$MDS OS volume..."
  rm -f $VMROOT/$VEPREFIX-mds$MDS
  qemu-img create -f raw $VMROOT/$VEPREFIX-mds$MDS 10G
  echo "done."
  virt-install --name $VEPREFIX-mds$MDS \
    --ram $SMEM --vcpus 2 --check-cpu --hvm \
    --graphics none \
    --initrd-inject="/tmp/$USER-$VEPREFIX-nodes.ks" \
    --extra-args "inst.ks=file:/$USER-$VEPREFIX-nodes.ks console=tty0 console=ttyS0,115200 vehostname=$VEPREFIX-mds$MDS ve1st_net=$PRIMARY_NET_PREFIX.1$MDS ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW ve2nd_net=$SECONDARY_NET_PREFIX.1$MDS ve2nd_netmask=$SECONDARY_SUBNET_MASK veprefix=$VEPREFIX veclients=$CLIENTS" \
    --disk "$VMROOT/$VEPREFIX-mds$MDS,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
    --network bridge=$PRIBRIDGE,mac=$BASEMDSMAC"1" \
    --network bridge=$VEPREFIX-lnet,mac=$BASEMDSMAC"2" \
    --network bridge=$VEPREFIX-m0102,mac=$BASEMDSMAC"3" \
    --location "$REPO_URL" \
    --noautoconsole
# Create scsi devices for the lustre storage
cat > ctl.xml <<\__EOF
<controller type='scsi' model='virtio-scsi'/>
__EOF
virsh attach-device --config $VEPREFIX-mds$MDS ctl.xml 
virsh attach-disk $VEPREFIX-mds$MDS $VMROOT/$VEPREFIX-mgs sda --serial EEMGT0000 --config --shareable
virsh attach-disk $VEPREFIX-mds$MDS $VMROOT/$VEPREFIX-mdt0 sdb --serial EEMDT0000 --config --shareable
rm -f ctl.xml
done

#
# Object Storage Servers
#

# Create the OST Volumes for each OSS pair
for OST in `seq 0  \`expr $OSTCT - 1\``; do
  echo "Create OST$OST volume..."
  rm -f $VMROOT/$VEPREFIX-ost$OST
  qemu-img create -f raw $VMROOT/$VEPREFIX-ost$OST $OSTSIZE"G"
  echo "done."
done

# OSS VMs
for OSS in 1 2 3 4; do
  BASEOSSMAC=$BASEMAC":22:"$OSS
  if [ $OSS -eq 1 ] || [ $OSS -eq 2 ]; then
    OSSHBN=$VEPREFIX-o0102
  elif [ $OSS -eq 3 ] || [ $OSS -eq 4 ]; then
    OSSHBN=$VEPREFIX-o0304
  else
    echo "ERROR: OSS $OSS -- number out of range".
    exit -1
  fi

  # OS LVM Volume
  echo "Create OSS$OSS OS volume..."
  rm -f $VMROOT/$VEPREFIX-oss$OSS
  qemu-img create -f raw $VMROOT/$VEPREFIX-oss$OSS 10G
  echo "done."
  virt-install --name $VEPREFIX-oss$OSS \
    --ram $SMEM --vcpus 2 --check-cpu --hvm \
    --graphics none \
    --initrd-inject="/tmp/$USER-$VEPREFIX-nodes.ks" \
    --extra-args "inst.ks=file:/$USER-$VEPREFIX-nodes.ks console=tty0 console=ttyS0,115200 vehostname=$VEPREFIX-oss$OSS ve1st_net=$PRIMARY_NET_PREFIX.2$OSS ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW ve2nd_net=$SECONDARY_NET_PREFIX.2$OSS ve2nd_netmask=$SECONDARY_SUBNET_MASK veprefix=$VEPREFIX veclients=$CLIENTS" \
    --disk "$VMROOT/$VEPREFIX-oss$OSS,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
    --network bridge=$PRIBRIDGE,mac=$BASEOSSMAC"1" \
    --network bridge=$VEPREFIX-lnet,mac=$BASEOSSMAC"2" \
    --network bridge=$OSSHBN,mac=$BASEOSSMAC"3" \
    --location "$REPO_URL" \
    --noautoconsole

# Create scsi devices for the lustre storage
# The virtio-scsi controllers appear to have a 7 device limit.
# Because there may be more than 7 disks attached to the host, multiple SCSI
# controllers must therefore be added to each OSS. libvirt/virsh will try
# to do this automatically, but will omit the controller type, rendering the
# additional controller useless. As a work-around, create 4 SCSI controllers.
#
# Also, you can't put multiple controller entries into a single file
# and run the command once. I already tried and it does not work.
for i in `seq 0 3`; do
cat > /tmp/$VEPREFIX-oss$OSS-ctl.xml <<__EOF
<controller type='scsi' model='virtio-scsi' index='$i'/>
__EOF
virsh attach-device --config $VEPREFIX-oss$OSS /tmp/$VEPREFIX-oss$OSS-ctl.xml
rm -f /tmp/$VEPREFIX-oss$OSS-ctl.xml
done

# Add the volumes to the OSS Pairs
MIDPT=`awk 'BEGIN{print int("'$OSTCT'"/2)}'`
if [ $OSS -eq 1 ] || [ $OSS -eq 2 ]; then
  # OST Volumes for OSS clusters
  for OST in `seq 0  \`expr $MIDPT - 1\``; do
    virsh attach-disk $VEPREFIX-oss$OSS $VMROOT/$VEPREFIX-ost$OST sd`awk 'BEGIN {c='$OST'+97;printf "%c",c}'` --serial EEOST`awk 'BEGIN{printf "%04d\n",'$OST'}'` --config --shareable
  done
elif [ $OSS -eq 3 ] || [ $OSS -eq 4 ]; then
  # OST Volumes for OSS clusters
  for OST in `seq $MIDPT \`expr $OSTCT - 1\``; do
    virsh attach-disk $VEPREFIX-oss$OSS $VMROOT/$VEPREFIX-ost$OST sd`awk 'BEGIN {c='$OST'-'$MIDPT'+97;printf "%c",c}'` --serial EEOST`awk 'BEGIN{printf "%04d\n",'$OST'}'` --config --shareable
  done
fi
done

#
# Create Admin Server
#
BASEADMMAC=$BASEMAC":00:1"
# OS LVM Volume
echo "Create ADM OS volume..."
rm -f $VMROOT/$VEPREFIX-adm
qemu-img create -f raw $VMROOT/$VEPREFIX-adm 10G
echo "done."
virt-install --name $VEPREFIX-adm \
  --ram $AMEM --vcpus 2 --check-cpu --hvm \
  --graphics none \
  --initrd-inject="/tmp/$USER-$VEPREFIX-adm.ks" \
  --extra-args "ks=file:/$USER-$VEPREFIX-adm.ks console=tty0 console=ttyS0,115200 vehostname=$VEPREFIX-adm ve1st_net=$PRIMARY_NET_PREFIX.10 ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW veprefix=$VEPREFIX veclients=$CLIENTS" \
  --disk "$VMROOT/$VEPREFIX-adm,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
  --network bridge=$PRIBRIDGE,mac=$BASEADMMAC"1" \
  --location "$REPO_URL" \
  --noautoconsole

#
# Compute nodes
# 
for CLIENT in `seq 1 $CLIENTS`; do
  BASECLIENTMAC=$BASEMAC":33:"$CLIENT
  # OS LVM Volume
  echo "Create client $CLIENT OS volume..."
  rm -f $VMROOT/$VEPREFIX-c$CLIENT
  qemu-img create -f raw $VMROOT/$VEPREFIX-c$CLIENT 10G
  echo "done."
  virt-install --name $VEPREFIX-c$CLIENT \
    --ram $CLMEM --vcpus 2 --check-cpu --hvm \
    --graphics none \
    --initrd-inject="/tmp/$USER-$VEPREFIX-nodes.ks" \
    --extra-args "ks=file:/$USER-$VEPREFIX-nodes.ks console=tty0 console=ttyS0,115200 vehostname=$VEPREFIX-c$CLIENT ve1st_net=$PRIMARY_NET_PREFIX.3$CLIENT ve1st_netmask=$PRIMARY_SUBNET_MASK ve1st_gw=$PRIMARY_GW ve2nd_net=$SECONDARY_NET_PREFIX.3$CLIENT ve2nd_netmask=$SECONDARY_SUBNET_MASK veprefix=$VEPREFIX veclients=$CLIENTS" \
    --disk "$VMROOT/$VEPREFIX-c$CLIENT,device=disk,bus=virtio,size=10,sparse=true,format=raw" \
    --network bridge=$PRIBRIDGE,mac=$BASECLIENTMAC"1" \
    --network bridge=$VEPREFIX-lnet,mac=$BASECLIENTMAC"2" \
    --location "$REPO_URL" \
    --noautoconsole
done

# Clean up the KS templates
rm -f /tmp/$USER-$VEPREFIX-nodes.ks
rm -r /tmp/$USER-$VEPREFIX-adm.ks

echo
echo "Waiting for cluster installation to complete."

TIMEOUT=120
ITERATION=1
while [ `virsh list --all | tail -n +3| awk '!/shut/ && !/^$/ && /'$VEPREFIX'-/'|wc -l` -gt 0 ] && [ "$ITERATION" -le "$TIMEOUT" ]; do
  echo -n "."
  sleep 10
  ITERATION=`expr $ITERATION + 1`
done
echo

if [ `virsh list --all | tail -n +3| awk '!/shut/ && !/^$/ && /'$VEPREFIX'-/'|wc -l` -gt 0 ]; then
  echo "Installation still in progress on some VMs."
  echo "Monitor progress of individual VMs using the following command:"
  echo "    virsh console <VM Name>"
else
  echo "Installation is complete. VMs have been powered down."
fi
echo

echo "Installation Status:"

virsh net-list --all
virsh list --all
