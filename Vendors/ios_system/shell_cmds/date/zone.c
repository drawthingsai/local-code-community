/*
 * Time zones for date(1) that do not go through the process-wide TZ.
 *
 * Sessions run date concurrently with different TZ values, while libc's
 * localtime(3) and mktime(3) read the one process environment. This reads
 * the same TZif files and POSIX TZ strings libc does and converts with an
 * explicit zone.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "zone.h"

enum { ABBREVIATION_SIZE = 16 };

struct zone_type {
	int32_t gmtoff;
	int isdst;
	char abbreviation[ABBREVIATION_SIZE];
};

struct zone_rule {
	char kind;		/* 'J' (1-365, no leap day), 'D' (0-365), 'M' */
	int day, week, month;
	int32_t time;		/* seconds after local midnight */
};

struct date_zone {
	int64_t *transitions;
	unsigned char *indices;
	size_t count;
	struct zone_type *types;
	size_t type_count;
	/* POSIX rule for times after the table, or for the whole zone. */
	int has_rule;
	struct zone_type standard, daylight;
	int has_daylight;
	struct zone_rule start, end;
	int empty;		/* TZ="": tzcode's UTC without a type table */
};

static const char *const zone_directories[] = {
	"/var/db/timezone/zoneinfo",
	"/usr/share/zoneinfo",
};

static int64_t
read_be(const unsigned char *p, int size)
{
	uint64_t value = 0;
	for (int i = 0; i < size; i++)
		value = value << 8 | p[i];
	if (size == 4)
		return (int32_t)(uint32_t)value;
	return (int64_t)value;
}

/* POSIX TZ strings (tzset(3)): std offset [dst [offset] [,rule,rule]]. */

static const char *
parse_name(const char *p, char *name)
{
	const char *start = p;
	size_t length;

	if (*p == '<') {
		start = ++p;
		while (*p != '\0' && *p != '>')
			p++;
		if (*p != '>')
			return (NULL);
		length = p - start;
		p++;
	} else {
		while ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z'))
			p++;
		length = p - start;
	}
	if (length < 3 || length >= ABBREVIATION_SIZE)
		return (NULL);
	memcpy(name, start, length);
	name[length] = '\0';
	return (p);
}

static const char *
parse_number(const char *p, int *value, int max)
{
	int n = 0;

	if (*p < '0' || *p > '9')
		return (NULL);
	while (*p >= '0' && *p <= '9') {
		n = n * 10 + (*p++ - '0');
		if (n > max)
			return (NULL);
	}
	*value = n;
	return (p);
}

/* [+-]hh[:mm[:ss]] as seconds. */
static const char *
parse_time(const char *p, int32_t *seconds, int max_hours)
{
	int sign = 1, hours, minutes = 0, secs = 0;

	if (*p == '-' || *p == '+')
		sign = *p++ == '-' ? -1 : 1;
	if ((p = parse_number(p, &hours, max_hours)) == NULL)
		return (NULL);
	if (*p == ':') {
		if ((p = parse_number(p + 1, &minutes, 59)) == NULL)
			return (NULL);
		if (*p == ':' && (p = parse_number(p + 1, &secs, 60)) == NULL)
			return (NULL);
	}
	*seconds = sign * (hours * 3600 + minutes * 60 + secs);
	return (p);
}

static const char *
parse_rule(const char *p, struct zone_rule *rule)
{
	if (*p == 'J') {
		rule->kind = 'J';
		if ((p = parse_number(p + 1, &rule->day, 365)) == NULL || rule->day < 1)
			return (NULL);
	} else if (*p == 'M') {
		rule->kind = 'M';
		if ((p = parse_number(p + 1, &rule->month, 12)) == NULL || rule->month < 1 ||
		    *p++ != '.' || (p = parse_number(p, &rule->week, 5)) == NULL ||
		    rule->week < 1 || *p++ != '.' ||
		    (p = parse_number(p, &rule->day, 6)) == NULL)
			return (NULL);
	} else {
		rule->kind = 'D';
		if ((p = parse_number(p, &rule->day, 365)) == NULL)
			return (NULL);
	}
	rule->time = 2 * 3600;
	if (*p == '/' && (p = parse_time(p + 1, &rule->time, 167)) == NULL)
		return (NULL);
	return (p);
}

