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

/* Replay of blktrace traces.
 * 
 * The standard input must be in a special format (see docs).
 *
 * TODO: Reorganize / modularize code. It grew over a too long time, out
 * of a really _trivial_ initial version. Too many features were added
 * which were originally never envisioned.
 * Replace some global variables with helper structs for
 * parameters, runtime states, etc.
 *
 * MAYBE: Add reasonable getopt() in place of wild-grown parameter parsing,
 * but KEEP PORTABILITY IN MIND, even to very old UNICES.
 *
 * Exception: for good timer resolution, we use nanosleep() & friends.
 * But this can be easily abstracted/interfaced to
 * elder kernel interfaces when necessary.
 */

#define _LARGEFILE64_SOURCE
#define _GNU_SOURCE
#include <config.h>

#include <stdio.h>

#include <errno.h>

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

#include <fcntl.h>

#ifdef HAVE_STRING_H
# if !defined STDC_HEADERS && defined HAVE_MEMORY_H
#  include <memory.h>
# endif
#include <string.h>
#endif
#ifdef HAVE_STRINGS_H
# include <strings.h>
#endif

#include <time.h>

#include <math.h>

#include <signal.h>

#ifdef HAVE_SYS_STAT_H
# include <sys/stat.h>
#endif

#ifdef HAVE_SYS_TYPES_H
# include <sys/types.h>
#endif

/**********************************************************
 *
 */

#ifndef HAVE_DECL_POSIX_MEMALIGN
# if HAVE_MALLOC_H && HAVE_DECL_MEMALIGN
#  define posix_memalign(res,align,size) ((*(res)) = memalign((align), (size)), 0)
# else
#  define posix_memalign(res,align,size) ((*(res)) = malloc(size), 0)
# endif
#endif

#if !HAVE_DECL_LSEEK64
# define lseek64 lseek
#endif

// use -lrt -lm for linking.
//
// example: gcc -Wall -O2 blkreplay.c -lrt -lm -o blkreplay

#define QUEUES               4096
#define MAX_THREADS         32768
#define FILL_FACTOR             8
#define DEFAULT_THREADS      1024
#define DEFAULT_FAN_OUT         8
#define DEFAULT_SPEEDUP       1.0

#ifndef TMP_DIR
# define TMP_DIR "/tmp"
#endif
#define VERIFY_TABLE     "verify_table" // default filename for verify table
#define COMPLETION_TABLE "completion_table" // default filename for completed requests

#define RQ_HASH_MAX (16 * QUEUES)
#define FLOAT long double

//#define DEBUG_TIMING

FLOAT time_factor = DEFAULT_SPEEDUP;
FLOAT time_stretch = 1.0 / DEFAULT_SPEEDUP;
int replay_start = 0;
int replay_end = 0;
int replay_duration = 0;
int replay_out = 0;
int already_forked = 0;
int overflow = 0;
int verify_fd = -1;
int complete_fd = -1;
int main_fd = -1;
char *mmap_ptr = NULL;
char *main_name = NULL;
long long main_size = 0;
long long max_size = 0;
int dry_run = 0;
int fake_io = 0;
int fork_dispatcher = 1;
int mmap_mode = 0;
int conflict_mode = 0; 
/* 0 = allow arbitrary permutations in ordering
 * 1 = drop conflicting requests
 * 2 = enforce ordering by waiting for conflicts
 */
int verify_mode = 0; 
/* 0 = no verify
 * 1 = verify data during execution
 * 2 = additionally verify data after execution
 * 3 = additionally re-read and verify data immediatley after each write
 */
int final_verify_mode = 0; 

int total_max = DEFAULT_THREADS; // parallelism
int sub_max = 0;
int fan_out = DEFAULT_FAN_OUT;
int bottleneck = 0;

int count_completion = 0;  // number of requests on the fly
int statist_lines = 0;     // total number of input lines
int statist_total = 0;     // total number of requests
int statist_writes = 0;    // total number of write requests
int statist_completed = 0; // number of completed requests
int statist_dropped = 0;   // number of dropped requests (verify_mode == 1)
long long verify_errors = 0;
long long verify_errors_after = 0;
long long verify_mismatches = 0;

struct timespec start_stamp = {};
struct timespec first_stamp = {};
struct timespec timeshift = {};
struct timespec meta_delays = {};
long long meta_delay_count;

#define _STRINGIFY(x) #x
#define STRINGIFY(x) _STRINGIFY(x)

///////////////////////////////////////////////////////////////////////

#define NANO 1000000000

static
void timespec_diff(struct timespec *res, struct timespec *start, struct timespec *time)
{
	res->tv_sec = time->tv_sec - start->tv_sec;
	res->tv_nsec = time->tv_nsec - start->tv_nsec;
	//if (time->tv_nsec < start->tv_nsec) {
	if (res->tv_nsec < 0) {
		res->tv_nsec += NANO;
		res->tv_sec--;
	}
}

static
void timespec_add(struct timespec *res, struct timespec *time)
{
	res->tv_sec += time->tv_sec;
	res->tv_nsec += time->tv_nsec;
	if (res->tv_nsec >= NANO) {
		res->tv_nsec -= NANO;
		res->tv_sec++;
	}
}

static
void timespec_multiply(struct timespec *res, FLOAT factor)
{
	FLOAT val = res->tv_nsec * (1.0/(FLOAT)NANO) + res->tv_sec;
	val *= factor;
	res->tv_sec = floor(val);
	res->tv_nsec = floor((val - res->tv_sec) * NANO);
}

///////////////////////////////////////////////////////////////////////

struct verify_tag {
	long long tag_start;
	unsigned int tag_seqnr;
	unsigned int tag_write_seqnr;
	long long tag_len;
	long long tag_index;
};

struct request {
	struct verify_tag tag;
	struct timespec orig_stamp;
	struct timespec orig_factor_stamp;
	struct timespec replay_stamp;
	struct timespec replay_duration;
	long long seqnr;
	long long sector;
	int length;
	int verify_errors;
	int q_nr;
	char rwbs;
	char has_version;
	// starting from here, the rest is _not_ transferred over the pipelines
	struct request *next;
	unsigned int *old_version;
};
// the following reduces a potential space bottleneck on the answer pipe
#define RQ_SIZE (sizeof(struct request) - 2*sizeof(void*))

static struct request *rq_hash[RQ_HASH_MAX] = {};

#define rq_hash_fn(sector) (sector % RQ_HASH_MAX)

