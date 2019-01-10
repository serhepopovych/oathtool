#!/bin/sh -e

# Requires: lockfile-progs(1), gpg(1), oathtool(1), kill(1), rm(1), mv(1), mktemp(1)

config_oathtool=~/.config/oathtool

use_gpg=no

### DO NOT EDIT BELOW THIS LINE ###

# Usage: error <fmt> ...
error()
{
	local rc=$?

	local func="${FUNCNAME:-error}"

	local fmt="${1:?missing 1st arg to ${func}() (<fmt>)}"
	shift

	[ $V -le 0 ] || printf >&2 -- "${fmt}" "$@"

	return $rc
}

# Usage: abort <fmt> ...
abort()
{
	V=1 error "$@"
	local rc=$?
	trap - EXIT
	exit $rc
}

# Usage: lock_oathtool <lock>
lock_oathtool()
{
	local func="${FUNCNAME:-lock_oathtool}"

	local lock="${1:?missing 1st arg to ${func}() (<lock>)}"

	# Assert if used concurrently
	[ -z "${__lock_oathtool_lockfile_touch_pid}" ] || \
		abort 'bug: %s is not reentrant\n' "$func"

	lockfile-create --use-pid --retry 3 --lock-name "$lock"
	lockfile-touch --lock-name "$lock" &
	# Record lockfile-touch(1) pid
	__lock_oathtool_lockfile_touch_pid="$!"

	# Assert if no lockfile-touch(1) pid
	[ -n "${__lock_oathtool_lockfile_touch_pid}" ] || \
		abort 'bug: %s no lockfile-touch(1) pid\n'
}

# Usage: unlock_oathtool
unlock_oathtool()
{
	local func="${FUNCNAME:-unlock_oathtool}"

	local lock="${1:?missing 1st arg to ${func}() (<lock>)}"

	# Assert if called before lock
	[ -n "${__lock_oathtool_lockfile_touch_pid}" ] || \
		abort 'bug: %s no lockfile-touch(1) pid\n' "$func"

	kill "${__lock_oathtool_lockfile_touch_pid}" ||:
	lockfile-remove --lock-name "$lock" ||:
	# Cleanup lockfile-touch(1) pid
	__lock_oathtool_lockfile_touch_pid=''
}

# Usage: is_yes <value>
is_yes()
{
	case "$1" in
		[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|[Yy]|1)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

# Usage: is_no <value>
is_no()
{
	case "$1" in
		[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|[Nn]|0)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

################################################################################

# Program (script) name
prog_name="${0##*/}"

# Verbosity: report errors by default
V=1

# Adjust umask to unset group and others write bit
umask $(printf -- '%04o\n' $(($(umask) | 0022))) ||:

# Check usage
[ $# -le 1 ] || abort 'usage: %s [profile]\n' "$prog_name"

# Find profile or use default
profile="${1:-default}"

config_oathtool_profile="$config_oathtool/$profile"
if [ ! -d "$config_oathtool_profile" ]; then
	abort '%s: no profile "%s" dir exists\n' \
		"$prog_name" "$config_oathtool_profile"
fi

# GPG encrypt/decrypt command line
if is_yes "$use_gpg"; then
	gpg_cmdline="${gpg_cmdline:-gpg} --debug-level=0 --no-verbose --quiet --batch"
	gpg_decrypt="$gpg_cmdline --decrypt"
	gpg_encrypt="$gpg_cmdline --encrypt --default-recipient-self"
else
	gpg_cmdline="${gpg_cmdline:-cat}"
	gpg_decrypt="$gpg_cmdline"
	gpg_encrypt="$gpg_cmdline"
	use_gpg=''
fi

# Counter and Key used as parameters to oathtool(1) for HOTP
config_oathtool_counter="${config_oathtool_profile}/counter${use_gpg:+.gpg}"
config_oathtool_key="${config_oathtool_profile}/key${use_gpg:+.gpg}"

config_oathtool_counter_templ="${config_oathtool_counter}.XXXXXXXX"

config_oathtool_lock="${config_oathtool_profile}/.lock"

# Cleanup at exit
exit_handler()
{
	rm -f "$config_oathtool_counter_tmp" ||:
	# Unlock profile
	unlock_oathtool "$config_oathtool_lock"
}
trap exit_handler EXIT

# Try lock profile
lock_oathtool "$config_oathtool_lock" || \
	abort '%s: cannot access profile \"%s\" exclusively\n' \
		"$prog_name" "$profile"

# Get the counter and key for HOTP authentication
counter="$($gpg_decrypt "$config_oathtool_counter")"
key="$($gpg_decrypt "$config_oathtool_key")"

# This seems only place where we expose @counter and @key to others.
# One could use ps(1) to see command line options passed to oathtool(1).
echo -n "$(oathtool --hotp --counter "$counter" "$key")"

# Update the counter in a safe way.
config_oathtool_counter_tmp="$(mktemp -u "$config_oathtool_counter_templ")"
echo $((counter + 1)) | \
	$gpg_encrypt >"$config_oathtool_counter_tmp"
mv -f "$config_oathtool_counter_tmp" "$config_oathtool_counter"

exit 0
