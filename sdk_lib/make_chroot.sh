#!/bin/bash

# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script sets up a Gentoo chroot environment. The script is passed the
# path to an empty folder, which will be populated with a Gentoo stage3 and
# setup for development. Once created, the password is set to PASSWORD (below).
# One can enter the chrooted environment for work by running enter_chroot.sh.

SCRIPT_ROOT=$(readlink -f $(dirname "$0")/..)
. "${SCRIPT_ROOT}/common.sh" || exit 1

ENTER_CHROOT=$(readlink -f $(dirname "$0")/enter_chroot.sh)

enable_strict_sudo

# Check if the host machine architecture is supported.
ARCHITECTURE="$(uname -m)"
if [[ "$ARCHITECTURE" != "x86_64" ]]; then
  echo "$SCRIPT_NAME: $ARCHITECTURE is not supported as a host machine architecture."
  exit 1
fi

# Script must be run outside the chroot.
assert_outside_chroot

# Define command line flags.
# See http://code.google.com/p/shflags/wiki/Documentation10x

DEFINE_string chroot "$DEFAULT_CHROOT_DIR" \
  "Destination dir for the chroot environment."
DEFINE_boolean usepkg $FLAGS_TRUE "Use binary packages to bootstrap."
DEFINE_boolean delete $FLAGS_FALSE "Delete an existing chroot."
DEFINE_boolean replace $FLAGS_FALSE "Overwrite existing chroot, if any."
DEFINE_integer jobs -1 "How many packages to build in parallel at maximum."
DEFINE_boolean fast ${DEFAULT_FAST} "Call many emerges in parallel"
DEFINE_string stage3_date "2010.03.09" \
  "Use the stage3 with the given date."
DEFINE_string stage3_path "" \
  "Use the stage3 located on this path."

# Parse command line flags.
FLAGS_HELP="usage: $SCRIPT_NAME [flags]"
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
check_flags_only_and_allow_null_arg "$@" && set --

CROS_LOG_PREFIX=cros_sdk

assert_not_root_user
# Set the right umask for chroot creation.
umask 022

# Only now can we die on error.  shflags functions leak non-zero error codes,
# so will die prematurely if 'set -e' is specified before now.
# TODO: replace shflags with something less error-prone, or contribute a fix.
set -e

FULLNAME="ChromeOS Developer"
DEFGROUPS="eng,adm,cdrom,floppy,audio,video,portage"
PASSWORD=chronos
CRYPTED_PASSWD=$(perl -e 'print crypt($ARGV[0], "foo")', $PASSWORD)

USEPKG=""
if [[ $FLAGS_usepkg -eq $FLAGS_TRUE ]]; then
  # Use binary packages. Include all build-time dependencies,
  # so as to avoid unnecessary differences between source
  # and binary builds.
  USEPKG="--getbinpkg --usepkg --with-bdeps y"
fi

# Support faster build if necessary.
EMERGE_CMD="emerge"
if [ "$FLAGS_fast" -eq "${FLAGS_TRUE}" ]; then
  CHROOT_CHROMITE_DIR="/home/${USER}/trunk/chromite"
  EMERGE_CMD="${CHROOT_CHROMITE_DIR}/bin/parallel_emerge"
fi

ENTER_CHROOT_ARGS=(
  CROS_WORKON_SRCROOT="$CHROOT_TRUNK"
  PORTAGE_USERNAME="$USER"
  IGNORE_PREFLIGHT_BINHOST="$IGNORE_PREFLIGHT_BINHOST"
)

# Invoke enter_chroot.  This can only be used after sudo has been installed.
function enter_chroot {
  "$ENTER_CHROOT" --chroot "$FLAGS_chroot" -- "${ENTER_CHROOT_ARGS[@]}" "$@"
}

# Invoke enter_chroot running the command as root, and w/out sudo.
# This should be used prior to sudo being merged.
function early_enter_chroot() {
  "$ENTER_CHROOT" --chroot "$FLAGS_chroot" --early_make_chroot \
    -- "${ENTER_CHROOT_ARGS[@]}" "$@"
}

# Run a command within the chroot.  The main usage of this is to avoid
# the overhead of enter_chroot, and do not need access to the source tree,
# don't need the actual chroot profile env, and can run the command as root.
sudo_chroot() {
  sudo chroot "${FLAGS_chroot}" "$@"
}

function cleanup {
  # Clean up mounts
  safe_umount_tree "${FLAGS_chroot}"
}