static
struct request *find_request_seq(long long sector, long long seqnr)
{
	struct request *rq = rq_hash[rq_hash_fn(sector)];
	while (rq && rq->seqnr != seqnr)
		rq = rq->next;
	return rq;
}

static
void add_request(struct request *rq)
{
	struct request **ptr = &rq_hash[rq_hash_fn(rq->sector)];
	rq->next = *ptr;
	*ptr = rq;
}

static
void del_request(long long sector, long long seqnr)
{
	struct request **ptr = &rq_hash[rq_hash_fn(sector)];
	struct request *found = NULL;
	while (*ptr && (*ptr)->seqnr != seqnr) {
		ptr = &(*ptr)->next;
	}
	if (*ptr && (*ptr)->sector == sector) {
		found = *ptr;
		*ptr = found->next;
		if (found->old_version) {
			free(found->old_version);
		}
		free(found);
	}
}

///////////////////////////////////////////////////////////////////////

/* Fast in-memory determination of conflicts.
 * Used in place of temporary files (where possible).
 */
#define FLY_HASH      2048
#define FLY_ZONE        64
#define FLY_HASH_FN(sector) (((sector) / FLY_ZONE) % FLY_HASH)
#define FLY_NEXT_ZONE(sector) (((sector / FLY_ZONE) + 1) * FLY_ZONE)

struct fly {
	struct fly *fl_next;
	long long   fl_sector;
	int         fl_len;
};

static struct fly *fly_hash_table[FLY_HASH];
static int fly_count = 0;

static
void fly_add(long long sector, int len)
{
	while (len > 0) {
		struct fly *new = malloc(sizeof(struct fly));
		int index = FLY_HASH_FN(sector);
		int max_len = FLY_NEXT_ZONE(sector) - sector;
		int this_len = len;
		if (this_len > max_len)
			this_len = max_len;

		if (!new) {
			printf("FATAL ERROR: out of memory for hashing\n");
			fflush(stdout);
			exit(-1);
		}
		new->fl_sector = sector;
		new->fl_len = this_len;
		new->fl_next = fly_hash_table[index];
		fly_hash_table[index] = new;
		fly_count++;

		sector += this_len;
		len -= this_len;
	}
}

static
int fly_check(long long sector, int len)
{
	while (len > 0) {
		struct fly *tmp = fly_hash_table[FLY_HASH_FN(sector)];
		int max_len = FLY_NEXT_ZONE(sector) - sector;
		int this_len = len;
		if (this_len > max_len)
			this_len = max_len;

		for (; tmp != NULL; tmp = tmp->fl_next) {
			if (sector + this_len > tmp->fl_sector && sector <= tmp->fl_sector + tmp->fl_len) {
				return 1;
			}
		}

		sector += this_len;
		len -= this_len;
	}
	return 0;
}

static
void fly_delete(long long sector, int len)
{
	while (len > 0) {
		struct fly **res = &fly_hash_table[FLY_HASH_FN(sector)];
		struct fly *tmp;
		int max_len = FLY_NEXT_ZONE(sector) - sector;
		int this_len = len;
		if (this_len > max_len)
			this_len = max_len;
		
		for (tmp = *res; tmp != NULL; res = &tmp->fl_next, tmp = *res) {
			if (tmp->fl_sector == sector && tmp->fl_len == this_len) {
				*res = tmp->fl_next;
				fly_count--;
				free(tmp);
				break;
			}
		}
		
		sector += this_len;
		len -= this_len;
	}
}

///////////////////////////////////////////////////////////////////////

// abstracting read() and write()

static
int do_read(void *buffer, int len)
{
	if (dry_run)
		return len;
	if (mmap_ptr) {
	}
	return read(main_fd, buffer, len);
}

static
int do_write(void *buffer, int len)
{
	if (dry_run)
		return len;
	if (mmap_ptr) {
	}
	return write(main_fd, buffer, len);
}

///////////////////////////////////////////////////////////////////////

// version number bookkeeping

static
unsigned int *get_blockversion(int fd, long long blocknr, int count)
{
	int status;
	void *data;
	int memlen = count * sizeof(unsigned int);
	struct timespec t0;
	struct timespec t1;
	struct timespec delay;

	if (!verify_mode)
		return NULL;

	clock_gettime(CLOCK_REALTIME, &t0);

	data = malloc(memlen);
	if (!data) {
		printf("FATAL ERROR: out of memory for hashing\n");
		fflush(stdout);
		verify_mode = 0;
		return NULL;
	}
	if (lseek64(fd, blocknr * sizeof(unsigned int), SEEK_SET) != blocknr * sizeof(unsigned int)) {
		printf("FATAL ERROR: llseek(%lld) in verify table failed %d (%s)\n", blocknr, errno, strerror(errno));
		fflush(stdout);
		verify_mode = 0;
		free(data);
		return NULL;
	}

	status = read(fd, data, memlen);

	clock_gettime(CLOCK_REALTIME, &t1);
	timespec_diff(&delay, &t0, &t1);
	timespec_add(&meta_delays, &delay);
	meta_delay_count++;

	if (status < 0) {
		printf("FATAL ERROR: read(%lld) from verify table failed %d %d (%s)\n", blocknr, status, errno, strerror(errno));
		fflush(stdout);
		verify_mode = 0;
		free(data);
		return NULL;
	}
	if (status < memlen) { // this may result from a sparse file
		memset(data+status, 0, memlen - status);
	}
	return data;
}

static
void put_blockversion(int fd, unsigned int *data, long long blocknr, int count)
{
	int status;
	struct timespec t0;
	struct timespec t1;
	struct timespec delay;

	if (!verify_mode)
		return;

	clock_gettime(CLOCK_REALTIME, &t0);

	if (lseek64(fd, blocknr * sizeof(unsigned int), SEEK_SET) != blocknr * sizeof(unsigned int)) {
		printf("FATAL ERROR: llseek(%lld) in verify table failed %d (%s)\n", blocknr, errno, strerror(errno));
		fflush(stdout);
		verify_mode = 0;
		return;
	}

	status = write(fd, data, count * sizeof(unsigned int));

	clock_gettime(CLOCK_REALTIME, &t1);
	timespec_diff(&delay, &t0, &t1);
	timespec_add(&meta_delays, &delay);
	meta_delay_count++;

	if (status < 0) {
		printf("FATAL ERROR: write to verify table failed %d (%s)\n", errno, strerror(errno));
		fflush(stdout);
		verify_mode = 0;
	}
}

