#!/usr/bin/bash

#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#

#
# Copyright 2017 OmniTI Computer Consulting, Inc. All rights reserved.
# Copyright 2018 OmniOS Community Edition (OmniOSce) Association.
#

. /kayak/dialog.sh
. /kayak/utils.sh

keyboard_layout=${1:-US-English}

tmpf=`mktemp`

##########################################################################
# Disk selection

# In a KVM, the disks don't show up on the first invocation of diskinfo.
# More investigation required but, for now, run it twice.
diskinfo >/dev/null

diskinfo -H | tr "\t" "^" > $tmpf.disks
if [ ! -s $tmpf.disks ]; then
	d_msg "No disks found!"
	exit 0
fi

declare -a args=()
# SCSI    c0t0d1  SEAGATE ST300MP0005      279.40 GiB     no      no
#   -     c2t0d0  Virtio  Block Device     300.00 GiB     no      no
exec 3<$tmpf.disks
while read line <&3; do
	dev="`echo $line | cut -d^ -f2`"
	vid="`echo $line | cut -d^ -f3`"
	pid="`echo $line | cut -d^ -f4`"
	size="`echo $line | cut -d^ -f5`"
	option=`printf "%-20s %s" "$vid $pid" "$size"`

	args+=("$dev" "$option" off)
done
exec 3<&-

while :; do
	dialog \
		--title "Select disks for installation" \
		--colors \
		--checklist "\nSelect disks using arrow keys and space bar.\nIf you select multiple disks, you will be able to choose a RAID level on the next screen.\n\Zn" \
		0 0 0 \
		"${args[@]}" 2> $tmpf

	[ $? -ne 0 ] && exit 0

	DISKLIST="`cat $tmpf`"
	rm -f $tmpf
	if [ -z "$DISKLIST" ]; then
		d_msg "No disks selected"
		continue
	fi
	break
done

# Check if any selected disks are part of an existing zpool. This can happen
# if the installer is re-run.
flag=0
for disk in $DISKLIST; do
	if zpool status | fgrep " $disk"; then
		d_msg "$disk is part of an active ZFS pool."
		flag=1
	fi
done
[ $flag -eq 1 ] && exit 0

test_rpool() {
	mkfile 64m /tmp/test.$$
	if [ $? != 0 ]; then
		[ -f /tmp/test.$$ ] && rm -f /tmp/test.$$
		d_msg "WARNING: Insufficient space in /tmp for installation..."
		return 1
	fi
	zpool create "$1" /tmp/test.$$
	if [ $? != 0 ]; then
		d_msg "Can't test zpool create $1"
		rm -f /tmp/test.$$
		return 1
	fi
	zpool destroy "$1" > /dev/null 2>&1
	rm -f /tmp/test.$$
	return 0
}

##########################################################################
# Pool RAID level

ztype=
typeset -i ndisks="`echo $DISKLIST | wc -w`"
if [ "$ndisks" -gt 1 ]; then
	ztype=mirror

	typeset -a args=()

	args+=(stripe "Striped (no redundancy)" off)
	args+=(mirror "${ndisks}-way mirror" on)
	[ "$ndisks" -ge 3 ] && args+=(raidz "raidz  (single-parity)" off)
	[ "$ndisks" -ge 4 ] && args+=(raidz2 "raidz2 (dual-parity)" off)
	[ "$ndisks" -ge 5 ] && args+=(raidz3 "raidz3 (triple-parity)" off)

	dialog \
	    --title "RAID level" \
	    --colors \
	    --default-item $ztype \
	    --radiolist "\nSelect the desired pool configuration\n\Zn" \
	    12 50 0 \
	    "${args[@]}" 2> $tmpf
	[ $? -ne 0 ] && exit 0
	ztype="`cat $tmpf`"
	rm -f $tmpf
fi
[ "$ztype" = "stripe" ] && ztype=

##########################################################################
# Root pool name function

