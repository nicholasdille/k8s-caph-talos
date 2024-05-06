#!/bin/bash
set -o errexit -o pipefail

# https://github.com/syself/cluster-api-provider-hetzner/blob/main/docs/topics/quickstart.md

# TODO: Test for envsubst
type envsubst
# TODO: Test for kind/k3d
type kind
# TODO: Test for kubectl
type kubectl
# TODO: Test for clusterctl
type clusterctl
# TODO: Test for packer
type packer
# TODO: Test for talosctl
#type talosctl

# TODO: Test for Docker
type docker
while ! docker version >/dev/null 2>&1; do
    sleep 2
done

echo "### Create CAPH image"
packer build k8s1.28.4-ubuntu-22-04-containerd/image.json

#echo "### Create talos image"
# TODO: Set image name: caph-image-name
#packer init .
#packer build .
#CLUSTERCTL_INIT_BOOTSTRAP=talos
#CLUSTERCTL_INIT_CONTROL_PLANE=talos

echo "### Create bootstrap cluster"
kind create cluster \
    --kubeconfig ./kubeconfig \
    --wait 5m
# OR:
# k3d cluster create
# k3d kubeconfig get >./kubeconfig
export KUBECONFIG=./kubeconfig

echo "### Initializing CAPH in bootstrap cluster"
: "${CLUSTERCTL_INIT_BOOTSTRAP:=kubeadm}"
: "${CLUSTERCTL_INIT_CONTROL_PLANE:=kubeadm}"
if ! clusterctl init --bootstrap "${CLUSTERCTL_INIT_BOOTSTRAP}" --control-plane "${CLUSTERCTL_INIT_CONTROL_PLANE}" --infrastructure hetzner --wait-providers; then
    echo "ERROR: Failed to execute 'clusterctl init'."
    false
fi
while kubectl get pods -A | tail -n +2 | grep -vq Running; do
    echo "Waiting for all pods to be running..."
    sleep 10
done
kubectl get pods -A

echo "### Prepare credentials"
test -n "${HCLOUD_TOKEN}"
kubectl create secret generic hetzner --from-literal=hcloud="${HCLOUD_TOKEN}"
kubectl patch secret hetzner -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'

echo "### Configure cluster"
export HCLOUD_SSH_KEY="<ssh-key-name>"
export CLUSTER_NAME="my-cluster"
export HCLOUD_REGION="fsn1"
export CONTROL_PLANE_MACHINE_COUNT=1
export WORKER_MACHINE_COUNT=3
export KUBERNETES_VERSION=1.30.0
export HCLOUD_CONTROL_PLANE_MACHINE_TYPE=cpx21
export HCLOUD_WORKER_MACHINE_TYPE=cpx41

echo "### Rolling out workload cluster"
clusterctl generate cluster "${CLUSTER_NAME}" \
    --kubernetes-version "v${KUBERNETES_VERSION}" \
    --control-plane-machine-count="${CONTROL_PLANE_MACHINE_COUNT}" \
    --worker-machine-count="${WORKER_MACHINE_COUNT}" \
| kubectl apply -f -
sleep 10
MAX_WAIT_SECONDS=$(( 30 * 60 ))
SECONDS=0
while test "${SECONDS}" -lt "${MAX_WAIT_SECONDS}"; do
    echo
    echo "### Waiting for control plane of workload cluster to be ready"
    clusterctl describe cluster ${CLUSTER_NAME}

    control_plane_initialized="$(
        kubectl get cluster ${CLUSTER_NAME} --output json | \
            jq --raw-output '.status.conditions[] | select(.type == "ControlPlaneInitialized") | .status'
    )"
    if test "${control_plane_initialized}" == "True"; then
        kubectl describe cluster ${CLUSTER_NAME}
        kubectl describe KubeadmControlPlane
        echo "### Control plane initialized"
        break
    fi

    sleep 60
done
if test "${control_plane_initialized}" == "False"; then
    echo "### Control plane failed to initialize"
    exit 1
fi

echo "### Getting kubeconfig for workload cluster"
clusterctl get kubeconfig ${CLUSTER_NAME} >kubeconfig-${CLUSTER_NAME}

echo "### Deploy CNI plugin"
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
tar xvzf cilium-linux-amd64.tar.gz -C /usr/local/bin
helm repo add cilium https://helm.cilium.io
helm repo update
KUBECONFIG=kubeconfig-${CLUSTER_NAME} helm install \
    --namespace kube-system \
    cilium cilium/cilium \
        --set cluster.id=0 \
        --set cluster.name=${CLUSTER_NAME} \
        --set encryption.nodeEncryption=false \
        --set extraConfig.ipam=kubernetes \
        --set extraConfig.kubeProxyReplacement=strict \
        --set k8sServiceHost=${CONTROL_PLANE_ENDPOINT_IP} \
        --set k8sServicePort=6443 \
        --set kubeProxyReplacement=strict \
        --set operator.replicas=1 \
        --set serviceAccounts.cilium.name=cilium \
        --set serviceAccounts.operator.name=cilium-operator \
        --set tunnel=vxlan \
        --set prometheus.enabled=true \
        --set operator.prometheus.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}" \
        --wait --timeout 5m
KUBECONFIG=kubeconfig-${CLUSTER_NAME} cilium status

