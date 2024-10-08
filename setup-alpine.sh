#!/usr/bin/env bash
# vim: set ts=4 sw=4:
#
# Required environment variables:
# - INPUT_APK_TOOLS_URL
# - INPUT_ARCH
# - INPUT_BRANCH
# - INPUT_EXTRA_KEYS
# - INPUT_EXTRA_REPOSITORIES
# - INPUT_MIRROR_URL
# - INPUT_PACKAGES
# - INPUT_SHELL_NAME
# - INPUT_VOLUMES
#
set -euo pipefail

readonly SCRIPT_PATH=$(readlink -f "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

readonly ALPINE_BASE_PKGS='alpine-baselayout apk-tools bash busybox busybox-suid musl-utils sudo'
readonly RUNNER_HOME="/home/$SUDO_USER"
readonly RUNNER_WORKDIR="$(dirname "$RUNNER_WORKSPACE")"
readonly ROOTFS_BASE_DIR="$RUNNER_HOME/rootfs"


err_handler() {
	local lno=$1
	set +e

	# Print error line with 4 lines before/after.
	awk -v LINENO=$lno -v RED="\033[1;31m" -v RESET="\033[0m" '
		BEGIN { print "\n" RED "Error occurred at line " LINENO ":" RESET }
		NR > LINENO - 4 && NR < LINENO + 4 {
			pad = length(LINENO + 4); err = NR == LINENO
			printf "%s %" pad "d | %s%s\n", (err ? RED ">" : " "), NR, $0, (err ? RESET : "")
		}' "$SCRIPT_PATH"
	line=$(awk -v LINENO=$lno 'NR == LINENO { print $0 }' "$SCRIPT_PATH")

	die "${_current_group:-"Error"}" \
	    "Error occurred at line $lno: $line (see the job log for more information)"
}
trap 'err_handler $LINENO' ERR


#=======================  F u n c t i o n s  =======================#

die() {
	local title=$1
	local msg=$2

	printf '::error title=setup-alpine: %s::%s\n' "$title" "$msg"
	exit 1
}

info() {
	printf '▷ %s\n' "$@"
}

# Creates an expandable group in the log with title $1.
group() {
	[ "${_current_group:-}" ] && endgroup

	printf '::group::%s\n' "$*"
	_current_group="$*"
}

# Closes the expandable group in the log.
endgroup() {
	echo '::endgroup::'
}

# Converts Alpine architecture name to the corresponding QEMU name.
qemu_arch() {
	case "$1" in
		x86 | i[3456]86) echo 'i386';;
		armhf | armv[4-9]) echo 'arm';;
		*) echo "$1";;
	esac
}

# Downloads a file from URL $1 to path $2 and verify its integrity.
# URL must end with '#!sha256!' followed by a SHA-256 checksum of the file.
download_file() {
	local url=${1%\#*}  # strips '#' and everything after
	local sha256=${1##*\#\!sha256\!}  # strips '#!sha256!' and everything before
	local filepath=$2

	[ -f "$filepath" ] \
		&& sha256_check "$filepath" "$sha256" >/dev/null 2>&1 \
		&& return 0

	mkdir -p "$(dirname "$filepath")" \
		&& curl --connect-timeout 10 -fsSL -o "$filepath" "$url" \
		&& sha256_check "$filepath" "$sha256"
}

# Checks SHA-256 checksum $2 of the given file $1.
sha256_check() {
	local filepath=$1
	local sha256=$2

	(cd "$(dirname "$filepath")" \
		&& echo "$sha256  ${filepath##*/}" | sha256sum -c)
}

# Unpacks content of an APK package.
unpack_apk() {
	tar -xz "$@" |& sed '/tar: Ignoring unknown extended header/d'
}


#============================  M a i n  ============================#

# Both validate input architecture and set expected SHA256 for apk-tools for
# that architecture.
case "$INPUT_ARCH" in
    x86_64)  DEFAULT_TOOLS_SHA256=1c65115a425d049590bec7c729c7fd88357fbb090a6fc8c31d834d7b0bc7d6f2 ;;
    x86)     DEFAULT_TOOLS_SHA256=cb8160be3f57b2e7b071b63cb9acb4f06c1e2521b69db178b63e2130acd5504a ;;
    aarch64) DEFAULT_TOOLS_SHA256=d49a63b8b6780fc1342d3e7e14862aa006c30bafbf74beec8e1dfe99e6f89471 ;;
    armhf)   DEFAULT_TOOLS_SHA256=878a000702c1faeb9fdab594dc071b5a1c40647646c96b07aa35dcd43247567a ;;
    armv7)   DEFAULT_TOOLS_SHA256=9d68d7cb0bbb46e02b7616e030eba7be1697d84cabf61e0a186a6b7522ffb09e ;;
    ppc64le) DEFAULT_TOOLS_SHA256=e7d28c677b0a90f7b89bf85d848c52c1a91d06fd7e0661a55b457abaac4eb0b3 ;;
    riscv64) DEFAULT_TOOLS_SHA256=b32132ebcb4fd0b01cd270689328e11d094bb9a69c2991ed40f359f857cce6a3 ;;
    s390x)   DEFAULT_TOOLS_SHA256=c1ca31c424ce8c62a22cc8cc597770f64ca1106709e65ae447a81f6175081fa5 ;;
	*) die 'Invalid input parameter: arch' \
	       "Expected one of: x86_64, x86, aarch64, armhf, armv7, ppc64le, riscv64, s390x, but got: $INPUT_ARCH."
