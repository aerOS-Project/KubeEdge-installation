# KubeEdge installation steps

This installation procedure **only works for Linux machines**. List of devices successfully tested as KubeEdge edge nodes (CPU architecture, RAM):

- Virtual Machines (AMD64, 1-2-4 GB)
- Raspberry Pi 5 (ARM64, 4-8 GB)
- Raspberry Pi 4 (ARM64, 4 GB)
- Raspberry Pi 3 (ARM64, 1 GB)
- Raspberry Pi Zero 2W (ARM64, 512 MB)

The latest KubeEdge version that has been tested is v1.19.1

## Raspberry Pi OS prerequirements

- Recommended stack for Raspberry Pi: *Raspberry Pi OS server 64 bits* (ARM64) and *containerd 1.7.28*

1. Enable cgroups (more info [here](https://docs.k3s.io/installation/requirements?os=pi#cgroups)). Just edit the */boot/cmdline.txt* or */boot/firmware/cmdline.txt* file to add this content:

```bash
cgroup_memory=1 cgroup_enable=memory
```

2. Install iptables

```bash
sudo apt install iptables -y
```

3. Restart the machine


## General prerequirements

The CPU architecture of the machines that will become KubeEdge nodes (both cloud and edge) must be known in advance. Currently, the valid CPU architectures (it must be used this exact naming) are the following:

- amd64
- arm64
- arm32 (not recommended)

Then, a *NODE_ARCH* environment variable **must be set** after starting with the step 2. You can do it manually:

```bash
export NODE_ARCH=arm64
```

or running the [getCpuArch.sh](./resources/scripts/getCpuArch.sh) script:
```bash
chmod +x getCpuArch.sh
export NODE_ARCH=$(./getCpuArch.sh)
```


## 1. Install a K8s cluster to act as the Cloud tier of KubeEdge

**It is recommended to deploy a single-node K8s cluster to test KubeEdge from scratch**. In the future, the idea is to test the intereaction among a full K8s cluster with more than one node and KubeEdge nodes under complex network topologies.

### Using the [provided script](./resources/k8s-installation-scripts/kubernetes-1.29-kubeedge.sh)

To deploy a K8s v1.29.12 cluster with a single node (the Control Plane node with Pod scheduling enabled), use the *-t SERVER* option, then choose a Pod CIDR and set it using the *-p* option.

```bash
chmod +x kubernetes-1.29-kubeedge.sh
./kubernetes-1.29-kubeedge.sh -t SERVER -p "10.216.0.0/16"
```

To deploy more K8s worker nodes, just use the *-t AGENT* option. The script will install *keadm*, but you have to [manually join the node](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/) to the existing K8s cluster.

```bash
chmod +x kubernetes-1.29-kubeedge.sh
./kubernetes-1.29-kubeedge.sh -t AGENT
```

Then, obtain the *kubeadm join command* in the Control Plane node:
```bash
kubeadm token create --print-join-command
```

Finally, just run the obtained *join command*
```bash
kubeadm join <node-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash>
```

### Following your own procedure

In the K8s cluster creation process, **only deploy the CNI plugin (e.g. Flannel, Cilium, ..) Pods in the original K8s cluster nodes** (not KubeEdge nodes running Edgecore). **If you are using the custom K8s installation script, you can avoid this subsection** because it means that you have succesfully installed a K8s cluster compliant with KubeEdge.

Therefore, use the [custom Flannel Helm chart](./resources/helm-charts-manifests/flannel-helm-chart-kubeedge.tgz) to install Flannel DaemonSet only in the cloud nodes (the nodes of the K8s cluster).

```bash
helm install flannel --set podCidr="10.216.0.0/16" --namespace kube-flannel flannel-helm-chart-kubeedge.tgz --debug
```

As in the CNI plugin installation, if you are using a custom K8s storage tool such as OpenEBS, please deploy its DaemonSet only in the cloud nodes. In case you are using OpenEBS, create a YAML file (also availabe [here](./resources/helm-charts-manifests/openebs-kubeedge-values.yaml)) with this values (currently we are deploying the DaemonSet Pods only in the Control Plane node because the OpenEBS Helm chart only supports NodeSelector -instead of affinity-, so this chart should be modified):

```yaml
ndm:
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
```

and then install the OpenEBS Helm chart using it:

```bash
helm install openebs openebs/openebs -n openebs -f openebs-kubeedge-values.yaml --debug
```

Of course, you are free to use an alternative K8s storage plugin such as [Rancher Local Path Provisioner](https://github.com/rancher/local-path-provisioner).

Currently, KubeEdge only [supports this Volume types](https://kubeedge.io/docs/advanced/storage):

- configMap
- csi
- downwardApi
- emptyDir
- hostPath
- projected
- secret

Finally, remove the taint of the K8s Control Plane nodes:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```


## 2. Install KubeEdge cloudcore in the K8s cluster

These steps must be performed preferably in the K8s Control Plane node machine.

1. [Install keadm](https://kubeedge.io/docs/setup/install-with-keadm#install-keadm):

```bash
wget https://github.com/kubeedge/kubeedge/releases/download/v1.19.1/keadm-v1.19.1-linux-${NODE_ARCH}.tar.gz
tar -zxvf keadm-v1.19.1-linux-${NODE_ARCH}.tar.gz
cp keadm-v1.19.1-linux-${NODE_ARCH}/keadm/keadm /usr/local/bin/keadm
rm -r keadm-v1.19.1-linux-${NODE_ARCH}.tar.gz
rm -r keadm-v1.19.1-linux-${NODE_ARCH}
```

2. [Install KubeEdge cloudcore](https://kubeedge.io/docs/setup/install-with-keadm#setup-cloud-side-kubeedge-master-node) using the Helm chart:

```bash
keadm init --advertise-address="<cloudcore-advertise-address>" --kubeedge-version=v1.19.1 --kube-config=<path-to-kubeconfig-file> --set cloudCore.modules.dynamicController.enable=true
```


## 3. Install KubeEdge edgecore in the edge nodes

1. Install *containerd* as container runtime (find more info [here](https://github.com/containerd/containerd/blob/main/docs/getting-started.md) about containerd installation and configuration)

```bash
wget https://github.com/containerd/containerd/releases/download/v1.7.28/containerd-1.7.28-linux-${NODE_ARCH}.tar.gz
tar Cxzvf /usr/local containerd-1.7.28-linux-${NODE_ARCH}.tar.gz
rm -r containerd-1.7.28-linux-${NODE_ARCH}.tar.gz
wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
mkdir -p /usr/local/lib/systemd/system
mv containerd.service /usr/local/lib/systemd/system/containerd.service


wget https://github.com/opencontainers/runc/releases/download/v1.1.11/runc.${NODE_ARCH}
install -m 755 runc.${NODE_ARCH} /usr/local/sbin/runc
rm runc.${NODE_ARCH}
```

2. Install CNI plugins

```bash
wget https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-${NODE_ARCH}-v1.4.0.tgz
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-${NODE_ARCH}-v1.4.0.tgz
rm cni-plugins-linux-${NODE_ARCH}-v1.4.0.tgz
```

3. Configure containerd and restart it

```bash
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
```

- To debug the containerd service, run:

```bash
journalctl -xeu containerd
```

- Additional: install *crictl* to debug running containers and Pods

```bash
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.29.0/crictl-v1.29.0-linux-${NODE_ARCH}.tar.gz
tar Cxzvf /usr/bin crictl-v1.29.0-linux-${NODE_ARCH}.tar.gz
rm crictl-v1.29.0-linux-${NODE_ARCH}.tar.gz
crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
```

4. Create the CNI configuration. Currently, a simple bridge network configuration is used, so create the file [10-containerd-net.conflist](./resources/cni-configurations/10-containerd-net.conflist) inside the folder */etc/cni/net.d/* with this content:

```json
{
  "cniVersion": "1.0.0",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "<node-pod-subnet>"
          }]
        ],
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
```

For each edge node, please use a different subnet (e.g. 10.216.2.0/24, 10.216.3.0/24, ...). This subnets should be inside the K8s Pod CIDR range (e.g. 10.216.0.0/16), which is usually configured in the K8s cluster and/or in the CNI plugin installation process. For instance, in our K8s installation script it is configured both in the K8s installation using Kubeadm and in the Flannel installation.


5. [Install keadm](https://kubeedge.io/docs/setup/install-with-keadm#install-keadm):

```bash
wget https://github.com/kubeedge/kubeedge/releases/download/v1.19.1/keadm-v1.19.1-linux-${NODE_ARCH}.tar.gz
tar -zxvf keadm-v1.19.1-linux-${NODE_ARCH}.tar.gz
cp keadm-v1.19.1-linux-${NODE_ARCH}/keadm/keadm /usr/local/bin/keadm
rm -r keadm-v1.19.1-linux-${NODE_ARCH}.tar.gz
rm -r keadm-v1.19.1-linux-${NODE_ARCH}
```

6. Get the keadm join token **in the cloudcore machine**

```bash
keadm gettoken
```

7. [Join the edge node](https://kubeedge.io/docs/setup/install-with-keadm#setup-cloud-side-kubeedge-master-node) to the KubeEdge cluster

```bash
keadm join --cloudcore-ipport=<cloudcore-advertise-address>:10000 --token=<keadm-join-token> --kubeedge-version=v1.19.1 --cgroupdriver=systemd --runtimetype=remote
```

- To debug the edgecore service, run:

```bash
journalctl -xeu edgecore
```

## 4. [Enable Kubectl logs/exec to debug Pods on the edge](https://kubeedge.io/docs/advanced/debug/) (optional)

### 4.1 In cloud node

1. Make sure you can find the kubernetes *ca.crt* and *ca.key* files in the **cloud node**. If you set up your kubernetes cluster by kubeadm, those files will be in */etc/kubernetes/pki/* dir.
```bash
ls /etc/kubernetes/pki/
```
2. Set *CLOUDCOREIPS* env. The environment variable is set to specify the IP address of cloudcore, or a VIP if you have a highly available cluster.
```bash
export CLOUDCOREIPS="<cloudcore-advertise-address"
```
- (Warning: the same terminal is essential to continue the work, or it is necessary to type this command again.) Checking the environment variable with the following command:
```bash
echo $CLOUDCOREIPS
```
3. Run the *certgen.sh* script to generate the needed certificates
```bash
mkdir /etc/kubeedge
wget https://raw.githubusercontent.com/kubeedge/kubeedge/master/build/tools/certgen.sh
cp certgen.sh /etc/kubeedge
cd /etc/kubeedge
chmod +x certgen.sh
./certgen.sh stream
```
4. Set iptables rules
```bash
iptables -t nat -A OUTPUT -p tcp --dport 10350 -j DNAT --to $CLOUDCOREIPS:10003
```

5. In the 1.19.1 version of KubeEdge, the *cloudStream* module is enabled by default, so you don't need to edit the cloudcore's ConfigMap to enable it. However, if you are using a previous version of KubeEdge, you should enable the *cloudStream* module in the cloudcore's ConfigMap.
You can check this configuration in the *cloudcore* ConfigMap:

```bash
kubectl get cm cloudcore -n kubeedge -o yaml
```

This is the desired configuration:

```yaml
modules:
  cloudStream:
    enable: true
    streamPort: 10003
    tlsStreamCAFile: /etc/kubeedge/ca/streamCA.crt
    tlsStreamCertFile: /etc/kubeedge/certs/stream.crt
    tlsStreamPrivateKeyFile: /etc/kubeedge/certs/stream.key
    tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
    tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
    tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
    tunnelPort: 10004
```

### 4.2 In all edge nodes
1. Edit */etc/kubeedge/config/edgecore.yaml* with the desired configuration:

```yaml
edgeStream:
  enable: true
  handshakeTimeout: 30
  readDeadline: 15
  server: <cloudcore-advertise-address>:10004
  tlsTunnelCAFile: /etc/kubeedge/ca/rootCA.crt
  tlsTunnelCertFile: /etc/kubeedge/certs/server.crt
  tlsTunnelPrivateKeyFile: /etc/kubeedge/certs/server.key
  writeDeadline: 15
```

2. Finally, restart the edgecore service to apply the configuration changes

```bash
systemctl restart edgecore
```


## 5. [Collect metrics from edge](https://kubeedge.io/docs/advanced/metrics/) using K8s Metrics Server (optional)

After enabling Kubectl logs/exec to debug Pods on the edge (step 4), deploy the previously updated [Metrics Server K8s manifests](./resources/helm-charts-manifests/deploy-k8s-metrics-server.yaml) from this repository:

```bash
kubectl apply -f deploy-k8s-metric-server.yaml
```

Then, check if metrics are shown:

```bash
kubectl top node
```

## 6. Install EdgeMesh

After the installation of EdgeMesh, all [test cases](https://edgemesh.netlify.app/guide/test-case) described in its official documentation have been passes successfully.

### 6.1 Prerequirements in cloud node

You should have enabled the *dynamicController* module during the installation of the CloudCore using the *--set cloudCore.modules.dynamicController.enable=true* flag
If you're not sure, you can check it in the *cloudcore* ConfigMap:

```bash
kubectl get cm cloudcore -n kubeedge -o yaml
```

This is the desired configuration:

```yaml
modules:
  dynamicController:
    enable: true
```

1. Add filter labels to Kubernetes API services
```bash
kubectl label services kubernetes service.edgemesh.kubeedge.io/service-proxy-name=""
```


### 6.2 Prerequirements in all edge nodes

1. Edit */etc/kubeedge/config/edgecore.yaml* with the desired configuration:
```yaml
modules:
  edged:
    tailoredKubeletConfig:
      clusterDNS:
      - 169.254.96.16
      clusterDomain: cluster.local
  metaManager:
    metaServer:
      enable: true
```

2. Restart the edgecore service to apply the configuration changes
```bash
systemctl restart edgecore
```

3. Test if the Edge Kube-API Endpoint works properly
```bash
curl 127.0.0.1:10550/api/v1/services
```
- The response should be like this one:
```json
{"apiVersion":"v1","items":[{"apiVersion":"v1","kind":"Service","metadata":{"creationTimestamp":"2021-04-14T06:30:05Z","labels":{"component":"apiserver","provider":"kubernetes"},"name":"kubernetes","namespace":"default","resourceVersion":"147","selfLink":"default/services/kubernetes","uid":"55eeebea-08cf-4d1a-8b04-e85f8ae112a9"},"spec":{"clusterIP":"10.96.0.1","ports":[{"name":"https","port":443,"protocol":"TCP","targetPort":6443}],"sessionAffinity":"None","type":"ClusterIP"},"status":{"loadBalancer":{}}},{"apiVersion":"v1","kind":"Service","metadata":{"annotations":{"prometheus.io/port":"9153","prometheus.io/scrape":"true"},"creationTimestamp":"2021-04-14T06:30:07Z","labels":{"k8s-app":"kube-dns","kubernetes.io/cluster-service":"true","kubernetes.io/name":"KubeDNS"},"name":"kube-dns","namespace":"kube-system","resourceVersion":"203","selfLink":"kube-system/services/kube-dns","uid":"c221ac20-cbfa-406b-812a-c44b9d82d6dc"},"spec":{"clusterIP":"10.96.0.10","ports":[{"name":"dns","port":53,"protocol":"UDP","targetPort":53},{"name":"dns-tcp","port":53,"protocol":"TCP","targetPort":53},{"name":"metrics","port":9153,"protocol":"TCP","targetPort":9153}],"selector":{"k8s-app":"kube-dns"},"sessionAffinity":"None","type":"ClusterIP"},"status":{"loadBalancer":{}}}],"kind":"ServiceList","metadata":{"resourceVersion":"377360","selfLink":"/api/v1/services"}}
```

### 6.3 [Helm chart installation](https://github.com/kubeedge/edgemesh/blob/main/build/helm/edgemesh/README.md) in cloud node

1. Generate a PSK cipher
```bash
openssl rand -base64 32
```

2. Select one or more *relay nodes*. The relay nodes are nodes with a public IP (or at least reachable by the "internal" nodes) that
   allow to stablish connections between edge internal nodes that are behind a firewall or a LAN using NAT
   
  Currently, we are using a single relay node which is the cloud node (the Control Plane node of the K8s cluster).
   
3. Install EdgeMesh using its Helm chart
```bash
helm install edgemesh --namespace kubeedge \
    --set agent.psk=<psk-cipher-string> \
    --set agent.relayNodes[0].nodeName=<k8s-cluster-master-node>,agent.relayNodes[0].advertiseAddress="{<cloudcore-advertise-address>}" \
    https://raw.githubusercontent.com/kubeedge/edgemesh/release-1.17/build/helm/edgemesh.tgz
```

## 7. [Uninstall KubeEdge](https://kubeedge.io/docs/setup/install-with-keadm#reset-kubeedge-master-and-worker-nodes)

### 7.1 Edge nodes

1. In the cloud node, drain the edge node
```bash
kubectl drain <node-name> --delete-emptydir-data --force --ignore-DaemonSets
```
2. In the cloud node, delete the edge node
```bash
kubectl delete node <node-name>
```
3. In the edge node, uninstall edgecore service
```bash
keadm reset edge
rm -r /etc/kubeedge
```
4. Reboot the machine

### 7.2 Cloud node

1. Uninstall EdgeMesh
```bash
helm uninstall -n kubeedge edgemesh
```

2. Uninstall KubeEdge
```bash
keadm reset
```

3. Reboot the machine

## Future work

- (X) Test with newer K8s versions (up to 1.29.12).
- (X) Use CRI-O as container runtime (tested with 1.29.13 version).
- Install Cilium as CNI plugin for the K8s cluster (not KubeEdge edge nodes). Thus, a modification of the Cilium Helm chart values or even the chart itself must be explored.
  It doesn't work properly as Edge nodes cannot reach the IPs of the Svc of type ClusterIP
  - Now KubeEdge supports the use of Cilium + Wireguard in Edge nodes: check this blog entry https://kubeedge.io/blog/enable-cilium
- Test advanced EdgeMesh features:
  - (X) Add more EdgeMesh relay nodes that are connected to different networks.
  - (X) Test in depth EdgeMesh network connections.
  - Test Edge Gateway (an Ingress for edge services).
- Test in ARM32 devices and also in Windows Server 2019 (functionality added in v1.16.0).
- (X) Update to newer versions of KubeEdge (1.19.0) and EdgeMesh (1.16.0) -> 1.19.1 and 1.17.0
- Allow edge Pods to use in-cluster config to access Kube-APIServer https://kubeedge.io/docs/advanced/inclusterconfig/
- Test KubeEdge Dashboard https://kubeedge.io/blog/dashboard-getting-started

## Issues created in the KubeEdge repository
- [#5139](https://github.com/kubeedge/kubeedge/issues/5139)
- [#5153](https://github.com/kubeedge/kubeedge/issues/5153)
- [#5344](https://github.com/kubeedge/kubeedge/issues/5344)
- [#6387](https://github.com/kubeedge/kubeedge/issues/6387)
- [#6464](https://github.com/kubeedge/kubeedge/issues/6464)
- (EdgeMesh) [#423](https://github.com/kubeedge/edgemesh/issues/423)

And a discussion: [#5134](https://github.com/kubeedge/kubeedge/discussions/5145)