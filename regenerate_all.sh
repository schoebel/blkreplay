#!/bin/bash

echo "####################################################"
echo "Regenerating (almost) everything from scratch..."
echo ""
rm="rm -rf conf* auto* ac* missing install-sh INSTALL depcomp stamp* Makefile *.in src/*.in src/*.o src/*.exe src/Makefile src/*/*.in src/*/*.o src/*/*.exe src/*/Makefile"
echo "$rm"
$rm

ls -lt

echo "autoscan..."
autoscan || exit $?
<<EOF cat > configure.ac
####################################################
# customization prefix

define(IS_REQUIRED, [AC_MSG_ERROR([this is absolutely needed])])

AC_INIT([blkreplay], [0.1], [tst@1und1.de])
AM_INIT_AUTOMAKE([-Wall -Werror])

AC_SEARCH_LIBS([log10], [m], , IS_REQUIRED)
AC_SEARCH_LIBS([clock_gettime], [rt], , IS_REQUIRED)

AC_CHECK_HEADERS([malloc.h])
AC_CHECK_HEADERS([unistd.h])
AC_CHECK_HEADERS([limits.h])

# required functions
AC_CHECK_DECLS([strlen, malloc, free], , IS_REQUIRED)

# optional functions
#AC_CHECK_DECLS([O_LARGEFILE]) # does not work, use direct test instead
AC_CHECK_DECLS([random])
AC_CHECK_DECLS([exp10])
AC_CHECK_DECLS([lseek64])
AC_CHECK_DECLS([llseek])
AC_CHECK_DECLS([lseek])
AC_CHECK_DECLS([memalign])
AC_CHECK_DECLS([posix_memalign], ,
[AC_MSG_WARN([posix_memalign() not available, substituting by malloc()
====> This may lead to distortions of your measurements!])])

####################################################
EOF
grep -v "AC_INIT\|AC_OUTPUT" < configure.scan >> configure.ac
rm configure.scan 
<<EOF cat >> configure.ac
####################################################
# customization suffix

$(for i in src/arch.*/subconfigure.ac; do echo "m4_include([$i])"; done)

AM_PROG_CC_C_O

####################################################
AC_OUTPUT
EOF

(
  grep -v SUBDIRS < src/Makefile.am
  echo "SUBDIRS = $(cd src; echo arch.*)"
) > src/Makefile.tmp && mv src/Makefile.tmp src/Makefile.am

echo "aclocal..."
aclocal || exit $?

echo "autoheader..."
autoheader || exit $?

echo "autoreconf --install..."
autoreconf --install

echo "autoconf..."
autoconf || exit $?

echo "automake..."
automake || exit $?

echo "git add..."
git add $0 configure.ac configure INSTALL *.in src/*.{am,in} src/arch.*/*.{ac,am,in}

echo "OK, now do 'git commit' by hand if all is right."
