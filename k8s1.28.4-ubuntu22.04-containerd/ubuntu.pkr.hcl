packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "~> 1"
    }
  }
}

variable "os" {
    type = string
    default = "ubuntu-22.04"
}

variable "arch" {
    type = string
    default = "amd64"
}

variable "image-name" {
    type = string
    default = "ubuntu-22.04-kubeadm"
}

variable "version" {
    type = string
    default = "{{isotime '2006-01-02-1504'}}"
}

source "hcloud" "ubuntu" {
    image = "${var.os}"
    location = "fsn1"
    server_type = "cx21"
    ssh_username = "root"

    snapshot_name = "${var.os}-${var.arch}"
    snapshot_labels = {
        "caph-image-name" = "${var.os}-${var.arch}"
    }
}

build {
    sources = ["source.hcloud.ubuntu"]

    provisioner "shell" {
        environment_vars = [
            "PACKER_OS_IMAGE=${var.os}",
            "PACKER_ARCH=${var.arch}"
        ]
        scripts = [
            "scripts/base.sh",
            "scripts/cilium-requirements.sh",
            "scripts/cri.sh",
            "scripts/kubernetes.sh",
            "scripts/cleanup.sh"
        ]
    }
}