MAX_WAIT_SECONDS=$(( 30 * 60 ))
SECONDS=0
while test "${SECONDS}" -lt "${MAX_WAIT_SECONDS}"; do
    echo
    echo "### Waiting for control plane of workload cluster to be ready"
    clusterctl describe cluster ${CLUSTER_NAME}

    control_plane_ready="$(
        kubectl get cluster ${CLUSTER_NAME} --output json | \
            jq --raw-output '.status.conditions[] | select(.type == "ControlPlaneReady") | .status'
    )"
    if test "${control_plane_ready}" == "True"; then
        kubectl describe cluster ${CLUSTER_NAME}
        kubectl describe KubeadmControlPlane
        echo "### Control plane initialized"
        break
    fi

    sleep 60
done
if test "${control_plane_ready}" == "False"; then
    echo "### Control plane failed to initialize"
    exit 1
fi

MAX_WAIT_SECONDS=$(( 30 * 60 ))
SECONDS=0
while test "${SECONDS}" -lt "${MAX_WAIT_SECONDS}"; do
    echo
    echo "### Waiting for workers of workload cluster to be ready"
    clusterctl describe cluster ${CLUSTER_NAME}

    worker_ready="$(
        kubectl get machinedeployment ${CLUSTER_NAME}-md-0 --output json | \
            jq --raw-output '.status.conditions[] | select(.type == "Ready") | .status'
    )"
    if test "${worker_ready}" == "True"; then
        echo "### Worker ready"
        break
    fi

    sleep 60
done
if test "${worker_ready}" == "False"; then
    echo "### Workers failed to initialize"
    kubectl describe machinedeployment ${CLUSTER_NAME}-md-0
    exit 1
fi

MAX_WAIT_SECONDS=$(( 30 * 60 ))
SECONDS=0
while test "${SECONDS}" -lt "${MAX_WAIT_SECONDS}"; do
    echo
    echo "### Waiting for nodes to be ready..."
    sleep 5

    if ! kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} get nodes --output jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.reason=="KubeletReady")].status}{"\n"}{end}' | grep -qE "\sFalse$"; then
        echo "### All nodes are ready"
        break
    fi
done
if kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} get nodes --output jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.reason=="KubeletReady")].status}{"\n"}{end}' | grep -qE "\sFalse$"; then
    kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} describe nodes
    kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} get pods -A
    echo "### Nodes are not ready"
    exit 1
fi
echo "### Nodes are ready"

kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} --namespace kube-system get pods --selector k8s-app=cilium --output name | \
    xargs -I{} kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} --namespace kube-system exec -i {} --container cilium-agent -- cilium-health status

echo "### Initialize CAPH in workload cluster"
clusterctl init --kubeconfig kubeconfig-${CLUSTER_NAME} --infrastructure hetzner --wait-providers

echo "### Waiting for management resources to be running"
MAX_WAIT_SECONDS=$(( 30 * 60 ))
SECONDS=0
while test "${SECONDS}" -lt "${MAX_WAIT_SECONDS}"; do
    echo
    echo "Waiting for all pods to be running..."

    if ! kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} get pods -A | tail -n +2 | grep -vq Running; then
        echo "### All pods are ready"
        break
    fi

    sleep 10
done
if kubectl --kubeconfig kubeconfig-${CLUSTER_NAME} get pods -A | tail -n +2 | grep -vq Running; then
    echo "### Pods are not ready"
    exit 1
fi
echo "### Pods are ready"
echo "### Move management resources to workload cluster"
clusterctl move --to-kubeconfig kubeconfig-${CLUSTER_NAME}

echo "### Creating cluster admin"
mv kubeconfig-${CLUSTER_NAME} kubeconfig-${CLUSTER_NAME}-certificate
export KUBECONFIG=kubeconfig-${CLUSTER_NAME}-certificate
cat <<EOF | kubectl --namespace kube-system apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-cluster-admin
  namespace: kube-system
EOF
cat <<EOF | kubectl --namespace kube-system apply -f -
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: my-cluster-admin
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: my-cluster-admin
  namespace: kube-system
EOF
cat <<EOF | kubectl --namespace kube-system apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: my-cluster-admin-token
  annotations:
    kubernetes.io/service-account.name: my-cluster-admin
type: kubernetes.io/service-account-token
EOF
TOKEN=$(
    kubectl --namespace kube-system get secrets my-cluster-admin-token -o json \
    | jq --raw-output '.data.token' \
    | base64 -d
)
SERVER=$(
    kubectl config view --raw --output json \
    | jq --raw-output '.clusters[].cluster.server'
)
CA=$(
    kubectl config view --raw --output json \
    | jq --raw-output '.clusters[].cluster."certificate-authority-data"' \
    | base64 -d
)
export KUBECONFIG=kubeconfig-${CLUSTER_NAME}
if test -f "${KUBECONFIG}"; then
    echo "kubeconfig ${KUBECONFIG} already exists" >&2
    exit 1
fi
touch "${KUBECONFIG}"
kubectl config set-cluster default --server="${SERVER}" --certificate-authority=<(echo "${CA}") --embed-certs=true
kubectl config set-credentials my-cluster-admin --token="${TOKEN}"
kubectl config set-context cluster-admin --cluster=default --user=my-cluster-admin
kubectl config use-context cluster-admin
