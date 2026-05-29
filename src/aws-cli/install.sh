#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/awscli.md
# Maintainer: The VS Code and Codespaces Teams

set -e

VERSION=${VERSION:-"latest"}
VERBOSE=${VERBOSE:-"true"}

AWSCLI_GPG_KEY=FB5DB77FD5C118B80511ADA8A6310ACC4672475C
AWSCLI_GPG_KEY_MATERIAL="-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBF2Cr7UBEADJZHcgusOJl7ENSyumXh85z0TRV0xJorM2B/JL0kHOyigQluUG
ZMLhENaG0bYatdrKP+3H91lvK050pXwnO/R7fB/FSTouki4ciIx5OuLlnJZIxSzx
PqGl0mkxImLNbGWoi6Lto0LYxqHN2iQtzlwTVmq9733zd3XfcXrZ3+LblHAgEt5G
TfNxEKJ8soPLyWmwDH6HWCnjZ/aIQRBTIQ05uVeEoYxSh6wOai7ss/KveoSNBbYz
gbdzoqI2Y8cgH2nbfgp3DSasaLZEdCSsIsK1u05CinE7k2qZ7KgKAUIcT/cR/grk
C6VwsnDU0OUCideXcQ8WeHutqvgZH1JgKDbznoIzeQHJD238GEu+eKhRHcz8/jeG
94zkcgJOz3KbZGYMiTh277Fvj9zzvZsbMBCedV1BTg3TqgvdX4bdkhf5cH+7NtWO
lrFj6UwAsGukBTAOxC0l/dnSmZhJ7Z1KmEWilro/gOrjtOxqRQutlIqG22TaqoPG
fYVN+en3Zwbt97kcgZDwqbuykNt64oZWc4XKCa3mprEGC3IbJTBFqglXmZ7l9ywG
EEUJYOlb2XrSuPWml39beWdKM8kzr1OjnlOm6+lpTRCBfo0wa9F8YZRhHPAkwKkX
XDeOGpWRj4ohOx0d2GWkyV5xyN14p2tQOCdOODmz80yUTgRpPVQUtOEhXQARAQAB
tCFBV1MgQ0xJIFRlYW0gPGF3cy1jbGlAYW1hem9uLmNvbT6JAlQEEwEIAD4WIQT7
Xbd/1cEYuAURraimMQrMRnJHXAUCXYKvtQIbAwUJB4TOAAULCQgHAgYVCgkICwIE
FgIDAQIeAQIXgAAKCRCmMQrMRnJHXJIXEAChLUIkg80uPUkGjE3jejvQSA1aWuAM
yzy6fdpdlRUz6M6nmsUhOExjVIvibEJpzK5mhuSZ4lb0vJ2ZUPgCv4zs2nBd7BGJ
MxKiWgBReGvTdqZ0SzyYH4PYCJSE732x/Fw9hfnh1dMTXNcrQXzwOmmFNNegG0Ox
au+VnpcR5Kz3smiTrIwZbRudo1ijhCYPQ7t5CMp9kjC6bObvy1hSIg2xNbMAN/Do
ikebAl36uA6Y/Uczjj3GxZW4ZWeFirMidKbtqvUz2y0UFszobjiBSqZZHCreC34B
hw9bFNpuWC/0SrXgohdsc6vK50pDGdV5kM2qo9tMQ/izsAwTh/d/GzZv8H4lV9eO
tEis+EpR497PaxKKh9tJf0N6Q1YLRHof5xePZtOIlS3gfvsH5hXA3HJ9yIxb8T0H
QYmVr3aIUes20i6meI3fuV36VFupwfrTKaL7VXnsrK2fq5cRvyJLNzXucg0WAjPF
RrAGLzY7nP1xeg1a0aeP+pdsqjqlPJom8OCWc1+6DWbg0jsC74WoesAqgBItODMB
rsal1y/q+bPzpsnWjzHV8+1/EtZmSc8ZUGSJOPkfC7hObnfkl18h+1QtKTjZme4d
H17gsBJr+opwJw/Zio2LMjQBOqlm3K1A4zFTh7wBC7He6KPQea1p2XAMgtvATtNe
YLZATHZKTJyiqA==
=vYOk
-----END PGP PUBLIC KEY BLOCK-----"

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile.' >&2
    exit 1
fi

# --- ALPINE (apk) ---
apk_install_packages() {
    echo "Installing packages on Alpine: $*"
    # --no-cache updates the index automatically and doesn't leave clutter
    apk add --no-cache "$@"
}