static
void force_blockversion(int fd, unsigned int version, long long blocknr, int count)
{
	if (!verify_mode)
		return;
	{
		unsigned int data[count];
		int i;
		for (i = 0; i < count; i++)
			data[i] = version;
		put_blockversion(fd, data, blocknr, count);
	}
}

static
int compare_blockversion(unsigned int *a, unsigned int *b, int count)
{
	for (; count > 0; a++, b++, count--) {
		if (!*a)
			continue; // ignore
		if (!*b || *a > *b)
			return 1; // mismatch
	}
	return 0;
}

static
void advance_blockversion(unsigned int *data, int count, unsigned int version)
{
	for (; count > 0; data++, count--) {
		if (*data < version)
			*data = version;
	}
}

///////////////////////////////////////////////////////////////////////

// infrastructure for verify mode

static
void check_tags(struct request *rq, void *buffer, int len, int do_write)
{
	int i;
	char *mode = do_write ? "write" : "read";
	if (!verify_mode || !rq->old_version)
		return;
	for (i = 0; i < len; i += 512) {
		struct verify_tag *tag = buffer+i;
		if (!rq->old_version[i/512]) { // version not yet valid
			continue;
		}
		if (dry_run)
			continue;
		if (tag->tag_start != start_stamp.tv_sec) {
			printf("VERIFY ERROR (%s): bad start tag at sector %lld+%d (tag %lld != [expected] %ld)\n", mode, rq->sector, i/512, tag->tag_start, start_stamp.tv_sec);
			fflush(stdout);
			rq->verify_errors++;
			continue;
		}
		/* Only writes are fully protected from overlaps with other writes.
		 * Reads may overlap with concurrent writes to some degree.
		 * Therefore we check reads only for backslips in time
		 * (which never should happen).
		 */
		if ((do_write && tag->tag_write_seqnr != rq->old_version[i/512]) ||
		   tag->tag_write_seqnr < rq->old_version[i/512]) {
			printf("VERIFY ERROR (%s): data version mismatch at sector %lld+%d (seqnr %u != [expected] %u)\n", mode, rq->sector, i/512, tag->tag_write_seqnr, rq->old_version[i/512]);
			fflush(stdout);
			rq->verify_errors++;
			continue;
		}
	}
}

static
void make_tags(struct request *rq, void *buffer, int len)
{
	int i;

	// check old tag before overwriting
	if (verify_mode >= 1) {
		int status;
		status = do_read(buffer, len);
		if (status == len) {
			check_tags(rq, buffer, len, 1);
		}
		if (lseek64(main_fd, rq->sector * 512, SEEK_SET) != rq->sector * 512) {
			printf("ERROR: bad lseek at make_tags()\n");
			fflush(stdout);
		}
	}

	memset(buffer, 0, len);

	for (i = 0; i < len; i += 512) {
		struct verify_tag *tag = buffer+i;
		memcpy(tag, &rq->tag, sizeof(*tag));
		tag->tag_len = len;
		tag->tag_index = i;
	}
}

#define TAG_CHUNK (4096 * 1024 / sizeof(unsigned int))

static
void check_all_tags()
{
	long long blocknr = 0;
	int status;
	long long checked = 0;
	int i;
	unsigned int *table = NULL;
	unsigned int *table2 = NULL;
	void *buffer = NULL;
	struct verify_tag *tag;

	printf("checking all tags..........\n");
	fflush(stdout);

	if (posix_memalign((void**)&table, 4096, TAG_CHUNK) ||
	    posix_memalign((void**)&table2, 4096, TAG_CHUNK) ||
	    posix_memalign(&buffer, 512, 512)) {
		printf("FATAL ERROR: cannot allocate memory\n");
		fflush(stdout);
		exit(-1);
	}
	tag = buffer;

	lseek64(verify_fd, 0, SEEK_SET);
	lseek64(complete_fd, 0, SEEK_SET);

	for (;;) {
		status = read(verify_fd, table, TAG_CHUNK);
		if (!status)
			break;
		if (status < 0) {
			printf("ERROR: cannot read version table for block %lld: %d %s\n", blocknr, errno, strerror(errno));
			fflush(stdout);
			break;
		}
		status = read(complete_fd, table2, TAG_CHUNK);
		if (status <= 0) {
			printf("ERROR: cannot read completion table for block %lld: %d %s\n", blocknr, errno, strerror(errno));
			fflush(stdout);
			break;
		}

		for (i = 0; i < status / sizeof(unsigned int); i++, blocknr++) {
			unsigned int version = table[i];
			unsigned int version2;

			if (!version)
				continue;

			if (lseek64(main_fd, blocknr * 512, SEEK_SET) != blocknr * 512) {
				printf("ERROR: bad lseek in check_all_tags()\n");
				fflush(stdout);
			}
			if (do_read(buffer, 512) != 512) {
				printf("ERROR: bad read in check_all_tags(): %d %s\n", errno, strerror(errno));
				fflush(stdout);
			}
			checked++;
			version2 = table2[i];
			if (dry_run)
				continue;
			if (tag->tag_write_seqnr != version && tag->tag_write_seqnr != version2) {
				if (version != version2) {
					printf("VERIFY MISMATCH: at block %lld (%u != %u != %u)\n", blocknr, tag->tag_write_seqnr, version, version2);
					fflush(stdout);
					verify_mismatches++;
				} else {
					printf("VERIFY ERROR:    at block %lld (%u != [expected] %u)\n", blocknr, tag->tag_write_seqnr, version);
					fflush(stdout);
					verify_errors_after++;
				}
			}
		}
	}
	printf("SUMMARY: checked %lld / %lld blocks (%1.3f%%), found %lld errors, %lld mismatches\n", checked, max_size, 100.0 * (double)checked / (double)max_size, verify_errors_after, verify_mismatches);
	fflush(stdout);
	free(table);
	free(table2);
	free(buffer);
}

