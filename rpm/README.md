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
sudo yum install yarn
## OR ##
sudo dnf install yarn
```

