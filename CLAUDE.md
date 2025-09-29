# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a home lab Kubernetes cluster configuration repository using k0s as the Kubernetes distribution. The cluster consists of 4 nodes (1 controller+worker, 3 workers) with Longhorn for persistent storage.

## Architecture

- **Cluster Management**: Uses k0sctl for cluster provisioning and management
- **Kubernetes Distribution**: k0s (lightweight, certified Kubernetes distribution)
- **Storage**: Longhorn distributed block storage system with single replica configuration
- **Network**: kuberouter CNI with iptables mode
- **Node Configuration**:
  - Controller+worker: 192.168.2.100 (no taints)
  - Workers: 192.168.2.101, 192.168.2.102, 192.168.2.103

## Essential Commands

### Cluster Operations
```bash
# Deploy/update the cluster
k0sctl apply --config k0sctl.yaml

# Get cluster status
k0sctl kubeconfig --config k0sctl.yaml > kubeconfig
export KUBECONFIG=./kubeconfig
kubectl get nodes

# Reset the cluster (destructive)
k0sctl reset --config k0sctl.yaml
```

### Longhorn Storage Setup
```bash
# Install iscsi tools on all nodes first
# Then install Longhorn
helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create namespace longhorn-system
helm install longhorn longhorn/longhorn -n longhorn-system -f longhorn/values-longhorn.yaml

# Apply storage class
kubectl apply -f longhorn/storageclass.yaml

# Access Longhorn UI
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

## Configuration Files

- `k0sctl.yaml`: Main cluster configuration with node definitions and k0s settings
- `longhorn/values-longhorn.yaml`: Longhorn Helm chart values (single replica, SSD-only)
- `longhorn/storageclass.yaml`: Default StorageClass with single replica
- `longhorn/README.md`: Detailed Longhorn setup instructions

## Important Notes

- The cluster uses single replica storage (no redundancy) for cost efficiency
- Only SSD nodes (alpha, beta) are used for Longhorn storage
- Default storage class is `longhorn-single` with ext4 filesystem
- All nodes use the same SSH key (`~/.ssh/id_ed25519`) and user (`rboiko`)
- Cluster API runs on port 6443, k0s API on port 9443

## Required Tools

- `k0sctl`: Cluster management tool
- `kubectl`: Kubernetes CLI
- `helm`: Package manager for Kubernetes