static int
parse_posix(struct date_zone *zone, const char *p)
{
	int32_t offset;

	memset(&zone->standard, 0, sizeof(zone->standard));
	memset(&zone->daylight, 0, sizeof(zone->daylight));
	zone->has_daylight = 0;
	if ((p = parse_name(p, zone->standard.abbreviation)) == NULL ||
	    (p = parse_time(p, &offset, 24)) == NULL)
		return (-1);
	zone->standard.gmtoff = -offset;
	if (*p != '\0') {
		if ((p = parse_name(p, zone->daylight.abbreviation)) == NULL)
			return (-1);
		zone->daylight.gmtoff = zone->standard.gmtoff + 3600;
		zone->daylight.isdst = 1;
		if (*p != '\0' && *p != ',') {
			if ((p = parse_time(p, &offset, 24)) == NULL)
				return (-1);
			zone->daylight.gmtoff = -offset;
		}
		/* tzcode's default rule when a daylight zone has none. */
		if (*p == '\0')
			p = ",M3.2.0,M11.1.0";
		if (*p++ != ',' || (p = parse_rule(p, &zone->start)) == NULL ||
		    *p++ != ',' || (p = parse_rule(p, &zone->end)) == NULL)
			return (-1);
		zone->has_daylight = 1;
	}
	if (*p != '\0')
		return (-1);
	zone->has_rule = 1;
	return (0);
}

static int
load_file(struct date_zone *zone, const char *path)
{
	unsigned char *data = NULL;
	size_t size = 0, capacity = 0;
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	int result = -1;

	if (fd < 0)
		return (-1);
	for (;;) {
		if (size == capacity) {
			unsigned char *grown;
			capacity = capacity ? capacity * 2 : 8192;
			if (capacity > (1 << 20) || (grown = realloc(data, capacity)) == NULL)
				goto out;
			data = grown;
		}
		ssize_t n = read(fd, data + size, capacity - size);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0)
			goto out;
		if (n == 0)
			break;
		size += n;
	}

	const unsigned char *p = data, *end = data + size;
	int time_size = 4;
	for (int pass = 0; pass < 2; pass++) {
		if (end - p < 44 || memcmp(p, "TZif", 4) != 0)
			goto out;
		char version = p[4];
		size_t isutcnt = read_be(p + 20, 4), isstdcnt = read_be(p + 24, 4);
		size_t leapcnt = read_be(p + 28, 4), timecnt = read_be(p + 32, 4);
		size_t typecnt = read_be(p + 36, 4), charcnt = read_be(p + 40, 4);
		size_t length = timecnt * time_size + timecnt + typecnt * 6 + charcnt +
		    leapcnt * (time_size + 4) + isstdcnt + isutcnt;
		p += 44;
		if ((size_t)(end - p) < length || typecnt == 0)
			goto out;
		if (pass == 0 && version >= '2') {
			/* Skip the 32-bit data for the 64-bit copy that follows. */
			p += length;
			time_size = 8;
			continue;
		}
		zone->transitions = calloc(timecnt + 1, sizeof(*zone->transitions));
		zone->indices = calloc(timecnt + 1, 1);
		zone->types = calloc(typecnt, sizeof(*zone->types));
		if (zone->transitions == NULL || zone->indices == NULL || zone->types == NULL)
			goto out;
		for (size_t i = 0; i < timecnt; i++)
			zone->transitions[i] = read_be(p + i * time_size, time_size);
		p += timecnt * time_size;
		for (size_t i = 0; i < timecnt; i++) {
			if (p[i] >= typecnt)
				goto out;
			zone->indices[i] = p[i];
		}
		p += timecnt;
		const unsigned char *types = p, *chars = p + typecnt * 6;
		for (size_t i = 0; i < typecnt; i++) {
			struct zone_type *type = &zone->types[i];
			size_t index = types[i * 6 + 5];
			type->gmtoff = (int32_t)read_be(types + i * 6, 4);
			type->isdst = types[i * 6 + 4] != 0;
			if (index < charcnt) {
				size_t n = strnlen((const char *)chars + index, charcnt - index);
				if (n >= ABBREVIATION_SIZE)
					n = ABBREVIATION_SIZE - 1;
				memcpy(type->abbreviation, chars + index, n);
			}
		}
		zone->count = timecnt;
		zone->type_count = typecnt;
		p += length - timecnt * time_size - timecnt;
		/* Version 2+ footer: "\n" POSIX TZ "\n" for later times. */
		if (time_size == 8 && p < end && *p == '\n') {
			const unsigned char *newline = memchr(p + 1, '\n', end - p - 1);
			if (newline != NULL && newline > p + 1) {
				char rule[128];
				size_t n = newline - p - 1;
				if (n < sizeof(rule)) {
					struct date_zone footer = {0};
					memcpy(rule, p + 1, n);
					rule[n] = '\0';
					if (parse_posix(&footer, rule) == 0) {
						zone->has_rule = 1;
						zone->standard = footer.standard;
						zone->daylight = footer.daylight;
						zone->has_daylight = footer.has_daylight;
						zone->start = footer.start;
						zone->end = footer.end;
					}
				}
			}
		}
		result = 0;
		break;
	}
