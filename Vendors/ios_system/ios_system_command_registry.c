#include "ios_system_command_registry.h"
#include "rg.h"

#include <ctype.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define IOS_STATIC_COMMAND_VIRTUAL_BIN_PATH "/usr/bin"

extern int basename_main(int, char **);
extern int dirname_main(int, char **);
extern int realpath_main(int, char **);
extern int mktemp_main(int, char **);
extern int cut_main(int, char **);
extern int comm_main(int, char **);
extern int paste_main(int, char **);
extern int join_main(int, char **);
extern int jq_main(int, char **);
extern int zip_main(int, char **);
extern int unzip_main(int, char **);
extern int split_main(int, char **);
extern int du_main(int, char **);
extern int df_main(int, char **);
extern int chmod_main(int, char **);
extern int cmp_main(int, char **);
extern int diff_main(int, char **);
extern int xxd_main(int, char **);
extern int sha256sum_main(int, char **);
extern int base64_main(int, char **);
extern int ffmpeg_main(int, char **);
extern int ffprobe_main(int, char **);

extern int alias_main(int, char **);
extern int awk_main(int, char **);
extern int cat_main(int, char **);
extern int cd_main(int, char **);
extern int cp_main(int, char **);
extern int curl_main(int, char **);
extern int date_main(int, char **);
extern int echo_main(int, char **);
extern int env_main(int, char **);
extern int export_main(int, char **);
extern int find_main(int, char **);
extern int grep_main(int, char **);
extern int head_main(int, char **);
extern int id_main(int, char **);
extern int img2txt_main(int, char **);
extern int ln_main(int, char **);
extern int lg2_main(int, char **);
extern int git_lfs_main(int, char **);
extern int ls_main(int, char **);
extern int mkdir_main(int, char **);
extern int mv_main(int, char **);
extern int ios_node_main(int, char **);
extern int ios_npm_main(int, char **);
extern int ios_npx_main(int, char **);
extern int openurl_main(int, char **);
extern int pbcopy(int, char **);
extern int pbpaste(int, char **);
extern int ios_pip_main(int, char **);
extern int ios_ytdlp_main(int, char **);
extern int office_main(int, char **);
extern int printenv_main(int, char **);
extern int pwd_main(int, char **);
extern int ios_python_main(int, char **);
extern int rm_main(int, char **);
extern int rmdir_main(int, char **);
extern int scp_main(int, char **);
extern int sed_main(int, char **);
extern int setenv_main(int, char **);
extern int sh_main(int, char **);
extern int sftp_main(int, char **);
extern int sleep_main(int, char **);
extern int sort_main(int, char **);
extern int ssh_main(int, char **);
extern int ssh_keygen_main(int, char **);
extern int sshpass_main(int, char **);
extern int stat_main(int, char **);
extern int tail_main(int, char **);
extern int tee_main(int, char **);
extern int touch_main(int, char **);
extern int tr_main(int, char **);
extern int true_main(int, char **);
extern int type_main(int, char **);
extern int unalias_main(int, char **);
extern int uname_main(int, char **);
extern int uniq_main(int, char **);
extern int unsetenv_main(int, char **);
extern int w_main(int, char **);
extern int wc_main(int, char **);
extern int which_main(int, char **);
extern int xargs_main(int, char **);

