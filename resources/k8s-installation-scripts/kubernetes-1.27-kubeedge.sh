#!/bin/bash

function install_prerequirements() {
    swapoff -a
    sudo apt-get install ebtables ethtool -y
    sudo apt-get update -y
    sudo apt-get install -y curl
    # check both commands if preflights errors
    # modprobe br_netfilter
    # sudo sh -c 'echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf'
    # echo '1' > /proc/sys/net/ipv4/ip_forward
    # sudo sysctl -w net.ipv4.ip_forward=1 # permanent: edit /etc/sysctl.conf and sudo sysctl -p /etc/sysctl.conf

    # From official K8s doc
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    # sysctl params required by setup, params persist across reboots
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # Apply sysctl params without reboot
    sudo sysctl --system
}

function install_containerd() {
  # install containerd
  echo "Installing containerd"
  wget https://github.com/containerd/containerd/releases/download/v1.7.11/containerd-1.7.11-linux-amd64.tar.gz
  tar Cxzvf /usr/local containerd-1.7.11-linux-amd64.tar.gz
  rm -r containerd-1.7.11-linux-amd64.tar.gz
  wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
  mkdir -p /usr/local/lib/systemd/system
  mv containerd.service /usr/local/lib/systemd/system/containerd.service

  # install runc
  echo "Installing runc"
  wget https://github.com/opencontainers/runc/releases/download/v1.1.11/runc.amd64
  install -m 755 runc.amd64 /usr/local/sbin/runc
  rm runc.amd64

  # install CNI plugins
  echo "Installing CNI plugins"
  wget https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz
  mkdir -p /opt/cni/bin
  tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.4.0.tgz
  rm cni-plugins-linux-amd64-v1.4.0.tgz
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
  systemctl restart containerd

  # install crictl (optional)
  wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz
  tar Cxzvf /usr/bin crictl-v1.28.0-linux-amd64.tar.gz
  rm crictl-v1.28.0-linux-amd64.tar.gz
  crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
}

function install_kubeadm() {
    sudo apt-get update && sudo apt-get install -y apt-transport-https
    sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.27/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.27/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -y
    echo "Installing Kubernetes Packages ..."
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
}

function init_kubeadm() {
    sudo swapoff -a
    sudo sed -i.bak '/.*none.*swap/s/^\(.*\)$/#\1/g' /etc/fstab
    sudo sed -i '/swap/d' /etc/fstab
    cat <<EOF > /tmp/kubeadm-init-args.conf
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: $POD_CIDR
EOF
    sudo kubeadm init --config /tmp/kubeadm-init-args.conf
    sleep 5
}

