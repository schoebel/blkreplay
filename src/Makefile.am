bin_PROGRAMS = blkreplay-bins blkreplay-random_data blkreplay

blkreplay_bins_SOURCES = bins.c

blkreplay_random_data_SOURCES = random_data.c

blkreplay_SOURCES = blkreplay.c

# errors in these subdirectories are (mostly) ignored.
# try to build as much architectures as possible, but don't insist.
AM_MAKEFLAGS = -i
SUBDIRS = arch.m32 arch.m64
