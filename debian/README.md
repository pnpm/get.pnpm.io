# Debian package repository for pnpm

## Prerequisites for updating the repo

```sh
dnf install -y dpkg-dev
```

To update the repository, run:

```sh
dpkg-scanpackages . | gzip -c9 > Packages.gz
```

## Usage

On Debian or Ubuntu Linux, you can install pnpm via our Debian package repository. You will first need to configure the repository:

```sh
echo "deb https://get.pnpm.io/debian/" | sudo tee /etc/apt/sources.list.d/pnpm.list
```

Then you can simply:

```sh
sudo apt update && sudo apt install pnpm
```