static
void paranoia_check(struct request *rq, void *buffer)
{
	int len = rq->length * 512;
	long long newpos = (long long)rq->sector * 512;
	int status2;
	void *buffer2 = NULL;
	struct verify_tag *tag = buffer;
	struct verify_tag *tag2;
	long long s_status;

	if (posix_memalign(&buffer2, 4096, len)) {
		printf("VERIFY ERROR: cannot allocate memory\n");
		fflush(stdout);
		rq->verify_errors++;
		goto done;
	}
	tag2 = buffer2;
	s_status = lseek64(main_fd, newpos, SEEK_SET);
	if (s_status != newpos) {
		printf("VERIFY ERROR: bad lseek64() %lld on main_fd=%d at pos %lld (%s) pid=%d\n", s_status, main_fd, rq->sector, strerror(errno), getpid());
		fflush(stdout);
		rq->verify_errors++;
		goto done;
	}
	status2 = do_read(buffer2, len);
	if (status2 != len) {
		printf("VERIFY ERROR: bad %cIO %d / %d on %d at pos %lld (%s)\n", rq->rwbs, status2, errno, main_fd, rq->sector, strerror(errno));
		fflush(stdout);
		rq->verify_errors++;
		goto done;
	}
	if (dry_run)
		goto done;
	if (memcmp(buffer, buffer2, len)) {
		printf("VERIFY ERROR: memcmp(): bad storage semantics at sector = %lld len = %d tag_start = %lld tag2_start = %lld\n", rq->sector, len, tag->tag_start, tag2->tag_start);
		fflush(stdout);
		rq->verify_errors++;
		goto done;
	}
done:
	free(buffer2);
}

///////////////////////////////////////////////////////////////////////

static
int similar_execute(struct request *rq)
{
	int len = rq->length * 512;
	long long newpos;
	long long s_status;

	if (main_fd < 0) {
		return -1;
	}
	if (rq->sector + rq->length >= main_size) {
		printf("ERROR: trying to position at %lld (main_size=%lld)\n", rq->sector, main_size);
		fflush(stdout);
	}
	if (fake_io)
		return 0;
	newpos = (long long)rq->sector * 512;
	s_status = lseek64(main_fd, newpos, SEEK_SET);
	if (s_status != newpos) {
		printf("ERROR: bad lseek64() %lld on main_fd=%d at pos %lld (%s) pid=%d\n", s_status, main_fd, rq->sector, strerror(errno), getpid());
		fflush(stdout);
		return -1;
	}
	{
		int status;
		void *buffer = NULL;
		if (posix_memalign(&buffer, 4096, len)) {
			printf("ERROR: cannot allocate memory\n");
			fflush(stdout);
			return -1;
		}
		if (rq->rwbs == 'W') {
			make_tags(rq, buffer, len);
			status = do_write(buffer, len);
			if (verify_mode >= 3 && status == len) { // additional re-read and verify
				paranoia_check(rq, buffer);
			}
		} else {
			status = do_read(buffer, len);
			check_tags(rq, buffer, len, 0);
		}
		free(buffer);
		if (status != len) {
			printf("ERROR: bad %cIO %d / %d on %d at pos %lld (%s)\n", rq->rwbs, status, errno, main_fd, rq->sector, strerror(errno));
			fflush(stdout);
			//exit(-1);
		}
	}
	return 0;
}


///////////////////////////////////////////////////////////////////////

// submitting requests over pipes

static
void pipe_write(int fd, void *data, int len)
{
	while (len > 0) {
		int status = write(fd, data, len);
		if (status > 0) {
			data += status;
			len -= status;
		} else {
			printf("FATAL ERROR: bad pipe write fd=%d status=%d (%d %s)\n", fd, status, errno, strerror(errno));
			fflush(stdout);
			exit(-1);
		}
	}
}

static
int pipe_read(int fd, void *data, int len)
{
	int status = read(fd, data, len);
	if (status < 0) {
		printf("FATAL ERROR: bad pipe read fd=%d status=%d (%d %s)\n", fd, status, errno, strerror(errno));
		fflush(stdout);
		exit(-1);
	}
	return status;
}

static
void submit_request(int fd, struct request *rq)
{
	pipe_write(fd, rq, RQ_SIZE);
	if (rq->has_version) {
		int size = rq->length * sizeof(unsigned int);
		pipe_write(fd, rq->old_version, size);
	}
}

static
int get_request(int fd, struct request *rq)
{
	int status = pipe_read(fd, rq, RQ_SIZE);
	if (status == RQ_SIZE && rq->has_version) {
		int size = rq->length * sizeof(unsigned int);
		rq->old_version = malloc(size);
		if (!rq->old_version) {
			printf("FATAL ERROR: out of memory\n");
			fflush(stdout);
			exit(-1);
		}
		pipe_read(fd, rq->old_version, size);
	}
	return status;
}

///////////////////////////////////////////////////////////////////////

// the pipes

static int queue[QUEUES][2];
static int answer[2];

static
void make_all_queues(int q[][2], int max)
{
	int i;
	for(i = 0; i < max; i++) {
		int status = pipe(q[i]);
		if (status < 0) {
			printf("FATAL ERROR: cannot create pipe %d\n", i);
			exit(-1);
		}
	}
}

static
void close_all_queues(int q[][2], int max, int i2, int except)
{
	int i;
	for(i = 0; i < max; i++) {
		if (i == except)
			continue;
		close(q[i][i2]);
	}
}

///////////////////////////////////////////////////////////////////////

static
void dump_request(struct request *rq)
{
	struct timespec delay;
	static int did_head = 0;
	if (!did_head) {
		printf("orig_start ; sector; length ; op ;  replay_delay; replay_duration\n");
		did_head++;
	}

	timespec_diff(&delay, &rq->orig_factor_stamp, &rq->replay_stamp);

	printf("%4lu.%09lu ; %10lld ; %3d ; %c ; %3lu.%09lu ; %3lu.%09lu\n",
	       rq->orig_factor_stamp.tv_sec,
	       rq->orig_factor_stamp.tv_nsec,
	       rq->sector,
	       rq->length,
	       rq->rwbs,

	       delay.tv_sec + replay_out,
	       delay.tv_nsec,

	       rq->replay_duration.tv_sec,
	       rq->replay_duration.tv_nsec);

	fflush(stdout);
	statist_completed++;
}

static
void do_done(struct request *old)
{
	dump_request(old);
	del_request(old->sector, old->seqnr);
}

