# <div align="center">Automatic configuration and installation of GlusterFS with encryption and any number of nodes</div>

<div align="center">
  <img src="/docs/screenshots/glusterfs.png" width="50%" /> 
</div>


[GlusterFS](https://www.gluster.org/) is a free and open source scalable network filesystem. Gluster is a scalable network filesystem. Using common off-the-shelf hardware, you can create large, distributed storage solutions for media streaming, data analysis, and other data and bandwidth-intensive tasks.

### What does the project do? 
This project automatically installs GlusterFS and configures a cluster with encryption and any number of nodes.

### What problem does it solve?
- Single point of failure. Data is automatically replicated between different nodes. If one or more servers fail, file access is not interrupted.
- Consolidates thousands of servers into a single shared volume. Storage capacity can be scaled on the fly to petabytes.
- Enables the construction of reliable storage systems using common, inexpensive hardware instead of purchasing expensive disk arrays.

## Main features
- Only 3 files to run
- Runs from the terminal
- Answer questions in the terminal to configure
- Automatic encryption setup
- Tested in a production environment

## What do files do?

```part_1.sh```

 - Checking the etc/hosts file and adding the host name with the IP address there
 - Checking the node's time synchronization is very important; if there is no synchronization, the system does not work.
 - Checking the repository, adding and installing the GlusterFS server
 - Checking the firewall, adding services and ports for communication
 - Issues certificates (you can specify the number of days here), adds encryption settings, and adds the service to startup
 - Done

---

```part_2.sh```
 
 - Setting up network access between machines. This will also ask how many machines you have in the cluster, etc.
 - Synchronizing the /etc/hosts file between all machines in the cluster
 - We define the user gluster
 - Collecting and distributing certificates between machines in a cluster
 - Checking external nodes and waiting for a connection (using hostnames)
 - Creating a volume and monitoring it. Configuring the volume for replication is also possible here.
 - Turn on TLS
 - Starts the mounted volume on all nodes, cleans up FUSE, and adds volumes on all nodes to startup
 - Displays the current cluster state on the terminal screen.
 - Done

---

```health_check.sh```

A file that checks the cluster status and writes a log with output to the terminal. It's best to add this file to the cron service.
- Checking the glusterd service
- Checking the status of nodes (peer)
- Checking volume status
- Checking the status of bricks
- Checking the status of healing/treatment failure (split brain)
- Mount and disk usage check (readiness check + exact errors)
- TLS certificate expiration check (15 days - WARNING, 5 days - CRITICAL)
- Checking time synchronization (NTP/Chrony)
- Split-brain detection test and automatic resolution
- Status output, error output

## Installation
- Installation and configuration should be performed on at least 2 nodes, but preferably 3, 5, etc. 
- The machines must communicate with each other. 
- Only distributions that use the DNF package manager (e.g. Oracle Linux or Alma Linux) are supported.

Install and download the repository on each computer.

```sh
dnf install git -y && git clone https://github.com/sergeybezlepkin/glusterfs.git
```
- Run the ```part_1.sh``` file on each node.

- Select a node and run the file ```part_2.sh.``` This node will be the leader after configuration. Configuration will be performed via terminal prompts.

## License

This project uses the [MIT](https://github.com/sergeybezlepkin/glusterfs/blob/main/LICENSE)
