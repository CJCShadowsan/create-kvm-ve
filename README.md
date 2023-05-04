# Create Virtual HPC Environments for Development, Test and Demos with KVM

## Introduction
This repository contains a set of scripts suitable for quickly creating a small virtual environment, comprising hosts, shared storage and networking, on a single hypervisor host with KVM. the main script will create an admin server, 2 servers for metadata storage functions, 2-8 servers for object storage functions, and up to 8 compute nodes.

The environment is designed to enable users to quickly and easily spin up a working HPC cluster for use in software development, training or demonstrations.

In addition, there is a script for creating a stand-alone virtual guest with characteristics equival
ent to a compute node. It allows users to create virtual guests with different storage and memory characteristics, and provides a good basis for a virtual build host. It is typically used to create a more powerful VM for compiling source code in a predictable, contained environment.

The setup is straightforward, and the scripts automatically build the virtual cluster environment with minimum input from the operator. Once the hypervisor host has been setup, the script takes care of all of the virtual machine deployment and configuration. Building and rebuilding the virtual environment is mechanically reliable repeatable.

## Requirements

The principal requirement is a reasonably modern computer with a CPU capable of supporting the virtualisation extension instructions, a good amount of RAM, and running a Linux distribution that has support for the KVM hypervisor. 

The examples in this article use the Fedora distribution as the hypervisor host, but the concepts are portable to other distributions.

The setup can be ported to other Linux-based operating system distributions, with a little work. The original version of this virtual environment was developed using Ubuntu 14.04 as the hypervisor host; porting it to Fedora was straightforward.

The host will require a good deal of RAM (16GB is the minimum that should be considered in order to be able to run more than 3-4 VMs; 32GB or more is recommended). Storage requirements are dependent on the size of the virtual disks that will be used for the VM root disks and Lustre OSDs. The full virtual environment comprises 12 VMs, so plan on a few hundred GBs of storage overall.

Guests must be either RHEL or CentOS, version 6 or 7. The scripts have been used to create VMs running various releases of both RHEL/CentSOS 6.x and 7.x. The ISO of one of these distributions must be copied onto the host so that it can be used to install the VMs using Kickstart.

The environment created by theses scripts has been installed on a variety of hardware platforms, including an Intel NUC with a 6th generation Intel i5 CPU and 32GB RAM.

## Platform Software

### Additional Packages
In addition to the Fedora Workstation default installation, the following packages are required:

* virt-install
* kvm
* qemu-kvm

Install them using DNF (replacement for YUM):

```
dnf install \
  virt-install \
  kvm \
  qemu-kvm
```

### Enable SSH for remote access
It may be necessary to enable and start the SSH service on the host, if it is to be accessed remotely:

```
systemctl enable sshd
systemctl start sshd
```

