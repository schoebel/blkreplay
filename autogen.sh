#!/bin/bash

[ "$ACLOCAL"    ] || ACLOCAL=aclocal
[ "$AUTOCONF"   ] || AUTOCONF=autoconf
[ "$AUTOHEADER" ] || AUTOHEADER=autoheader
[ "$AUTOMAKE"   ] || AUTOMAKE=automake
[ "$AUTORECONF" ] || AUTORECONF=autoreconf

echo "autoheader..."
$AUTOHEADER || exit $?

echo "autoreconf --install..."
$AUTORECONF --install

echo "autoconf..."
$AUTOCONF || exit $?

echo "automake..."
$AUTOMAKE || exit $?
