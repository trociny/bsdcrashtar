#!/bin/sh
#
# Copyright (c) 2009 Mikolaj Golub.
# All rights reserved.
#
# Some parts of the code (vmcore and kernel autodetection) were taken
# from FreeBSD crashinfo(8) script.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. Neither the name of the author nor the names of any co-contributors
#    may be used to endorse or promote products derived from this software
#    without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $Id$

# This script creates tar archive that contains all files needed for
# debugging FreeBSD kernel crash (vmcore, kernel, loaded modules,
# sources that appear in backtrace). This is useful for debugging a
# crash on another host or sending it to developer.
#
# Created tar archive contains also a script that when being run
# inside unpacked archive will give kgdb(1) session with crash core
# loaded in it. The script should be run with root privileges because
# it does chroot(8) before starting kgdb(1).
#
# WARNING: As core file presents a content of kernel virtual memory at
# the moment of the crash it might contain information you would not
# like to become public. So think twice before giving the access to
# the core to other person.
# 

set -ue

#
# Global vars
#

PROGNAME=`basename $0`
CRASHDIR=/var/crash
DUMPNR=
VMCORE=
KERNEL=
TARFILE=
TMPDIR=
CRASH=

#
# Functions
#

# Print minihelp.

usage()
{

    echo
    echo "usage: $PROGNAME [options] [<crash.tar.gz>]"
    echo
    echo "Options:"
    echo
    echo "  -h              print this help and exit"
    echo "  -d <crashdir>   path to crash directory"
    echo "  -n <dumpnr>     dump number"
    echo "  -k <kernel>     path to kernel"
    echo "  -c <core>       path to core file"
    echo
    echo "  <crash.tar.gz>  path to tar file where files will be stored"
    echo
}

# Create directory we will use for storing temporary files and
# data. Set trap to remove it on exit.

mk_tmpdir ()
{

    if ! TMPDIR=`mktemp -dt $PROGNAME`; then
	echo "Can't create tmp directory" >&2
	exit 1
    fi
    
    chmod 0700 "$TMPDIR"

    trap "rm -Rf '$TMPDIR'" INT QUIT EXIT

}

# Find kernel.