out:
	free(data);
	close(fd);
	return (result);
}

struct date_zone *
date_zone_load(const char *tz)
{
	struct date_zone *zone = calloc(1, sizeof(*zone));
	char path[PATH_MAX];

	if (zone == NULL)
		return (NULL);
	if (tz == NULL) {
		if (load_file(zone, "/etc/localtime") == 0)
			return (zone);
		tz = "";
	}
	const char *name = *tz == ':' ? tz + 1 : tz;
	if (*name != '\0' && strstr(name, "..") == NULL) {
		if (*name == '/') {
			if (load_file(zone, name) == 0)
				return (zone);
		} else {
			for (size_t i = 0; i < sizeof(zone_directories) / sizeof(*zone_directories); i++) {
				if (snprintf(path, sizeof(path), "%s/%s", zone_directories[i], name) <
				    (int)sizeof(path) && load_file(zone, path) == 0)
					return (zone);
			}
		}
	}
	date_zone_free(zone);
	if ((zone = calloc(1, sizeof(*zone))) == NULL)
		return (NULL);
	if (*name == '\0' || parse_posix(zone, name) != 0) {
		/* Like tzcode: an empty or unusable TZ is UTC. */
		memset(zone, 0, sizeof(*zone));
		zone->has_rule = 1;
		zone->empty = *name == '\0';
		strlcpy(zone->standard.abbreviation, "UTC", sizeof(zone->standard.abbreviation));
	}
	return (zone);
}

void
date_zone_free(struct date_zone *zone)
{
	if (zone == NULL)
		return;
	free(zone->transitions);
	free(zone->indices);
	free(zone->types);
	free(zone);
}

static int
is_leap(int64_t year)
{
	return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
}

/* Seconds from local midnight, January 1, to the rule's moment in year. */
static int64_t
rule_offset(const struct zone_rule *rule, int64_t year)
{
	static const int month_days[2][12] = {
		{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31},
		{31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31},
	};
	int leap = is_leap(year);
	int64_t day;

	if (rule->kind == 'J') {
		day = rule->day - 1;
		if (leap && rule->day >= 60)
			day++;
	} else if (rule->kind == 'D') {
		day = rule->day;
	} else {
		int64_t first = 0;
		for (int m = 0; m < rule->month - 1; m++)
			first += month_days[leap][m];
		/* Zeller-free weekday: January 1, 1970 was a Thursday (4). */
		int64_t days = 0;
		struct tm jan1 = {.tm_year = (int)(year - 1900), .tm_mday = 1};
		days = timegm(&jan1) / 86400;
		int weekday = (int)(((days + first) % 7 + 11) % 7);	/* (4 + n) mod 7 */
		int64_t date = (rule->day - weekday + 7) % 7;
		for (int w = 1; w < rule->week; w++) {
			if (date + 7 >= month_days[leap][rule->month - 1])
				break;
			date += 7;
		}
		day = first + date;
	}
	return (day * 86400 + rule->time);
}

