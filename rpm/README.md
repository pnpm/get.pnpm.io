# RPM package repository of pnpm

To update the repository, run:

```
createrepo .
```

## Usage

On CentOS, Fedora and RHEL, you can install pnpm via our RPM package repository.

```sh
curl --silent --location https://get.pnpm.io/rpm/pnpm.repo | sudo tee /etc/yum.repos.d/pnpm.repo
```

Then you can simply:

```sh
sudo yum install pnpm
## OR ##
sudo dnf install pnpm
```

## Testing

```
docker run -it centos sh
curl --silent --location https://get.pnpm.io/rpm/pnpm.repo | tee /etc/yum.repos.d/pnpm.repo
dnf install pnpm -y
pnpm env use -g lts
```

