# k8s_caph_talos

This repository contains a script to create a Kubernetes cluster using the Cluster API on Hetzner Cloud with the option to use Talos as the operating system.

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
- `HCLOUD_REGION` defaults to `fsn1`
- `CONTROL_PLANE_MACHINE_COUNT` and `WORKER_MACHINE_COUNT` both default to 3
- `HCLOUD_CONTROL_PLANE_MACHINE_TYPE` and `HCLOUD_WORKER_MACHINE_TYPE` both default to `cx21`
- `BOOTSTRAP_TOOL` defaults to `kind`
- `TALOS` defaults to `false`
- `PACKER_REBUILD` defaults to `false` but is automatically set to `true` if no suitable image is found

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
