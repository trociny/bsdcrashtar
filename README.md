# bsdcrashtar

archive FreeBSD kernel crash files

Automatically exported from code.google.com/p/bsdcrashtar

The bsdcrashtar utility creates a tar archive that contains all
files needed for debugging FreeBSD kernel crash (vmcore, kernel,
loaded modules, sources that appear in backtrace). This is useful
for debugging a crash on another host, sending it to developers
or if you are going to upgrade the kernel on crashed host but
would like to keep crashdump in case the developers ask you to
provide additional info.

Created tar archive contains also a script that when being run
inside unpacked archive will give kgdb(1) session with crash core
loaded in it. The script should be run with root privileges
because it does chroot(8) before starting kgdb(1).