function delete_existing {
  # Delete old chroot dir.
  if [[ ! -e "$FLAGS_chroot" ]]; then
    return
  fi
  info "Cleaning up old mount points..."
  cleanup
  info "Deleting $FLAGS_chroot..."
  sudo rm -rf "$FLAGS_chroot"
  info "Done."
}

function init_users () {
   info "Set timezone..."
   # date +%Z has trouble with daylight time, so use host's info.
   sudo rm -f "${FLAGS_chroot}/etc/localtime"
   if [ -f /etc/localtime ] ; then
     sudo cp /etc/localtime "${FLAGS_chroot}/etc"
   else
     sudo ln -sf /usr/share/zoneinfo/PST8PDT "${FLAGS_chroot}/etc/localtime"
   fi
   info "Adding user/group..."
   # Add ourselves as a user inside the chroot.
   sudo_chroot groupadd -g 5000 eng
   # We need the UID to match the host user's. This can conflict with
   # a particular chroot UID. At the same time, the added user has to
   # be a primary user for the given UID for sudo to work, which is
   # determined by the order in /etc/passwd. Let's put ourselves on top
   # of the file.
   sudo_chroot useradd -o -G ${DEFGROUPS} -g eng -u `id -u` -s \
     /bin/bash -m -c "${FULLNAME}" -p ${CRYPTED_PASSWD} ${USER}
   # Because passwd generally isn't sorted and the entry ended up at the
   # bottom, it is safe to just take it and move it to top instead.
   sudo sed -e '1{h;d};$!{H;d};$G' -i "${FLAGS_chroot}/etc/passwd"
}