static
int get_answer(void)
{
	struct request rq = {};
	int status;
	int res = 0;

#ifdef DEBUG_TIMING
	printf("get_answer\n");
#endif
	if (!already_forked)
		goto done;

	status = get_request(answer[0], &rq);
	if (status == RQ_SIZE) {
		struct request *old = find_request_seq(rq.sector, rq.seqnr);
		if (old) {
			memcpy(&old->replay_stamp, &rq.replay_stamp, sizeof(old->replay_stamp));
			memcpy(&old->replay_duration, &rq.replay_duration, sizeof(old->replay_duration));
			memcpy(&old->orig_factor_stamp, &rq.orig_factor_stamp, sizeof(old->orig_factor_stamp));
			do_done(old);
		} else {
			printf("ERROR: request %lld vanished\n", rq.sector);
		}
		if (rq.rwbs == 'W') {
			if (conflict_mode) {
				fly_delete(rq.sector, rq.length);
			}
			if (verify_mode) {
				unsigned int *data = get_blockversion(complete_fd, rq.sector, rq.length);
				advance_blockversion(data, rq.length, rq.tag.tag_write_seqnr);
      
				put_blockversion(complete_fd, data, rq.sector, rq.length);
			}
		}
		verify_errors += rq.verify_errors;
		count_completion--;
		res = 1;
	}

done:
#ifdef DEBUG_TIMING
	printf("aw=%d\n", res);
	fflush(stdout);
#endif
	return res;
}

///////////////////////////////////////////////////////////////////////

static
void do_wait(struct request *rq, struct timespec *now, int less_wait)
{
#ifdef DEBUG_TIMING
	printf("do_wait\n");
#endif

	for (;;) {
		struct timespec rest_wait = {};
		clock_gettime(CLOCK_REALTIME, now);
		timespec_diff(&rq->replay_stamp, &start_stamp, now);
		rq->replay_stamp.tv_sec -= 15; // grace period

		timespec_diff(&rest_wait, &rq->replay_stamp, &rq->orig_factor_stamp);

		rest_wait.tv_sec -= less_wait;


#ifdef DEBUG_TIMING
		printf("(%d) %d %lld.%09ld %lld.%09ld %lld.%09ld\n",
		       getpid(),
		       less_wait,
		       (long long)now->tv_sec,
		       now->tv_nsec,
		       (long long)rq->replay_stamp.tv_sec,
		       rq->replay_stamp.tv_nsec,
		       (long long)rest_wait.tv_sec,
		       rest_wait.tv_nsec);
		fflush(stdout);
#endif

		if ((long long)rest_wait.tv_sec < 0) {
			break;
		}

		nanosleep(&rest_wait, NULL);
	}
}

static
void do_action(struct request *rq)
{
	struct timespec t0 = {};
	struct timespec t1 = {};
	int code;

	do_wait(rq, &t0, 0);

	code = similar_execute(rq);

	clock_gettime(CLOCK_REALTIME, &t1);

	timespec_diff(&rq->replay_duration, &t0, &t1);
	(void)code; // shut up gcc
}

///////////////////////////////////////////////////////////////////////

static
void main_open(int again)
{
	long long size;
	int flags = O_RDWR | O_DIRECT;
	if (again || dry_run) {
		flags = O_RDONLY | O_DIRECT;
	}
#ifdef O_LARGEFILE
	flags |= O_LARGEFILE;
#endif
	main_fd = open(main_name, flags);
	if (main_fd < 0) {
		printf("ERROR: cannot open file '%s', errno = %d (%s)\n", main_name, errno, strerror(errno));
		exit(-1);
	}
	size = lseek64(main_fd, 0, SEEK_END);
	if (size <= 0) {
		printf("ERROR: cannot determine size of device (%d %s)\n", errno, strerror(errno));
		exit(-1);
	}
	if (!main_size) {
		main_size = size / 512;
		printf("INFO: device %s has %lld blocks (%lld kB).\n", main_name, main_size, main_size/2);
	}
}

static
char *mk_temp(const char *basename)
{
	char *tmpdir = getenv("TMPDIR");
	char *res = malloc(1024);
	int len;
	if (!res) {
		printf("FATAL ERROR: out of memory for tmp pathname\n");
		exit(-1);
	}
	if (!tmpdir)
		tmpdir = TMP_DIR;
	len = snprintf(res, 1024, "%s/blkreplay.%d/", tmpdir, getpid());
	(void)mkdir(res, 0700);
	snprintf(res + len, 1024 - len, "%s", basename);
	return res;
}

static
void verify_open(int again)
{
	int flags;

	if (!verify_mode)
		return;

	flags = O_RDWR | O_CREAT | O_TRUNC;
	if (again) {
		flags = O_RDONLY;
	}
#ifdef O_LARGEFILE
	flags |= O_LARGEFILE;
#endif
	if (verify_fd < 0) {
		char *file = getenv("VERIFY_TABLE");
		if (!file) {
			file = mk_temp(VERIFY_TABLE);
		}
		verify_fd = open(file, flags, S_IRUSR | S_IWUSR);
		if (verify_fd < 0) {
			printf("ERROR: cannot open '%s' (%d %s)\n", VERIFY_TABLE, errno, strerror(errno));
			fflush(stdout);
			verify_mode = 0;
		}
	}
	if (complete_fd < 0) {
		char *file = getenv("COMPLETION_TABLE");
		if (!file) {
			file = mk_temp(COMPLETION_TABLE);
		}
		complete_fd = open(file, flags, S_IRUSR | S_IWUSR);
		if (complete_fd < 0) {
			printf("ERROR: cannot open '%s' (%d %s)\n", COMPLETION_TABLE, errno, strerror(errno));
			fflush(stdout);
			verify_mode = 0;
		}
	}
}

///////////////////////////////////////////////////////////////////////

static
void do_worker(int in_fd, int back_fd)
{
	/* Each worker needs his own filehandle instance to avoid races
	 * between seek() and read()/write().
	 * So open it again.
	 */
	if (main_name && main_name[0]) {
		main_open(0);
	}
	for (;;) {
		struct request rq = {};
		int status = get_request(in_fd, &rq);
		if (!status)
			break;

		do_action(&rq);

		if (rq.old_version) {
			free(rq.old_version);
			rq.old_version = NULL;
		}
		rq.has_version = 0;

		submit_request(back_fd, &rq);
	}
	close(in_fd);
	close(back_fd);
}

/* Intermediate copy thread.
 * When too many threads are writing into the same pipe,
 * lock contention may put a serious limit onto overall
 * throughput.
 * In order to limit the fan-in / fan-out, we create intermediate
 * "distributor threads" limiting the maximum competition.
 */
static
void do_dispatcher_copy(int in_fd, int out_fd)
{
	for (;;) {
		struct request rq = {};
		int status = get_request(in_fd, &rq);
		if (!status)
			break;

		submit_request(out_fd, &rq);
	}
}

