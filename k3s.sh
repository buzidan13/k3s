#!/bin/bash

# Absolute path to this script
SCRIPT=$(readlink -f "$0")
# Absolute path to the script directory
BASEDIR=$(dirname "$SCRIPT")

# Application catalog url
CATALOG_URL=$1

# install mode = demokit/server
INSTALL_MODE="${2:-server}"


# Disable Ansible warnings
export ANSIBLE_LOCALHOST_WARNING=false
export ANSIBLE_DEPRECATION_WARNINGS=false

# APT Install noninteractive
export DEBIAN_FRONTEND=noninteractive

echo "------ Staring k3 installer $(date '+%Y-%m-%d %H:%M:%S')  ------" > ${BASEDIR}/k3s-logger.log

## Permissions check
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root." | tee -a ${BASEDIR}/k3s-logger.log
   echo "Installation failed, please contact support." | tee -a ${BASEDIR}/k3s-logger.log
   exit 1
fi

## Get home Dir of the current user
if [ $SUDO_USER ]; then 
  user=$SUDO_USER
else
  user=`whoami`
fi

if [ ${user} == "root" ]; then
  user_home_dir="/${user}"
else
  user_home_dir="/home/${user}"
fi

## Check if this machine is part of an existing Kubernetes cluster
if [ -x "$(command -v kubectl)" ]; then
  if ! [[ $(kubectl cluster-info) == *'https://localhost:6443'* ]]; then 
    echo "" | tee -a ${BASEDIR}/k3s-logger.log
    echo "Error: this machine is part of an existing Kubernetes cluster, please detach it before running this installer." | tee -a ${BASEDIR}/k3s-logger.log
    echo "Installation failed, please contact support." | tee -a ${BASEDIR}/k3s-logger.log
    exit 1
  fi
fi

echo "" | tee -a ${BASEDIR}/k3s-logger.log
echo "=====================================================================" | tee -a ${BASEDIR}/k3s-logger.log
echo "== Making sure that all dependencies are installed, please wait... ==" | tee -a ${BASEDIR}/k3s-logger.log
echo "=====================================================================" | tee -a ${BASEDIR}/k3s-logger.log
echo "" | tee -a ${BASEDIR}/k3s-logger.log


## APT update
apt update >> ${BASEDIR}/k3s-logger.log 2>&1

## Install software-properties-common
#dpkg-query -l software-properties-common > /dev/null 2>&1
#if [ $? != 0 ]; then
set -e
apt-get -qq install -y software-properties-common >> ${BASEDIR}/k3s-logger.log 2>&1
set +e
#fi

## Install ansible
#dpkg-query -l ansible > /dev/null 2>&1
#if [ $? != 0 ]; then
set -e
apt-add-repository --yes --update ppa:ansible/ansible >> ${BASEDIR}/k3s-logger.log 2>&1
apt-get -qq install -y ansible >> ${BASEDIR}/k3s-logger.log 2>&1
set +e
#fi

## Install nvidia-driver, docker-ce, nvidia-docker
ansible-playbook --become --become-user=root -e install_mode="${INSTALL_MODE}" ansible/main.yml -vvv >> ${BASEDIR}/k3s-logger.log 2>&1
if [ $? != 0 ]; then
    echo "" | tee -a ${BASEDIR}/k3s-logger.log
    echo "Installation failed, please contact support." | tee -a ${BASEDIR}/k3s-logger.log
    exit 1
fi

## Fix nvidia-driver bug on Ubuntu 18.04 black screen on login: https://devtalk.nvidia.com/default/topic/1048019/linux/black-screen-after-install-cuda-10-1-on-ubuntu-18-04/post/5321320/#5321320
sed -i -r -e 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)?quiet ?(.*)?"/GRUB_CMDLINE_LINUX_DEFAULT="\1\2"/' -e 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)?splash ?(.*)?"/GRUB_CMDLINE_LINUX_DEFAULT="\1\2"/' /etc/default/grub
update-grub >> ${BASEDIR}/k3s-logger.log 2>&1

