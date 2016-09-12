#!/bin/bash

# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
# curl -sSL https://storage.googleapis.com/kubernetes-release/release/v1.3.5/bin/linux/amd64/kubectl > /usr/local/bin/kubectl
# chmod +x /usr/local/bin/kubectl

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source $(dirname "${BASH_SOURCE}")/cni-plugin.sh
source $(dirname "${BASH_SOURCE}")/docker-bootstrap.sh

kube::multinode::get_pause_pod(){
    cnt=$(docker images |grep "gcr.io/google_containers/pause-amd64"|wc -l)
    i_cnt=$((cnt))
    if [ $i_cnt -lt 1 ] ;then
        docker pull $IMAGE_PREFIX/pause-amd64:3.0
        docker tag $IMAGE_PREFIX/pause-amd64:3.0 gcr.io/google_containers/pause-amd64:3.0
    else
        echo "gcr.io/google_containers/pause-amd64:3.0 exist"
    fi
}
kube::multinode::main(){

  # Require root
  if [[ "$(id -u)" != "0" ]]; then
    kube::log::fatal "Please run as root"
  fi

  for tool in curl ip docker;
  do
    if [[ ! -f $(which ${tool} 2>&1) ]]; then
      kube::log::fatal "The binary ${tool} is required. Install it."
    fi
  done

  # Make sure docker daemon is running
  if [[ $(docker ps 2>&1 1>/dev/null; echo $?) != 0 ]]; then
    kube::log::fatal "Docker is not running on this machine!"
  fi

  IMAGE_PREFIX="registry.cn-hangzhou.aliyuncs.com/google-containers"
#  IMAGE_PREFIX="gcr.io/google_containers"
#  LATEST_STABLE_K8S_VERSION=$(curl -sSL "https://storage.googleapis.com/kubernetes-release/release/stable.txt")
  LATEST_STABLE_K8S_VERSION=v1.3.5
  K8S_VERSION=${K8S_VERSION:-${LATEST_STABLE_K8S_VERSION}}

  # TODO: Update to 3.0.3
  ETCD_VERSION=${ETCD_VERSION:-"2.2.5"}

  FLANNEL_VERSION=${FLANNEL_VERSION:-"0.5.5"}
  FLANNEL_IPMASQ=${FLANNEL_IPMASQ:-"true"}
  FLANNEL_BACKEND=${FLANNEL_BACKEND:-"udp"}
  FLANNEL_NETWORK=${FLANNEL_NETWORK:-"10.1.0.0/16"}

  RESTART_POLICY=${RESTART_POLICY:-"unless-stopped"}

  CURRENT_PLATFORM=$(kube::helpers::host_platform)
  ARCH=${ARCH:-${CURRENT_PLATFORM##*/}}

  DEFAULT_IP_ADDRESS=$(ip -o -4 addr list $(ip -o -4 route show to default | awk '{print $5}' | head -1) | awk '{print $4}' | cut -d/ -f1 | head -1)
  IP_ADDRESS=${IP_ADDRESS:-${DEFAULT_IP_ADDRESS}}

  TIMEOUT_FOR_SERVICES=${TIMEOUT_FOR_SERVICES:-20}
  USE_CNI=${USE_CNI:-"false"}
  CNI_ARGS=""

  # Constants
  BOOTSTRAP_DOCKER_SOCK="unix:///var/run/docker-bootstrap.sock"
  BOOTSTRAP_DOCKER_PARAM="-H ${BOOTSTRAP_DOCKER_SOCK}"
  ETCD_NET_PARAM="--net host"
  KUBELET_MOUNTS="\
    -v /sys:/sys:rw \
    -v /var/run:/var/run:rw \
    -v /run:/run:rw \
    -v /var/lib/docker:/var/lib/docker:rw \
    -v /var/lib/kubelet:/var/lib/kubelet:shared \
    -v /var/log/containers:/var/log/containers:rw"

  # Paths
  FLANNEL_SUBNET_DIR=${FLANNEL_SUBNET_DIR:-/run/flannel}

  if [[ ${USE_CNI} == "true" ]]; then

    BOOTSTRAP_DOCKER_PARAM=""
    ETCD_NET_PARAM="-p 2379:2379 -p 2380:2380 -p 4001:4001"
    CNI_ARGS="\
      --network-plugin=cni \
      --network-plugin-dir=/etc/cni/net.d"
  fi
  kube::multinode::get_pause_pod
}

# Ensure everything is OK, docker is running and we're root
kube::multinode::log_variables() {

  kube::helpers::parse_version ${K8S_VERSION}

  # Output the value of the variables
  kube::log::status "K8S_VERSION is set to: ${K8S_VERSION}"
  kube::log::status "ETCD_VERSION is set to: ${ETCD_VERSION}"
  kube::log::status "FLANNEL_VERSION is set to: ${FLANNEL_VERSION}"
  kube::log::status "FLANNEL_IPMASQ is set to: ${FLANNEL_IPMASQ}"
  kube::log::status "FLANNEL_NETWORK is set to: ${FLANNEL_NETWORK}"
  kube::log::status "FLANNEL_BACKEND is set to: ${FLANNEL_BACKEND}"
  kube::log::status "RESTART_POLICY is set to: ${RESTART_POLICY}"
  kube::log::status "MASTER_IP is set to: ${MASTER_IP}"
  kube::log::status "ARCH is set to: ${ARCH}"
  kube::log::status "IP_ADDRESS is set to: ${IP_ADDRESS}"
  kube::log::status "USE_CNI is set to: ${USE_CNI}"
  kube::log::status "--------------------------------------------"
}

# Start etcd on the master node
kube::multinode::start_etcd() {

  kube::log::status "Launching etcd..."

  # TODO: Remove the 4001 port as it is deprecated
  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --name kube_etcd_$(kube::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    ${ETCD_NET_PARAM} \
    -v /var/lib/kubelet/etcd:/var/etcd \
    ${IMAGE_PREFIX}/etcd-${ARCH}:${ETCD_VERSION} \
    /usr/local/bin/etcd \
      --listen-client-urls=http://0.0.0.0:2379,http://0.0.0.0:4001 \
      --advertise-client-urls=http://localhost:2379,http://localhost:4001 \
      --listen-peer-urls=http://0.0.0.0:2380 \
      --data-dir=/var/etcd/data

  # Wait for etcd to come up
  local SECONDS=0
  while [[ $(curl -fsSL http://localhost:2379/health 2>&1 1>/dev/null; echo $?) != 0 ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      kube::log::fatal "etcd failed to start. Exiting..."
    fi
    sleep 1
  done

  sleep 2
}

# Start flannel in docker bootstrap, both for master and worker
kube::multinode::start_flannel() {

  kube::log::status "Launching flannel..."

  # Set flannel net config (when running on master)
  if [[ "${MASTER_IP}" == "localhost" ]]; then
    curl -sSL http://localhost:2379/v2/keys/coreos.com/network/config -XPUT \
      -d value="{ \"Network\": \"${FLANNEL_NETWORK}\", \"Backend\": {\"Type\": \"${FLANNEL_BACKEND}\"}}"
  fi

  docker ${BOOTSTRAP_DOCKER_PARAM} run -d \
    --name kube_flannel_$(kube::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    --net=host \
    --privileged \
    -v /dev/net:/dev/net \
    -v ${FLANNEL_SUBNET_DIR}:${FLANNEL_SUBNET_DIR} \
    ${IMAGE_PREFIX}/flannel-${ARCH}:${FLANNEL_VERSION} \
    /opt/bin/flanneld \
      --etcd-endpoints=http://${MASTER_IP}:2379 \
      --ip-masq="${FLANNEL_IPMASQ}" \
      --iface="${IP_ADDRESS}"

  # Wait for the flannel subnet.env file to be created instead of a timeout. This is faster and more reliable
  local SECONDS=0
  while [[ ! -f ${FLANNEL_SUBNET_DIR}/subnet.env ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      kube::log::fatal "flannel failed to start. Exiting..."
    fi
    sleep 1
  done

  source ${FLANNEL_SUBNET_DIR}/subnet.env

  kube::log::status "FLANNEL_SUBNET is set to: ${FLANNEL_SUBNET}"
  kube::log::status "FLANNEL_MTU is set to: ${FLANNEL_MTU}"
}

# Start kubelet first and then the master components as pods
kube::multinode::start_k8s_master() {
  kube::log::status "Launching Kubernetes master components..."

  kube::multinode::make_shared_kubelet_dir

  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    --name kube_kubelet_$(kube::helpers::small_sha) \
    ${KUBELET_MOUNTS} \
    ${IMAGE_PREFIX}/hyperkube-${ARCH}:${K8S_VERSION} \
    /hyperkube kubelet \
      --allow-privileged \
      --api-servers=http://localhost:8080 \
      --config=/etc/kubernetes/manifests-multi \
      --cluster-dns=10.0.0.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      --hostname-override=${IP_ADDRESS} \
      --v=2
}

# Start kubelet in a container, for a worker node
kube::multinode::start_k8s_worker() {
  kube::log::status "Launching Kubernetes worker components..."

  kube::multinode::make_shared_kubelet_dir

  # TODO: Use secure port for communication
  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    --name kube_kubelet_$(kube::helpers::small_sha) \
    ${KUBELET_MOUNTS} \
    ${IMAGE_PREFIX}/hyperkube-${ARCH}:${K8S_VERSION} \
    /hyperkube kubelet \
      --allow-privileged \
      --api-servers=http://${MASTER_IP}:8080 \
      --cluster-dns=10.0.0.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      --hostname-override=${IP_ADDRESS} \
      --v=2
}

# Start kube-proxy in a container, for a worker node
kube::multinode::start_k8s_worker_proxy() {

  kube::log::status "Launching kube-proxy..."
  docker run -d \
    --net=host \
    --privileged \
    --name kube_proxy_$(kube::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    ${IMAGE_PREFIX}/hyperkube-${ARCH}:${K8S_VERSION} \
    /hyperkube proxy \
        --master=http://${MASTER_IP}:8080 \
        --v=2
}

# Turndown the local cluster
kube::multinode::turndown(){

  # Check if docker bootstrap is running
  DOCKER_BOOTSTRAP_PID=$(ps aux | grep ${BOOTSTRAP_DOCKER_SOCK} | grep -v "grep" | awk '{print $2}')
  if [[ ! -z ${DOCKER_BOOTSTRAP_PID} ]]; then

    kube::log::status "Killing docker bootstrap..."

    # Kill the bootstrap docker daemon and it's containers
    docker -H ${BOOTSTRAP_DOCKER_SOCK} rm -f $(docker -H ${BOOTSTRAP_DOCKER_SOCK} ps -q) >/dev/null 2>/dev/null
    kill ${DOCKER_BOOTSTRAP_PID}
  fi

  kube::log::status "Killing all kubernetes containers..."

  for c in $(docker ps | grep "k8s_" | awk '{print $1}')
  do
      docker rm -f $c
  done

  for c in $(docker ps | grep "kube_" | awk '{print $1}')
  do
      docker rm -f $c
  done

  if [[ -d /var/lib/kubelet ]]; then
    read -p "Do you want to clean /var/lib/kubelet? [Y/n] " clean_kubelet_dir

    case $clean_kubelet_dir in
      [nN]*)
        ;; # Do nothing
      *)
        # umount if there are mounts in /var/lib/kubelet
        if [[ ! -z $(mount | grep "/var/lib/kubelet" | awk '{print $3}') ]]; then

          # The umount command may be a little bit stubborn sometimes, so run the commands twice to ensure the mounts are gone
          df | grep "/var/lib/kubelet/*" | awk '{print $6}' | xargs umount 1>/dev/null 2>/dev/null
          umount /var/lib/kubelet 1>/dev/null 2>/dev/null
        fi

        # Delete the directory
        rm -rf /var/lib/kubelet
        ;;
    esac
  fi

  # Remove cni0 bridge
  kube::multinode::delete_bridge cni0
}

kube::multinode::delete_bridge() {
  if [[ ! -z $(ip link | grep "$1") ]]; then
    ip link set $1 down
    ip link del $1
  fi
}

# Make shared kubelet directory
kube::multinode::make_shared_kubelet_dir() {

  # This only has to be done when the host doesn't use systemd
  if ! kube::helpers::command_exists systemctl; then
    mkdir -p /var/lib/kubelet
    mount --bind /var/lib/kubelet /var/lib/kubelet
    mount --make-shared /var/lib/kubelet

    kube::log::status "Mounted /var/lib/kubelet with shared propagnation"
  fi
}

# Check if a command is valid
kube::helpers::command_exists() {
  command -v "$@" > /dev/null 2>&1
}

# Backup the current file
kube::helpers::backup_file(){
  cp -f ${1} ${1}.backup
}

# Returns five "random" chars
kube::helpers::small_sha(){
  date | md5sum | cut -c-5
}

# Get the architecture for the current machine
kube::helpers::host_platform() {
  local host_os
  local host_arch
  case "$(uname -s)" in
    Linux)
      host_os=linux;;
    *)
      kube::log::fatal "Unsupported host OS. Must be linux.";;
  esac

  case "$(uname -m)" in
    x86_64*)
      host_arch=amd64;;
    i?86_64*)
      host_arch=amd64;;
    amd64*)
      host_arch=amd64;;
    aarch64*)
      host_arch=arm64;;
    arm64*)
      host_arch=arm64;;
    arm*)
      host_arch=arm;;
    ppc64le*)
      host_arch=ppc64le;;
    *)
      kube::log::fatal "Unsupported host arch. Must be x86_64, arm, arm64 or ppc64le.";;
  esac
  echo "${host_os}/${host_arch}"
}

