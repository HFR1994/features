#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/ruby.md
# Maintainer: The VS Code and Codespaces Teams

RUBY_VERSION="${VERSION:-"latest"}"

USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
UPDATE_RC="${UPDATE_RC:-"true"}"
INSTALL_RUBY_TOOLS="${INSTALL_RUBY_TOOLS:-"true"}"

# Comma-separated list of ruby versions to be installed (with rvm)
# alongside RUBY_VERSION, but not set as default.
ADDITIONAL_VERSIONS="${ADDITIONALVERSIONS:-""}"

DEFAULT_GEMS="rake"
RVM_GPG_KEYS="409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB"

set -e

# Detect OS Family
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_ID_LIKE="${ID_LIKE}"
else
    OS_ID="unknown"
    OS_ID_LIKE="unknown"
fi

# Multi-distro package manager wrapper
pkg_manager_update() {
    case "${OS_ID}" in
        debian|ubuntu)
            if [ "$(find /var/lib/apt/lists/* 2>/dev/null | wc -l)" = "0" ]; then
                echo "Running apt-get update..."
                apt-get update -y
            fi
            ;;
        fedora|rhel|amzn|centos)
            echo "Refreshing package cache..."
            if type dnf > /dev/null 2>&1; then
                dnf check-update > /dev/null 2>&1 || true
            else
                yum check-update > /dev/null 2>&1 || true
            fi
            ;;
        alpine)
            echo "Running apk update..."
            apk update
            ;;
    esac
}