static
void _fork_answer_dispatcher()
{
	int old_answer_1 = answer[1];
	int status;
	pid_t pid;
				
	status = pipe(answer);
	if (status < 0) {
		printf("FATAL ERROR: cannot create sub-answer pipe\n");
		exit(-1);
	}
	
	pid = fork();
	if (pid < 0) {
		printf("FATAL ERROR: cannot fork\n");
		exit(-1);
	}
	if (!pid) { // son
		close(answer[1]);
		
		do_dispatcher_copy(answer[0], old_answer_1);
		
		exit(0);
	}
	close(old_answer_1);
}

/* Intermediate submit thread.
 * Also useful to reduce contention.
 * Necessary to distribute the requests to more than 1000 workers,
 * since the max number of filehandles / pipes is limited.
 */
static
void _fork_childs(int in_fd, int this_max)
{
	static int next_max[QUEUES] = {};
	int rest;
	int i;

	if (this_max <= 1 && in_fd >= 0) {
		do_worker(in_fd, answer[1]);
		return;
	}

	sub_max = fan_out;
	if (this_max < sub_max)
		sub_max = this_max;

	rest = this_max - ((this_max / sub_max) * sub_max);
	for (i = 0; i < sub_max; i++) {
		next_max[i] = this_max / sub_max;
		if (rest-- > 0)
			next_max[i]++;
	}

	make_all_queues(queue, sub_max);

	for (i = 0; i < sub_max; i++) {
		pid_t pid;

		pid = fork();
		if (pid < 0) {
			printf("FATAL ERROR: cannot fork\n");
			exit(-1);
		}
		if (!pid) { // son
			if (in_fd < 0)
				fclose(stdin);
			else
				close(answer[0]);
			close_all_queues(queue, sub_max, 0, i);
			close_all_queues(queue, sub_max, 1, -1);

			if (fork_dispatcher && in_fd >= 0) {
				_fork_answer_dispatcher();
			}

			_fork_childs(queue[i][0], next_max[i]);

			exit(0);
		}
	}

	close_all_queues(queue, sub_max, 0, -1);
	close(answer[1]);

	if (in_fd  < 0)
		return;

	for (;;) {
		struct request rq = {};
		int index;
		int status = get_request(in_fd, &rq);
		if (!status)
			break;

		index = rq.q_nr % sub_max;
		rq.q_nr /= sub_max;
		submit_request(queue[index][1], &rq);

		if (rq.old_version) {
			free(rq.old_version);
			rq.old_version = NULL;
		}
	}
}

static
void fork_childs()
{
	int status;

	if (already_forked)
		return;
	already_forked++;

	// setup pipes and fork()

	status = pipe(answer);
	if (status < 0) {
		printf("FATAL ERROR: cannot create answer pipe\n");
		exit(-1);
	}

	printf("forking %d child processes in total\n", total_max);
	fflush(stdout);

	_fork_childs(-1, total_max);

	printf("done forking (fan_out=%d)\n\n", sub_max);
	fflush(stdout);
}

///////////////////////////////////////////////////////////////////////

static
int execute(struct request *rq)
{
	static long long seqnr = 0;
	static long long write_seqnr = 0;
	int index;

	rq->q_nr = ++seqnr % total_max;
	if (!start_stamp.tv_sec) { // only upon first call
		// get start time, but only after opening everything, since open() may produce delays
		memcpy(&first_stamp, &rq->orig_stamp, sizeof(first_stamp));
		clock_gettime(CLOCK_REALTIME, &start_stamp);
		printf("tag_start = %ld\n", start_stamp.tv_sec);
		fflush(stdout);
		// effective only opon first call
		fork_childs();
	}

	// compute virtual start time
	timespec_diff(&rq->orig_factor_stamp, &first_stamp, &rq->orig_stamp);
	timespec_multiply(&rq->orig_factor_stamp, time_stretch);

	// generate write tag
	rq->tag.tag_start = start_stamp.tv_sec;
	rq->tag.tag_seqnr = seqnr;
	if (rq->old_version) {
		free(rq->old_version);
		rq->old_version = NULL;
	}

	if (verify_mode) {
		rq->old_version = get_blockversion(verify_fd, rq->sector, rq->length);
	}
	for (;;) {
		int status = 0;
		if (conflict_mode) {
			status = fly_check(rq->sector, rq->length);
		} else if (verify_mode) {
			unsigned int *now_version = get_blockversion(complete_fd, rq->sector, rq->length);
			status = compare_blockversion(rq->old_version, now_version, rq->length);
			free(now_version);
		}
		if (!status) { // no conflict
			break;
		}
		// well, we have a conflict.
		if (conflict_mode == 1) { // drop request
			printf("INFO: dropping block=%lld len=%d mode=%c\n", rq->sector, rq->length, rq->rwbs);
			fflush(stdout);
			statist_dropped++;
			return 0;
		}
		// wait until conflict has gone...
		if (count_completion) {
			get_answer();
			continue;
		}
		printf("FATAL ERROR: block %lld waiting for up-to-date version\n", rq->sector);
		exit(-1);
	}
	if (rq->rwbs == 'W') {
		if (conflict_mode)
			fly_add(rq->sector, rq->length);
		write_seqnr++;
		force_blockversion(verify_fd, write_seqnr, rq->sector, rq->length);
	}
	rq->tag.tag_write_seqnr = write_seqnr;
	rq->has_version = !!rq->old_version;

	// submit request to worker threads
	count_completion++;
	index = rq->q_nr % sub_max;
	rq->q_nr /= sub_max;
	submit_request(queue[index][1], rq);
	return 1;
}

static
int delay_distance(struct timespec *check)
{
	struct timespec now;
	struct timespec diff;

	if (!check->tv_sec)
		return 0;

	clock_gettime(CLOCK_REALTIME, &now);
	timespec_diff(&diff, &now, check);
	if ((long)diff.tv_sec >= 1)
		return 1;

	return 0;
}