static const ios_command_entry kStaticCommands[] = {
    {"alias", alias_main, "alias_main", "h", "no"},
    {"awk", awk_main, "awk_main", "dF:f:v:", "file"},
    {"base64", base64_main, "base64_main", "diw:", "file"},
    {"basename", basename_main, "basename_main", "as:", "file"},
    // Shell recursion runs on the C stack (see ios_system_osh_invocation).
    {"bash", sh_main, "sh_main", "c:h:", "file", NULL, 16 * 1024 * 1024},
    {"cat", cat_main, "cat_main", "benstuv", "file"},
    {"cd", cd_main, "cd_main", "", "directory"},
    {"chmod", chmod_main, "chmod_main", "ACEHILNPRVXafghinorstuvwx", "file"},
    {"cmp", cmp_main, "cmp_main", "ls", "file"},
    {"comm", comm_main, "comm_main", "123i", "file"},
    {"cp", cp_main, "cp_main", "cHLPRXafinprv", "file"},
    {"curl", curl_main, "curl_main", "2346aAbBcCdDeEfgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwxXYyz#", "file"},
    {"cut", cut_main, "cut_main", "b:c:d:f:snw", "file"},
    {"date", date_main, "date_main", "d:f:jnRr:t:uv:", "no"},
    {"df", df_main, "df_main", "abgHhiklmnPtT:", "file"},
    {"diff", diff_main, "diff_main", "abBC:c::dD:efHhiI:L:lNnPpqrsS:tTU:u::wx:X:", "file"},
    {"dirname", dirname_main, "dirname_main", "", "file"},
    {"du", du_main, "du_main", "AB:HI:LPasd:cghklmnrt:x", "file"},
    {"echo", echo_main, "echo_main", "n", "no"},
    {"egrep", grep_main, "grep_main", "0123456789A:B:C:D:EFGHIJMLOPSRUVZabcd:e:f:hilm:nopqrsuvwxXy", "file"},
    {"env", env_main, "env_main", "-iP:S:u:v", "no"},
    {"export", export_main, "export_main", "", "no"},
    {"ffmpeg", ffmpeg_main, "ffmpeg_main", "", "file"},
    {"ffprobe", ffprobe_main, "ffprobe_main", "", "file"},
    {"fgrep", grep_main, "grep_main", "0123456789A:B:C:D:EFGHIJMLOPSRUVZabcd:e:f:hilm:nopqrsuvwxXy", "file"},
    {"find", find_main, "find_main", "EHLPXdf:sx", "directory"},
    {"grep", grep_main, "grep_main", "0123456789A:B:C:D:EFGHIJMLOPSRUVZabcd:e:f:hilm:nopqrsuvwxXy", "file"},
    {"git", lg2_main, "lg2_main", "", "file"},
    {"git-lfs", git_lfs_main, "git_lfs_main", "", "file"},
    {"head", head_main, "head_main", "n:c:", "file"},
    {"id", id_main, "id_main", "GMPgnpru", "no"},
    {"img2txt", img2txt_main, "img2txt_main", "W:H:f:d:g:b:c:hvx:y:", "file"},
    {"join", join_main, "join_main", "a:e:j:1:2:o:t:v:", "file"},
    {"jq", jq_main, "jq_main", "acCef:hjL:MnRrsSV", "file", NULL, 16 * 1024 * 1024},
    {"link", ln_main, "ln_main", "", "file"},
    {"ln", ln_main, "ln_main", "Ffhinsv", "file"},
    {"lg2", lg2_main, "lg2_main", "", "file"},
    {"ls", ls_main, "ls_main", "1@ABCFGHLOPRSTUWabcdefghiklmnopqrstuvwx", "file"},
    {"mkdir", mkdir_main, "mkdir_main", "m:pv", "directory"},
    {"mktemp", mktemp_main, "mktemp_main", "dp:qt:u", "file"},
    {"mv", mv_main, "mv_main", "finv", "file"},
    {"node", ios_node_main, "ios_node_main", "e:hp:r:v", "no"},
    {"npm", ios_npm_main, "ios_npm_main", "", "no"},
    {"npx", ios_npx_main, "ios_npx_main", "", "no"},
    {"openurl", openurl_main, "openurl_main", "", "no"},
    {"paste", paste_main, "paste_main", "d:s", "file"},
    {"office", office_main, "office_main", "", "file"},
    {"pbcopy", pbcopy, "pbcopy", "", "no"},
    {"pbpaste", pbpaste, "pbpaste", "", "no"},
    {"pip", ios_pip_main, "ios_pip_main", "", "no"},
    {"pip3", ios_pip_main, "ios_pip_main", "", "no"},
    {"pip3.14", ios_pip_main, "ios_pip_main", "", "no"},
    {"printenv", printenv_main, "printenv_main", "", "no"},
    {"pwd", pwd_main, "pwd_main", "LP", "no"},
    {"python", ios_python_main, "ios_python_main", "3bBc:dEhiJm:OQ:RsStuUvVW:xX?", "no"},
    {"python3", ios_python_main, "ios_python_main", "3bBc:dEhiJm:OQ:RsStuUvVW:xX?", "no"},
    {"python3.14", ios_python_main, "ios_python_main", "3bBc:dEhiJm:OQ:RsStuUvVW:xX?", "no"},
    {"realpath", realpath_main, "realpath_main", "q", "file"},
    {"rg", rg_main, "rg_main", "", "file"},
    {"readlink", stat_main, "stat_main", "n", "file"},
    {"rm", rm_main, "rm_main", "dfiPRrvW", "file"},
    {"rmdir", rmdir_main, "rmdir_main", "p", "directory"},
    {"scp", scp_main, "scp_main", "12346ABCTdfOpqRrstvD:F:J:M:P:S:c:i:l:o:X:", "file"},
    {"sed", sed_main, "sed_main", "Eae:f:i:ln", "file"},
    {"setenv", setenv_main, "setenv_main", "", "no"},
    {"sh", sh_main, "sh_main", "c:h:", "file", NULL, 16 * 1024 * 1024},
    {"sftp", sftp_main, "sftp_main", "1246AafhNpqrvCc:D:i:l:o:s:S:b:B:F:J:P:R:X:", "file"},
    {"sha256sum", sha256sum_main, "sha256sum_main", "bctwz", "file"},
    {"sleep", sleep_main, "sleep_main", "", "no"},
    {"sort", sort_main, "sort_main", "bcCdfghik:Mmno:RrsS:t:T:uVz", "file"},
    {"split", split_main, "split_main", "a:b:cdl:n:p:", "file"},
    {"ssh", ssh_main, "ssh_main", "1246ab:c:e:fgi:kl:m:no:p:qstvxAB:CD:E:F:GI:J:KL:MNO:P:Q:R:S:TVw:W:XYy", "no"},
    {"ssh-keygen", ssh_keygen_main, "ssh_keygen_main", "ABHKLQUXceghiklopquvyC:D:E:F:I:M:N:O:P:R:V:Y:Z:a:b:f:g:m:n:r:s:t:w:z:", "file"},
    {"sshpass", sshpass_main, "sshpass_main", "f:d:p:P:heVv", "no"},
    {"stat", stat_main, "stat_main", "f:FlLnqrst:x", "file"},
    {"tail", tail_main, "tail_main", "Fb:c:fn:qr", "file"},
    {"tee", tee_main, "tee_main", "ai", "file"},
    {"touch", touch_main, "touch_main", "A:acfhmr:t:", "file"},
    {"tr", tr_main, "tr_main", "Ccdsu", "no"},
    {"true", true_main, "true_main", "", "no"},
    {"type", type_main, "type_main", "", "no"},
    {"unalias", unalias_main, "unalias_main", "a", "no"},
    {"uname", uname_main, "uname_main", "amnprsv", "no"},
    {"uniq", uniq_main, "uniq_main", "cdif:s:u", "file"},
    {"unlink", rm_main, "rm_main", "", "file"},
    {"unzip", unzip_main, "unzip_main", "aBcCd:efhijKlLmMnopP:qtuvVx:Zz", "file"},
    {"unsetenv", unsetenv_main, "unsetenv_main", "", "no"},
    {"uptime", w_main, "w_main", "", "no"},
    {"w", w_main, "w_main", "hin", "no"},
    {"wc", wc_main, "wc_main", "clmw", "file"},
    {"which", which_main, "which_main", "as", "no"},
    {"whoami", id_main, "id_main", "", "no"},
    {"xargs", xargs_main, "xargs_main", "0E:I:J:L:n:oP:pR:s:tx", "no"},
    {"xxd", xxd_main, "xxd_main", "abCc:deEg:hil:n:o:prR:s:tuv", "file"},
    {"yt-dlp", ios_ytdlp_main, "ios_ytdlp_main", "", "file"},
    {"zip", zip_main, "zip_main", "0123456789AcdfFghjklmno:pP:qrTuvxy", "file"},
};

