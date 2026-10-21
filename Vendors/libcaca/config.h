#ifndef LIBCACA_APPLE_CONFIG_H
#define LIBCACA_APPLE_CONFIG_H

/* Apple configuration for the checked-in libcaca source snapshot. */
#ifdef DEBUG
#undef DEBUG
#endif

#define PACKAGE "libcaca"
#define PACKAGE_NAME "libcaca"
#define PACKAGE_TARNAME "libcaca"
#define PACKAGE_VERSION "0.99.beta20"
#define PACKAGE_STRING "libcaca 0.99.beta20"
#define VERSION "0.99.beta20"

#define HAVE_ARPA_INET_H 1
#define HAVE_ATEXIT 1
#define HAVE_ERRNO_H 1
#define HAVE_GETENV 1
#define HAVE_GETOPT_H 1
#define HAVE_GETOPT_LONG 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_HTONS 1
#define HAVE_LOCALE_H 1
#define HAVE_PUTENV 1
#define HAVE_SIGNAL 1
#define HAVE_SIGNAL_H 1
#define HAVE_SNPRINTF 1
#define HAVE_STDARG_H 1
#define HAVE_STDIO_H 1
#define HAVE_STRCASECMP 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_TERMIOS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_USLEEP 1
#define HAVE_VSNPRINTF 1

#endif
