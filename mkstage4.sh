#!/usr/bin/env bash

# checks if run as root:
if [ "$(whoami)" != 'root' ]
then
	echo "$(basename "$0"): must be root."
	exit 1
fi

# get available compression types
declare -A COMPRESS_TYPES
COMPRESS_TYPES=(
	["bz2"]="bzip2 pbzip2 lbzip2"
	["gz"]="gzip pigz"
	["lrz"]="lrzip"
	["lz"]="lzip plzip"
	["lz4"]="lz4"
	["lzo"]="lzop"
	["xz"]="xz pixz"
	["zst"]="zstd pzstd"
	)
declare -A COMPRESS_AVAILABLE
for ext in "${!COMPRESS_TYPES[@]}"; do
	for exe in ${COMPRESS_TYPES[${ext}]}; do
		BIN=$(command -v "${exe}")
		if [ "${BIN}" != "" ]; then
			COMPRESS_AVAILABLE+=(["${ext}"]="${BIN}")
		fi
	done
done

# set flag variables to null/default
EXCLUDE_BOOT=0
EXCLUDE_CONFIDENTIAL=0
EXCLUDE_LOST=0
QUIET=0
USER_EXCL=()
USER_INCL=()
S_KERNEL=0
HAS_PORTAGEQ=0
COMPRESS_TYPE="zst"
# Assumed ratio for zstd
COMP_RATIO="4.4"

if command -v portageq &>/dev/null
then
	HAS_PORTAGEQ=1
fi

USAGE="Usage:\n\
	$(basename "$0") [-b -c -k -l -q] [-C <compression-type>] [-s || -t <target-mountpoint>] [-e <additional excludes dir*>] [-i <additional include target>] <archive-filename> [custom-tar-options]\n\
	-b: excludes boot directory.\n\
	-c: excludes some confidential files (currently only .bash_history and connman network lists).\n\
	-k: separately save current kernel modules and src (creates smaller archives and saves decompression time).\n\
	-l: excludes lost+found directory.\n\
	-q: activates quiet mode (no confirmation).\n\
	-C: specify tar compression (default: ${COMPRESS_TYPE}, available: ${!COMPRESS_AVAILABLE[*]}).\n\
	-s: makes tarball of current system.\n\
	-t: makes tarball of system located at the <target-mountpoint>.\n\
	-e: an additional excludes directory (one dir one -e, do not use it with *).\n\
	-i: an additional target to include. This has higher precedence than -e, -t, and -s.\n\
	-h: display this help message."

# reads options:
while getopts ":t:C:e:i:skqcblh" flag
do
	case "$flag" in
		t)
			TARGET="$OPTARG"
			;;
		s)
			TARGET="/"
			;;
		C)
			COMPRESS_TYPE="$OPTARG"
			;;
		q)
			QUIET=1
			;;
		k)
			S_KERNEL=1
			;;
		c)
			EXCLUDE_CONFIDENTIAL=1
			;;
		b)
			EXCLUDE_BOOT=1
			;;
		l)
			EXCLUDE_LOST=1
			;;
		e)
			USER_EXCL+=("--exclude=${OPTARG}")
			;;
		i)
			USER_INCL+=("${OPTARG}")
			;;
		h)
			echo -e "$USAGE"
			exit 0
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument." >&2
			exit 1
			;;
	esac
done

if [ -z "$TARGET" ]
then
	echo "$(basename "$0"): no target specified."
	echo -e "$USAGE"
	exit 1
fi

# make sure TARGET path ends with slash
if [[ "$TARGET" != */ ]]
then
	TARGET="${TARGET}/"
fi

# shifts pointer to read mandatory output file specification
shift $((OPTIND - 1))
ARCHIVE=$1

# checks for correct output file specification
if [ -z "$ARCHIVE" ]
then
	echo "$(basename "$0"): no archive file name specified."
	echo -e "$USAGE"
	exit 1
fi

# checks for quiet mode (no confirmation)
if ((QUIET))
then
	AGREE="yes"
fi

# determines if filename was given with relative or absolute path
if (($(grep -c '^/' <<< "$ARCHIVE") > 0))
then
	STAGE4_FILENAME="${ARCHIVE}.tar"
else
	STAGE4_FILENAME="$(pwd)/${ARCHIVE}.tar"
fi

# Check if compression in option and filename
if [ -z "$COMPRESS_TYPE" ]
then
	echo "$(basename "$0"): no archive compression type specified."
	echo -e "$USAGE"
	exit 1
else
	STAGE4_FILENAME="${STAGE4_FILENAME}.${COMPRESS_TYPE}"
fi

# Check if specified type is available
if [ -z "${COMPRESS_AVAILABLE[$COMPRESS_TYPE]}" ]
then
	echo "$(basename "$0"): specified archive compression type not supported."
	echo "Supported: ${COMPRESS_AVAILABLE[*]}"
	exit 1
fi