function init_setup () {
   info "Running init_setup()..."
   sudo mkdir -p -m 755 "${FLAGS_chroot}/usr" \
     "${FLAGS_chroot}/usr/local/portage" \
     "${FLAGS_chroot}"/"${CROSSDEV_OVERLAY}"
   sudo ln -sf "${CHROOT_TRUNK}/src/third_party/portage" \
     "${FLAGS_chroot}/usr/portage"
   sudo ln -sf "${CHROOT_TRUNK}/src/third_party/chromiumos-overlay" \
     "${FLAGS_chroot}"/"${CHROOT_OVERLAY}"
   sudo ln -sf "${CHROOT_TRUNK}/src/third_party/portage-stable" \
     "${FLAGS_chroot}"/"${PORTAGE_STABLE_OVERLAY}"

   # Some operations need an mtab.
   sudo ln -s /proc/mounts "${FLAGS_chroot}/etc/mtab"

   # Set up sudoers.  Inside the chroot, the user can sudo without a password.
   # (Safe enough, since the only way into the chroot is to 'sudo chroot', so
   # the user's already typed in one sudo password...)
   # Make sure the sudoers.d subdir exists as older stage3 base images lack it.
   sudo mkdir -p "${FLAGS_chroot}/etc/sudoers.d"
   sudo_clobber "${FLAGS_chroot}/etc/sudoers.d/90_cros" <<EOF
Defaults env_keep += CROS_WORKON_SRCROOT
Defaults env_keep += CHROMEOS_OFFICIAL
Defaults env_keep += PORTAGE_USERNAME
Defaults env_keep += http_proxy
Defaults env_keep += ftp_proxy
Defaults env_keep += all_proxy
%adm ALL=(ALL) ALL
root ALL=(ALL) ALL
$USER ALL=NOPASSWD: ALL
EOF
   sudo find "${FLAGS_chroot}/etc/"sudoers* -type f -exec chmod 0440 {} +
   # Fix bad group for some.
   sudo chown -R root:root "${FLAGS_chroot}/etc/"sudoers*

   info "Setting up hosts/resolv..."
   # Copy config from outside chroot into chroot.
   sudo cp /etc/{hosts,resolv.conf} "$FLAGS_chroot/etc/"
   sudo chmod 0644 "$FLAGS_chroot"/etc/{hosts,resolv.conf}

   # Setup host make.conf. This includes any overlay that we may be using
   # and a pointer to pre-built packages.
   # TODO: This should really be part of a profile in the portage.
   info "Setting up /etc/make.*..."
   sudo mv "${FLAGS_chroot}"/etc/make.conf{,.orig}
   sudo ln -sf "${CHROOT_CONFIG}/make.conf.amd64-host" \
     "${FLAGS_chroot}/etc/make.conf"
   sudo mv "${FLAGS_chroot}"/etc/make.profile{,.orig}
   sudo ln -sf "${CHROOT_OVERLAY}/profiles/default/linux/amd64/10.0" \
     "${FLAGS_chroot}/etc/make.profile"

   # Create make.conf.user .
   sudo touch "${FLAGS_chroot}"/etc/make.conf.user
   sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.user

   # Create directories referred to by our conf files.
   sudo mkdir -p -m 775 "${FLAGS_chroot}/var/lib/portage/pkgs" \
     "${FLAGS_chroot}/var/cache/distfiles" \
     "${FLAGS_chroot}/var/cache/chromeos-chrome"

   # Run this from w/in the chroot so we use whatever uid/gid
   # these are defined as w/in the chroot.
   sudo_chroot chown "${USER}:portage" /var/cache/chromeos-chrome

   # These are created for compatibility while transitioning
   # make.conf and friends over to the new location.
   # TODO(ferringb): remove this 03/12 or so.
   sudo ln -s ../../cache/distfiles/host \
     "${FLAGS_chroot}/var/lib/portage/distfiles"
   sudo ln -s ../../cache/distfiles/target \
     "${FLAGS_chroot}/var/lib/portage/distfiles-target"

   if [[ $FLAGS_jobs -ne -1 ]]; then
     EMERGE_JOBS="--jobs=$FLAGS_jobs"
   fi

   # Add chromite/bin and depot_tools into the path globally; note that the
   # chromite wrapper itself might also be found in depot_tools.
   # We rely on 'env-update' getting called below.
   target="${FLAGS_chroot}/etc/env.d/99chromiumos"
   sudo_clobber "${target}" <<EOF
PATH=/home/$USER/trunk/chromite/bin:/home/$USER/depot_tools
CROS_WORKON_SRCROOT="${CHROOT_TRUNK}"
PORTAGE_USERNAME=$USER
EOF

   # TODO(zbehan): Configure stuff that is usually configured in postinst's,
   # but wasn't. Fix the postinst's. crosbug.com/18036
   info "Running post-inst configuration hacks"
   early_enter_chroot env-update
   if [ -f ${FLAGS_chroot}/usr/bin/build-docbook-catalog ]; then
     # For too ancient chroots that didn't have build-docbook-catalog, this
     # is not relevant, and will get installed during update.
     early_enter_chroot build-docbook-catalog
     # Configure basic stuff needed.
     early_enter_chroot env-update
   fi

   # This is basically a sanity check of our chroot.  If any of these
   # don't exist, then either bind mounts have failed, an invocation
   # from above is broke, or some assumption about the stage3 is no longer
   # true.
   early_enter_chroot ls -l /etc/make.{conf,profile} \
     /usr/local/portage/chromiumos/profiles/default/linux/amd64/10.0

   target="${FLAGS_chroot}/etc/profile.d"
   sudo mkdir -p "${target}"
   sudo_clobber "${target}/chromiumos-niceties.sh" << EOF
# Niceties for interactive logins. (cr) denotes this is a chroot, the
# __git_branch_ps1 prints current git branch in ./ . The $r behavior is to
# make sure we don't reset the previous $? value which later formats in
# $PS1 might rely on.
PS1='\$(r=\$?; __git_branch_ps1 "(%s) "; exit \$r)'"\${PS1}"
PS1="(cr) \${PS1}"
EOF

   # Select a small set of locales for the user if they haven't done so
   # already.  This makes glibc upgrades cheap by only generating a small
   # set of locales.  The ones listed here are basically for the buildbots
   # which always assume these are available.  This works in conjunction
   # with `cros_sdk --enter`.
   # http://crosbug.com/20378
   local localegen="$FLAGS_chroot/etc/locale.gen"
   if ! grep -q -v -e '^#' -e '^$' "${localegen}" ; then
     sudo_append "${localegen}" <<EOF
en_US ISO-8859-1
en_US.UTF-8 UTF-8
EOF
   fi

   # Add chromite as a local site-package.
   mkdir -p "${FLAGS_chroot}/home/$USER/.local/lib/python2.6/site-packages"
   ln -s ../../../../trunk/chromite \
     "${FLAGS_chroot}/home/$USER/.local/lib/python2.6/site-packages/"

   chmod a+x "$FLAGS_chroot/home/$USER/.bashrc"
   # Automatically change to scripts directory.
   echo 'cd ${CHROOT_CWD:-~/trunk/src/scripts}' \
       >> "$FLAGS_chroot/home/$USER/.bash_profile"

   # Enable bash completion for build scripts.
   echo ". ~/trunk/src/scripts/bash_completion" \
       >> "$FLAGS_chroot/home/$USER/.bashrc"

   # Warn if attempting to use source control commands inside the chroot.
   for NOUSE in svn gcl gclient
   do
     echo "alias $NOUSE='echo In the chroot, it is a bad idea to run $NOUSE'" \
       >> "$FLAGS_chroot/home/$USER/.bash_profile"
   done

   if [[ "$USER" = "chrome-bot" ]]; then
     # Copy ssh keys, so chroot'd chrome-bot can scp files from chrome-web.
     cp -r ~/.ssh "$FLAGS_chroot/home/$USER/"
   fi

   if [[ -f $HOME/.gitconfig ]]; then
     # Copy .gitconfig into chroot so repo and git can be used from inside.
     # This is required for repo to work since it validates the email address.
     echo "Copying ~/.gitconfig into chroot"
     cp $HOME/.gitconfig "$FLAGS_chroot/home/$USER/"
   fi
}

