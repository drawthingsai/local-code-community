#ifndef DATE_ZONE_H
#define DATE_ZONE_H

#include <time.h>

/* A TZ value loaded without setting the process-wide TZ: NULL is the system
 * zone, "" or an unusable value UTC, otherwise a zoneinfo name or a POSIX TZ
 * string, as tzset(3) reads them. */
struct date_zone;
struct date_zone *date_zone_load(const char *tz);
void date_zone_free(struct date_zone *zone);
/* localtime_r(3) and mktime(3) in zone; tm_zone points into the zone. */
struct tm *date_localtime(const struct date_zone *zone, const time_t *clock, struct tm *result);
time_t date_mktime(const struct date_zone *zone, struct tm *tm);
/* The offset strftime's %z prints for a time with this DST state. */
long date_zone_offset(const struct date_zone *zone, int isdst);

#endif
