#!/bin/bash
set -o errexit -o pipefail

# https://github.com/syself/cluster-api-provider-hetzner/blob/main/docs/topics/quickstart.md

: "${BOOTSTRAP_TOOL:=kind}"

if ! type envsubst 2>&1; then
    echo "ERROR: Missing envsubst. Aborting."
    false
fi
if ! type jq 2>&1; then
    echo "ERROR: Missing jq. Aborting."
    false
fi
case "${BOOTSTRAP_TOOL}" in
    kind)
        if ! type kind 2>&1; then
            echo "ERROR: Missing kind. Aborting."
            false
        fi
        ;;
    k3d)
        if ! type k3d 2>&1; then
            echo "ERROR: Missing k3d. Aborting."
            false
        fi
        ;;
esac
if ! type hcloud 2>&1; then
    echo "ERROR: Missing hcloud. Aborting."
    false
fi
if ! type kubectl 2>&1; then
    echo "ERROR: Missing kubectl. Aborting."
    false
fi
if ! type clusterctl 2>&1; then
    echo "ERROR: Missing clusterctl. Aborting."
    false
fi
if ! type packer 2>&1; then
    echo "ERROR: Missing packer. Aborting."
    false
fi
if ${TALOS} && ! type talosctl 2>&1; then
    echo "ERROR: Missing talosctl. Aborting."
    false
fi
if ! type cilium 2>&1; then
    echo "ERROR: Missing cilium. Aborting."
    false
fi
if ! type helm 2>&1; then
    echo "ERROR: Missing helm. Aborting."
    false
fi
if ! type docker 2>&1; then
    echo "ERROR: Missing docker. Aborting."
    false
fi
while ! docker version >/dev/null 2>&1; do
    sleep 2
done

if test -f .env; then
    source .env
fi

if test -z "${HCLOUD_TOKEN}"; then
    echo "ERROR: Missing environment variable HCLOUD_TOKEN. Aborting."
    false
fi
export HCLOUD_TOKEN

: "${PACKER_REBUILD:=false}"
if test "$( hcloud image list --selector caph-image-name --output json | jq length )" -eq 0; then
    echo "Warning: No image with label caph-image-name found. Image rebuild required."
    PACKER_REBUILD=true
fi
if ${PACKER_REBUILD}; then
    if ${TALOS}; then
        # TODO: Set image name: caph-image-name
        packer init k8s-talos/talos.pkr.hcl
        packer build k8s-talos/talos.pkr.hcl
        CLUSTERCTL_INIT_BOOTSTRAP=talos
        CLUSTERCTL_INIT_CONTROL_PLANE=talos

    else
        echo "### Create CAPH image"
        packer build k8s1.28.4-ubuntu22.04-containerd/image.json
    fi
fi
if test -z "${CAPH_IMAGE_NAME}"; then
    CAPH_IMAGE_NAME="$(
        hcloud image list --selector caph-image-name --output json \
        | jq --raw-output 'sort_by(.created) | .[-1] | .labels."caph-image-name"'
    )"
fi

: "${CLUSTER_NAME:=my-cluster}"
export CLUSTER_NAME

function cleanup() {
    case "${BOOTSTRAP_TOOL}" in
        kind)
            kind delete cluster \
                --name "${CLUSTER_NAME}-bootstrap"
            ;;
        k3d)
            k3d cluster delete "${CLUSTER_NAME}-bootstrap"
            ;;
    esac
}
#trap cleanup EXIT

echo "### Create bootstrap cluster"
: "${BOOTSTRAP_TOOL:=kind}"
case "${BOOTSTRAP_TOOL}" in
    kind)
        if kind get clusters | grep -q "^${CLUSTER_NAME}-bootstrap$"; then
            echo "Bootstrap cluster already exists"
    
        else
            kind create cluster \
                --name "${CLUSTER_NAME}-bootstrap" \
                --kubeconfig ./kubeconfig \
                --wait 5m
        fi
        ;;
    k3d)
        if k3d cluster list | grep -q "^${CLUSTER_NAME}-bootstrap"; then
            echo "Bootstrap cluster already exists"
        
        else
            k3d cluster create "${CLUSTER_NAME}-bootstrap" --kubeconfig-update-default=false
            k3d kubeconfig get "${CLUSTER_NAME}-bootstrap" >./kubeconfig
        fi
        ;;
    *)
        echo "ERROR: Unsupported bootstrapping tool: ${BOOTSTRAP_TOOL}. Aborting."
        false
        ;;
esac
export KUBECONFIG=./kubeconfig

echo "### Initializing CAPH in bootstrap cluster"
: "${CLUSTERCTL_INIT_BOOTSTRAP:=kubeadm}"
: "${CLUSTERCTL_INIT_CONTROL_PLANE:=kubeadm}"
if ! clusterctl init \
        --bootstrap "${CLUSTERCTL_INIT_BOOTSTRAP}" \
        --control-plane "${CLUSTERCTL_INIT_CONTROL_PLANE}" \
        --infrastructure hetzner \
        --wait-providers; then
    echo "ERROR: Failed to execute 'clusterctl init'."
    false
fi
while kubectl get pods -A | tail -n +2 | grep -vqE "(Running|Completed)"; do
    echo "Waiting for all pods to be running..."
    sleep 2
done
sleep 30

echo "### Prepare credentials"
if ! kubectl get secret hetzner >/dev/null 2>&1; then
    kubectl create secret generic hetzner --from-literal=hcloud="${HCLOUD_TOKEN}"

else
    kubectl patch secret hetzner --patch-file <(cat <<EOF
data:
  hcloud: ${HCLOUD_TOKEN}
EOF
)
fi
kubectl patch secret hetzner --patch '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'