# Shifts pointer to read custom tar options
shift
mapfile -t OPTIONS <<< "$@"
# Handle when no options are passed
((${#OPTIONS[@]} == 1)) && [ -z "${OPTIONS[0]}" ] && unset OPTIONS

if ((S_KERNEL))
then
	USER_EXCL+=("--exclude=${TARGET}usr/src/*")
	USER_EXCL+=("--exclude=${TARGET}lib*/modules/*")
fi


# Excludes:
EXCLUDES=(
	"--exclude=${TARGET}dev/*"
	"--exclude=${TARGET}var/tmp/*"
	"--exclude=${TARGET}media/*"
	"--exclude=${TARGET}mnt/*/*"
	"--exclude=${TARGET}proc/*"
	"--exclude=${TARGET}run/*"
	"--exclude=${TARGET}sys/*"
	"--exclude=${TARGET}tmp/*"
	"--exclude=${TARGET}var/lock/*"
	"--exclude=${TARGET}var/log/*"
	"--exclude=${TARGET}var/run/*"
	"--exclude=${TARGET}var/lib/docker/*"
)

EXCLUDES_DEFAULT_PORTAGE=(
	"--exclude=${TARGET}var/db/repos/*/*"
	"--exclude=${TARGET}var/cache/distfiles/*"
	"--exclude=${TARGET}usr/portage/*"
)

EXCLUDES+=("${USER_EXCL[@]}")

INCLUDES=(
)

INCLUDES+=("${USER_INCL[@]}")

if [ "$TARGET" == '/' ]
then
	EXCLUDES+=("--exclude=$(realpath "$STAGE4_FILENAME")")
	if ((HAS_PORTAGEQ))
	then
		PORTAGEQ_REPOS=$(portageq get_repos /)
		for i in ${PORTAGEQ_REPOS}; do
			REPO_PATH=$(portageq get_repo_path / "${i}")
			EXCLUDES+=("--exclude=${REPO_PATH}/*")
		done
		EXCLUDES+=("--exclude=$(portageq distdir)/*")
	else
		EXCLUDES+=("${EXCLUDES_DEFAULT_PORTAGE[@]}")
	fi
else
	EXCLUDES+=("${EXCLUDES_DEFAULT_PORTAGE[@]}")
fi

if ((EXCLUDE_CONFIDENTIAL))
then
	EXCLUDES+=("--exclude=${TARGET}home/*/.bash_history")
	EXCLUDES+=("--exclude=${TARGET}root/.bash_history")
	EXCLUDES+=("--exclude=${TARGET}var/lib/connman/*")
fi

if ((EXCLUDE_BOOT))
then
	EXCLUDES+=("--exclude=${TARGET}boot/*")
fi

if ((EXCLUDE_LOST))
then
	EXCLUDES+=("--exclude=lost+found")
fi

# Compression options
COMP_OPTIONS=("${COMPRESS_AVAILABLE[$COMPRESS_TYPE]}")
if [[ "${COMPRESS_AVAILABLE[$COMPRESS_TYPE]}" == *"/xz" ]]
then
	COMP_OPTIONS+=( "-T0" )
fi

# Generic tar options:
TAR_OPTIONS=(
	-cpP
	--ignore-failed-read
	"--xattrs-include=*.*"
	--numeric-owner
	"--use-compress-prog=${COMP_OPTIONS[*]}"
	)
 
# Get $TARGET size for pv eta
  TOTAL_SIZE="$(du -hs --apparent-size --block-size=1G "${EXCLUDES[@]}" "$TARGET" 2> /dev/null |  awk '{print $1}')"
  COMP_SIZE="$(awk "BEGIN {printf \"%.2f\",${TOTAL_SIZE}/${COMP_RATIO}}" | awk '{print int($1+0.5)}')"

# if not in quiet mode, this message will be displayed:
if [[ "$AGREE" != 'yes' ]]
then
	echo "Are you sure that you want to make a stage 4 tarball of the system"
	echo "located under the following directory?"
        printf "%b" "\e[5m\e[31m"$TARGET" \e[0m" "--- at a total size of = "$TOTAL_SIZE"GB"
	echo
	echo "WARNING: since all data is saved by default the user should exclude all"
	echo "security- or privacy-related files and directories, which are not"
	echo "already excluded by mkstage4 options (such as -c), manually per cmdline."
	echo "example: \$ $(basename "$0") -s /my-backup --exclude=/etc/ssh/ssh_host*"
	echo
	echo "COMMAND LINE PREVIEW:"
	echo 'tar' "${TAR_OPTIONS[@]}" "${INCLUDES[@]}" "${EXCLUDES[@]}" "${OPTIONS[@]}" -f "$STAGE4_FILENAME" "${TARGET}"
	if ((S_KERNEL))
	then
		echo
		echo 'tar' "${TAR_OPTIONS[@]}" -f "$STAGE4_FILENAME.ksrc" "${TARGET}usr/src/linux-$(uname -r)"
		echo 'tar' "${TAR_OPTIONS[@]}" -f "$STAGE4_FILENAME.kmod" "${TARGET}lib"*"/modules/$(uname -r)"
	fi
	echo
	echo -n 'Type "yes" to continue or anything else to quit: '
	read -r AGREE
fi

# start stage4 creation:
if [ "$AGREE" == 'yes' ]
then
	tar "${TAR_OPTIONS[@]}" "${INCLUDES[@]}" "${EXCLUDES[@]}" "${OPTIONS[@]}" "${TARGET}" | pv -abept -s "$COMP_SIZE"G > "$STAGE4_FILENAME"
	if ((S_KERNEL))
	then
		tar "${TAR_OPTIONS[@]}" -f "$STAGE4_FILENAME.ksrc" "${TARGET}usr/src/linux-$(uname -r)"
		tar "${TAR_OPTIONS[@]}" -f "$STAGE4_FILENAME.kmod" "${TARGET}lib"*"/modules/$(uname -r)"
	fi
fi