## Delete /root/.kube/config
rm -f /root/.kube/config > /dev/null

## Install k3s
echo "" | tee -a ${BASEDIR}/k3s-logger.log
echo "====================================" | tee -a ${BASEDIR}/k3s-logger.log
echo "== Installing k3s, please wait... ==" | tee -a ${BASEDIR}/k3s-logger.log
echo "====================================" | tee -a ${BASEDIR}/k3s-logger.log
echo "" | tee -a ${BASEDIR}/k3s-logger.log

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v0.6.1' sh -s - \
  --docker --no-deploy traefik --kubelet-arg='node-labels=edge=true,backend=true,app=edge,mode=backend,frontend=true' \
  --kubelet-arg='eviction-soft=memory.available<500Mi' --kubelet-arg='eviction-soft-grace-period=memory.available=1m' --kubelet-arg='eviction-hard=memory.available<100Mi' \
  --kubelet-arg='eviction-soft=nodefs.available<15%' --kubelet-arg='eviction-soft-grace-period=nodefs.available=60m' --kubelet-arg='eviction-hard=nodefs.available<10%' \
  --kubelet-arg='eviction-soft=nodefs.inodesFree<10%' --kubelet-arg='eviction-soft-grace-period=nodefs.inodesFree=120m' --kubelet-arg='eviction-hard=nodefs.inodesFree<5%' | tee -a ${BASEDIR}/k3s-logger.log

if [ $? != 0 ]; then
    echo "" | tee -a ${BASEDIR}/k3s-logger.log
    echo "Installation failed, please contact support." | tee -a ${BASEDIR}/k3s-logger.log
    exit 1
fi

## Enable kubectl bash auto-completion
source <(kubectl completion bash)
ansible localhost -m lineinfile -a "dest=/root/.bashrc line='source <(kubectl completion bash)'" >> ${BASEDIR}/k3s-logger.log 2>&1

## Create directories if not exists
mkdir -p /var/lib/rancher/k3s/server/manifests/
mkdir -p /root/.kube/
mkdir -p /ssd/

## Symlink to kubeconfig file
if [ ! -e "/root/.kube/config" ]; then
    ln -s /etc/rancher/k3s/k3s.yaml /root/.kube/config
fi

## Nginx Ingress
cat > /var/lib/rancher/k3s/server/manifests/ingress-nginx.yaml <<- EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: ingress-nginx
  namespace: kube-system
spec:
  chart: stable/nginx-ingress
  version: 1.7.0
  targetNamespace: ingress-nginx
  valuesContent: |-
    tcp:
      3022: "default/ift3-be:3022"
      3005: "default/ift3-be:3005"
      1080: "default/apigateway:1080"
      9443: "default/apigateway:9443"
      3000: "default/api:3000"
      2000: "default/api-master:2000"
      16180: "default/master-sync:16180"
      5671: "default/rabbitmq:5671"
      5672: "default/rabbitmq:5672"
      15671: "default/rabbitmq:15671"
      7443: "default/push-notification:7443"
      1935: "default/rtstreamer:1935"
      27017: "default/mongodb:27017"
      50051: "default/liveness:50051"
      8081: "default/dslr-dashboard-bt:8081"
EOF

## Local Path Provisioner
#wget -q https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml -O - | sed -e 's@/opt/local-path-provisioner@/ssd/local-path-provisioner@' > /var/lib/rancher/k3s/server/manifests/local-path-storage.yaml
wget -q https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml -O - | sed -e 's@/opt/local-path-provisioner@/ssd/local-path-provisioner@' > ${BASEDIR}/local-path-storage.yaml
kubectl apply -f ${BASEDIR}/local-path-storage.yaml 