# Handle deleting an existing environment.
if [[ $FLAGS_delete  -eq $FLAGS_TRUE || \
  $FLAGS_replace -eq $FLAGS_TRUE ]]; then
  delete_existing
  [[ $FLAGS_delete -eq $FLAGS_TRUE ]] && exit 0
fi

CHROOT_TRUNK="${CHROOT_TRUNK_DIR}"
PORTAGE="${SRC_ROOT}/third_party/portage"
OVERLAY="${SRC_ROOT}/third_party/chromiumos-overlay"
CONFIG_DIR="${OVERLAY}/chromeos/config"
CHROOT_CONFIG="${CHROOT_TRUNK}/src/third_party/chromiumos-overlay/chromeos/config"
PORTAGE_STABLE_OVERLAY="/usr/local/portage/stable"
CROSSDEV_OVERLAY="/usr/local/portage/crossdev"
CHROOT_OVERLAY="/usr/local/portage/chromiumos"
CHROOT_STATE="${FLAGS_chroot}/etc/debian_chroot"

# Pass proxy variables into the environment.
for type in http ftp all; do
   value=$(env | grep ${type}_proxy || true)
   if [ -n "${value}" ]; then
      CHROOT_PASSTHRU+=("$value")
   fi
done

# Create the base Gentoo stage3 based on last version put in chroot.
STAGE3="${OVERLAY}/chromeos/stage3/stage3-amd64-${FLAGS_stage3_date}.tar.bz2"
if [ -f $CHROOT_STATE ] && \
  ! sudo egrep -q "^STAGE3=$STAGE3" $CHROOT_STATE >/dev/null 2>&1
then
  info "STAGE3 version has changed."
  delete_existing
fi

if [ -n "${FLAGS_stage3_path}" ]; then
  if [ ! -f "${FLAGS_stage3_path}" ]; then
    error "Invalid stage3!"
    exit 1;
  fi
  STAGE3="${FLAGS_stage3_path}"
fi

# Create the destination directory.
mkdir -p "$FLAGS_chroot"

echo
if [ -f $CHROOT_STATE ]
then
  info "STAGE3 already set up.  Skipping..."
else
  info "Unpacking STAGE3..."
  sudo tar -xp -I $(type -p pbzip2 || echo bzip2) \
    -C "${FLAGS_chroot}" -f "${STAGE3}"
  sudo rm -f "$FLAGS_chroot/etc/"make.{globals,conf.user}
fi

# Set up users, if needed, before mkdir/mounts below.
[ -f $CHROOT_STATE ] || init_users

echo
info "Setting up mounts..."
# Set up necessary mounts and make sure we clean them up on exit.
sudo mkdir -p "${FLAGS_chroot}/${CHROOT_TRUNK}" "${FLAGS_chroot}/run"
PREBUILT_SETUP="$FLAGS_chroot/etc/make.conf.prebuilt_setup"
if [[ -z "$IGNORE_PREFLIGHT_BINHOST" ]]; then
  echo 'PORTAGE_BINHOST="$FULL_BINHOST"'
fi | sudo_clobber "$PREBUILT_SETUP"

sudo chmod 0644 "$PREBUILT_SETUP"

# For bootstrapping from old wget, disable certificate checking. Once we've
# upgraded to new curl (below), certificate checking is re-enabled. See
# http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=409938
sudo_clobber "${FLAGS_chroot}/etc/make.conf.fetchcommand_setup" <<'EOF'
FETCHCOMMAND="/usr/bin/wget -t 5 -T 60 --no-check-certificate --passive-ftp -O \"\${DISTDIR}/\${FILE}\" \"\${URI}\""
RESUMECOMMAND="/usr/bin/wget -c -t 5 -T 60 --no-check-certificate --passive-ftp -O \"\${DISTDIR}/\${FILE}\" \"\${URI}\""
EOF

