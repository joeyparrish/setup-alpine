#!/bin/sh
# vim: set ts=4 sw=4:
set -e

root_arg=''
case "$1" in
	-r | --root) root_arg='-0'; shift;;
esac

rootfs=$(cd "$(dirname "$0")"/.. && pwd)
oldpwd=$(pwd)
export | sudo tee "$rootfs"/tmp/.env.sh >/dev/null

exec "$rootfs"/abin/proot-configured $root_arg -w $oldpwd \
	/bin/sh -eo pipefail "$@"