check_packages() {
    local pkgs_to_install=()
    case "${OS_ID}" in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            for pkg in "$@"; do
                if ! dpkg -s "${pkg}" > /dev/null 2>&1; then
                    pkgs_to_install+=("${pkg}")
                fi
            done
            if [ ${#pkgs_to_install[@]} -gt 0 ]; then
                pkg_manager_update
                apt-get -y install --no-install-recommends "${pkgs_to_install[@]}"
            fi
            ;;
        fedora|rhel|amzn|centos)
            local pkg_cmd="yum"
            type dnf > /dev/null 2>&1 && pkg_cmd="dnf"
            for pkg in "$@"; do
                if ! rpm -q "${pkg}" > /dev/null 2>&1; then
                    pkgs_to_install+=("${pkg}")
                fi
            done
            if [ ${#pkgs_to_install[@]} -gt 0 ]; then
                ${pkg_cmd} --allowerasing -y install "${pkgs_to_install[@]}"
            fi
            ;;
        alpine)
            for pkg in "$@"; do
                if ! apk info -e "${pkg}" > /dev/null 2>&1; then
                    pkgs_to_install+=("${pkg}")
                fi
            done
            if [ ${#pkgs_to_install[@]} -gt 0 ]; then
                pkg_manager_update
                apk add --no-cache "${pkgs_to_install[@]}"
            fi
            ;;
    esac
}

# Clean initial package caches safely
if [ "${OS_ID}" = "debian" ] || [ "${OS_ID}" = "ubuntu" ]; then
    rm -rf /var/lib/apt/lists/*
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Cross-distro dependencies mappings
if [ "${OS_ID}" = "alpine" ]; then
    # Alpine target dependencies
    check_packages bash curl ca-certificates build-base gnupg procps gawk autoconf automake bison libffi-dev gdbm-dev ncurses-dev sqlite-dev libtool yaml-dev pkgconfig zlib-dev gmp-dev openssl-dev shadow git jq
elif [ "${OS_ID}" = "fedora" ] || [ "${OS_ID}" = "rhel" ] || [ "${OS_ID}" = "amzn" ]; then
    # RedHat family target dependencies
    check_packages curl ca-certificates make gcc gcc-c++ gnupg2 procps gawk autoconf automake bison libffi-devel gdbm-devel ncurses-devel sqlite-devel libtool libyaml-devel pkgconfig zlib-devel gmp-devel openssl-devel git jq
else
    # Debian/Ubuntu targets
    check_packages curl ca-certificates build-essential gnupg2 libreadline-dev procps dirmngr gawk autoconf automake bison libffi-dev libgdbm-dev libncurses5-dev libsqlite3-dev libtool libyaml-dev pkg-config sqlite3 zlib1g-dev libgmp-dev libssl-dev jq git
    if [ "${VERSION_CODENAME}" != "trixie" ]; then
        check_packages software-properties-common
    fi
fi

# Ensure that login shells get the correct path if the user updated the PATH using ENV.
rm -f /etc/profile.d/00-restore-env.sh
echo "export PATH=${PATH//$(sh -lc 'echo $PATH')/\$PATH}" > /etc/profile.d/00-restore-env.sh
chmod +x /etc/profile.d/00-restore-env.sh

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

updaterc() {
    if [ "${UPDATE_RC}" = "true" ]; then
        echo "Updating shell configurations..."
        local rc_files=()
        [ -f /etc/bash.bashrc ] && rc_files+=( "/etc/bash.bashrc" )
        [ -f /etc/bashrc ] && rc_files+=( "/etc/bashrc" )
        [ -f /etc/zsh/zshrc ] && rc_files+=( "/etc/zsh/zshrc" )

        # Alpine/Minimal fallbacks if global configurations don't exist
        if [ ${#rc_files[@]} -eq 0 ]; then
            mkdir -p /etc
            touch /etc/bashrc
            rc_files+=( "/etc/bashrc" )
        fi

        for rc_file in "${rc_files[@]}"; do
            if [[ "$(cat "${rc_file}")" != *"$1"* ]]; then
                echo -e "$1" >> "${rc_file}"
            fi
        done
    fi
}

get_gpg_key_servers() {
    declare -A keyservers_curl_map=(
        ["hkp://keyserver.ubuntu.com"]="http://keyserver.ubuntu.com:11371"
        ["hkp://keyserver.ubuntu.com:80"]="http://keyserver.ubuntu.com"
        ["hkps://keys.openpgp.org"]="https://keys.openpgp.org"
        ["hkp://keyserver.pgp.com"]="http://keyserver.pgp.com:11371"
    )
    local curl_args=""
    local keyserver_reachable=false

    if [ ! -z "${KEYSERVER_PROXY}" ]; then
        curl_args="--proxy ${KEYSERVER_PROXY}"
    fi

    for keyserver in "${!keyservers_curl_map[@]}"; do
        local keyserver_curl_url="${keyservers_curl_map[${keyserver}]}"
        if curl -s ${curl_args} --max-time 5 ${keyserver_curl_url} > /dev/null; then
            echo "keyserver ${keyserver}"
            keyserver_reachable=true
        else
            echo "(*) Keyserver ${keyserver} is not reachable." >&2
        fi
    done

    if ! $keyserver_reachable; then
        echo "(!) No keyserver is reachable." >&2
        exit 1
    fi
}

receive_gpg_keys() {
    local keys=${!1}
    local keyring_args=""
    if [ ! -z "$2" ]; then
        keyring_args="--no-default-keyring --keyring \"$2\""
    fi

    export GNUPGHOME="/tmp/tmp-gnupg"
    mkdir -p ${GNUPGHOME}
    chmod 700 ${GNUPGHOME}
    echo -e "disable-ipv6\n$(get_gpg_key_servers)" > ${GNUPGHOME}/dirmngr.conf

    local retry_count=0
    local gpg_ok="false"
    set +e
    until [ "${gpg_ok}" = "true" ] || [ "${retry_count}" -eq "5" ];
    do
        echo "(*) Downloading GPG key..."
        ( echo "${keys}" | xargs -n 1 gpg -q ${keyring_args} --recv-keys) 2>&1 && gpg_ok="true"
        if [ "${gpg_ok}" != "true" ]; then
            echo "(*) Failed getting key, retrying in 10s..."
            (( retry_count++ ))
            sleep 10s
        fi
    done
    set -e
    if [ "${gpg_ok}" = "false" ]; then
        echo "(!) Failed to get gpg key."
        exit 1
    fi
}

find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}
    if [ "$(echo "${requested_version}" | grep -o "\." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

find_prev_version_from_git_tags() {
    local variable_name=$1
    local current_version=${!variable_name}
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}
    local version_suffix_regex=$6
    set +e
        major="$(echo "${current_version}" | grep -oE '^[0-9]+' || echo '')"
        minor="$(echo "${current_version}" | grep -oP '^[0-9]+\.\K[0-9]+' || echo '')"
        breakfix="$(echo "${current_version}" | grep -oP '^[0-9]+\.[0-9]+\.\K[0-9]+' 2>/dev/null || echo '')"

        if [ "${minor}" = "0" ] && [ "${breakfix}" = "0" ]; then
            ((major=major-1))
            declare -g ${variable_name}="${major}"
            find_version_from_git_tags "${variable_name}" "${repository}" "${prefix}" "${separator}" "${last_part_optional}"
        elif [ "${breakfix}" = "" ] || [ "${breakfix}" = "0" ]; then
            ((minor=minor-1))
            declare -g ${variable_name}="${major}.${minor}"
            find_version_from_git_tags "${variable_name}" "${repository}" "${prefix}" "${separator}" "${last_part_optional}"
        else
            ((breakfix=breakfix-1))
            if [ "${breakfix}" = "0" ] && [ "${last_part_optional}" = "true" ]; then
                declare -g ${variable_name}="${major}.${minor}"
            else
                declare -g ${variable_name}="${major}.${minor}.${breakfix}"
            fi
        fi
    set -e
}

get_previous_version() {
    local url=$1
    local repo_url=$2
    variable_name=$3
    prev_version=${!variable_name}

    output=$(curl -s "$repo_url");
    message=$(echo "$output" | jq -r '.message')

    if [[ $message == "API rate limit exceeded"* ]]; then
        echo -e "\nAn attempt to find latest version using GitHub Api Failed... \nReason: ${message}"
        echo -e "\nAttempting to find latest version using GitHub tags."
        find_prev_version_from_git_tags prev_version "$url" "tags/v" "_"
        declare -g ${variable_name}="${prev_version}"
    else
        echo -e "\nAttempting to find latest version using GitHub Api."
        version=$(echo "$output" | jq -r '.tag_name' | tr '_' '.')
        declare -g ${variable_name}="${version#v}"
    fi
    echo "${variable_name}=${!variable_name}"
}

get_github_api_repo_url() {
    local url=$1
    echo "${url/https:\/\/github.com/https:\/\/api.github.com\/repos}/releases/latest"
}

RUBY_URL="https://github.com/ruby/ruby"
ORIGINAL_RUBY_VERSION=$RUBY_VERSION
find_version_from_git_tags RUBY_VERSION $RUBY_URL "tags/v" "_"

set_rvm_install_args() {
    RUBY_VERSION=$1
    if [ "${RUBY_VERSION}" = "none" ]; then
        RVM_INSTALL_ARGS=""
    elif [[ "$(ruby -v 2>/dev/null)" = *"${RUBY_VERSION}"* ]]; then
        echo "(!) Ruby is already installed with version ${RUBY_VERSION}. Skipping..."
        RVM_INSTALL_ARGS=""
    else
        if [ "${RUBY_VERSION}" = "latest" ] || [ "${RUBY_VERSION}" = "current" ] || [ "${RUBY_VERSION}" = "lts" ]; then
            RVM_INSTALL_ARGS="--ruby"
            RUBY_VERSION=""
        else
            RVM_INSTALL_ARGS="--ruby=${RUBY_VERSION}"
        fi
        if [ "${INSTALL_RUBY_TOOLS}" = "true" ]; then
            SKIP_GEM_INSTALL="true"
        else
            DEFAULT_GEMS=""
        fi
    fi
}

install_previous_version() {
    if [[ $ORIGINAL_RUBY_VERSION == "latest" ]]; then
        repo_url=$(get_github_api_repo_url "$RUBY_URL")
        get_previous_version "${RUBY_URL}" "${repo_url}" RUBY_VERSION
        set_rvm_install_args $RUBY_VERSION
        curl -sSL https://get.rvm.io | bash -s stable --ignore-dotfiles ${RVM_INSTALL_ARGS} --with-default-gems="${DEFAULT_GEMS}" 2>&1
    else
        echo "Failed to install Ruby version $ORIGINAL_RUBY_VERSION. Exiting..."
    fi
}

if rvm --version > /dev/null 2>&1; then
    echo "Ruby Version Manager already exists."
    if [[ "$(ruby -v 2>/dev/null)" = *"${RUBY_VERSION}"* ]]; then
        echo "(!) Ruby is already installed with version ${RUBY_VERSION}. Skipping..."
    elif [ "${RUBY_VERSION}" != "none" ]; then
        echo "Installing specified Ruby version."
        su ${USERNAME} -c "rvm install ruby ${RUBY_VERSION}"
    fi
    SKIP_GEM_INSTALL="false"
    SKIP_RBENV_RBUILD="true"
else
    receive_gpg_keys RVM_GPG_KEYS
    set_rvm_install_args $RUBY_VERSION
    if ! cat /etc/group | grep -e "^rvm:" > /dev/null 2>&1; then
        groupadd -r rvm
    fi
    curl -sSL https://get.rvm.io | bash -s stable --ignore-dotfiles ${RVM_INSTALL_ARGS} --with-default-gems="${DEFAULT_GEMS}" 2>&1 || install_previous_version
    usermod -aG rvm ${USERNAME}

    # Secure dynamic resolution of RVM script paths
    [ -f /usr/local/rvm/scripts/rvm ] && source /usr/local/rvm/scripts/rvm
    [ -f /usr/share/rvm/scripts/rvm ] && source /usr/share/rvm/scripts/rvm

    rvm fix-permissions system
    rm -rf ${GNUPGHOME}
fi

if [ "${INSTALL_RUBY_TOOLS}" = "true" ]; then
    ROOT_GEM="$(which gem || echo "")"
    if [ ! -z "${ROOT_GEM}" ]; then
        ${ROOT_GEM} install ${DEFAULT_GEMS}
    fi
fi

# Clean up configuration scripts mappings
RVM_SRC_PATH="/usr/local/rvm/scripts/rvm"
[ ! -f "${RVM_SRC_PATH}" ] && [ -f "/usr/share/rvm/scripts/rvm" ] && RVM_SRC_PATH="/usr/share/rvm/scripts/rvm"
updaterc "if ! grep rvm_silence_path_mismatch_check_flag \$HOME/.rvmrc > /dev/null 2>&1; then echo 'rvm_silence_path_mismatch_check_flag=1' >> \$HOME/.rvmrc; fi\nsource ${RVM_SRC_PATH} > /dev/null 2>&1"

if [ ! -z "${ADDITIONAL_VERSIONS}" ]; then
    OLDIFS=$IFS
    IFS=","
        read -a additional_versions <<< "$ADDITIONAL_VERSIONS"
        for version in "${additional_versions[@]}"; do
            find_version_from_git_tags version $RUBY_URL "tags/v" "_"
            [ -f "${RVM_SRC_PATH}" ] && source "${RVM_SRC_PATH}"
            rvm install ruby ${version}
        done
    IFS=$OLDIFS
fi

if [ "${SKIP_RBENV_RBUILD}" != "true" ]; then
    if [[ ! -d "/usr/local/share/rbenv" ]]; then
        git clone --depth=1 \
            -c core.eol=lf \
            -c core.autocrlf=false \
            -c fsck.zeroPaddedFilemode=ignore \
            -c fetch.fsck.zeroPaddedFilemode=ignore \
            -c receive.fsck.zeroPaddedFilemode=ignore \
            https://github.com/rbenv/rbenv.git /usr/local/share/rbenv
    fi

    if [[ ! -d "/usr/local/share/ruby-build" ]]; then
        git clone --depth=1 \
            -c core.eol=lf \
            -c core.autocrlf=false \
            -c fsck.zeroPaddedFilemode=ignore \
            -c fetch.fsck.zeroPaddedFilemode=ignore \
            -c receive.fsck.zeroPaddedFilemode=ignore \
            https://github.com/rbenv/ruby-build.git /usr/local/share/ruby-build
        mkdir -p /root/.rbenv/plugins
        ln -s /usr/local/share/ruby-build /root/.rbenv/plugins/ruby-build
    fi

    if [ "${USERNAME}" != "root" ]; then
        MAPPED_HOME="/home/${USERNAME}"
        [ "${USERNAME}" = "root" ] && MAPPED_HOME="/root"
        # Alpine path variations lookup fallback
        [ ! -d "${MAPPED_HOME}" ] && [ -d "/root" ] && [ "${USERNAME}" = "root" ] && MAPPED_HOME="/root"

        mkdir -p ${MAPPED_HOME}/.rbenv/plugins
        if [[ ! -d "${MAPPED_HOME}/.rbenv/plugins/ruby-build" ]]; then
            ln -s /usr/local/share/ruby-build ${MAPPED_HOME}/.rbenv/plugins/ruby-build
        fi

        if [ -d /usr/local/rvm ]; then
            if [ ! -f /usr/local/rvm/gems/default/bin/ruby ]; then
                mkdir -p /usr/local/rvm/gems/default/bin
                ln -s /usr/local/rvm/rubies/default/bin/ruby /usr/local/rvm/gems/default/bin 2>/dev/null || true
            fi
            chown -R "${USERNAME}:rvm" "/usr/local/rvm/" 2>/dev/null || true
            chmod -R g+r+w "/usr/local/rvm/" 2>/dev/null || true
        fi
        chown -R "${USERNAME}" "${MAPPED_HOME}/.rbenv/" 2>/dev/null || true
    fi
fi

if [ -d /usr/local/rvm/ ]; then
    chown -R "${USERNAME}:rvm" "/usr/local/rvm/" 2>/dev/null || true
    chmod -R g+r+w "/usr/local/rvm/" 2>/dev/null || true
    find "/usr/local/rvm/" -type d | xargs -n 1 chmod g+s 2>/dev/null || true
    rvm cleanup all || true
fi

if [ ! -z "${ROOT_GEM}" ] && type "${ROOT_GEM}" > /dev/null 2>&1; then
    ${ROOT_GEM} cleanup 2>/dev/null || true
fi

# Multi-distro generic cleanup post installations
case "${OS_ID}" in
    debian|ubuntu) rm -rf /var/lib/apt/lists/* ;;
    fedora|rhel|amzn|centos) type dnf >/dev/null 2>&1 && dnf clean all || yum clean all ;;
    alpine) rm -rf /var/cache/apk/* ;;
esac

echo "Done!"