sudo_clobber "${FLAGS_chroot}/etc/make.conf.host_setup" <<EOF
# Created by make_chroot.
source make.conf.prebuilt_setup
source make.conf.fetchcommand_setup
MAKEOPTS="-j${NUM_JOBS}"
EOF

sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.host_setup \
  "${FLAGS_chroot}"/etc/make.conf.fetchcommand_setup

if ! [ -f "$CHROOT_STATE" ];then
  INITIALIZE_CHROOT=1
fi


if [ -z "${INITIALIZE_CHROOT}" ];then
  info "chroot already initialized.  Skipping..."
else
  # Run all the init stuff to setup the env.
  init_setup
fi

# Add file to indicate that it is a chroot.
# Add version of $STAGE3 for update checks.
sudo sh -c "echo STAGE3=$STAGE3 > $CHROOT_STATE"

info "Updating portage"
early_enter_chroot emerge -uNv portage

info "Updating toolchain"
early_enter_chroot emerge -uNv $USEPKG '>=sys-devel/gcc-4.4' sys-libs/glibc \
  sys-devel/binutils sys-kernel/linux-headers

# HACK: Select the latest toolchain. We're assuming that when this is
# ran, the chroot has no experimental versions of new toolchains, just
# one that is very old, and one that was just emerged.
GCC_ATOM="$(early_enter_chroot portageq best_version / sys-devel/gcc)"
early_enter_chroot emerge --unmerge "<${GCC_ATOM}"
CHOST="$(early_enter_chroot portageq envvar CHOST)"
LATEST="$(early_enter_chroot gcc-config -l | grep "${CHOST}" | tail -n1 | \
          cut -f3 -d' ')"
early_enter_chroot gcc-config "${LATEST}"

# dhcpcd is included in 'world' by the stage3 that we pull in for some reason.
# We have no need to install it in our host environment, so pull it out here.
info "Deselecting dhcpcd"
early_enter_chroot $EMERGE_CMD --deselect dhcpcd

info "Running emerge ccache curl sudo ..."
early_enter_chroot $EMERGE_CMD -uNv $USEPKG $EMERGE_JOS \
  ccache net-misc/curl sudo

# Curl is now installed, so we can depend on it now.
sudo_clobber "${FLAGS_chroot}/etc/make.conf.fetchcommand_setup" <<'EOF'
FETCHCOMMAND='curl -f -y 30 --retry 9 -L --output \${DISTDIR}/\${FILE} \${URI}'
RESUMECOMMAND='curl -f -y 30 -C - --retry 9 -L --output \${DISTDIR}/\${FILE} \${URI}'
EOF
sudo chmod 0644 "${FLAGS_chroot}"/etc/make.conf.fetchcommand_setup

if [ -n "${INITIALIZE_CHROOT}" ]; then
  # If we're creating a new chroot, we also want to set it to the latest
  # version.
  enter_chroot \
    "${CHROOT_TRUNK}/src/scripts/run_chroot_version_hooks" --force_latest
fi

# Update chroot.
UPDATE_ARGS=()
if [[ $FLAGS_usepkg -eq $FLAGS_TRUE ]]; then
  UPDATE_ARGS+=( --usepkg )
else
  UPDATE_ARGS+=( --nousepkg )
fi
if [[ ${FLAGS_fast} -eq ${FLAGS_TRUE} ]]; then
  UPDATE_ARGS+=( --fast )
else
  UPDATE_ARGS+=( --nofast )
fi
enter_chroot "${CHROOT_TRUNK}/src/scripts/update_chroot" "${UPDATE_ARGS[@]}"

CHROOT_EXAMPLE_OPT=""
if [[ "$FLAGS_chroot" != "$DEFAULT_CHROOT_DIR" ]]; then
  CHROOT_EXAMPLE_OPT="--chroot=$FLAGS_chroot"
fi

print_time_elapsed

cat <<EOF
${CROS_LOG_PREFIX:-cros_sdk}: All set up.  To enter the chroot, run:"
${CROS_LOG_PREFIX:-cros_sdk}: $ cros_sdk --enter $CHROOT_EXAMPLE_OPT"

CAUTION: Do *NOT* rm -rf the chroot directory; if there are stale bind
mounts you may end up deleting your source tree too.  To unmount and
delete the chroot cleanly, use:
$ cros_sdk --delete $CHROOT_EXAMPLE_OPT
EOF