static const struct zone_type *
rule_type(const struct date_zone *zone, time_t t)
{
	if (!zone->has_daylight)
		return (&zone->standard);
	time_t local = t + zone->standard.gmtoff;
	struct tm tm;
	if (gmtime_r(&local, &tm) == NULL)
		return (&zone->standard);
	int64_t year = tm.tm_year + 1900LL;
	/* Like tzcode, a TZ string's transitions begin in 1970. */
	if (zone->count == 0 && year < 1970)
		return (&zone->standard);
	struct tm jan1 = {.tm_year = tm.tm_year, .tm_mday = 1};
	int64_t base = timegm(&jan1);
	int64_t start = base + rule_offset(&zone->start, year) - zone->standard.gmtoff;
	int64_t end = base + rule_offset(&zone->end, year) - zone->daylight.gmtoff;
	if (zone->count == 0 && year == 1970 && t < (start < end ? start : end))
		return (&zone->standard);
	int daylight = start < end ? (t >= start && t < end) : !(t >= end && t < start);
	return (daylight ? &zone->daylight : &zone->standard);
}

static const struct zone_type *
type_at(const struct date_zone *zone, time_t t)
{
	if (zone->has_rule && (zone->count == 0 || t >= zone->transitions[zone->count - 1]))
		return (rule_type(zone, t));
	if (zone->count == 0 || t < zone->transitions[0]) {
		/* Before the first transition: the first standard-time type. */
		for (size_t i = 0; i < zone->type_count; i++)
			if (!zone->types[i].isdst)
				return (&zone->types[i]);
		return (&zone->types[0]);
	}
	size_t low = 0, high = zone->count;
	while (high - low > 1) {
		size_t middle = low + (high - low) / 2;
		if (t >= zone->transitions[middle])
			low = middle;
		else
			high = middle;
	}
	return (&zone->types[zone->indices[low]]);
}

struct tm *
date_localtime(const struct date_zone *zone, const time_t *clock, struct tm *result)
{
	const struct zone_type *type = type_at(zone, *clock);
	time_t local = *clock + type->gmtoff;

	if (gmtime_r(&local, result) == NULL)
		return (NULL);
	result->tm_isdst = type->isdst;
	result->tm_gmtoff = type->gmtoff;
	result->tm_zone = (char *)type->abbreviation;
	return (result);
}

/*
 * mktime(3) as Darwin's tzcode does it (stdtime/FreeBSD/localtime.c: time1,
 * time2, time2sub with __DARWIN_UNIX03 and PCTS), so results match libc's for
 * the same TZ, including for skipped and repeated wall-clock times.
 */

enum { MAX_TYPES = 256 };

/* The zone's types in tzcode's table order, and in most-recent-use order. */
struct type_table {
	const struct zone_type *types[MAX_TYPES];
	size_t count;
	const struct zone_type *recent[MAX_TYPES];
	size_t recent_count;
};

static void
add_type(struct type_table *table, const struct zone_type *type)
{
	for (size_t i = 0; i < table->count; i++)
		if (table->types[i]->gmtoff == type->gmtoff && table->types[i]->isdst == type->isdst &&
		    strcmp(table->types[i]->abbreviation, type->abbreviation) == 0)
			return;
	if (table->count < MAX_TYPES)
		table->types[table->count++] = type;
}

static void
type_table(const struct date_zone *zone, struct type_table *table)
{
	table->count = table->recent_count = 0;
	if (zone->empty)
		return;
	if (zone->type_count > 0) {
		for (size_t i = 0; i < zone->type_count; i++)
			add_type(table, &zone->types[i]);
		if (zone->has_rule) {
			add_type(table, &zone->standard);
			if (zone->has_daylight)
				add_type(table, &zone->daylight);
		}
		int seen[MAX_TYPES] = {0};
		for (size_t i = zone->count; i-- > 0;) {
			size_t index = zone->indices[i];
			if (!seen[index] && table->recent_count < MAX_TYPES) {
				seen[index] = 1;
				table->recent[table->recent_count++] = &zone->types[index];
			}
		}
		return;
	}
	/* A TZ string: tzparse's [dst, std], transitions from 1970 on. */
	if (zone->has_daylight) {
		table->types[table->count++] = &zone->daylight;
		table->types[table->count++] = &zone->standard;
		struct tm jan1 = {.tm_year = 2037 - 1900, .tm_mday = 1};
		int64_t base = timegm(&jan1);
		int64_t start = base + rule_offset(&zone->start, 2037) - zone->standard.gmtoff;
		int64_t end = base + rule_offset(&zone->end, 2037) - zone->daylight.gmtoff;
		const struct zone_type *last = start < end ? &zone->standard : &zone->daylight;
		table->recent[table->recent_count++] = last;
		table->recent[table->recent_count++] = last == &zone->standard ? &zone->daylight : &zone->standard;
	} else {
		table->types[table->count++] = &zone->standard;
	}
}