## Set local-path as the default StorageClass (async, delayed in background)
(sleep 20 && while ! kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>&1; do sleep 3; done >> ${BASEDIR}/k3s-logger.log)


## Cert-Manager
wget -q https://raw.githubusercontent.com/jetstack/cert-manager/release-0.8/deploy/manifests/00-crds.yaml -O /var/lib/rancher/k3s/server/manifests/cert-manager-crds.yaml
kubectl create namespace cert-manager >> ${BASEDIR}/k3s-logger.log 2>&1
kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true >> ${BASEDIR}/k3s-logger.log 2>&1
sleep 5
cat > /var/lib/rancher/k3s/server/manifests/cert-manager.yaml <<- EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: cert-manager
  namespace: kube-system
spec:
  chart: https://charts.jetstack.io/charts/cert-manager-v0.8.0.tgz
  targetNamespace: cert-manager
EOF


## Rancher
cat > /var/lib/rancher/k3s/server/manifests/rancher.yaml <<- EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: rancher
  namespace: kube-system
spec:
  chart: https://releases.rancher.com/server-charts/latest/rancher-2.2.7.tgz
  targetNamespace: cattle-system
  valuesContent: |-
    replicas: 1
    hostname: rancher.tes
EOF

## Add local hosts to /etc/hosts
ansible localhost -m lineinfile -a "dest=/etc/hosts line='127.0.0.1 rancher.tes'" >> ${BASEDIR}/k3s-logger.log 2>&1

## JQ
wget -q https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O /usr/local/bin/jq
chmod +x /usr/local/bin/jq

## Rancher CLI + Cattlectl
echo "" | tee -a ${BASEDIR}/k3s-logger.log
echo "====================================" | tee -a ${BASEDIR}/k3s-logger.log
echo "== Set up Rancher, please wait... ==" | tee -a ${BASEDIR}/k3s-logger.log
echo "====================================" | tee -a ${BASEDIR}/k3s-logger.log
echo "" | tee -a ${BASEDIR}/k3s-logger.log

mkdir -p /tmp/rancher
wget -q https://github.com/rancher/cli/releases/download/v2.2.0/rancher-linux-amd64-v2.2.0.tar.gz -O - | tar xzf - --strip=2 -C /tmp/rancher/
mv /tmp/rancher/rancher /usr/local/bin/rancher
chmod +x /usr/local/bin/rancher
wget -q https://github.com/bitgrip/cattlectl/releases/download/v1.1.1/cattlectl-v1.1.1-linux.tar.gz -O - | tar xzf - --strip=2 -C /tmp/rancher/
mv /tmp/rancher/cattlectl /usr/local/bin/cattlectl
chmod +x /usr/local/bin/cattlectl
rm -rf /tmp/rancher
source <(cattlectl completion)
ansible localhost -m lineinfile -a "dest=/root/.bashrc line='source <(cattlectl completion)'" >> ${BASEDIR}/k3s-logger.log 2>&1

## Bootstrap Rancher
echo ""
echo "Please wait while Rancher is initializing..."
RANCHER_SERVER_BASE=https://rancher.tes

# Login with default admin credentials get a temporary token with 60s TTL
LOGINRESPONSE=`while ! curl --fail -s "$RANCHER_SERVER_BASE/v3-public/localProviders/local?action=login" -H "content-type: application/json" --data-binary '{"username":"admin","password":"admin","ttl":60000}' --insecure 2>/dev/null; do sleep 3; done`
LOGINTOKEN=`echo $LOGINRESPONSE | jq -r .token`

# Create and get admin API key
APIRESPONSE=`curl -s "$RANCHER_SERVER_BASE/v3/token" -H "content-type: application/json" -H "Authorization: Bearer $LOGINTOKEN" --data-binary '{"type":"token","description":"automation"}' --insecure`
APITOKEN=`echo $APIRESPONSE | jq -r .token`

