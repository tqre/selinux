#!/bin/sh
# Build and install every package which is not already installed

cd "$(dirname -- "$0")" || exit $?

if [ "$(id -u)" = 0 ]
then
    echo >&2 "makepkg does not support building as root. Please run with an other user (e.g. nobody)"
    exit 1
fi

# Gather the package extension from /etc/makepkg.conf
PKGEXT="$(bash -c 'source /etc/makepkg.conf ; echo "$PKGEXT"')"
if [ -z "$PKGEXT" ]
then
    # Use zstd compression by default
    PKGEXT='.pkg.tar.zst'
fi

# Verify whether a package needs to be installed
needs_install() {
    local CURRENT_VERSION PKGREL PKGVER

    if "$UPGRADE_GIT_PACKAGE"
    then
        # Always ugrade -git packages
        if [ "${1%-git}" != "$1" ]
        then
            return 0
        fi
    fi

    CURRENT_VERSION="$(LANG=C pacman -Q "${1##*/}" 2> /dev/null | awk '{print $2}')"
    if [ -z "$CURRENT_VERSION" ]
    then
        # The package was not installed
        return 0
    fi
    PKGVER="$(sed -n 's/^\s*pkgver = \(\S\+\)/\1/p' "$1/.SRCINFO" | head -n1)"
    PKGREL="$(sed -n 's/^\s*pkgrel = \(\S\+\)/\1/p' "$1/.SRCINFO" | head -n1)"
    if [ "$CURRENT_VERSION" = "$PKGVER-$PKGREL" ]
    then
        # The package is already installed to the same version as in the tree
        return 1
    fi

    # If the package is a git package, do not install it if the git tree
    # contains an older package
    if [ "${1%-git}" != "$1" ] && [ "$(vercmp "$CURRENT_VERSION" "$PKGVER-$PKGREL")" -ge 0 ]
    then
        return 1
    fi
    return 0
}

# Build a package
# Arguments:
# - package name
# - makepkg environment tweaks
build() {
    rm -rf "./$1/src" "./$1/pkg"
    rm -f "./$1/"*.pkg.tar.xz "./$1/"*.pkg.tar.xz.sig
    rm -f "./$1/"*.pkg.tar.zst "./$1/"*.pkg.tar.zst.sig
    # When building in a container, systemd's tests fail because of default Seccomp filters
    if [ "$1" = 'systemd-selinux' ] && grep '^Seccomp:\s*2$' /proc/self/status > /dev/null
    then
        set -- "$@" --nocheck
    fi
    (cd "./$1" && shift && makepkg -s -C --noconfirm "$@") || exit $?
}

# Run an install command for a package which may conflict with a base package
# and answer yes to ":: $PKG-selinux and $PKG are in conflict. Remove $PKG? [y/N]"
# Use undocumented pacman's --ask=4 option to do this while in --noconfirm
#
# 4 is ALPM_QUESTION_CONFLICT_PKG in https://git.archlinux.org/pacman.git/tree/lib/libalpm/alpm.h?h=v5.0.2#n602
# and --ask=... inverts the default answer of the interactive question according
# to https://git.archlinux.org/pacman.git/tree/src/pacman/callback.c?h=v5.0.2#n490
run_conflictual_install() {
    local SUBCOMMAND

    if [ "$1" = "pacman" ] ; then
        shift
        set pacman '--noconfirm' '--ask=4' "$@"
    elif [ "$1" = "sh" ] && [ "$2" = "-c" ] ; then
        # run "sh -c 'subcommand with pacman'
        SUBCOMMAND="$3"
        shift 3
        set sh '-c' "$(echo "$SUBCOMMAND" | sed 's/pacman /pacman --noconfirm --ask=4 /g')" "$@"
    else
        echo >&2 "Internal error: run_conflictual_install without pacman but '$*'"
        exit 1
    fi

    # Invoke pacman with sudo
    if ! sudo LANG=C "$@"
    then
        echo >&2 "Error: the following command failed, sudo LANG=C $*"
        exit 1
    fi
}

# Build and install a package
build_and_install() {
    needs_install "$1" || return 0
    build "$@"
    run_conflictual_install pacman -U "./$1/"*"$PKGEXT"
}

# Install libreport package from the AUR, if it is not already installed
install_libreport() {
    local MAKEPKGDIR
    if pacman -Qi libreport > /dev/null 2>&1
    then
        return 0
    fi
    MAKEPKGDIR="$(mktemp -d -p "${TMPDIR:-/tmp}" makepkg-libreport-XXXXXX)"
    git -C "$MAKEPKGDIR" clone https://aur.archlinux.org/satyr.git || exit $?
    (cd "$MAKEPKGDIR/satyr" && makepkg -si --noconfirm --asdeps) || exit $?
    git -C "$MAKEPKGDIR" clone https://aur.archlinux.org/libreport.git || exit $?
    (cd "$MAKEPKGDIR/libreport" && makepkg -si --noconfirm --asdeps) || exit $?
    rm -rf "$MAKEPKGDIR"
}

# Parse options
UPGRADE_GIT_PACKAGE=false
while getopts ":gh" OPT
do
    case "$OPT" in
        h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Build and install/upgrade every package which is not already installed"
            echo ""
            echo "Optional arguments:"
            echo "  -h      display this help and exit"
            echo "  -g      always upgrade -git packages"
            echo "          (default: upgrade only when pkgver-pkgrel changes)"
            exit
            ;;
        g)
            UPGRADE_GIT_PACKAGE=true
            ;;
    esac
done

# Install the packages which are needed for the script if they are not already installed
# base and base-devel groups are supposed to be installed
for PKG in expect git
do
    if ! pacman -Qi "$PKG" > /dev/null 2>&1
    then
        sudo pacman --noconfirm -S "$PKG" || exit $?
    fi
done

build_nodeps() {
    rm -rf "./$1/src" "./$1/pkg"
    rm -f "./$1/"*.pkg.tar.zst "./$1/"*.pkg.tar.zst.sig
    (cd "./$1" && shift && makepkg -d -C --noconfirm "$@") || exit $?
}

build_nodeps base-selinux
build_nodeps base-devel-selinux
