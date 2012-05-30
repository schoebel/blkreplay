####################################################
# customization prefix

define(IS_REQUIRED, [AC_MSG_ERROR([this is absolutely needed])])

AC_INIT([blkreplay], [0.1], [tst@1und1.de])
AM_INIT_AUTOMAKE([-Wall -Werror])

AC_SEARCH_LIBS([log10], [m], , IS_REQUIRED)
AC_SEARCH_LIBS([clock_gettime], [rt], , IS_REQUIRED)

AC_CHECK_HEADERS([malloc.h])

# required functions
AC_CHECK_DECLS([strlen, malloc, free], , IS_REQUIRED)

# optional functions
#AC_CHECK_DECLS([O_LARGEFILE]) # does not work, use direct test instead
AC_CHECK_DECLS([exp10])
AC_CHECK_DECLS([lseek64])
AC_CHECK_DECLS([memalign])
AC_CHECK_DECLS([posix_memalign], ,
[AC_MSG_WARN([posix_memalign() not available, substituting by malloc()
====> This may lead to distortions of your measurements!])])

####################################################
#                                               -*- Autoconf -*-
# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.68])
AC_CONFIG_SRCDIR([src/bins.c])
AC_CONFIG_HEADERS([config.h])

# Checks for programs.
AC_PROG_AWK
AC_PROG_CC
AC_PROG_INSTALL
AC_PROG_LN_S
AC_PROG_MAKE_SET

# Checks for libraries.

# Checks for header files.
AC_CHECK_HEADERS([fcntl.h memory.h stddef.h stdlib.h string.h strings.h unistd.h])

# Checks for typedefs, structures, and compiler characteristics.
AC_TYPE_PID_T

# Checks for library functions.
AC_FUNC_FORK
AC_FUNC_MALLOC
AC_CHECK_FUNCS([clock_gettime floor memset mkdir strerror])

AC_CONFIG_FILES([Makefile
                 src/Makefile
                 src/arch.m32/Makefile
                 src/arch.m64/Makefile])
####################################################
# customization suffix

m4_include([src/arch.m32/subconfigure.ac])
m4_include([src/arch.m64/subconfigure.ac])

AM_PROG_CC_C_O

####################################################
AC_OUTPUT