esac

if [[ -z "$INPUT_APK_TOOLS_URL" ]]; then
    # Default the apk tools URL based on the architecture and the SHA256 for
    # that architecture's binary.
    INPUT_APK_TOOLS_URL="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.0/$INPUT_ARCH/apk.static#!sha256!$DEFAULT_TOOLS_SHA256"
fi

case "$INPUT_APK_TOOLS_URL" in
	https://*\#\!sha256\!* | http://*\#\!sha256\!*) ;;  # valid
	*) die 'Invalid input parameter: apk-tools-url' \
	       "The value must start with https:// or http:// and end with '#!sha256!' followed by a SHA-256 hash of the file to be downloaded, but got: $INPUT_APK_TOOLS_URL"
esac

case "$INPUT_BRANCH" in
	v[0-9].[0-9]* | edge | latest-stable) ;;  # valid
	*) die 'Invalid input parameter: branch' \
	       "Expected 'v[0-9].[0-9]+' (e.g. v3.15), edge, or latest-stable, but got: $INPUT_BRANCH."
esac

for path in $INPUT_EXTRA_KEYS; do
	if ! [ -r "$GITHUB_WORKSPACE/$path" ]; then
		die 'Invalid input parameter: extra-keys' \
		    "File does not exist in workspace or is not readable: $path."
	fi
done

if ! expr "$INPUT_SHELL_NAME" : [a-zA-Z][a-zA-Z0-9_.~+@%-]*$ >/dev/null; then
	die 'Invalid input parameter: shell-name' \
	    "Expected value matching regex ^[a-zA-Z][a-zA-Z0-9_.~+@%-]*$, but got: $INPUT_SHELL_NAME."
fi


#-----------------------------------------------------------------------
group 'Prepare rootfs directory'

rootfs_dir="$ROOTFS_BASE_DIR/alpine-${INPUT_BRANCH%-stable}-$INPUT_ARCH"
if [ -e "$rootfs_dir" ]; then
	mkdir -p "$ROOTFS_BASE_DIR"
	rootfs_dir=$(mktemp -d "$rootfs_dir-XXXXXX")
	chmod 755 "$rootfs_dir"
else
	mkdir -p "$rootfs_dir"
fi
info "Alpine will be installed into: $rootfs_dir"

cd "$RUNNER_TEMP"


#-----------------------------------------------------------------------
group 'Download static apk-tools'

APK="$RUNNER_TEMP/apk"

info "Downloading ${INPUT_APK_TOOLS_URL%\#*}"
download_file "$INPUT_APK_TOOLS_URL" "$APK"
chmod +x "$APK"


#-----------------------------------------------------------------------
if [[ "$INPUT_ARCH" != $(uname -m) ]]; then
	qemu_arch=$(qemu_arch "$INPUT_ARCH")
	qemu_cmd="qemu-$qemu_arch"

	group "Install $qemu_cmd emulator"

	if update-binfmts --display $qemu_cmd >/dev/null 2>&1; then
		info "$qemu_cmd is already installed on the host system"

	else
		# apt-get is terribly slow - installing qemu-user-static via apt-get
		# takes anywhere from ten seconds to tens of seconds. This method takes
		# less than a second.
		info "Fetching $qemu_cmd from the latest-stable Alpine repository"
		$APK fetch \
			--keys-dir "$SCRIPT_DIR"/keys \
			--repository "$INPUT_MIRROR_URL/latest-stable/community" \
			--no-progress \
			--no-cache \
			$qemu_cmd

		info "Unpacking $qemu_cmd and installing on the host system"
		unpack_apk -f ./$qemu_cmd-*.apk usr/bin/$qemu_cmd
		mv usr/bin/$qemu_cmd /usr/local/bin/
		rm ./$qemu_cmd-*.apk

		info "Registering binfmt for $qemu_arch"
		update-binfmts --import "$SCRIPT_DIR"/binfmts/$qemu_cmd
	fi
fi


#-----------------------------------------------------------------------
group "Initialize Alpine Linux $INPUT_BRANCH ($INPUT_ARCH)"

cd "$rootfs_dir"