static
void parse(FILE *inp)
{
	char buffer[4096];
	struct timespec old_stamp = {};
	struct request *rq = NULL;

	if (main_name && main_name[0]) { // just determine main_size
		main_open(0);
		close(main_fd);
		main_fd = -1;
	}
	verify_open(0);

	while (fgets(buffer, sizeof(buffer), inp)) {
		int count;

		statist_lines++;

		// avoid flooding the pipelines too much
		while (count_completion > bottleneck ||
		       (count_completion > 1 && delay_distance(&old_stamp))) {
			get_answer();
		}

		if (!rq)
			rq = malloc(sizeof(struct request));
		if (!rq) {
			printf("FATAL ERROR: out of memory for requests\n");
			fflush(stdout);
			exit(-1);
		}
		memset(rq, 0, sizeof(struct request));
		//count = sscanf(buffer, ": %c%c%c%c%c %lld %ld.%ld %lld %d", &rq->code, &dummy, rq->rwbs+0, rq->rwbs+1, rq->rwbs+2, &rq->seqnr, &rq->orig_stamp.tv_sec, &rq->orig_stamp.tv_nsec, &rq->sector, &rq->length);
		count = sscanf(buffer, "%ld.%ld ; %lld ; %d ; %c", &rq->orig_stamp.tv_sec, &rq->orig_stamp.tv_nsec, &rq->sector, &rq->length, &rq->rwbs);
		if (count != 5) {
			continue;
		}
		// treat backshifts in time (caused by repeated input files)
		timespec_add(&rq->orig_stamp, &timeshift);
		if (rq->orig_stamp.tv_sec < old_stamp.tv_sec) {
			struct timespec delta = {};
			timespec_diff(&delta, &rq->orig_stamp, &old_stamp);
			timespec_add(&timeshift, &delta);
			timespec_add(&rq->orig_stamp, &delta);
			printf("INFO: backshift in time at %ld.%09ld s detected (delta = %ld.%09ld s, total timeshift = %ld.%09ld s)\n", rq->orig_stamp.tv_sec, rq->orig_stamp.tv_nsec, delta.tv_sec, delta.tv_nsec, timeshift.tv_sec, timeshift.tv_nsec);
			fflush(stdout);
		}
		memcpy(&old_stamp, &rq->orig_stamp, sizeof(old_stamp));
		// check replay time window
		if (rq->orig_stamp.tv_sec < replay_start) {
			continue;
		}
		if (replay_end && rq->orig_stamp.tv_sec >= replay_end) {
			break;
		}
		if (rq->rwbs != 'R' && rq->rwbs != 'W') {
			printf("ERROR: bad character '%c'\n", rq->rwbs);
			continue;
		}

		rq->seqnr = ++statist_total;
		if (rq->rwbs == 'W')
			statist_writes++;

		if (rq->sector + rq->length > max_size)
			max_size = rq->sector + rq->length;

		if (rq->sector + rq->length > main_size && main_size) {
			if (!overflow) {
				printf("WARN: sector %lld+%d exceeds %lld, turning on wraparound.\n", rq->sector, rq->length, main_size);
				fflush(stdout);
				overflow++;
			}
			rq->sector %= main_size;
			if (rq->sector + rq->length > main_size) { // damn, it spans the border
				printf("WARN: cannot process sector %lld+%d at border %lld, please use a larger device\n", rq->sector, rq->length, main_size);
				fflush(stdout);
				continue;
			}
		}

		// add new element
		if (execute(rq))
			add_request(rq);
		rq = NULL;
	}

	printf("--------------------------------------\n");
	fflush(stdout);

	// close all pipes => leads to EOF at childs
	close_all_queues(queue, sub_max, 1, -1);

	printf("--------------------------------------\n");
	fflush(stdout);

	while (get_answer()) {
	}

	printf("=======================================\n\n");
	printf("meta_ops=%lld, total meta_delay=%lu.%09ld, avg=%lf\n",
	       meta_delay_count,
	       meta_delays.tv_sec,
	       meta_delays.tv_nsec,
	       meta_delay_count ? (meta_delays.tv_nsec * ((double)1.0/NANO) + (double)meta_delays.tv_sec) / meta_delay_count : 0);
	printf("# total input lines           : %6d\n", statist_lines);
	printf("# total     requests          : %6d\n", statist_total);
	printf("# write     requests          : %6d\n", statist_writes);
	printf("# completed requests          : %6d\n", statist_completed);
	printf("# dropped   requests          : %6d\n", statist_dropped);
	printf("# verify errors during replay : %6lld\n", verify_errors);
	printf("conflict_mode                 : %6d\n", conflict_mode);
	printf("verify_mode                   : %6d\n", verify_mode);
	if (fly_count)
		printf("fly_count                     : %6d\n", fly_count);
	printf("size of device:      %12lld blocks (%lld kB)\n", main_size, main_size/2);
	printf("max block# occurred: %12lld blocks (%lld kB)\n", max_size, max_size/2);
	printf("wraparound factor:   %6.3f\n", (double)max_size / (double)main_size);
	fflush(stdout);
}

///////////////////////////////////////////////////////////////////////

// arg parsing
// don't use GNU getopt, it's not available everywhere

struct arg {
	char *arg_name;
	char *arg_descr;
	int   arg_const;
	int  *arg_val_int;
	FLOAT*arg_val_float;
};