typedef struct ios_runtime_command_entry {
  ios_command_entry command;
  struct ios_runtime_command_entry *next;
} ios_runtime_command_entry;

static pthread_mutex_t runtimeCommandMutex = PTHREAD_MUTEX_INITIALIZER;
// Entries are append-only, so pointers returned after releasing the mutex
// remain valid.
static ios_runtime_command_entry *runtimeCommandHead = NULL;
static ios_runtime_command_entry *runtimeCommandTail = NULL;
static int runtimeCommandCount = 0;

static int ios_static_command_count(void) {
  return (int)(sizeof(kStaticCommands) / sizeof(kStaticCommands[0]));
}

static const ios_command_entry *ios_static_command_at_index(int index) {
  if (index < 0 || index >= ios_static_command_count()) {
    return NULL;
  }
  return &kStaticCommands[index];
}

static const ios_command_entry *ios_static_command_lookup(const char *name) {
  if (name == NULL) {
    return NULL;
  }
  for (int i = 0; i < ios_static_command_count(); ++i) {
    if (strcmp(kStaticCommands[i].name, name) == 0) {
      return &kStaticCommands[i];
    }
  }
  return NULL;
}

int ios_registerCommand(const char *commandName, ios_command_main commandMain) {
  if (commandName == NULL || commandName[0] == '\0' || commandMain == NULL ||
      strchr(commandName, '/') != NULL) {
    return 0;
  }
  for (const unsigned char *character = (const unsigned char *)commandName;
       *character != '\0'; ++character) {
    if (isspace(*character)) {
      return 0;
    }
  }
  if (ios_static_command_lookup(commandName) != NULL) {
    return 0;
  }

  pthread_mutex_lock(&runtimeCommandMutex);
  for (ios_runtime_command_entry *entry = runtimeCommandHead; entry != NULL;
       entry = entry->next) {
    if (strcmp(entry->command.name, commandName) == 0) {
      pthread_mutex_unlock(&runtimeCommandMutex);
      return 0;
    }
  }

  ios_runtime_command_entry *entry = calloc(1, sizeof(*entry));
  char *name = strdup(commandName);
  if (entry == NULL || name == NULL) {
    free(entry);
    free(name);
    pthread_mutex_unlock(&runtimeCommandMutex);
    return 0;
  }
  entry->command = (ios_command_entry){
      name,
      commandMain,
      "",
      "",
      "no",
      "RUNTIME",
  };
  if (runtimeCommandTail == NULL) {
    runtimeCommandHead = entry;
  } else {
    runtimeCommandTail->next = entry;
  }
  runtimeCommandTail = entry;
  runtimeCommandCount += 1;
  pthread_mutex_unlock(&runtimeCommandMutex);
  return 1;
}