function kube_config_dir() {
    K8S_MANIFEST_DIR="/etc/kubernetes/manifests"
    mkdir -p $HOME/.kube
    sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

function install_helm() {
    HELM_VERSION=$(curl -L --silent --show-error --fail "https://get.helm.sh/helm-latest-version" 2>&1)
    if ! [[ "$(helm version --short 2>/dev/null)" =~ ^v3.* ]]; then
        # Helm is not installed. Install helm
        echo "Helm3 is not installed, installing ..."
        curl https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz --output helm-${HELM_VERSION}.tar.gz
        tar -zxvf helm-${HELM_VERSION}.tar.gz
        sudo mv linux-amd64/helm /usr/local/bin/helm
        rm -r linux-amd64
        rm helm-${HELM_VERSION}.tar.gz
    else
        echo "Helm3 is already installed. Skipping installation..."
    fi
}

function install_k8s_storageclass() {
    echo "Installing open-iscsi"
    sudo apt-get update -y
    sudo apt-get install open-iscsi -y
    sudo systemctl enable --now iscsid
    OPENEBS_VERSION="3.7.0"
    echo "Installing OpenEBS"
    helm repo add openebs https://openebs.github.io/charts
    helm repo update
    wget https://raw.githubusercontent.com/aerOS-Project/KubeEdge-installation/refs/heads/main/resources/helm-charts-manifests/openebs-kubeedge-values.yaml
    helm install --create-namespace --namespace openebs openebs openebs/openebs -f openebs-kubeedge-values.yaml --version ${OPENEBS_VERSION}
    helm ls -n openebs
    local storageclass_timeout=400
    local counter=0
    local storageclass_ready=""
    echo "Waiting for storageclass"
    while (( counter < storageclass_timeout ))
    do
        kubectl get storageclass openebs-hostpath &> /dev/null

        if [ $? -eq 0 ] ; then
            echo "Storageclass available"
            storageclass_ready="y"
            break
        else
            counter=$((counter + 15))
            sleep 15
        fi
    done
    [ -n "$storageclass_ready" ] || FATAL "Storageclass not ready after $storageclass_timeout seconds. Cannot install openebs"
    kubectl patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

function taint_master_node() {
    K8S_MASTER=$(kubectl get nodes | awk '$3~/control-plane/'| awk '{print $1}')
    kubectl taint node $K8S_MASTER node-role.kubernetes.io/control-plane-
    kubectl taint node $K8S_MASTER node-role.kubernetes.io/master-
    sleep 5
}

function install_prometheus(){
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    kubectl create ns monitoring; 
    helm install prometheus-community/kube-prometheus-stack --generate-name --set grafana.service.type=NodePort --set prometheus.service.type=NodePort --set prometheus.prometheusSpec.scrapeInterval="5s" --namespace monitoring
}

function install_cni(){
    if [ "$CNI" == "cilium" ]; then
        install_cilium
    elif [ "$CNI" == "calico" ]; then
        install_calico
    else
        install_flannel
    fi
}

function install_cilium(){
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

    cilium install --helm-set-string ipam.operator.clusterPoolIPv4PodCIDRList=$POD_CIDR
    #cilium install --helm-set-string ipam.operator.clusterPoolIPv4PodCIDR=$POD_CIDR
    #cilium clustermesh enable --service-type NodePort
}

# TODO change POD_CIDR in calico-yaml-config
function install_calico(){
    CALICO_VERSION=v3.26.0
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml
    # curl https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml -o calico-custom-resources.yaml
    # cird_line=$(grep -n 'cidr' ./calico-custom-resources.yaml | cut -d ':' -f1)
    # sed -i '${cird_line}s/.*/    cidr: ${POD_CIDR}/' ./calico-custom-resources
    kubectl create -f calico-custom-resources.yaml


    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L https://github.com/projectcalico/calico/releases/latest/download/calicoctl-linux-${CLI_ARCH} -o calicoctl
    mv calicoctl /usr/local/bin
    chmod +x /usr/local/bin/calicoctl
}

function install_flannel(){
    kubectl create ns kube-flannel
    kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged
    helm install flannel --set podCidr=$POD_CIDR --namespace kube-flannel https://github.com/aerOS-Project/KubeEdge-installation/blob/main/resources/helm-charts-manifests/flannel-helm-chart-kubeedge.tgz --debug
}


function usage() {         
    echo                        # Function: Print a help message.
    echo "usage: $0 [-t types]"
    echo "Must run as root"
    echo "options:"
    echo "  -t      Type of Kubernetes' component (AGENT or SERVER)"
    echo "  -p      Pod CIDR Network (Only SERVER Mode)"
    echo "  -c      Cluster CNI (cilium or calico)"
    exit 1
}
function exit_abnormal() {                         # Function: Exit with error.
  usage
  exit 1
}

while getopts "t:p:c:" options; do

  case "${options}" in
    t)
      KUBETYPE=${OPTARG}
      if [ "$KUBETYPE" != "AGENT" ] && [ "$KUBETYPE" != "SERVER" ]; then
        echo "Error: TYPE must be SERVER or AGENT"
        exit_abnormal
        exit 1
      fi
      ;;
    p) 
      POD_CIDR=${OPTARG}
      ;;
    c)
      CNI=${OPTARG}
      ;;
    :)
      echo "Error: -${OPTARG} requires an argument."
      exit_abnormal               
      ;;
    *)    
      exit_abnormal
      ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "Must run as sudo";
  exit_abnormal
fi

#No options were passed to the script
if [ $OPTIND -eq 1 ]; then 
    echo "No options were passed";
    exit_abnormal
fi

#Depending on the type, the installation changes
if [ "$KUBETYPE" == "AGENT" ]; then
    install_prerequirements
    install_kubeadm
else
    install_prerequirements
    install_containerd
    install_kubeadm
    init_kubeadm
    kube_config_dir
    taint_master_node
    install_helm
    install_k8s_storageclass 
    install_cni
    # install_prometheus
fi