static
const struct arg arg_table[] = {
	{
		.arg_name  = "|",
		.arg_descr = "Influence replay duration:",
	},
	{
		.arg_name  = "replay-start",
		.arg_descr = "start offset (in seconds, 0=from_start)",
		.arg_const = -1,
		.arg_val_int = &replay_start,
	},
	{
		.arg_name  = "replay-end",
		.arg_descr = "end offset (in seconds, 0=unlimited)",
		.arg_const = -1,
		.arg_val_int = &replay_end,
	},
	{
		.arg_name  = "replay-duration",
		.arg_descr = "alternatively specify the end offset as delta",
		.arg_const = -1,
		.arg_val_int = &replay_duration,
	},
	{
		.arg_name  = "replay-out",
		.arg_descr = "start offset, used for output (in seconds)",
		.arg_const = -1,
		.arg_val_int = &replay_out,
	},


	{
		.arg_name  = "|",
		.arg_descr = "Handling of conflicting IO requests:",
	},
	{
		.arg_name  = "with-conflicts",
		.arg_descr = "conflicting writes are ALLOWED (damaged IO)",
		.arg_const = 0,
		.arg_val_int = &conflict_mode,
	},
	{
		.arg_name  = "with-drop",
		.arg_descr = "conflicting writes are simply dropped",
		.arg_const = 1,
		.arg_val_int = &conflict_mode,
	},
	{
		.arg_name  = "with-ordering",
		.arg_descr = "enforce total order in case of conflicts",
		.arg_const = 2,
		.arg_val_int = &conflict_mode,
	},



	{
		.arg_name  = "|",
		.arg_descr = "Replay parameters:",
	},
	{
		.arg_name  = "threads",
		.arg_descr = "parallelism (default=" STRINGIFY(DEFAULT_THREADS) ")",
		.arg_const = -1,
		.arg_val_int = &total_max,
	},



	{
		.arg_name  = "|",
		.arg_descr = "Verification modes:",
	},
	{
		.arg_name  = "no-overhead",
		.arg_descr = "verify is OFF (default)",
		.arg_const = 0,
		.arg_val_int = &verify_mode,
	},
	{
		.arg_name  = "with-verify",
		.arg_descr = "verify on reads",
		.arg_const = 1,
		.arg_val_int = &verify_mode,
	},
	{
		.arg_name  = "with-final-verify",
		.arg_descr = "additional verify pass at the end",
		.arg_const = 2,
		.arg_val_int = &verify_mode,
	},
	{
		.arg_name  = "with-paranoia",
		.arg_descr = "re-read after each write (destroys performance)",
		.arg_const = 3,
		.arg_val_int = &verify_mode,
	},



	{
		.arg_name  = "|",
		.arg_descr = "Expert options (DANGEROUS):",
	},
	{
		.arg_name  = "dry-run",
		.arg_descr = "don't actually do IO, measure internal overhead",
		.arg_const = 1,
		.arg_val_int = &dry_run,
	},
	{
		.arg_name  = "fake-io",
		.arg_descr = "omit lseek() and tags, even less internal overhead",
		.arg_const = 1,
		.arg_val_int = &fake_io,
	},
	{
		.arg_name  = "fan-out",
		.arg_descr = "only for kernel hackers (default=" STRINGIFY(DEFAULT_FAN_OUT) ")",
		.arg_const = -1,
		.arg_val_int = &fan_out,
	},
	{
		.arg_name  = "no-dispatcher",
		.arg_descr = "only for kernel hackers",
		.arg_const = 0,
		.arg_val_int = &fork_dispatcher,
	},
	{
		.arg_name  = "bottleneck",
		.arg_descr = "max #requests on dispatch",
		.arg_const = -1,
		.arg_val_int = &bottleneck,
	},
	{
		.arg_name  = "speedup",
		.arg_descr = "speedup / slowdown by REAL factor (default=" STRINGIFY(DEFAULT_SPEEDUP) ")",
		.arg_const = -1,
		.arg_val_float = &time_factor,
	},
	{
		.arg_name  = "mmap-mode",
		.arg_descr = "use mmap() instead of read() / write() [NYI]",
		.arg_const = 1,
		.arg_val_int = &mmap_mode,
	},
	{}
};

static
void usage(void)
{
	const struct arg *tmp;

	printf("usage: blkreplay {--<option>[=<value>]} <device>\n");

	for (tmp = arg_table; tmp->arg_name; tmp++) {
		int len;

		if (tmp->arg_name[0] == '|') {
			printf("\n%s\n", tmp->arg_descr);
			continue;
		}

		len = strlen(tmp->arg_name);
		printf("  --%s", tmp->arg_name);
		if (tmp->arg_const < 0) {
			printf("=<val>");
			len += 6;
		}
		while (len++ < 21) {
			printf(" ");
		}
		printf(" %s\n", tmp->arg_descr);
	}
	exit(-1);
}

static
void parse_args(int argc, char *argv[])
{
	int i;

	for (i = 1; i < argc; i++) {
		char *this = argv[i];
		const struct arg *tmp;
		int count = 1;

		if (this[0] != '-') {
			if (main_name) {
				printf("<device> must not be set twice\n");
				usage();
			}
			main_name = this;
			continue;
		}
		this++;
		if (this[0] != '-') {
			printf("only double options starting with -- are allowed\n");
			usage();
		}
		this++;
		for (tmp = arg_table; tmp->arg_name; tmp++) {
			int len = strlen(tmp->arg_name);
			if (!strncmp(tmp->arg_name, this, len)) {
				this += len;
				break;
			}
		}

		if (!tmp->arg_name) {
			printf("unknown option '%s'\n", this);
			usage();
		}

		if (tmp->arg_const >= 0) {
			*tmp->arg_val_int = tmp->arg_const;
			continue;
		}

		while (*this == ' ')
			this++;
		if (*this == '=')
			this++;

		if (tmp->arg_val_int)
			count = sscanf(this, "%d", tmp->arg_val_int);
		else
			*tmp->arg_val_float = atof(this);
		if (count != 1) {
			printf("cannot parse <val> '%s'\n", this);
			usage();
		}
	}

	if (!main_name) {
		printf("you forgot to provide a <device>\n");
		usage();
	}
}

int main(int argc, char *argv[])
{
	time_t now = time(NULL);
	/* avoid zombies */
	signal(SIGCHLD, SIG_IGN);

	/* argument parsing */
	parse_args(argc, argv);

	if (verify_mode >= 2)
		final_verify_mode++;

	if (total_max > MAX_THREADS)
		total_max = MAX_THREADS;
	if (total_max < 1)
		total_max = 1;
	if (fan_out < 2)
		fan_out = 2;
	if (fan_out > QUEUES)
		fan_out = QUEUES;
	if (bottleneck <= 0)
		bottleneck = total_max * FILL_FACTOR;
	if (replay_duration > 0)
		replay_end = replay_start + replay_duration;

	if (fake_io)
		dry_run = 1;
	if (dry_run) {
		printf("INFO: this is a DRY_RUN!!!!!!!!!\n"
		       "INFO: measurements results are FAKE results!\n"
		       "\n"
		       );
	}

	if (time_factor != 0.0) {
		time_stretch = 1.0 / time_factor;

		/* Notice: the following GNU all-permissive license applies
		 * to the generated DATA file only, and does not change
		 * the GPL of this program.
		 */

		printf(
			"Copyright Thomas Schoebel-Theuer, sponsored by 1&1 Internet AG\n"
			"\n"
			"This file was automatically generated by blkreplay\n"
			"\n"
			"Copying and distribution of this file, with or without modification,\n"
			"are permitted in any medium without royalty provided the copyright\n"
			"notice and this notice are preserved.  This file is offered as-is,\n"
			"without any warranty.\n"
			"\n"
			"\n"
			"blkreplay on %s started at %s\n"
			"\n",
			main_name,
			ctime(&now));

		parse(stdin);

		printf("blkreplay on %s ended at %s\n",
		       main_name,
		       ctime(&now));
		fflush(stdout);
	}

	// verify the end result
	if (final_verify_mode) {
		printf("-------------------------------\n");
		printf("verifying the end result.......\n");
		fflush(stdout);
		verify_open(1);
		main_open(1);
		sleep(3);
		check_all_tags();
	}

	if (dry_run) {
		printf("\n"
		       "INFO: this was a DRY_RUN!!!!!!!!!\n"
		       "INFO: measurements results are FAKE results!\n"
		       );
	}

	return 0;
}