int ios_command_count(void) {
  pthread_mutex_lock(&runtimeCommandMutex);
  int count = ios_static_command_count() + runtimeCommandCount;
  pthread_mutex_unlock(&runtimeCommandMutex);
  return count;
}

const ios_command_entry *ios_command_at_index(int index) {
  int staticCommandCount = ios_static_command_count();
  if (index < 0) {
    return NULL;
  }
  if (index < staticCommandCount) {
    return ios_static_command_at_index(index);
  }

  pthread_mutex_lock(&runtimeCommandMutex);
  ios_runtime_command_entry *entry = runtimeCommandHead;
  for (int runtimeIndex = index - staticCommandCount;
       entry != NULL && runtimeIndex > 0; --runtimeIndex) {
    entry = entry->next;
  }
  const ios_command_entry *command = entry != NULL ? &entry->command : NULL;
  pthread_mutex_unlock(&runtimeCommandMutex);
  return command;
}

const ios_command_entry *ios_command_lookup(const char *name) {
  const ios_command_entry *staticCommand = ios_static_command_lookup(name);
  if (staticCommand != NULL || name == NULL) {
    return staticCommand;
  }

  pthread_mutex_lock(&runtimeCommandMutex);
  ios_runtime_command_entry *entry = runtimeCommandHead;
  while (entry != NULL && strcmp(entry->command.name, name) != 0) {
    entry = entry->next;
  }
  const ios_command_entry *command = entry != NULL ? &entry->command : NULL;
  pthread_mutex_unlock(&runtimeCommandMutex);
  return command;
}