info 'Creating /etc/apk/repositories:'
mkdir -p etc/apk
printf '%s\n' \
	"$INPUT_MIRROR_URL/$INPUT_BRANCH/main" \
	"$INPUT_MIRROR_URL/$INPUT_BRANCH/community" \
	$INPUT_EXTRA_REPOSITORIES \
	| tee etc/apk/repositories

cp -r "$SCRIPT_DIR"/keys etc/apk/

for path in $INPUT_EXTRA_KEYS; do
	cp "$GITHUB_WORKSPACE/$path" etc/apk/keys/
done

cat /etc/resolv.conf > etc/resolv.conf

release_pkg='alpine-release'
if [ "${INPUT_BRANCH#v}" != "$INPUT_BRANCH" ] && [ "$($APK version -t "$INPUT_BRANCH" 'v3.17')" = '<' ]; then
	release_pkg=''
fi

info "Installing base packages into $(pwd)"
$APK add \
	--root . \
	--initdb \
	--no-progress \
	--update-cache \
	--arch "$INPUT_ARCH" \
	$ALPINE_BASE_PKGS $release_pkg

if ! [ "$release_pkg" ]; then
	# This package contains /etc/os-release, /etc/alpine-release and /etc/issue,
	# but we don't wanna install all its dependencies (e.g. openrc).
	info 'Fetching and unpacking /etc from alpine-base'
	$APK fetch \
		--root . \
		--no-progress \
		--stdout \
		alpine-base \
		| unpack_apk etc
fi


#-----------------------------------------------------------------------
group 'Set chroot filesystem binds'

mkdir -p proc

# These are bind arguments to proot.
> .binds.sh
echo "PROOT_BIND_ARGS=(" >> .binds.sh

echo "  -b /proc" >> .binds.sh
echo "  -b /dev" >> .binds.sh
echo "  -b /sys" >> .binds.sh
echo "  -b \"$RUNNER_WORKDIR\"" >> .binds.sh

# Some systems (Ubuntu?) symlinks /dev/shm to /run/shm.
if [ -L /dev/shm ] && [ -d /run/shm ]; then
	echo "  -b /run/shm" >> .binds.sh
fi

for vol in $INPUT_VOLUMES; do
	[ "$vol" ] || continue
	src=${vol%%:*}
	dst=${vol#*:}

	echo "  -b \"$src:$dst\"" >> .binds.sh
done

echo ")" >> .binds.sh


#-----------------------------------------------------------------------
group 'Install proot'

# Installs PRoot from source, for compatibility with unprivileged, Docker-based
# runners.
(
	set -e
	cd "$RUNNER_TEMP"
	git clone https://github.com/proot-me/PRoot -b v5.4.0
	sudo apt -y install libtalloc-dev libarchive-dev
	make -C PRoot/src loader.elf proot
)
install -Dv -m755 "$RUNNER_TEMP"/PRoot/src/proot abin/proot


#-----------------------------------------------------------------------
group 'Copy action scripts'

install -Dv -m755 "$SCRIPT_DIR"/proot-configured abin/
install -Dv -m755 "$SCRIPT_DIR"/alpine.sh abin/"$INPUT_SHELL_NAME"
install -Dv -m755 "$SCRIPT_DIR"/destroy.sh .


#-----------------------------------------------------------------------
if [[ "$INPUT_PACKAGES" != "" ]]; then
	group 'Install packages'

	pkgs=$(printf '%s ' $INPUT_PACKAGES)
	cat > .setup.sh <<-SHELL
		echo '▷ Installing $pkgs'
		apk add --update-cache $pkgs
	SHELL
	abin/"$INPUT_SHELL_NAME" --root /.setup.sh
fi


#-----------------------------------------------------------------------
# Set up the user, but not if the runner is running as root.
if [[ ${SUDO_UID:-1000} != 0 ]]; then
	group "Set up user $SUDO_USER"

	cat > .setup.sh <<-SHELL
		echo '▷ Creating user $SUDO_USER with uid ${SUDO_UID:-1000}'
		adduser -u '${SUDO_UID:-1000}' -G users -s /bin/sh -D '$SUDO_USER'

		if [ -d /etc/sudoers.d ]; then
			echo '▷ Adding sudo rule:'
			echo '$SUDO_USER ALL=(ALL) NOPASSWD: ALL' | tee /etc/sudoers.d/root
		fi
		if [ -d /etc/doas.d ]; then
			echo '▷ Adding doas rule:'
			echo 'permit nopass keepenv $SUDO_USER' | tee /etc/doas.d/root.conf
		fi
	SHELL
	abin/"$INPUT_SHELL_NAME" --root /.setup.sh

	rm .setup.sh
	endgroup
fi
#-----------------------------------------------------------------------

echo "root-path=$rootfs_dir" >> $GITHUB_OUTPUT
echo "$rootfs_dir/abin" >> $GITHUB_PATH
