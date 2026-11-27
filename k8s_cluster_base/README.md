# Kubernetes cluster with kubeadm (Ansible)

Ansible playbook that builds an on-premises Kubernetes cluster for OpenLM:

- **HAProxy load balancer** in front of the cluster: TLS termination for your hostnames, Kubernetes API on port 6443
- **kubeadm** Kubernetes 1.32 with **Calico** networking and **metrics-server**
- **storage**: local disk (`hostpath`) or replicated **Longhorn**, optionally an extra **NFS** StorageClass
- **node roles**: every node gets a `role=<name>` label and taint, so workloads land on the nodes meant for them

It starts small and scales out by adding workers to the inventory.

**Smallest setup: 2 VMs.** One Kubernetes node that is both the control plane and the worker (`examples/hosts-single-node.ini`), plus the load balancer. The load balancer has to be its own machine: it listens on 80, 443 and 6443, the same ports the node's ingress controller and API server use. Add workers later without rebuilding (see [Scaling out](#scaling-out)).

## Flow

```
 Users / kubectl
      |
      |  https://apps.example.com (443)      kubectl (6443)
      v
 +-------------------------------+
 | Load balancer (HAProxy)       |   TLS terminates here (your certificate)
 |  80  -> redirect to 443       |
 |  443 -> ingress nodes :80     |
 |  6443 -> masters :6443 (TCP)  |
 +-------------------------------+
      |                    |
      v                    v
 +-----------+      +-------------------+
 | master(s) | <--> | workers           |   Calico pod network between all nodes
 | API, etcd |      | ingress (Traefik) |
 +-----------+      | applications      |
                    +-------------------+
```

The playbook runs in this order, one tag at a time:

```
haproxy -> node_prep -> init_master -> join_worker -> node_affinity_taint -> ns -> storage_install
   LB       all nodes    first master    workers        labels + taints      namespaces   storage
```

## Requirements

### Machines

| Machine | Minimum | Notes |
|---|---|---|
| Load balancer | 2 vCPU, 2 GB RAM, 20 GB disk | Separate machine: it uses ports 80/443/6443 itself. RHEL/AlmaLinux/Rocky 9 or Ubuntu 22.04/24.04 |
| Master (control plane) | 4 vCPU, 8 GB RAM, 50 GB disk | Ubuntu 22.04/24.04 |
| Worker | 4 vCPU, 16 GB RAM, 100 GB disk | Ubuntu 22.04/24.04. Size by the OpenLM applications you run |
| Single-node setup (master runs workloads) | 8 vCPU, 32 GB RAM, 150 GB disk | The master's size must cover both roles |

- Static IPs, and every node has a unique hostname.
- The inventory names of masters and workers must be the node hostnames (`hostname`). Labels and taints are applied by that name.
- Swap is turned off by the playbook. Images and containers live in `/var/lib/containerd`; a separate data disk can be used instead (see `node_data_disk_mount` in `roles/node_prep/defaults/main.yml`).
- Internet access from all machines (OS packages, `pkgs.k8s.io`, Helm charts, container registries), directly or through a proxy configured on the OS.

### Network and DNS

| DNS record | Points to | Used for |
|---|---|---|
| `load_balancer_dns`, e.g. `k8s-lb.example.com` | load balancer IP | Kubernetes API (nodes, kubectl) |
| each name in `haproxy_hosts`, e.g. `apps.example.com` | load balancer IP | your applications |

| From | To | Ports |
|---|---|---|
| Users | load balancer | TCP 80, 443 (and 27017 / 30000 if MongoDB / Kafka passthrough is enabled) |
| Admins, nodes | load balancer | TCP 6443 (Kubernetes API); 8081 for the HAProxy stats page (admins only) |
| Load balancer | masters | TCP 6443 |
| Load balancer | ingress nodes | TCP 80 (and 27017 / 30000 if enabled) |
| All cluster nodes | all cluster nodes | everything. At least: TCP 6443, 2379-2380, 10250, 179 (Calico BGP), IP protocol 4 (IP-in-IP) or UDP 4789 (VXLAN). Longhorn also needs TCP 9500-9504 and iSCSI |

The pod network `pod_network_cidr` (default `172.16.0.0/12`) and the service network `10.96.0.0/12` must not overlap your node or office networks. Change `pod_network_cidr` before installing if they do.

### TLS certificate

TLS terminates on the load balancer. HAProxy needs **one PEM file** that contains the certificate, the intermediate chain and the private key:

```bash
cat apps.example.com.crt intermediate.crt apps.example.com.key > cluster.pem
```

It must be valid for every hostname in `haproxy_hosts`; a wildcard certificate (`*.example.com`) is the simplest. Either put it on the load balancer at `haproxy_cert_path` yourself, or set `haproxy_cert_src` to the local file and the playbook copies it there (mode 0600). The playbook stops if the file is missing.

When the certificate is renewed, replace the file and reload HAProxy (`systemctl reload haproxy`), or re-run `--tags haproxy` with `haproxy_cert_src`.