### Apache HTTPD Configuration
The Apache web server should be installed as part of the standard Fedora Live workstation distribution (although I can't think why it is relevant to a workstation install). If it is not installed, then add it to the host using DNF:

```
dnf install httpd
```

The web server is required in order to create a package repository for the OS distribution used to build the VMs. Once installed, copy the CentOS or RHEL distribution into `/var/www/html`. For example, to copy the contents of an ISO of the CentOS 7.3 distribution:

```
mkdir -p /mnt/iso
wget http://mirrors.binaryracks.com/centos/8-stream/isos/x86_64/CentOS-Stream-8-x86_64-latest-dvd1.iso /tmp
mount -o loop /tmp/CentOS-Stream-8-x86_64-latest-dvd1.iso /mnt/iso
cp -a /mnt/iso /var/www/html/CENTOS7.3
umount /mnt/iso
rm -f /tmp/CentOS-Stream-8-x86_64-latest-dvd1.iso
```

Enable the HTTP service to start on system boot:

```
systemctl enable httpd
```

Start the HTTP server:

```
systemctl start httpd
```

The VMs may be obstructed from accessing the HTTP service by the host firewall software. A common symptom is a VM that can ping the gateway or the HTTPD server but is unable to retrieve files using the curl command, which fails with the unhelpful error "`no route to host`".

Rather than disable the firewall, just open the HTTP and HTTPS ports.The firewall software in Fedora 23 is called `firewalld` and it replaces `iptables`. If using the default workstation install, the following should be sufficient:

```
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --add-port=443/tcp
firewall-cmd --add-port=80/tcp
```

In some circumstances, it may be necessary to specify the firewall zone in the command line. To get the default zone, use the following:

```
firewall-cmd --get-default-zone
```

This will return the name of the default zone. This can be then be added to the firewall command to add the HTTP[S] ports, e.g.:

```
firewall-cmd --permanent --zone=FedoraWorkstation --add-port=443/tcp
firewall-cmd --permanent --zone=FedoraWorkstation --add-port=80/tcp
firewall-cmd --zone=FedoraWorkstation --add-port=443/tcp
firewall-cmd --zone=FedoraWorkstation --add-port=80/tcp
```

(the author is not very familiar with the firewall software, but adding the HTTP[S] ports to the firewall's default zone is all that appears to be required).

Note: the `--permanent` flag is used to write a persistent firewall configuration change but does not change the active (running) configuration. To apply the change to the running firewall process, run the command without the `--permanent` flag. Alternatively, restart the `firewalld` software:

```
systemctl restart firewalld
```

### DHCP Server
There is no requirement for a DHCP service to be configured on the host. The virtual machine manager provides all of the required network infrastructure for the VMs.

## Virtual Environment Preparation
### KVM / libvirt Virtual Networking

The `PRIMARY BRIDGE` is the name of the virtual interface created by KVM to provide a bridge between the VMs and the LAN that the host is connected to. By default a single bridge is created by KVM, usually called `default` and mapped to an interface called `virbr0`. To find out what virtual networks have been configured, first run the following command:

```
virsh net-list
```

For example:

```
root@pnuc create-ve,v5]# virsh net-list
 Name                 State      Autostart     Persistent
----------------------------------------------------------
 default              active     yes           yes
```

To get more information about the default network:

```
virsh net-info <net>
```

For example:

```
[root@pnuc create-ve,v5]# virsh net-info default
Name:           default
UUID:           29e972d8-e019-4ec5-bc5f-d565676c55ac
Active:         yes
Persistent:     yes
Autostart:      yes
Bridge:         virbr0
```

This tells us that the `default` virtual network uses the host bridge `virbr0`. This is what will be supplied to the `create-ve.sh` script. Having identified the VM bridge network device, use the `ip` command to obtain the IPv4 address of the subnet for the bridge. For example:

```
[root@pnuc create-ve,v5]# ip addr show dev virbr0
4: virbr0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 52:54:00:00:ca:ec brd ff:ff:ff:ff:ff:ff
    inet 192.168.124.1/24 brd 192.168.124.255 scope global virbr0
       valid_lft forever preferred_lft forever
```

In this case, `virbr0` has IP address `192.168.124.1/24`. The VMs will need to be able to connect to the `192.168.124.0/24` network in order to communicate with systems outside of the host machine.

If multiple VE clusters are required, a `/24` subnet range is not sufficient to accommodate the virtual machines, because of the way in which IP addresses are assigned to the hosts. Each cluster expects to have an exclusive `/24` subnet of its own for each of the networks that will be configured, so if multiple VE clusters share the same `/24` subnet, there will be IP address conflicts.

To change the configuration of the KVM network bridge interface, edit the default network as follows:

1. Run the following command:
    ```
    virsh net-edit default
    ```
    This will load the default network configuration into a text editor, usually `vi`
1. Look for the `<ip />` tag and edit the address and netmask attributes such that the netmask represents a `/16` network and the address is the first available IP address. For example:
    ```
    <ip address='192.168.0.1' netmask='255.255.0.0'>
    ```
    This creates a ```192.168/16``` subnet, with the gateway address of ```192.168.0.1```. This is sufficient for the majority purposes.
1. Look for the `<dhcp>` tag and edit the `<range />` attributes `start` and `end` to match the full range of the `/16` subnet, minus the gateway address defined above, and the broadcast address of the subnet. For example:
    ```
    <range start='192.168.0.2' end='192.168.255.254'/>
    ```
    This range can be made smaller, if the DHCP pool is only used during OS provisioning and the VMs will have static IP address assignments in this range.
1. Save the edits and exit.
1. The virtual network has to be restarted before the changes can take effect:
    ```
    virsh net-destroy default
    virsh net-start default
    ```
    The `net-destroy` command will not remove the network configuration, it will only destroy (i.e. stop) the currently running instance of the virtual network. The configuration is preserved.
1. Check that the new instance is running:
    ```
    root@pnuc network-scripts]# virsh net-list
     Name                 State      Autostart     Persistent
    ----------------------------------------------------------
     default              active     yes           yes
    ...
    
    [root@pnuc create-ve,v7]# ip addr show dev virbr0
    77: virbr0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN group default qlen 1000
        link/ether 52:54:00:00:ca:ec brd ff:ff:ff:ff:ff:ff
        inet 192.168.0.1/16 brd 192.168.255.255 scope global virbr0
           valid_lft forever preferred_lft forever
    ```

This example is a configuration taken from a working KVM host:
```
[root@pnuc create-ve,v7]# virsh net-dumpxml default
<network>
  <name>default</name>
  <uuid>29e972d8-e019-4ec5-bc5f-d565676c55ac</uuid>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:00:ca:ec'/>
  <ip address='192.168.0.1' netmask='255.255.0.0'>
    <dhcp>
      <range start='192.168.255.1' end='192.168.255.254'/>
    </dhcp>
  </ip>
</network>
```
 
If the default network is not present, it usually means that the package that creates the network has not been installed. The package is called `libvirt-daemon-config-network.x86_64`. To install it, run this command:

```
dnf install libvirt-daemon-config-network-2.2.0-2.fc25.x86_64
```
Change the version number appropriately.

Alternatively, create a new default from the following template:

```
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.0.1' netmask='255.255.0.0'>
    <dhcp>
      <range start='192.168.255.1' end='192.168.255.254'/>
    </dhcp>
  </ip>
</network>
```
Change the bridge name, IP address, netmask and DHCP ranges as required.

## Using `create-ve.sh` to Create a Virtual Cluster

The `create-ve.sh` script has the following usage guideline:

```
USAGE: ./create-ve.sh -d <VM BASE DIR> \
  -l <PRIMARY BRIDGE> \
  -b <BASE MAC> \
  -n <VE NAME> \
  -p <PRIMARY SUBNET> \
  -g <PRIMARY GATEWAY> \
  -s <SECONDARY SUBNET> \
  -r <REPO URL> \
  -c <CLIENTS> \
  [-o <OSTSIZE>] \
  [-O <OSTCT>] \
  [-A <AMEM>] \
  [-S <SMEM>] \
  [-C <CLMEM>]
 
 VM BASE DIR: base directory for storing VM disk images
  PRIMARY BRIDGE: (default: virbr0) the virtual switch
      providing a bridge to a LAN on the host.
  BASE MAC: 4-byte MAC prefix, e.g. 02:EE:22:73
  VE NAME: Name of virtual environment, e.g. st01, ieel, demo
  PRIMARY SUBNET: subnet for eth0, in CIDR notation, e.g. 10.70.73.0/16
  PRIMARY GATEWAY: gateway (IPv4 address) for eth0
  SECONDARY SUBNET: subnet for eth1, in CIDR notation, e.g. 192.168.73.0/24
  REPO URL: URL for operating system repository.
  CLIENTS: Number of Lustre clients to create. (Max: 9)
  OSTSIZE: Size in GB of each OST volume. Default: 10GB
  OSTCT: Number of OST volumes. Default: 2; Min: 2, Max: 52
  AMEM: Size of memory allocation for Admin VM in MB. Default: 3072
  SMEM: Size of memory allocation for Lustre server VMs in MB. Default: 3072
  CLMEM: Size of memory allocation for client VMs in MB. Default: 2048
```

The following example shows how to setup a small cluster using `create-ve.sh`, based on the information gathered about the primary bridge:

```
./create-ve.sh -n ct73 \
  -d /var/lib/vm-imgs \
  -b 02:EE:22:CE \
  -l virbr0 \
  -p 192.168.124.0/24 \
  -g 192.168.124.1 \
  -s 10.10.27.0/24 \
  -r http://192.168.124.1/CENTOS7.3 \
  -c 4 \
  -o 10 \
  -O 20
```

* This command creates a virtual environment called `ct73` (`-n` flag), where all the hosts have the prefix `ct73` in their name.
* The VM images are stored in `/var/lib/vm-imgs` (`-d` flag).
* The base MAC address (`-b` flag) is a 4 byte prefix used to create all the MAC addresses for all of the VMs in the environment. See the header in the script for some information about how this is used.
* The KVM network bridge is `virbr0` (`-l`).
* The primary subnet is `192.168.124.0/24`
* The primary gateway is `192.168.124.1` (IP address of the `virbr0` interface).
* The secondary network is `10.10.27.0/24` (an internal-only network used for cluster traffic – i.e. LNet)
* The OS repository is `http://192.168.124.1/CENTOS7.3`.
* There will be 4 clients created (`-c`)
* Each OST will be 10GB in size (20 OSTs total). These are really just virtual disks presented to the VMs; use a large number of virtual disks if working with ZFS and RAIDZ.

The script generates the kickstart templates and kicks off the installation of all the VMs for the cluster. Currently, the script must be run as root, because some of the virtual machine management commands require super-user access, namely the commands that create the necessary virtual networks for each virtual environment. However, these can probably be wrapped around a sudo command, allowing the rest to be executed as an unprivileged user.

When it is finished, use `virsh list --all` to list all of the VMs. For example:

```
[root@pnuc create-ve,v5]# virsh list --all
 Id    Name                           State
----------------------------------------------------
 -     ct73-adm                       shut off
 -     ct73-c1                        shut off
 -     ct73-mds1                      shut off
 -     ct73-mds2                      shut off
 -     ct73-oss1                      shut off
 -     ct73-oss2                      shut off
 -     ct73-oss3                      shut off
 -     ct73-oss4                      shut off
```

The VMs are shut down automatically when the installation is finished.To start a VM individually:

```
virsh start <vm-name>
```

Once the VMs have started, they can be accessed via SSH or by the VM console. The VMs are all configured with the same root password, which is hard-coded into the KS templates used to create the VMs. To login, use `root/lustre`.

To connect to the VM console (use `Control-]` to disconnect}:

```
virsh console <vm-name>
```

To force power off a VM (this does not remove the VM, it just powers off the instance):

```
virsh destroy <vm-name>
```

To delete a VM (does not remove the disk images):

```
virsh undefine <vm-name>
```

If the VM is running when the undefine command is issued, the instance will continue to run until it is shutdown or destroyed.

Convenience scripts are provided to start, stop and remove all of the VMs in a single virtual environment (VE) cluster. These are:

```
start-ve.sh
stop-ve.sh
remove-ve.sh
```

The `create-ve.sh` script will attempt to detect existing virtual environments and if an attempt is made to rebuild a VE, it will prompt for confirmation before continuing. If the script is prompted to continue, the existing VE will be completely removed and recreated.

## Issues and Limitations

1. The `create-ve.sh` script currently needs to be executed as the root super-user. There are a few reasons for this:
    1. The KVM network configuration commands need to be run with super-user privileges because they create driver interfaces.
    1. The default SELinux policies prevent creation of VM images in user home directories. Since unprivileged users cannot change the policies and because they do not generally have read/write access to arbitrary areas of the file system, attempting to create VMs will cause permission denied errors. Running as root allows the scripts to install VMs to a directory not obstructed by SELinux (e.g. `/var/lib/vm-img`).
        1. This needs to be fixed in a future release of the scripts – once there is a better understanding of the labeling required. Even now, the root account has limits on where it can store the VMs.
        1. If using Fedora, the root user can create a subdirectory under `/home` for storing VMs, e.g. `/home/kvm`. Fedora's default disk partitioning layout creates a very large `/home` partition, so it makes sense to use that for VM image files. This does not require any specific SELinux labels to be allocated to the directory.
1. The kickstart templates are embedded in the `create-ve script`. This has advantages and disadvantages, with the biggest disadvantage being maintenance and customisation of the templates. Currently, there are 2 templates: one for the Lustre hosts (servers and clients), one for the Admin host
1. The `remove-ve.sh` script does not remove the VM disk images.
1. Only supports RHEL or CentOS guests