find_kernel()
{
    local ivers k kvers

    ivers=$(awk '
	/Version String/ {
		print
		nextline=1
		next
	}
	// {
		if (nextline) {
			print
			nextline=0
		}
	}' $INFO)

    # Look for a matching kernel version.
    for k in `sysctl -n kern.bootfile` $(ls -t /boot/*/kernel); do

	kvers=$(echo 'printf "  Version String: %s", version' | \
	    gdb -x /dev/stdin -batch $k 2>/dev/null)

	if [ "$ivers" = "$kvers" ]; then
	    KERNEL=$k
	    break
	fi

    done
}

# Run kgdb and generate all info we need looking for files we want to
# archive.

run_kgdb()
{
    local nthr i

    # We run kgdb redirecting its output to fifo and read this output
    # to make a decision about the next command to run.

    mkfifo $TMPDIR/fifo

    {
	# Just generate some known output.
	echo "show version"

	# On start kgdb outputs modules it loads, like this one:
	# "Loaded symbols for /boot/kernel/ng_socket.ko".
	# Parse these lines to generate the list of modules.

	sed -lnEe 's|^Loaded symbols for (/[^ ].*\.ko)(\.symbols)?$|\1|p;
                   /\(kgdb\)/q' > $TMPDIR/modules

	# Find the number of threads from "info threads" command
	# output. The thread with the max number is printed first.
	echo "info threads"
	nthr=`sed -nEe '/^.* [0-9]+ Thread [0-9]+.*$/{
		          s/^.* ([0-9]+) Thread [0-9]+.*$/\1/p
		          q
		        }'`

	# Output backtrace of every thread and parse output looking
	# for source files. If a source path is not full run
	# "maintenance info symtabs file"
	
	i=$nthr
	while [ "$i" -gt 0 ]; do
	    echo thread apply $i backtrace
	    i=$((i - 1))
	done
	# Just generate some known output so we know where we is.
	echo "show version" 

	> $TMPDIR/sources.nonunique
	sed -lnEe 's|^.* at +([^:]*):[0-9]+$|\1|p; /GNU gdb.*FreeBSD/q' |
	awk '{
          if (/^\//) 
            print >> "'$TMPDIR/sources.nonunique'"
          else
            print "maintenance info symtabs " $0
        }'
	# Just generate some known output so we know where we is.
	echo "show version" 

	# Parse output of "maintenance info symtabs file" commands.
	# It looks like this one:
	#  { symtab vm_page.h ((struct symtab *) 0x2d11d8d0)
	#    dirname /usr/src/sys/vm
	#    fullname (null)
	#    blockvector ((struct blockvector *) 0x2d11d690)
	#    debugformat unknown
	#  }	
	awk '$1 == "{" && $2 == "symtab" {file=$3}
             file && $1 == "dirname"     {print $2 "/" file; file = ""}
             $1 == "}"                   {file = ""}
             /GNU gdb.*FreeBSD/          {exit}' >> $TMPDIR/sources.nonunique

	sort -u $TMPDIR/sources.nonunique > $TMPDIR/sources

	# Find srcbase.
	echo "break vn_open"
	srcbase=`sed -nEe '/^.*Breakpoint 1 at .* file .*\/kern\/vfs_vnops.c,.*$/{
                             s|^.*Breakpoint 1 at .* file (.*)/kern/vfs_vnops.c,.*$|\1|p
                             q
                           }'`
	echo ${srcbase#/} > $TMPDIR/srcbase
	find $srcbase/`uname -m`/include -type f -name '*.h' >> $TMPDIR/sources

	# Send quit and wait for gdb to close fifo on its side (to avoid sigpipe).
	echo "quit"
	cat > /dev/null

    } < $TMPDIR/fifo |
    kgdb $KERNEL $VMCORE 2>/dev/null | tee $TMPDIR/kgdb.out > $TMPDIR/fifo
}

#
# Main
#

while getopts "hd:n:k:c:" opt; do

    case "$opt" in

	h)
	    usage
	    exit 0
	    ;;
	d)
	    CRASHDIR=$OPTARG
	    ;;
	n)
	    DUMPNR=$OPTARG
	    ;;
	k)
	    KERNEL=$OPTARG
	    ;;
	c)
	    VMCORE=$OPTARG
	    ;;
	\?)
	    usage >&2
	    exit 1
	    ;;
    esac
done

mk_tmpdir

if [ -n "$DUMPNR" -a -n "$VMCORE" ]; then
    echo "-n and -c options are mutually exclusive" >&2
    usage >&2
    exit 1
fi


if [ -n "$VMCORE" ]; then
    CRASHDIR=`dirname $VMCORE`
fi

if [ ! -x $CRASHDIR ]; then
    echo "No access to crash directory $CRASHDIR" >&2
    exit 1
fi

if [ -n "$VMCORE" ]; then
    DUMPNR=$(expr $(basename $VMCORE) : 'vmcore\.\([0-9]*\)$') || :
    if [ -z "$DUMPNR" ]; then
	echo "Unable to determine dump number from vmcore file $VMCORE." >&2
	exit 1
    fi
else
    # If we don't have an explicit dump number, operate on the most
    # recent dump.
    if [ -z "$DUMPNR" ]; then
	if ! [ -r $CRASHDIR/bounds ]; then
	    echo "No crash dumps in $CRASHDIR." >&2
	    exit 1
	fi		
	next=`cat $CRASHDIR/bounds`
	if [ -z "$next" ] || [ "$next" -eq 0 ]; then
	    echo "No crash dumps in $CRASHDIR." >&2
	    exit 1
	fi
	DUMPNR=$(($next - 1))
    fi
fi

shift $((OPTIND - 1))

if [ $# -gt 1 ]; then
    usage >&2
    exit 1
elif [ $# -eq 1 ]; then
    TARFILE=$1
else
    TARFILE=$CRASHDIR/crash.$DUMPNR.tar.gz
fi

if ! echo $TARFILE | grep -q '\.tar\.gz$'; then
    echo "crash tarfile name should have '.tar.gz' extension" >&2
    usage >&2
    exit 1
fi

CRASH=`basename $TARFILE .tar.gz`
VMCORE=$CRASHDIR/vmcore.$DUMPNR
INFO=$CRASHDIR/info.$DUMPNR

if [ ! -e $VMCORE ]; then
	echo "$VMCORE not found" >&2
	exit 1
fi

if [ ! -r $VMCORE ]; then
	echo "$VMCORE not readable" >&2
	exit 1
fi

if [ ! -e $INFO ]; then
	echo "$INFO not found" >&2
	exit 1
fi

if [ ! -r $INFO ]; then
	echo "$INFO not readable" >&2
	exit 1
fi

# If the user didn't specify a kernel, then try to find one.
if [ -z "$KERNEL" ]; then
	find_kernel
	if [ -z "$KERNEL" ]; then
		echo "Unable to find matching kernel for $VMCORE" >&2
		exit 1
	fi
elif [ ! -e $KERNEL ]; then
	echo "$KERNEL not found" >&2
	exit 1
fi

run_kgdb;

mkdir $TMPDIR/$CRASH

mv $TMPDIR/kgdb.out $TMPDIR/$CRASH

ln -s `cat $TMPDIR/srcbase`/`uname -m`/include "$TMPDIR/$CRASH/machine"

{
    cat $TMPDIR/sources

    echo $VMCORE
    echo $INFO

    for f in $KERNEL `cat $TMPDIR/modules`; do
	echo $f
	echo $f.symbols
    done

} | cpio -pvd "$TMPDIR/$CRASH" 2>/dev/null || :

cat > "$TMPDIR/$CRASH/debug.sh" << EOF
#!/bin/sh
{
    echo /libexec/ld-elf.so.1
    echo /usr/bin/kgdb
    ldd /usr/bin/kgdb |
    awk '\$3 ~ /\.so\./ {print \$3}'
} | cpio -pvd .

chroot . /usr/bin/kgdb '$KERNEL' '$VMCORE'

EOF

chmod a+x "$TMPDIR/$CRASH/debug.sh"

cat > "$TMPDIR/$CRASH/README" <<EOF
Run ./debug.sh under root to debug the crashdump.
EOF

echo "Archiving the crash to $TARFILE."

touch "$TARFILE"
chmod 0600 "$TARFILE"
tar -C "$TMPDIR" -czf "$TARFILE" $CRASH
