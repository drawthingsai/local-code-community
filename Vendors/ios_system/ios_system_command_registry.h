#ifndef ios_system_command_registry_h
#define ios_system_command_registry_h

#include <stddef.h>
#include "ios_system_command.h"
#include "ios_system_isolation.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const char *name;
  ios_command_main function;
  const char *function_name;
  const char *getopt_string;
  const char *operates_on;
  const char *library_name;
  size_t stack_size; // Zero uses the pthread default.
} ios_command_entry;

int ios_command_count(void);
const ios_command_entry *ios_command_at_index(int index);
const ios_command_entry *ios_command_lookup(const char *name);
const char *ios_command_virtual_bin_path(void);
int ios_command_is_virtual_bin_path(const char *path);
const ios_command_entry *ios_command_lookup_virtual_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif
