#!/usr/bin/bash

# {{{ CDDL HEADER
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
# }}}

#
# Copyright 2017 OmniTI Computer Consulting, Inc.  All rights reserved.
# Copyright 2021 OmniOS Community Edition (OmniOSce) Association.
#

function ListDisks {
    log "ListDisks starting - want '$*'"
    typeset -A disksize
    typeset -A diskname
    for rdsk in `prtconf -v | nawk -F= '
        /dev_link=\/dev\/rdsk\/c.*p0/ { print $2 }'`; do
            disk="`echo $rdsk | sed -e 's/.*\///g; s/p0//;'`"
            size="`prtvtoc $rdsk 2>/dev/null | nawk '
                /bytes\/sector/         { bps=$2 }
                /sectors\/cylinder/     { bpc = bps * $2 }
                /accessible sectors/    { print ($2 * bps) / 1048576 }
                /accessible cylinders/  { print int(($2 * bpc) / 1048576) }
            '`"
            disksize+=([$disk]=$size)
            log "... found disk '$disk' = $size"
    done

    disk=
    while builtin read diskline; do
        if [ -n "$disk" ]; then
            desc=`echo $diskline | sed -e 's/^[^\<]*//; s/[\<\>]//g;'`
            diskname+=([$disk]=$desc)
            log "... found disk '$disk' = $desc"
            disk=
        else
            disk=$diskline
        fi
    done < <(format < /dev/null | nawk '/^ *[0-9]*\. /{print $2; print;}')

    for want in $*; do
        for disk in "${!disksize[@]}"; do
            case "$want" in
                \>*)
                    [ -n "${disksize[$disk]}" -a \
                        "${disksize[$disk]}" -ge "${want:1}" ] \
                        && echo $disk | pipelog
                    ;;
                \<*)
                    [ -n "${disksize[$disk]}" -a \
                        "${disksize[$disk]}" -le "${want:1}" ] \
                        && echo $disk | pipelog
                    ;;
                *)
                    [ "$disk" = "$want" ] && echo $disk | pipelog
                    ;;
            esac
       done

        for disk in "${!diskname[@]}"; do
            case "$want" in
                ~*)
                    PAT=${want:1}
                        echo ${diskname[$disk]} | egrep -se "$PAT" \
                            && echo $disk | pipelog
                    ;;
            esac
        done
    done
    log "ListDisks ending"
}

function ListDisksAnd {
    num=`echo $1 | sed -e 's/[^,]//g;' | wc -c`
    ((EXPECT = num + 0))
    for part in `echo $1 | sed -e 's/,/ /g;'`; do
        ListDisks $part
    done | sort | uniq -c | nawk -v e=$EXPECT '$1 == e { print $2 }'
}

ListDisksUnique(){
    for term in $*; do
        ListDisksAnd $term
    done | sort | uniq | xargs
}

function BuildRpoolOnly {
    ztype=
    ztgt=
    disks="`ListDisksUnique $*`"
    log "Disks being used for root pool $RPOOL: $disks"
    [ -z "$disks" ] && bomb "No matching disks found to build root pool $RPOOL"
    for i in $disks; do
        [ -n "$ztgt" ] && ztype=mirror
        ztgt+=" ${i}"
    done
    log "zpool destroy $RPOOL (just in case we've been run twice)"
    logcmd zpool destroy $RPOOL || true
    log "Creating root pool"
    # Just let "zpool create" do its thing.
    # We want GPT disks with a UEFI system partition now.
    logcmd zpool create -fB $RPOOL $ztype $ztgt \
        || bomb "Failed to create root pool $RPOOL"
}

function BuildRpool {
    BuildRpoolOnly $*
    BuildBE
}