kube::helpers::parse_version() {
  local -r version_regex="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-(beta|alpha)\\.(0|[1-9][0-9]*))?$"
  local -r version="${1-}"
  [[ "${version}" =~ ${version_regex} ]] || {
    kube::log::fatal "Invalid release version: '${version}', must match regex ${version_regex}"
    return 1
  }
  VERSION_MAJOR="${BASH_REMATCH[1]}"
  VERSION_MINOR="${BASH_REMATCH[2]}"
  VERSION_PATCH="${BASH_REMATCH[3]}"
  VERSION_EXTRA="${BASH_REMATCH[4]}"
  VERSION_PRERELEASE="${BASH_REMATCH[5]}"
  VERSION_PRERELEASE_REV="${BASH_REMATCH[6]}"
}

# Print a status line. Formatted to show up in a stream of output.
kube::log::status() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "+++ $timestamp $1"
  shift
  for message; do
    echo "    $message"
  done
}

# Log an error and exit
kube::log::fatal() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "!!! $timestamp ${1-}" >&2
  shift
  for message; do
    echo "    $message" >&2
  done
  exit 1
}

kube::helpers::create_kubeconfig()
{
    which kubectl
    if [ $? -ne 0 ] ;then
        curl -sSL https://storage.googleapis.com/kubernetes-release/release/v1.3.5/bin/linux/amd64/kubectl > /usr/local/bin/kubectl
        chmod +x /usr/local/bin/kubectl
    fi
    kubectl config set-cluster default --server=http://127.0.0.1:8080 --insecure-skip-tls-verify=true
    kubectl config set-credentials default-user --username=admin --password=secret
    kubectl config set-context default-context --cluster=default --user=default-user
    kubectl config use-context default-context
    mkdir -p /var/lib/kubelet/kubeconfig && cp ~/.kube/config /var/lib/kubelet/kubeconfig/kubeconfig.yaml
}

kube::helpers::kube_usage()
{
    echo " Usage:"
    echo "      kubectl get po --namespace=kube-system"
    echo "      kubectl get svc --namespace=kube-system"
    echo "      kubectl get svc --namespace=kube-system"
    echo "   1.use curl http://10.0.0.6:80 or "
    echo "   2.use ssh tunnel to expose remote node port to local :"
    echo "      ssh -N -v -L :8888:10.0.0.6:80 root@47.90.81.195  "
    echo "      8888 is your local port ,   root@47.90.81.195 is the remote node"
    echo "     to reach kube-dashboard"
}