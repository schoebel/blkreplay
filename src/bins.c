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
#include <stdio.h>
#include <math.h>

#define MAX_BINS 1024

double bin_size = 10.0;
int bin_min = MAX_BINS;
int bin_max = 0;
int bin_count[MAX_BINS];

void put_bin(double val)
{
	int bin = log10(val) * bin_size;
	bin += MAX_BINS/2;
	if (val <= 0 || bin < 0 || bin >= MAX_BINS)
		return;
	if (bin < bin_min)
		bin_min = bin;
	if (bin >= bin_max)
		bin_max = bin + 1;
	bin_count[bin]++;
}

int main()
{
	int i;
	char buf[4096];
	while (fgets(buf, sizeof(buf), stdin)) {
		double val = 0;
		sscanf(buf, " %lf", &val);
		put_bin(val);
	}
	for (i = bin_min; i < bin_max; i++) {
		printf("%le %6d\n", exp10((double)(i - MAX_BINS/2) / bin_size), bin_count[i]);
	}
	return 0;
}