get_rpool_name()
{
	NRPOOL="$RPOOL"
	while :; do
		dialog \
			--title "Enter the root pool name" \
			--colors \
			--inputbox '\nThis is the name of the ZFS pool that will be created using the selected disks and used for the OmniOS installation.\n\nThe default name is \Z7rpool\Zn and should usually be left unchanged.\n\Zn' \
			16 40 "$NRPOOL" 2> $tmpf
		[ $? -ne 0 ] && return
		NRPOOL="`cat $tmpf`"
		rm -f $tmpf
		[ -z "$NRPOOL" ] && continue
		[[ "$NRPOOL" =~ ^[a-z][-_a-z0-9]*$ ]] && break
		d_msg "Invalid pool name, $NRPOOL"
	done
	RPOOL="$NRPOOL"
}

##########################################################################
# Root pool properties

cont_label='>>> Continue <<<'
cont_text=''
cont_help="`d_centre 'Continue with the installation.'`"

RPOOL=rpool
rpool_label='Root pool name'
rpool_help="`d_centre 'Customise the name of the root pool if required.'`"

PSCHEMES=(UEFI GPT MBR GPT+Active GPT+Slot1)
PSCHEMES_HELP=(
  'Use GPT scheme with UEFI boot partition, recommended.'
  'Use GPT scheme, without UEFI boot partition.'
  'Use traditional MBR scheme, supports disks up to 2TB.'
  'Use GPT scheme but mark partition as active to work around BIOS bugs.'
  'Use GPT scheme but place pMBR in slot 1 to work around BIOS bugs.'
)
PSCHEME="${PSCHEMES[0]}"
PSCHEME_HELP="${PSCHEMES_HELP[0]}"
pscheme_label='Partitioning Scheme'
pscheme_help="`d_centre "$PSCHEME_HELP"`"

COMPRESSION=YES
compression_label='Compression'
compression_help="`d_centre 'Choose whether to enable LZ4 compression on the pool (recommended).'`"

FORCE4K=NO
force4k_label='Force 4K Sectors'
force4k_help="`d_centre 'Configure pool for 4K native sectors (ashift=12).'`"

cycle()
{
	declare -a arr=("${!1}")
	local val="$2"

	for i in "${!arr[@]}"; do
		[ "${arr[$i]}" = "$val" ] && break
	done
	((i = i + 1))
	[ $i -ge ${#arr[@]} ] && i=0
	echo ${arr[$i]}
}

YESNO=(YES NO)
function toggle { cycle YESNO[@] "$@"; }

defaultitem="$cont_label"
while :; do
	dialog \
	  --title "ZFS Root Pool Configuration" \
	  --colors \
	  --item-help \
	  --no-ok --no-cancel \
	  --default-item "$defaultitem" \
	  --menu "\nIf desired, customise aspects of the ZFS Root Pool below; the recommended values have been filled in automatically. Select \Z7Continue\Zn when ready to proceed.\n\Zn" \
	  0 0 0 \
	  "$cont_label"		"$cont_text"	"$cont_help" \
	  "$rpool_label"	"$RPOOL"	"$rpool_help" \
	  "$pscheme_label"	"$PSCHEME" 	"$pscheme_help" \
	  "$compression_label"	"$COMPRESSION"	"$compression_help" \
	  "$force4k_label"	"$FORCE4K"	"$force4k_help" \
	  2> $tmpf
	stat=$?

	[ $stat -ne 0 ] && exit 0

	opt="`cat $tmpf`"
	defaultitem="$opt"
	case $opt in
	    "$cont_label")
		if zpool list -H -o name | egrep -s "^$RPOOL\$"; then
			dialog --defaultno --yesno \
			    "\nPool already exists, overwrite?" 7 50
			[ $? = 0 ] || continue
			dialog --defaultno --yesno \
			    "\nConfirm destruction of existing pool?" 7 50
			[ $? = 0 ] || continue
			d_info "Destroying pool..."
			zpool destroy "$RPOOL" >/dev/null 2>&1
		fi
		d_info "Checking system..."
		test_rpool "$RPOOL" && break
		d_msg "Invalid root pool name"
		defaultitem="$rpool_label"
		continue
		;;
	    "$rpool_label")       get_rpool_name ;;
	    "$pscheme_label")
		PSCHEME="`cycle PSCHEMES[@] "$PSCHEME"`"
		PSCHEME_HELP="`cycle PSCHEMES_HELP[@] "$PSCHEME_HELP"`"
		pscheme_help="`d_centre "$PSCHEME_HELP"`"
		;;
	    "$compression_label") COMPRESSION="`toggle "$COMPRESSION"`" ;;
	    "$force4k_label")     FORCE4K="`toggle "$FORCE4K"`" ;;
	esac