static int
increment_overflow(int *number, int delta)
{
	int number0 = *number;
	*number += delta;
	return ((*number < number0) != (delta < 0));
}

static int
long_increment_overflow(long *number, int delta)
{
	long number0 = *number;
	*number += delta;
	return ((*number < number0) != (delta < 0));
}

static int
normalize_overflow(int *tensptr, int *unitsptr, int base)
{
	int tensdelta = *unitsptr >= 0 ? *unitsptr / base : -1 - (-1 - *unitsptr) / base;
	*unitsptr -= tensdelta * base;
	return (increment_overflow(tensptr, tensdelta));
}

static int
long_normalize_overflow(long *tensptr, int *unitsptr, int base)
{
	int tensdelta = *unitsptr >= 0 ? *unitsptr / base : -1 - (-1 - *unitsptr) / base;
	*unitsptr -= tensdelta * base;
	return (long_increment_overflow(tensptr, tensdelta));
}

static int
tmcomp(const struct tm *a, const struct tm *b)
{
	int result;

	if (a->tm_year != b->tm_year)
		return (a->tm_year > b->tm_year ? 1 : -1);
	if ((result = a->tm_mon - b->tm_mon) == 0 &&
	    (result = a->tm_mday - b->tm_mday) == 0 &&
	    (result = a->tm_hour - b->tm_hour) == 0 &&
	    (result = a->tm_min - b->tm_min) == 0)
		result = a->tm_sec - b->tm_sec;
	return (result);
}

static time_t
time2sub(const struct date_zone *zone, const struct type_table *table, struct tm *tmp,
    int *okayp, int do_norm_secs)
{
	static const int mon_lengths[2][12] = {
		{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31},
		{31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31},
	};
	static const int year_lengths[2] = {365, 366};
	struct tm yourtm = *tmp, mytm;
	int dir, saved_seconds;
	long li, y;
	time_t lo, hi, newt, t;

	*okayp = 0;
	if (do_norm_secs && normalize_overflow(&yourtm.tm_min, &yourtm.tm_sec, 60))
		return (-1);
	if (normalize_overflow(&yourtm.tm_hour, &yourtm.tm_min, 60) ||
	    normalize_overflow(&yourtm.tm_mday, &yourtm.tm_hour, 24))
		return (-1);
	y = yourtm.tm_year;
	if (long_normalize_overflow(&y, &yourtm.tm_mon, 12) || long_increment_overflow(&y, 1900))
		return (-1);
	while (yourtm.tm_mday <= 0) {
		if (long_increment_overflow(&y, -1))
			return (-1);
		li = y + (1 < yourtm.tm_mon);
		yourtm.tm_mday += year_lengths[is_leap(li)];
	}
	while (yourtm.tm_mday > 366) {
		li = y + (1 < yourtm.tm_mon);
		yourtm.tm_mday -= year_lengths[is_leap(li)];
		if (long_increment_overflow(&y, 1))
			return (-1);
	}
	for (;;) {
		int i = mon_lengths[is_leap(y)][yourtm.tm_mon];
		if (yourtm.tm_mday <= i)
			break;
		yourtm.tm_mday -= i;
		if (++yourtm.tm_mon >= 12) {
			yourtm.tm_mon = 0;
			if (long_increment_overflow(&y, 1))
				return (-1);
		}
	}
	if (long_increment_overflow(&y, -1900))
		return (-1);
	yourtm.tm_year = (int)y;
	if (yourtm.tm_year != y || yourtm.tm_year < 0)
		return (-1);
	if (yourtm.tm_sec >= 0 && yourtm.tm_sec < 60) {
		saved_seconds = 0;
	} else if (y + 1900 < 1970) {
		if (increment_overflow(&yourtm.tm_sec, 1 - 60))
			return (-1);
		saved_seconds = yourtm.tm_sec;
		yourtm.tm_sec = 60 - 1;
	} else {
		saved_seconds = yourtm.tm_sec;
		yourtm.tm_sec = 0;
	}
	lo = INT64_MIN;
	hi = INT64_MAX;
	for (;;) {
		t = lo / 2 + hi / 2;
		if (t < lo)
			t = lo;
		else if (t > hi)
			t = hi;
		if (date_localtime(zone, &t, &mytm) == NULL)
			dir = t > 0 ? 1 : -1;
		else
			dir = tmcomp(&mytm, &yourtm);
		if (dir != 0) {
			if (t == lo) {
				++t;
				if (t <= lo)
					return (-1);
				++lo;
			} else if (t == hi) {
				--t;
				if (t >= hi)
					return (-1);
				--hi;
			}
			if (lo > hi)
				return (-1);
			if (dir > 0)
				hi = t;
			else
				lo = t;
			continue;
		}
		if (table->count == 1 && yourtm.tm_isdst > 0)
			yourtm.tm_isdst = 0;	/* alternative time does not apply */
		if (yourtm.tm_isdst < 0 || mytm.tm_isdst == yourtm.tm_isdst)
			break;
		/* Right time, wrong type: hunt for right time, right type. */
		for (size_t i = table->count; i-- > 0;) {
			if (table->types[i]->isdst != yourtm.tm_isdst)
				continue;
			for (size_t j = table->count; j-- > 0;) {
				if (table->types[j]->isdst == yourtm.tm_isdst)
					continue;
				newt = t + table->types[j]->gmtoff - table->types[i]->gmtoff;
				if (date_localtime(zone, &newt, &mytm) == NULL ||
				    tmcomp(&mytm, &yourtm) != 0 || mytm.tm_isdst != yourtm.tm_isdst)
					continue;
				t = newt;
				goto label;
			}
		}
		return (-1);
	}
label:
	newt = t + saved_seconds;
	if ((newt < t) != (saved_seconds < 0))
		return (-1);
	t = newt;
	if (date_localtime(zone, &t, tmp) == NULL)
		return (-1);
	*okayp = 1;
	return (t);
}

