/* Copyright 2009-2012 Thomas Schoebel-Theuer, sponsored by 1&1 Internet AG
 *
 * Email: tst@1und1.de
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

#define _GNU_SOURCE
#include <config.h>

#ifdef STDC_HEADERS
# include <stdlib.h>
# include <stddef.h>
#else
# ifdef HAVE_STDLIB_H
#  include <stdlib.h>
# endif
#endif

#ifdef HAVE_UNISTD_H
# include <unistd.h>
#endif

#if HAVE_DECL_RANDOM
# define TYPE long int
#else
# define TYPE int
# define random rand
#endif

/* Infinitely create random data on stdout, until some error occurs.
 */

#define SIZE (1024 * 1024)

int main(int argc, char *argv[])
{
	static char buf[SIZE];
	int i;
	int status;
	
	do {
		for (i = 0; i < SIZE / sizeof(TYPE); i++) {
			TYPE *ptr = (void*)&buf[i * sizeof(TYPE)];
			*ptr = random();
		}

		status = write(1, buf, sizeof(buf));

	} while (status == sizeof(buf));

	return 0;
}