# Set `server-url` configuration option
curl -s "$RANCHER_SERVER_BASE/v3/settings/server-url" -H "content-type: application/json" -H "Authorization: Bearer $APITOKEN" -X PUT --data-binary '{"name":"server-url","value":"https://rancher.cattle-system.svc"}' --insecure > /dev/null

## Login with Rancher CLI and add our Helm catalog
#while ! kubectl -n ingress-nginx logs -l app=nginx-ingress -l component=controller | grep "cattle-system/tls-rancher-ingress" | grep "the local store" 2>&1; do sleep 3; done >> ${BASEDIR}/k3s-logger.log
while ! rancher login $RANCHER_SERVER_BASE --token $APITOKEN --skip-verify 2>&1; do sleep 3; done >> ${BASEDIR}/k3s-logger.log

## Set cattle-node-agent dnsPolicy to ClusterFirstWithHostNet (async, delayed in background)
(sleep 20 && while ! kubectl -n cattle-system patch daemonset cattle-node-agent --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/dnsPolicy", "value":"ClusterFirstWithHostNet"}]' 2>&1 ; do sleep 3; done >> ${BASEDIR}/k3s-logger.log)

kubectl create secret generic rancher-cli-token --from-file=${user_home_dir}/.rancher/cli2.json >> ${BASEDIR}/k3s-logger.log 2>&1  #--dry-run -o yaml | kubectl apply -f -
#kubectl create secret generic rancher-cli-token --from-literal=token=$APITOKEN --dry-run -o yaml | kubectl apply -f -

## Create Rancher Project and Deploy BetterTomorrow
ACCESSKEY=`echo $APITOKEN | cut -d':' -f1`
SECRETKEY=`echo $APITOKEN | cut -d':' -f2`
cat > /root/.cattlectl.yaml <<- EOF
---
rancher:
  url: $RANCHER_SERVER_BASE
  access_key: $ACCESSKEY
  secret_key: $SECRETKEY
  cluster_name: local
EOF

## Patch Rancher service to allow internal communication on port 443 for Rancher CLI automation (async)
(while ! kubectl -n cattle-system patch service rancher --patch '{"spec": {"ports": [{"name": "https","port": 443,"protocol": "TCP","targetPort": 443}]}}' 2>&1 ; do sleep 3; done >> ${BASEDIR}/k3s-logger.log)

## Give admin privileges for the default:default service account - for Argo to be able to create k8s resources [[ SECURITY RISK - TO BE FINE TUNED WITH RBAC ]]
kubectl create rolebinding default-admin --clusterrole=admin --serviceaccount=default:default >> ${BASEDIR}/k3s-logger.log 2>&1

# Add application catalog to rancher
rancher catalog add catalog ${CATALOG_URL} >> ${BASEDIR}/k3s-logger.log 2>&1

# Remove rancher system catalogs
rancher catalog delete library >> ${BASEDIR}/k3s-logger.log 2>&1
rancher catalog delete system-library >> ${BASEDIR}/k3s-logger.log 2>&1

## Present Rancher link
echo "" | tee -a ${BASEDIR}/k3s-logger.log
echo "To complete the installation, please login to https://rancher.tes/ in your browser." | tee -a ${BASEDIR}/k3s-logger.log
echo "" | tee -a ${BASEDIR}/k3s-logger.log
echo "In order to access the Rancher management UI from a remote server, please add the the following line into the hosts file:" | tee -a ${BASEDIR}/k3s-logger.log
echo "$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p') rancher.tes" | tee -a ${BASEDIR}/k3s-logger.log
echo "hosts file path: /etc/hosts (Linux) or C:\Windows\System32\drivers\etc\hosts (Windows)" | tee -a ${BASEDIR}/k3s-logger.log
echo "" | tee -a ${BASEDIR}/k3s-logger.log

## Installation complete
echo "Done!" | tee -a ${BASEDIR}/k3s-logger.log
echo "" | tee -a ${BASEDIR}/k3s-logger.log