static time_t
time2(const struct date_zone *zone, const struct type_table *table, struct tm *tmp, int *okayp)
{
	time_t t = time2sub(zone, table, tmp, okayp, 0);
	return (*okayp ? t : time2sub(zone, table, tmp, okayp, 1));
}

time_t
date_mktime(const struct date_zone *zone, struct tm *tmp)
{
	struct type_table table;
	int okay;
	time_t t;

	type_table(zone, &table);
	if (tmp->tm_isdst > 1)
		tmp->tm_isdst = 1;
	t = time2(zone, &table, tmp, &okay);
	if (okay)
		return (t);
	if (tmp->tm_isdst < 0)
		tmp->tm_isdst = 0;	/* reset to std and try again */
	/* A time of one type adjusted into the other: shift to the type it needs. */
	for (size_t same = 0; same < table.recent_count; same++) {
		if (table.recent[same]->isdst != tmp->tm_isdst)
			continue;
		for (size_t other = 0; other < table.recent_count; other++) {
			if (table.recent[other]->isdst == tmp->tm_isdst)
				continue;
			tmp->tm_sec += table.recent[other]->gmtoff - table.recent[same]->gmtoff;
			tmp->tm_isdst = !tmp->tm_isdst;
			t = time2(zone, &table, tmp, &okay);
			if (okay)
				return (t);
			tmp->tm_sec -= table.recent[other]->gmtoff - table.recent[same]->gmtoff;
			tmp->tm_isdst = !tmp->tm_isdst;
		}
	}
	return (-1);
}

/*
 * The offset strftime's %z prints: like Darwin's settzname, the most recent
 * standard (timezone) or daylight (altzone) offset, not the time's own.
 */
long
date_zone_offset(const struct date_zone *zone, int isdst)
{
	struct type_table table;

	if (zone->empty)
		return (0);
	if (zone->type_count == 0) {
		type_table(zone, &table);
		for (size_t i = 0; i < table.recent_count; i++)
			if (table.recent[i]->isdst == isdst)
				return (table.recent[i]->gmtoff);
		return (zone->standard.gmtoff);
	}
	if (zone->count == 0)
		return (zone->types[0].gmtoff);
	for (size_t i = zone->count; i-- > 0;) {
		const struct zone_type *type = &zone->types[zone->indices[i]];
		if (type->isdst == isdst || i == 0)
			return (type->gmtoff);
	}
	return (0);
}