# --- REDHAT/FEDORA (dnf) ---
dnf_install_packages() {
    # Check if any of the requested packages are missing
    # dnf list installed <pkg> returns 0 if installed, 1 if not
    if ! dnf list installed "$@" > /dev/null 2>&1; then
        # Check if cache is empty before updating
        if [ "$(find /var/cache/dnf/ -type f | wc -l)" = "0" ]; then
            echo "Running dnf update..."
            dnf update -y
        fi
        echo "Installing packages via dnf: $*"
        dnf -y install --allowerasing "$@"
        
        # CLEANUP FOR DNF
        echo "Cleaning up dnf cache..."
        dnf clean all
        rm -rf /var/cache/dnf
    fi
}

# --- DEBIAN/UBUNTU (apt) ---
apt_install_packages() {
    # Check if packages are missing using dpkg-query
    # We loop through because dpkg -s needs a specific syntax for multiple packages
    local missing_pkgs=""
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        # Check if apt cache is empty (safer find syntax without wildcard)
        if [ "$(find /var/lib/apt/lists/ -type f | wc -l)" = "0" ]; then
            echo "Running apt-get update..."
            apt-get update -y
        fi
        echo "Installing packages via apt: $missing_pkgs"
        apt-get -y install --no-install-recommends $missing_pkgs

        # CLEANUP FOR APT
        echo "Cleaning up apt cache..."
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    fi
}

# --- MAIN ENTRYPOINT ---
check_packages() {
    if [ -x "$(command -v apk)" ]; then
        apk_install_packages "$@"
    elif [ -x "$(command -v dnf)" ]; then
        dnf_install_packages "$@"
    elif [ -x "$(command -v apt-get)" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt_install_packages "$@"
    else
        echo "Error: No supported package manager found (apk, dnf, apt)." >&2
        exit 1
    fi
}

check_packages curl ca-certificates gpg dirmngr unzip bash-completion less

verify_aws_cli_gpg_signature() {
    local filePath=$1
    local sigFilePath=$2
    local awsGpgKeyring=aws-cli-public-key.gpg

    echo "${AWSCLI_GPG_KEY_MATERIAL}" | gpg --dearmor > "./${awsGpgKeyring}"
    gpg --batch --quiet --no-default-keyring --keyring "./${awsGpgKeyring}" --verify "${sigFilePath}" "${filePath}"
    local status=$?

    rm "./${awsGpgKeyring}"

    return ${status}
}

get_architecture() {
    local arch
    
    if [ -x "$(command -v dpkg)" ]; then
        # Safely use dpkg if on Debian/Ubuntu
        arch=$(dpkg --print-architecture)
    else
        # Fallback to universal uname for Alpine/Fedora
        arch=$(uname -m)
    fi

    # Normalize names to a standard format if you are downloading external binaries
    case "${arch}" in
        aarch64|arm64)
            echo "arm64"
            ;;
        x86_64|amd64)
            echo "amd64"
            ;;
        *)
            echo "${arch}"
            ;;
    esac
}

install() {
    local scriptZipFile=awscli.zip
    local scriptSigFile=awscli.sig

    # See Linux install docs at https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
    if [ "${VERSION}" != "latest" ]; then
        local versionStr=-${VERSION}
    fi

    if [ -x "$(command -v dpkg)" ]; then
        # Safely use dpkg if on Debian/Ubuntu
        architecture=$(dpkg --print-architecture)
    else
        # Fallback to universal uname for Alpine/Fedora
        architecture=$(uname -m)
    fi

    case "${architecture}" in
        aarch64|arm64) architectureStr=aarch64 ;;
        x86_64|amd64) architectureStr=x86_64 ;;
        *)
            echo "AWS CLI does not support machine architecture '$architecture'. Please use an x86-64 or ARM64 machine."
            exit 1
    esac
    local scriptUrl=https://awscli.amazonaws.com/awscli-exe-linux-${architectureStr}${versionStr}.zip
    curl "${scriptUrl}" -o "${scriptZipFile}"
    curl "${scriptUrl}.sig" -o "${scriptSigFile}"

    verify_aws_cli_gpg_signature "$scriptZipFile" "$scriptSigFile"
    if (( $? > 0 )); then
        echo "Could not verify GPG signature of AWS CLI install script. Make sure you provided a valid version."
        exit 1
    fi

    if [ "${VERBOSE}" = "false" ]; then
        unzip -q "${scriptZipFile}"
    else
        unzip "${scriptZipFile}"
    fi

    ./aws/install

    # AWS bash completion
    mkdir -p /etc/bash_completion.d
    cp ./scripts/vendor/aws_bash_completer /etc/bash_completion.d/aws

    # AWS zsh completion
    mkdir -p /usr/local/share/zsh/site-functions/
    cp ./scripts/vendor/aws_zsh_completer.sh /usr/local/share/zsh/site-functions/_aws
    sed -i '1s/^/#compdef aws\n/' /usr/local/share/zsh/site-functions/_aws

    rm -rf ./aws
}

echo "(*) Installing AWS CLI..."

install

echo "Done!"