echo "### Configure cluster"
if test -z "${HCLOUD_SSH_KEY}"; then
    HCLOUD_SSH_KEY=caph

    SSH_KEY_JSON="$( hcloud ssh-key list --selector type=caph --output json )"
    if test "$( jq 'length' <<<"${SSH_KEY_JSON}" )" -eq 0; then
        echo "### Create and upload SSH key"
        ssh-keygen -f ssh -t ed25519 -N ''
        hcloud ssh-key create --name caph --label type=caph --public-key-from-file ./ssh.pub

    elif test "$( jq 'length' <<<"${SSH_KEY_JSON}" )" -eq 1; then
        echo "### Use existing SSH key"
        if ! test -f ssh; then
            echo "ERROR: Missing ssh private key. Aborting."
            false
        fi

    else
        echo "ERROR: No or exactly one SSH key with label type=caph is required. Aborting."
        false

    fi
fi
export HCLOUD_SSH_KEY
: "${HCLOUD_REGION:=fsn1}"
: "${CONTROL_PLANE_MACHINE_COUNT:=3}"
: "${WORKER_MACHINE_COUNT:=3}"
: "${KUBERNETES_VERSION:=1.28.4}"
: "${HCLOUD_CONTROL_PLANE_MACHINE_TYPE:=cpx21}"
: "${HCLOUD_WORKER_MACHINE_TYPE:=cpx21}"
export HCLOUD_REGION
export HCLOUD_CONTROL_PLANE_MACHINE_TYPE
export HCLOUD_WORKER_MACHINE_TYPE

echo "### Rolling out workload cluster"
if ! test -f cluster.yaml; then
    clusterctl generate cluster "${CLUSTER_NAME}" \
        --kubernetes-version "v${KUBERNETES_VERSION}" \
        --control-plane-machine-count="${CONTROL_PLANE_MACHINE_COUNT}" \
        --worker-machine-count="${WORKER_MACHINE_COUNT}" \
    >cluster.yaml
fi
sed -i -E "s/^(\s+imageName:) .+$/\1 ${CAPH_IMAGE_NAME}/" cluster.yaml
: "${STOP_AFTER_CLUSTER_YAML:=false}"
if ${STOP_AFTER_CLUSTER_YAML}; then
    echo "STOP_AFTER_CLUSTER_YAML is set. Aborting."
    exit 0
fi

kubectl apply -f cluster.yaml
sleep 10
MAX_WAIT_SECONDS=$(( 30 * 60 ))
SECONDS=0
while test "${SECONDS}" -lt "${MAX_WAIT_SECONDS}"; do
    echo
    echo "### Waiting for control plane of workload cluster to be initialized"
    clusterctl describe cluster ${CLUSTER_NAME}

    control_plane_initialized="$(
        kubectl get cluster ${CLUSTER_NAME} --output json | \
            jq --raw-output '.status.conditions[] | select(.type == "ControlPlaneInitialized") | .status'
    )"
    if test "${control_plane_initialized}" == "True"; then
        echo "### Control plane initialized"
        break
    fi

    sleep 30
done
if test "${control_plane_initialized}" == "False"; then
    echo "### Control plane failed to initialize"
    exit 1
fi

echo "### Getting kubeconfig for workload cluster"
clusterctl get kubeconfig ${CLUSTER_NAME} >kubeconfig-${CLUSTER_NAME}

echo "### Deploy CNI plugin"
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

echo "### Deploy cloud-controller-manager"
helm repo add syself https://charts.syself.com
helm repo update syself
KUBECONFIG=kubeconfig-${CLUSTER_NAME} helm install \
	--namespace kube-system \
    ccm syself/ccm-hcloud \
        --set secret.name=hetzner \
        --set secret.tokenKeyName=hcloud \
        --set privateNetwork.enabled=false

echo "### Deploy csi"
KUBECONFIG=kubeconfig-${CLUSTER_NAME} helm install \
    --namespace kube-system \
    csi syself/csi-hcloud \
        --set controller.hcloudToken.existingSecret.name=hetzner \
        --set controller.hcloudToken.existingSecret.key=hcloud \
        --set storageClasses[0].name=hcloud-volumes \
        --set storageClasses[0].defaultStorageClass=true \
        --set storageClasses[0].reclaimPolicy=Retain

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
        echo "### Control plane ready"
        break
    fi

    sleep 60
done
if test "${control_plane_ready}" == "False"; then
    echo "### Control plane failed to become ready"
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
        echo "### Workers ready"
        break
    fi

    sleep 60
done
if test "${worker_ready}" == "False"; then
    echo "### Workers failed to become ready"
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

KUBECONFIG=kubeconfig-${CLUSTER_NAME} cilium status --wait

echo "### Initialize CAPH in workload cluster"
clusterctl init --bootstrap "${CLUSTERCTL_INIT_BOOTSTRAP}" --control-plane "${CLUSTERCTL_INIT_CONTROL_PLANE}" --kubeconfig kubeconfig-${CLUSTER_NAME} --infrastructure hetzner --wait-providers

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
# TODO: Always re-create sa, secret and kubeconfig
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

echo "### Removing bootstrap cluster"
case "${BOOTSTRAP_TOOL}" in
    kind)
        kind delete cluster "${CLUSTER_NAME}-bootstrap"
        ;;
    k3d)
        k3d cluster delete "${CLUSTER_NAME}-bootstrap"
        ;;
    *)
        echo "ERROR: Unsupported bootstrapping tool: ${BOOTSTRAP_TOOL}. Aborting."
        false
        ;;
esac