The Kubernetes API (6443) is passed through as TCP. Its certificates are created by kubeadm and are separate from yours.

### Control machine (where you run Ansible)

- Ansible 2.15 or newer, Python 3
- SSH access with a key to every machine, as a user that can `sudo`
- The collections in `requirements.yml`:

```bash
ansible-galaxy collection install -r requirements.yml
```

## Setup

### 1. Inventory

Pick the example that matches your layout and copy it:

| Example | Layout |
|---|---|
| `examples/hosts-single-node.ini` | one machine runs the control plane and the workloads |
| `examples/hosts-master-workers.ini` | dedicated master + workers |
| `examples/hosts-master-infra-workers.ini` | master + an infrastructure node (ingress, databases, storage) + application workers |

```bash
mkdir -p inventory/group_vars
cp examples/hosts-single-node.ini inventory/hosts.ini
cp examples/group_vars-all.yml inventory/group_vars/all.yml
```

`ansible.cfg` already points at `inventory/hosts.ini`.

| Group | Contains | Per-host settings |
|---|---|---|
| `[masters]` | control-plane node(s); the first one initializes the cluster | `ansible_host`, `node_label`, `node_taint` |
| `[workers]` | nodes that run workloads | `ansible_host`, `node_label`, `node_taint`, `node_data_disk_mount` (optional) |
| `[lb]` | the HAProxy machine | `ansible_host` |

`node_label` / `node_taint` set the node role (`role=main`, `role=infrastructure`, ...). Nodes without them get `default_label` / `default_taints` (`main`).

**Master that runs workloads:** list it in `[masters]` and in `[workers]`. It then gets its role label and taint like a worker, and the control-plane taint is removed. A master only in `[masters]` keeps the control-plane taint and runs no workloads.

### 2. Settings

Edit `inventory/group_vars/all.yml`. Required:

| Setting | Example | Meaning |
|---|---|---|
| `load_balancer_dns` | `k8s-lb.example.com` | DNS name of the load balancer, the cluster's API endpoint |
| `haproxy_hosts` | `[apps.example.com]` | public hostnames of your applications |
| `haproxy_cert_path` | `/etc/haproxy/certs/cluster.pem` | PEM on the load balancer |
| `haproxy_stats_pass` | (secret) | password of the stats page, or `haproxy_stats_enabled: false` |

Also review `storage_type` (`hostpath` for one node, `longhorn` for several), `haproxy_ingress_nodes` (where the ingress controller runs) and `k8s_namespaces_extra`. Every setting is described in the file and in `roles/<role>/defaults/main.yml`.

Keep the stats password out of plain text, for example:

```bash
ansible-vault encrypt_string 'the-password' --name haproxy_stats_pass >> inventory/group_vars/all.yml
```

and add `--ask-vault-pass` to the commands below.

## Usage

Run the tags one at a time, in this order, and check each step before the next. `-K` asks for the sudo password (leave it out with passwordless sudo).

```bash
ansible-playbook deploy-pbk.yml -K --tags haproxy           # load balancer + TLS
ansible-playbook deploy-pbk.yml -K --tags node_prep         # packages, containerd, kernel settings, kubeadm
ansible-playbook deploy-pbk.yml -K --tags init_master       # kubeadm init on the first master, Calico
ansible-playbook deploy-pbk.yml -K --tags join_master       # only with more than one master
ansible-playbook deploy-pbk.yml -K --tags join_worker       # join the workers
ansible-playbook deploy-pbk.yml -K --tags node_affinity_taint  # role labels and taints
ansible-playbook deploy-pbk.yml -K --tags metrics_server    # kubectl top
ansible-playbook deploy-pbk.yml -K --tags ns
ansible-playbook deploy-pbk.yml -K --tags storage_install
```

On a single node, `calico-typha` stays `Pending` and the node's Calico pod not ready after `init_master`: the only node still has the control-plane taint. That is expected; `node_affinity_taint` removes the taint (the master is in `[workers]`) and Calico becomes ready. Run it before `metrics_server`.

Every step can be re-run safely: finished work (an initialized master, joined nodes, installed charts) is detected and skipped.

`node_prep` adds kernel arguments (`node_kernel_args`) to GRUB; they take effect at the next reboot. Current Ubuntu releases already have the needed cgroups enabled, so a reboot is not required to continue.

### Check the cluster

On the first master:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A
```

All nodes `Ready`, all pods `Running`. To use kubectl from your own machine, copy `/etc/kubernetes/admin.conf` from the first master to `~/.kube/config`; it already points at `https://<load_balancer_dns>:6443`. It is a full admin credential, keep it safe.

The load balancer's stats page is at `http://<load balancer>:8081/stats`. The ingress backend shows DOWN until an ingress controller runs on the ingress nodes.

### Namespaces

`--tags ns` creates the namespaces the OpenLM platform is deployed into:

| Namespace | For |
|---|---|
| `openlm` | OpenLM applications |
| `openlm-infrastructure` | shared infrastructure |
| `openlm-telemetry` | monitoring: Grafana, Prometheus, Loki, Tempo, OpenTelemetry |
| `redis` | Redis |
| `traefik` | ingress controller |
| `headlamp` | Kubernetes web UI |

