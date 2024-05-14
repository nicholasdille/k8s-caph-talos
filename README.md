# k8s_caph_talos

This repository contains an opinionated script to create a Kubernetes cluster using the [Cluster API](https://cluster-api.sigs.k8s.io/) on [Hetzner Cloud](https://www.hetzner.com/de/cloud/) with the option to use [Talos](https://www.talos.dev/) as the operating system.

After creating a local bootstrap cluster, the workload cluster is created in Hetzer Cloud. Afterwards, the management services are moved into the workload cluster.

The resulting cluster will be able to manage itself as well as create new clusters on Hetzner Cloud. 

## Usage

Calling the following script ...

```shell
bash k8s_capi_hetzner.sh
```

...creates a Kubernetes cluster on Hetzner Cloud using the Cluster API.

The corresponding `kubeconfig` file is stored in the current directory as `kubeconfig-${CLUSTER_NAME}`.

## Prerequisites

The script relies on a number of binaries to work:
- `kubectl`
- `kind` or `k3d`
- `packer`
- `hcloud`
- `envsubst`
- `jq`
- `clusterctl`
- `talosctl`
- `cilium`
- `docker`

Those prerequisites can be installed with [`uniget`](https://uniget.dev).

## Configuration

The script is configured using environment variables. They can be added to a `.env` file in the same directory as the script.

The following environment variables are available:
- `HCLOUD_TOKEN`
- `CLUSTER_NAME` defaults to `my-cluster`
- `CAPH_IMAGE_NAME` defaults to youngest image with label `caph-image-name`
- `HCLOUD_REGION` defaults to `fsn1`
- `CONTROL_PLANE_MACHINE_COUNT` and `WORKER_MACHINE_COUNT` both default to 3
- `HCLOUD_CONTROL_PLANE_MACHINE_TYPE` and `HCLOUD_WORKER_MACHINE_TYPE` both default to `cx21`
- `BOOTSTRAP_TOOL` defaults to `kind`
- `TALOS` defaults to `false`
- `PACKER_REBUILD` defaults to `false` but is automatically set to `true` if no suitable image is found

The following environment variables enable debugging the script:
- `STOP_AFTER_CLUSTER_YAML` stops the script after the cluster configuration has been generated

## Internals

This is how the script works:

1. Create a bootstrap cluster using `kind` or `k3d`
1. Initialize Cluster API for Hetzner Cloud in the bootstrap cluster
1. Generate a cluster configuration for the workload cluster
1. Wait for the control plane to initialize
1. Deploy Cilium
1. Deploy cloud-controller-manager for Hetzner Cloud
1. Deploy the Hetzner Cloud CSI driver
1. Wait for the controle plane to be ready
1. Wait for the worker nodes to be ready
1. Initialize Cluster API in the workload cluster
1. Move the cluster configuration to the workload cluster
1. Create a `kubeconfig` for the workload cluster with a dedicated service account

## TODO

- [ ] Talos
- [x] Idempotency (being able to restart and pick up where it left off)
- [ ] Configure CIDRs for pods and services
    ```shell
    yq --inplace eval '.spec.clusterNetwork.pods.cidrBlocks = ["foo"]' templates/kubeadm/*.yaml
    ```
    OR
    ```shell
    yq --inplace eval 'select(.kind == "Cluster").spec.clusterNetwork.pods.cidrBlocks |= ["foo"]' cluster.yaml
    ```
- [ ] Support infrastructure docker?
- [ ] Support infrastructure vcluster?
- [ ] Check out [Cluster API Operator](https://github.com/kubernetes-sigs/cluster-api-operator)