function GetTargetVolSize {
    # Aim for 25% of physical memory (minimum 1G)
    # prtconf always reports in megabytes
    typeset mem=`/usr/sbin/prtconf -m`
    typeset vsize=1
    if [ "$mem" -ge 4096 ]; then
        typeset quart=`echo "scale=1;$mem/4096" | /bin/bc`
        vsize=`printf %0.f $quart`
    fi
    log "GetTargetVolSize: $vsize"
    echo $vsize
}

function GetRpoolFree {
    typeset zfsavail=`/sbin/zfs list -H -o avail $RPOOL`
    typeset avail
    if [ "${zfsavail:(-1)}" = "G" ]; then
        avail=`printf %0.f ${zfsavail::-1}`
    elif [ "${zfsavail:(-1)}" = "T" ]; then
        typeset gigs=`echo "scale=1;${zfsavail::-1}*1024" | /bin/bc`
        avail=`printf %0.f $gigs`
    else
        # If we get here, there's too little space left to be usable
        avail=0
    fi
    log "GetRpoolFree: $avail"
    echo $avail
}

function create_swap_dump {
    typeset tmppool=${1?pool}; shift
    typeset pool=${1?pool}; shift
    typeset root=${1?root}; shift
    typeset size=${1?size}; shift
    typeset blocksize=${1:-4096}
    typeset savecore=${2:-y}
    typeset sparse=${3:-n}

    typeset volname
    for volname in swap dump; do
        typeset extra_args=
        [ "$volname" = swap -a "$sparse" = y ] && extra_args=-s
        log "Creating $volname..."
        logcmd /sbin/zfs create \
            $extra_args \
            -V ${size} \
            -b $blocksize \
            -o logbias=throughput \
            -o sync=always \
            -o primarycache=metadata \
            -o secondarycache=none \
            $tmppool/$volname \
            || bomb "Failed to create $tmppool/$volname"
    done
    printf "/dev/zvol/dsk/$pool/swap\t-\t-\tswap\t-\tno\t-\n" \
        >> $root/etc/vfstab
    Postboot /usr/sbin/dumpadm -$savecore -c curproc \
        -d /dev/zvol/dsk/$pool/dump
    return 0
}

function MakeSwapDump {
    typeset size=`GetTargetVolSize`
    typeset free=`GetRpoolFree`
    typeset totalvols=
    typeset usable=
    typeset savecore=

    slog "Creating swap and dump volumes"

    # We're creating both swap and dump volumes of the same size
    ((totalvols = size * 2))

    # We want at least 10GB left free after swap/dump
    # If we can't make swap/dump at least 1G each, don't bother
    ((usable = free * 9 / 10 - 11))

    if [ $usable -lt 2 ]; then
        log "Not enough free space for reasonably-sized swap and dump;"\
            " not creating either."
        return 0
    fi

    # If the total of swap and dump is greater than the usable free space,
    # make swap and dump each take half but don't enable savecore

    if [ $totalvols -ge $usable ]; then
        log "Required volume space ($totalvols) is more than usable ($usable)"
        ((size = usable / 2))
        log "Using $size instead and disabling savecore"
        savecore="n"
    else
        savecore="y"
    fi

    log "Final swap/dump volume size is $size"

    blocksize="`getconf PAGESIZE`"
    [ -z "$blocksize" ] && blocksize=4096   # x86 default

    log "Using blocksize $blocksize"

    create_swap_dump $RPOOL $RPOOL $ALTROOT ${size}G $blocksize $savecore
    return 0
}

function MakeExportHome {
    typeset _rpool=$1

    slog "Creating /export/home dataset"

    logcmd /sbin/zfs create -o mountpoint=/export $_rpool/export
    logcmd /sbin/zfs create $_rpool/export/home
    logcmd $ALTROOT/usr/sbin/useradd -D -b /export/home
    logcmd cp {,$ALTROOT}/usr/sadm/defadduser

    cat <<- EOM > $ALTROOT/etc/auto_home
		+auto_home
		*   localhost:/export/home/&
	EOM

    return 0
}

# Vim hints
# vim:ts=4:sw=4:et:fdm=marker