Keep these names. The OpenLM services and the API gateway reach each other through in-cluster service names (`<service>.<namespace>.svc`), so a different namespace breaks those calls. Add your own namespaces with `k8s_namespaces_extra`.

### Running workloads

Every node that runs workloads is tainted `role=<name>:NoSchedule`. A pod runs only where it tolerates the taint, so give your deployments a toleration and a node selector for their role:

```yaml
nodeSelector:
  role: main
tolerations:
  - key: role
    operator: Equal
    value: main
    effect: NoSchedule
```

Pods without a `role` toleration stay `Pending`. Calico, CoreDNS, metrics-server, Longhorn, the NFS driver and the local-path provisioner already tolerate every `role` taint.

The ingress controller (for example Traefik) must run with `hostNetwork` on the nodes in `haproxy_ingress_nodes` and listen on port 80. The load balancer sends all HTTPS traffic for `haproxy_hosts` there, already decrypted, with `X-Forwarded-Proto: https`.

## Scaling out

**Add a worker:** add it to `[workers]` with its `node_label` / `node_taint`, then:

```bash
ansible-playbook deploy-pbk.yml -K --tags node_prep,join_worker,node_affinity_taint
```

With Longhorn, also run `--tags longhorn_prereqs` (plus `longhorn_storage_nodes` if you restrict where data lives).

**Single node to dedicated master:** once enough workers run the workloads, drain the master (`kubectl drain <master> --ignore-daemonsets --delete-emptydir-data`), remove it from `[workers]` and re-run `--tags node_affinity_taint`. The control-plane taint is put back before the role taint is removed, then `kubectl uncordon <master>`. Data on `hostpath` volumes stays on the master's disk and has to be moved by you.

**More masters:** add them to `[masters]` and run `--tags node_prep,join_master`, then `--tags haproxy` so the load balancer sends API traffic to all of them. Use an odd number (1 or 3).

Re-run `--tags haproxy` whenever you change `haproxy_hosts`, `haproxy_ingress_nodes` or the masters.

## Storage

| `storage_type` | StorageClass | Data lives on | Use for |
|---|---|---|---|
| `hostpath` (default) | `hostpath` | the local disk of the node where the pod first ran. Lost if that node is lost | single node, test setups |
| `longhorn` | `longhorn` | `longhorn_replica_count` copies on different nodes | several nodes |

`nfs_storageclass_enabled: true` adds an `nfs` StorageClass on an existing NFS export (each volume becomes a folder on the share). Use it for files, not for databases (MongoDB, Kafka, Prometheus need block storage). The export must be reachable from every node with `rw,sync,no_subtree_check,no_root_squash`.

Longhorn: the UI is not exposed. Use `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` and open http://localhost:8080. Backups to NFS: set `longhorn_backup_target`.

## Tags

| Tag | Does |
|---|---|
| `haproxy` | Install and configure HAProxy on `[lb]`, check the certificate |
| `node_prep` | All node preparation (sub-tags `packages`, `data_disk`, `containerd`, `cgroup`, `swap`, `k8s_install`) |
| `init_master` | `kubeadm init` on the first master, Calico, role tolerations for Calico and CoreDNS |
| `join_master` / `join_worker` | Join additional masters / workers |
| `metrics_server` | metrics-server (`kubectl top`) |
| `node_affinity_taint` | Role labels and taints (sub-tags `node_label`, `node_taint`) |
| `ns` | Create the OpenLM namespaces plus `k8s_namespaces_extra` |
| `storage_install` | Storage (sub-tags `hostpath`, `longhorn`, `longhorn_prereqs`, `nfs_storageclass`) |

To limit node tasks to some nodes, pass `-e '{"only_nodes":["k8s-w-3"]}'`. `--limit` does not work here: the roles run once and loop over the inventory groups.

## Troubleshooting

| Symptom | Check |
|---|---|
| `haproxy` stops: certificate not found | `haproxy_cert_path` on the LB, or set `haproxy_cert_src` |
| `init_master` hangs or the API is unreachable | DNS of `load_balancer_dns`, port 6443 open LB -> master, `haproxy` ran first |
| Node `NotReady` | `kubectl -n calico-system get pods -o wide`; traffic between nodes allowed (see ports) |
| Pods `Pending` | `kubectl describe pod`: usually a missing `role` toleration, or no StorageClass for the PVC |
| Ingress backend DOWN on the stats page | ingress controller not running with hostNetwork on `haproxy_ingress_nodes` |
| Kubernetes upgrade | after `kubeadm upgrade`, re-run `--tags init_master` (puts the CoreDNS tolerations back); bump `kubernetes_repo_url` per minor version |

`scripts/move-containerd-to-data-disk.sh` moves the images of an existing node to a data disk (drain the node first). It is a bash script for Linux nodes: `sudo bash scripts/move-containerd-to-data-disk.sh <mount>`, then `--cleanup` once the node is healthy.