done

##########################################################################
# Create root pool

d_info "Creating $RPOOL..."

sed -i '/sd-config-list/d' /kernel/drv/sd.conf
if [ "$FORCE4K" = "YES" ]; then
	function join_by { local IFS="$1"; shift; echo "$*"; }
	kdisks=()
	for disk in $DISKLIST; do
		inq="`diskinfo -Hp \
		    | nawk -v d=$disk -F"\t" '$2 == d { print $3,$4}'`"
		[ -n "$inq" ] || continue
		kdisks+=(" $inq " "physical-block-size:4096")
	done
	echo "sd-config-list = \"`join_by ',' "${kdisks[@]}"`\";" \
	    | sed 's/,/","/g' >> /kernel/drv/sd.conf
	update_drv -f sd
fi

NO_COMPRESSION=
[ "$COMPRESSION" = "YES" ] || NO_COMPRESSION=1
export NO_COMPRESSION

_DISKLIST="$DISKLIST"
_FLAGS=f
case "$PSCHEME" in
	UEFI)
		_FLAGS+=B
		# The zpool slice will now be slice 1 but slice 0 may have a
		# pool label from a previous installation. Clear it out.
		for disk in $DISKLIST; do
			zpool labelclear -f ${disk}s0
		done
		;;
	MBR)
		_DISKLIST=
		for disk in $DISKLIST; do
			# Single Solaris2 partition
			if ! fdisk -B ${disk}p0; then
				d_msg "Failed to partition $disk"
				exit 0
			fi
			_DISKLIST+="${disk}s0 "
		done
		;;
esac

if ! zpool create -$_FLAGS "$RPOOL" $ztype $_DISKLIST || \
   ! zpool list $RPOOL >& /dev/null; then
	d_msg "Failed to create root pool"
	exit 0
fi

pool_guid="`zpool list -H -o guid $RPOOL`"

# These options work around BIOS bugs on some systems.

case $PSCHEME in
    GPT+Active)
	zpool export $RPOOL >/dev/null 2>&1
	for disk in $DISKLIST; do
		# Set first entry in pMBR active
		fdisk -E 0:1 ${disk}p0
	done
	zpool import $pool_guid
	;;
    GPT+Slot1)
	zpool export $RPOOL >/dev/null 2>&1
	for disk in $DISKLIST; do
		# Move first pMBR entry to slot 1
		fdisk -E 1:0 ${disk}p0
	done
	zpool import $pool_guid
	;;
esac

if zpool list $RPOOL >& /dev/null; then
	d_info "Successfully created $RPOOL..."
else
	d_msg "Problem creating pool..."
	exit 0
fi

###########################################################################
# Prompt for additional information

prompt_hostname omniosce
prompt_timezone

ZFS_IMAGE=/.cdrom/image/*.zfs.bz2
d_info "Installing from ZFS image $ZFS_IMAGE"

# Because of kayak's small miniroot, just use C as the language for now.
LANG=C

. /kayak/install_help.sh
. /kayak/disk_help.sh

BuildBE $RPOOL $ZFS_IMAGE
ApplyChanges $HOSTNAME $TZ $LANG $keyboard_layout
MakeBootable $RPOOL
# Disable SSH by default for interactive installations
[ -f /kayak/nossh.xml ] && cp /kayak/nossh.xml $ALTROOT/etc/svc/profile/site/

if beadm list -H omnios 2>/dev/null; then
	dialog \
		--colors \
		--title "Installation Complete" \
		--msgbox "\\n\
`beadm list | sed 's/$/\\\\n/'`\\n\
$RPOOL now has a working and mounted boot environment, per above.\\n\
\\n\
Once back at the main menu, you can configure the initial system settings,\\n\
reboot, or enter the shell to modify your new BE before its first boot.\\n\\Zn\
" 0 0
else
	d_msg "Installation has failed.\\nCheck $INSTALL_LOG for more information."
fi

