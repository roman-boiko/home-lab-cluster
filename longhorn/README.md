# How to setup Longhorn

1. Install iscsi tools on every node

```
sudo apt update && sudo apt install -y open-iscsi
sudo systemctl enable --now iscsid
```

2. Label ssd nodes, so only they used as Longhorn storage

```
kubectl label node alpha node.longhorn.io/create-default-disk=true
kubectl label node beta node.longhorn.io/create-default-disk=true
```

3. Create mount points on the nodes

```
ssh rboiko@alpha sudo mkdir -p /opt/longhorn/
ssh rboiko@beta sudo mkdir -p /opt/longhorn1/
```

4. Install Longhorn with helm

```
helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create namespace longhorn-system
helm install longhorn longhorn/longhorn -n longhorn-system -f values-longhorn.yaml
```

5. Tag the SSD nodes/disks as "storage/ssd"

```
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# browse http://localhost:8080
```

In the UI:

- Node → alpha → Edit Node and Disks
  - Add a Node tag: storage
  - Add a Disk tag on the default disk: ssd
- Repeat for beta.

  Storage tags let you target only the SSD nodes/disks from a StorageClass

6. Create StorageClass

```
kubectl apply -f storageclass.yaml
```