ios_command_isolation_policy ios_commandIsExclusiveOrThreadSafe(const char *command) {
  const ios_command_entry *entry = ios_command_lookup(command);
  if (entry == NULL) {
    entry = ios_command_lookup_virtual_path(command);
  }
  if (entry == NULL) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH;
  }
  if (entry->library_name != NULL &&
      strcmp(entry->library_name, "RUNTIME") == 0) {
    if (strcmp(entry->name, "hyperframes") == 0) {
      return IOS_COMMAND_ISOLATION_EXCLUSIVE_NODE;
    }
    if (strcmp(entry->name, "draw-things-cli") == 0) {
      return IOS_COMMAND_ISOLATION_EXCLUSIVE_DRAW_THINGS;
    }
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH;
  }
  if (entry->function == sh_main) {
    return IOS_COMMAND_ISOLATION_OSH;
  }
  if (entry->function == echo_main ||
      entry->function == tee_main ||
      entry->function == pbcopy ||
      entry->function == pbpaste ||
      entry->function == sleep_main ||
      entry->function == true_main ||
      entry->function == type_main ||
      entry->function == basename_main ||
      entry->function == dirname_main ||
      entry->function == realpath_main ||
      entry->function == mktemp_main ||
      entry->function == cut_main ||
      entry->function == comm_main ||
      entry->function == paste_main ||
      entry->function == join_main ||
      entry->function == jq_main ||
      entry->function == zip_main ||
      entry->function == unzip_main ||
      entry->function == split_main ||
      entry->function == cmp_main ||
      entry->function == diff_main ||
      entry->function == xxd_main ||
      entry->function == base64_main ||
      entry->function == sha256sum_main) {
    return IOS_COMMAND_ISOLATION_THREAD_SAFE;
  }
  if (entry->function == ios_python_main || entry->function == ios_pip_main ||
      entry->function == ios_ytdlp_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_PYTHON;
  }
  if (entry->function == ios_node_main ||
      entry->function == ios_npm_main ||
      entry->function == ios_npx_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_NODE;
  }
  if (entry->function == curl_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_CURL;
  }
  if (entry->function == img2txt_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_IMG2TXT;
  }
  if (entry->function == office_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_LIBREOFFICE;
  }
  if (entry->function == ffmpeg_main || entry->function == ffprobe_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_FFMPEG;
  }
  if (entry->function == scp_main ||
      entry->function == sftp_main ||
      entry->function == ssh_main ||
      entry->function == ssh_keygen_main ||
      entry->function == sshpass_main) {
    return IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH;
  }
  return IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH;
}

const char *ios_command_virtual_bin_path(void) {
  return IOS_STATIC_COMMAND_VIRTUAL_BIN_PATH;
}

int ios_command_is_virtual_bin_path(const char *path) {
  if (path == NULL) {
    return 0;
  }
  return strcmp(path, IOS_STATIC_COMMAND_VIRTUAL_BIN_PATH) == 0 ||
         strcmp(path, IOS_STATIC_COMMAND_VIRTUAL_BIN_PATH "/") == 0;
}

const ios_command_entry *ios_command_lookup_virtual_path(const char *path) {
  const char *prefix = IOS_STATIC_COMMAND_VIRTUAL_BIN_PATH "/";
  size_t prefix_length = strlen(prefix);
  const char *command_name;

  if (path == NULL) {
    return NULL;
  }
  // Scripts and tools hard-code the conventional shell locations.
  if (strcmp(path, "/bin/sh") == 0 || strcmp(path, "/bin/bash") == 0) {
    return ios_command_lookup(path + strlen("/bin/"));
  }
  if (strncmp(path, prefix, prefix_length) != 0) {
    return NULL;
  }
  command_name = path + prefix_length;
  if (command_name[0] == '\0' || strchr(command_name, '/') != NULL) {
    return NULL;
  }
  return ios_command_lookup(command_name);
}
