# Simple bare-bones
# TODO: write a better Makefile

CFLAGS= -O2 -g -Wall
LDFLAGS= -lrt -lm

all: blkreplay.i686 blkreplay.x86_64

blkreplay.i686: blkreplay.c Makefile
	gcc -m32 $(CFLAGS) blkreplay.c $(LDFLAGS) -o blkreplay.i686

blkreplay.x86_64: blkreplay.c Makefile
	gcc -m64 $(CFLAGS) blkreplay.c $(LDFLAGS) -o blkreplay.x86_64

