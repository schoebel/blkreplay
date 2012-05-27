bin_PROGRAMS = bins.exe blkreplay.exe

bins_exe_SOURCES = bins.c

blkreplay_exe_SOURCES = blkreplay.c

# errors in these subdirectories are (mostly) ignored.
# try to build as much architectures as possible, but don't insist.
AM_MAKEFLAGS = -i
SUBDIRS = arch.m32 arch.m64
