load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_command_line_application")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")

package(default_visibility = ["//visibility:public"])

config_setting(
    name = "ios_build",
    constraint_values = [
        "@platforms//os:ios",
    ],
)

config_setting(
    name = "macos_build",
    constraint_values = [
        "@platforms//os:osx",
    ],
)

COMMON_COPTS = [
    "-Wno-ambiguous-macro",
    "-Wno-deprecated-declarations",
    "-Wno-incompatible-pointer-types-discards-qualifiers",
    "-Wno-int-conversion",
    "-Wno-shorten-64-to-32",
    "-Wno-unused-function",
    "-Wno-unused-variable",
    "-fcommon",
]

objc_library(
    name = "api",
    hdrs = [
        "ios_error.h",
        "ios_sshpass.h",
        "ios_system/ios_system.h",
        "ios_system_command.h",
        "ios_system_isolation.h",
        "libutil.h",
    ],
    includes = [
        ".",
        "ios_system",
    ],
    textual_hdrs = [
        "ncurses_dll.h",
        "termcap.h",
    ],
)

objc_library(
    name = "ios_system_api",
    hdrs = [
        "ios_error.h",
        "ios_sshpass.h",
        "ios_system/ios_system.h",
        "ios_system_command.h",
        "ios_system_isolation.h",
    ],
    includes = [
        ".",
        "ios_system",
    ],
    module_name = "ios_system",
)

objc_library(
    name = "registry_api",
    hdrs = [
        "ios_system_command.h",
        "ios_system_command_registry.h",
        "ios_system_isolation.h",
    ],
    includes = ["."],
)

objc_library(
    name = "core",
    srcs = [
        "getopt.c",
        "getopt_long.c",
        "ios_system.m",
        "libc_replacement.c",
        "macos_host_shims.c",
        "shell_cmds_ios/open.m",
        ":python_subprocess_source",
    ],
    copts = COMMON_COPTS,
    includes = [
        ".",
        "ios_system",
    ],
    sdk_frameworks = [
        "Foundation",
    ] + select({
        ":ios_build": [
            "CoreGraphics",
            "UIKit",
        ],
        "//conditions:default": [],
    }),
    deps = [
        ":api",
        ":registry_api",
        "//Vendors/OSH:api",
        "//Vendors/PythonIOS:PythonRuntimeAPI",
        "@oils_for_unix//:osh_ios",
    ],
)

genrule(
    name = "python_subprocess_source",
    srcs = ["python_subprocess.py"],
    outs = ["python_subprocess_source.h"],
    cmd = "python3 $(location embed_python.py) $(location python_subprocess.py) $@",
    tools = ["embed_python.py"],
)

objc_library(
    name = "cmd_ls",
    srcs = glob(["file_cmds/ls/*.c"]) + ["libutil/humanize_number.c"],
    hdrs = glob(["file_cmds/ls/*.h"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_ls_usage",
        "-DCOLORLS",
    ],
    includes = [
        ".",
        "file_cmds/ls",
    ],
    deps = [
        ":api",
        ":registry_api",
    ],
)

objc_library(
    name = "cmd_cp",
    srcs = glob(["file_cmds/cp/*.c"]),
    hdrs = glob(["file_cmds/cp/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_cp_usage"],
    includes = [
        ".",
        "file_cmds/cp",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_mv",
    srcs = glob(["file_cmds/mv/*.c"]),
    hdrs = glob(["file_cmds/mv/*.h"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_mv_usage",
        "-Ddo_move=mv_do_move",
        "-Dfastcopy=mv_fastcopy",
    ],
    includes = [
        ".",
        "file_cmds/mv",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_rm",
    srcs = glob(["file_cmds/rm/*.c"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_rm_usage",
        "-Dcheck=rm_check",
        "-Dcheckdir=rm_checkdir",
        "-Dcheckdot=rm_checkdot",
        "-Drm_file=rm_rm_file",
        "-Drm_tree=rm_rm_tree",
        "-Dyes_or_no=rm_yes_or_no",
    ],
    includes = [
        ".",
        "file_cmds/rm",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_mkdir",
    srcs = glob(["file_cmds/mkdir/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_mkdir_usage"],
    includes = [
        ".",
        "file_cmds/mkdir",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_rmdir",
    srcs = glob(["file_cmds/rmdir/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_rmdir_usage"],
    includes = [
        ".",
        "file_cmds/rmdir",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_ln",
    srcs = glob(["file_cmds/ln/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_ln_usage"],
    includes = [
        ".",
        "file_cmds/ln",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_stat",
    srcs = glob(["file_cmds/stat/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_stat_usage"],
    includes = [
        ".",
        "file_cmds/stat",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_touch",
    srcs = glob(["file_cmds/touch/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_touch_usage"],
    includes = [
        ".",
        "file_cmds/touch",
    ],
    deps = [":api"],
)

objc_library(
    name = "files_basic",
    deps = [
        ":cmd_cp",
        ":cmd_ln",
        ":cmd_ls",
        ":cmd_mkdir",
        ":cmd_mv",
        ":cmd_rm",
        ":cmd_rmdir",
        ":cmd_stat",
        ":cmd_touch",
    ],
)

objc_library(
    name = "cmd_cat",
    srcs = glob(["text_cmds/cat/*.c"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_cat_usage",
        "-Dfilename=cat_filename",
    ],
    includes = [
        ".",
        "text_cmds/cat",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_grep",
    srcs = glob(["text_cmds/grep/*.c"]),
    hdrs = glob(["text_cmds/grep/*.h"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_grep_usage",
        "-DWITHOUT_BZIP2",
        "-DWITHOUT_FASTMATCH",
        "-DWITHOUT_LZMA",
        "-Dfirst=grep_first",
    ],
    includes = [
        ".",
        "text_cmds/grep",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_sed",
    srcs = glob(["text_cmds/sed/*.c"]),
    hdrs = glob(["text_cmds/sed/*.h"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_sed_usage",
        "-Dinfile=sed_infile",
        "-Dmatch=sed_match",
    ],
    includes = [
        ".",
        "text_cmds/sed",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_head",
    srcs = glob(["text_cmds/head/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_head_usage"],
    includes = [
        ".",
        "text_cmds/head",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_tail",
    srcs = glob(["text_cmds/tail/*.c"]),
    hdrs = glob(["text_cmds/tail/*.h"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_tail_usage",
        "-Dfollow=tail_follow",
    ],
    includes = [
        ".",
        "text_cmds/tail",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_wc",
    srcs = glob(["text_cmds/wc/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_wc_usage"],
    includes = [
        ".",
        "text_cmds/wc",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_sort",
    srcs = glob(["text_cmds/sort/*.c"]),
    hdrs = glob(["text_cmds/sort/*.h"]),
    copts = COMMON_COPTS + [
        "-Dusage=cmd_sort_usage",
        "-Dcheck=sort_check",
        "-Dclosefile=sort_closefile",
        "-Dfile_reader_init=sort_file_reader_init",
        "-Dopenfile=sort_openfile",
    ],
    includes = [
        ".",
        "text_cmds/sort",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_uniq",
    srcs = glob(["text_cmds/uniq/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_uniq_usage"],
    includes = [
        ".",
        "text_cmds/uniq",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_tr",
    srcs = glob(["text_cmds/tr/*.c"]),
    hdrs = glob(["text_cmds/tr/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_tr_usage"],
    includes = [
        ".",
        "text_cmds/tr",
    ],
    deps = [":api"],
)

objc_library(
    name = "text_basic",
    deps = [
        ":cmd_cat",
        ":cmd_grep",
        ":cmd_head",
        ":cmd_sed",
        ":cmd_sort",
        ":cmd_tail",
        ":cmd_tr",
        ":cmd_uniq",
        ":cmd_wc",
    ],
)

objc_library(
    name = "cmd_date",
    srcs = [
        "shell_cmds/date/date.c",
        "shell_cmds/date/vary.c",
    ],
    hdrs = glob(["shell_cmds/date/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_date_usage"],
    includes = [
        ".",
        "shell_cmds/date",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_echo",
    srcs = glob(["shell_cmds/echo/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_echo_usage"],
    includes = [
        ".",
        "shell_cmds/echo",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_env",
    srcs = glob(["shell_cmds/env/*.c"]),
    hdrs = glob(["shell_cmds/env/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_env_usage"],
    includes = [
        ".",
        "shell_cmds/env",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_find",
    srcs = glob(["bsd_find/*.c"]),
    hdrs = glob(["bsd_find/*.h"]),
    copts = COMMON_COPTS + [
        "-Df_flags=find_f_flags",
        "-Df_group=find_f_group",
        "-Df_size=find_f_size",
        "-Df_type=find_f_type",
        "-Dusage=cmd_find_usage",
        "-Dprintlong=find_printlong",
        "-Dyychar=find_yychar",
        "-Dyydebug=find_yydebug",
        "-Dyyerror=find_yyerror",
        "-Dyyparse=find_yyparse",
        "-Dyylex=find_yylex",
        "-Dyylval=find_yylval",
        "-Dyynerrs=find_yynerrs",
    ],
    includes = [
        ".",
        "bsd_find",
    ],
    deps = [
        ":api",
        ":ios_system_support",
    ],
)

objc_library(
    name = "cmd_printenv",
    srcs = glob(["shell_cmds/printenv/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_printenv_usage"],
    includes = [
        ".",
        "shell_cmds/printenv",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_pwd",
    srcs = glob(["shell_cmds/pwd/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_pwd_usage"],
    includes = [
        ".",
        "shell_cmds/pwd",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_tee",
    srcs = glob(["shell_cmds/tee/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_tee_usage"],
    includes = [
        ".",
        "shell_cmds/tee",
    ],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_uname",
    srcs = glob(["shell_cmds/uname/*.c"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_uname_usage"],
    includes = [
        ".",
        "shell_cmds/uname",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_w",
    srcs = [
        "shell_cmds/w/fmt.c",
        "shell_cmds/w/pr_time.c",
        "shell_cmds/w/proc_compare.c",
        "shell_cmds/w/w.c",
    ],
    hdrs = glob(["shell_cmds/w/*.h"]) + ["libutil.h"],
    copts = COMMON_COPTS + [
        "-Dusage=cmd_w_usage",
        "-DHAVE_UTMPX=1",
    ],
    includes = [
        ".",
        "shell_cmds/w",
    ],
    linkopts = select({
        ":macos_build": ["-lresolv"],
        "//conditions:default": [],
    }),
    deps = [":api"],
)

objc_library(
    name = "cmd_id",
    srcs = ["shell_cmds/id/id.c"],
    copts = COMMON_COPTS + ["-Dusage=cmd_id_usage"],
    includes = [
        ".",
        "shell_cmds/id",
    ],
    deps = [":api"],
)

objc_library(
    name = "cmd_xargs",
    srcs = glob(["shell_cmds/xargs/*.c"]),
    hdrs = glob(["shell_cmds/xargs/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=cmd_xargs_usage"],
    includes = [
        ".",
        "shell_cmds/xargs",
    ],
    deps = [":api"],
)

objc_library(
    name = "shell",
    deps = [
        ":cmd_date",
        ":cmd_echo",
        ":cmd_env",
        ":cmd_find",
        ":cmd_id",
        ":cmd_printenv",
        ":cmd_pwd",
        ":cmd_tee",
        ":cmd_uname",
        ":cmd_w",
        ":cmd_xargs",
    ],
)

objc_library(
    name = "awk",
    srcs = [
        "awk-awk-35/src/awkgram.tab.c",
        "awk-awk-35/src/b.c",
        "awk-awk-35/src/lex.c",
        "awk-awk-35/src/lib.c",
        "awk-awk-35/src/main.c",
        "awk-awk-35/src/parse.c",
        "awk-awk-35/src/proctab.c",
        "awk-awk-35/src/run.c",
        "awk-awk-35/src/tran.c",
    ],
    hdrs = glob(["awk-awk-35/src/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=awk_usage"],
    includes = [
        ".",
        "awk-awk-35/src",
    ],
    deps = [":api"],
)

objc_library(
    name = "curl_lib",
    srcs = glob(
        [
            "curl/curl/lib/**/*.c",
        ],
        exclude = [
            "curl/curl/lib/vssh/*.c",
        ],
    ),
    hdrs = glob([
        "curl/curl/include/**/*.h",
        "curl/curl/lib/**/*.h",
        "curl/curl/src/**/*.h",
    ]),
    copts = COMMON_COPTS + [
        "-DHAVE_CONFIG_H",
        "-DBUILDING_LIBCURL",
    ],
    includes = [
        ".",
        "curl/curl/include",
        "curl/curl/lib",
    ],
    linkopts = ["-lz"],
    sdk_frameworks = [
        "CoreFoundation",
        "Foundation",
        "Security",
    ] + select({
        ":macos_build": ["SystemConfiguration"],
        "//conditions:default": [],
    }),
    deps = [":api"],
)

objc_library(
    name = "curl_tool_support",
    srcs = [
        "curl/curl/lib/curl_multibyte.c",
        "curl/curl/lib/dynbuf.c",
        "curl/curl/lib/nonblock.c",
        "curl/curl/lib/strtoofft.c",
        "curl/curl/lib/timediff.c",
        "curl/curl/lib/version_win32.c",
        "curl/curl/lib/warnless.c",
    ],
    hdrs = glob([
        "curl/curl/include/**/*.h",
        "curl/curl/lib/**/*.h",
    ]),
    copts = COMMON_COPTS + ["-DHAVE_CONFIG_H"],
    includes = [
        ".",
        "curl/curl/include",
        "curl/curl/lib",
    ],
    deps = [":api"],
)

objc_library(
    name = "curl_tool",
    srcs = glob([
        "curl/curl/src/*.c",
        "curl/curl/src/*.m",
    ]),
    hdrs = glob(["curl/curl/src/**/*.h"]),
    copts = COMMON_COPTS + [
        "-DHAVE_CONFIG_H",
        "-Dmain=curl_main",
    ],
    includes = [
        ".",
        "curl/curl/include",
        "curl/curl/lib",
        "curl/curl/src",
    ],
    sdk_frameworks = ["Foundation"],
    deps = [
        ":api",
        ":curl_lib",
        ":curl_tool_support",
    ],
)

objc_library(
    name = "curl_http",
    deps = [
        ":curl_lib",
        ":curl_tool",
        ":curl_tool_support",
    ],
)

objc_library(
    name = "git_lfs",
    srcs = ["git_lfs.m"],
    copts = COMMON_COPTS,
    sdk_frameworks = ["Foundation"],
    deps = [
        ":api",
        ":curl_lib",
        "//Vendors/libgit2",
    ],
)

objc_library(
    name = "cmd_git",
    srcs = ["//Vendors/libgit2:lg2_example_srcs"],
    hdrs = ["//Vendors/libgit2:lg2_example_hdrs"],
    copts = COMMON_COPTS + [
        "-DLIBGIT2_NO_FEATURES_H",
        "-Dmain=lg2_main",
        "-DIOS_SYSTEM_GIT_LFS",
        "-Wno-format",
        "-Wno-pointer-sign",
        "-Wno-unused-parameter",
    ],
    includes = ["."],
    sdk_frameworks = [
        "CoreFoundation",
        "Security",
    ],
    deps = [
        ":api",
        ":git_lfs",
        "//Vendors/libgit2",
    ],
)

objc_library(
    name = "cmd_sshpass",
    srcs = ["sshpass.c"],
    copts = COMMON_COPTS,
    deps = [":api"],
)

objc_library(
    name = "ios_system_support",
    srcs = [
        "getopt_long.c",
        "ios_system_support.c",
    ],
    hdrs = ["ios_system_support.h"],
    copts = COMMON_COPTS + ["-DIOS_SYSTEM_GETOPT"],
    includes = ["."],
    deps = [":api"],
)

objc_library(
    name = "cmd_basename",
    srcs = ["shell_cmds/basename/basename.c"],
    hdrs = glob(["shell_cmds/basename/*.h"]),
    copts = COMMON_COPTS,
    includes = ["shell_cmds/basename"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_dirname",
    srcs = ["shell_cmds/dirname/dirname.c"],
    hdrs = glob(["shell_cmds/dirname/*.h"]),
    copts = COMMON_COPTS,
    includes = ["shell_cmds/dirname"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_realpath",
    srcs = ["shell_cmds/realpath/realpath.c"],
    hdrs = glob(["shell_cmds/realpath/*.h"]),
    copts = COMMON_COPTS,
    includes = ["shell_cmds/realpath"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_mktemp",
    srcs = ["shell_cmds/mktemp/mktemp.c"],
    hdrs = glob(["shell_cmds/mktemp/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=mktemp_main",
        "-Dusage=mktemp_usage",
    ],
    includes = ["shell_cmds/mktemp"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_cut",
    srcs = ["text_cmds/cut/cut.c"],
    hdrs = glob(["text_cmds/cut/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=cut_main",
        "-Dusage=cut_usage",
    ],
    includes = ["text_cmds/cut"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_comm",
    srcs = ["text_cmds/comm/comm.c"],
    hdrs = glob(["text_cmds/comm/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=comm_main",
        "-Dusage=comm_usage",
    ],
    includes = ["text_cmds/comm"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_paste",
    srcs = ["text_cmds/paste/paste.c"],
    hdrs = glob(["text_cmds/paste/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=paste_main",
        "-Dusage=paste_usage",
    ],
    includes = ["text_cmds/paste"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_join",
    srcs = ["text_cmds/join/join.c"],
    hdrs = glob(["text_cmds/join/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=join_main",
        "-Dusage=join_usage",
    ],
    includes = ["text_cmds/join"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_split",
    srcs = ["text_cmds/split/split.c"],
    hdrs = glob(["text_cmds/split/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=split_main",
        "-Dusage=split_usage",
    ],
    includes = ["text_cmds/split"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_df",
    srcs = [
        "file_cmds/df/df.c",
        "file_cmds/df/vfslist.c",
    ],
    copts = COMMON_COPTS + [
        "-Dcheckvfsname=df_checkvfsname",
        "-Dmakevfslist=df_makevfslist",
    ],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_du",
    srcs = ["file_cmds/du/du.c"],
    hdrs = glob(["file_cmds/du/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=du_main",
        "-Dusage=du_usage",
    ],
    includes = ["file_cmds/du"],
    deps = [
        ":cmd_ls",
        ":ios_system_support",
    ],
)

objc_library(
    name = "cmd_chmod",
    srcs = [
        "file_cmds/chmod/chmod.c",
        "file_cmds/chmod/chmod_acl.c",
    ],
    hdrs = glob(["file_cmds/chmod/*.h"]),
    copts = COMMON_COPTS,
    includes = ["file_cmds/chmod"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_cmp",
    srcs = [
        "text_cmds/cmp/cmp.c",
        "text_cmds/cmp/misc.c",
        "text_cmds/cmp/regular.c",
        "text_cmds/cmp/special.c",
    ],
    hdrs = glob(["text_cmds/cmp/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=cmp_main",
        "-Dlflag=cmp_lflag",
        "-Dsflag=cmp_sflag",
        "-Dfatal=cmp_fatal",
        "-Dfatalx=cmp_fatalx",
        "-Ddiffmsg=cmp_diffmsg",
        "-Deofmsg=cmp_eofmsg",
        "-Dusage=cmp_usage",
    ],
    includes = ["text_cmds/cmp"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_diff",
    srcs = ["text_cmds/diff/diff.c"],
    copts = COMMON_COPTS + ["-DLIBGIT2_NO_FEATURES_H"],
    deps = [
        ":ios_system_support",
        "//Vendors/libgit2",
    ],
)

objc_library(
    name = "cmd_xxd",
    srcs = ["text_cmds/xxd/xxd.c"],
    hdrs = glob(["text_cmds/xxd/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=xxd_main",
        "-Dversion=xxd_version",
        "-Dosver=xxd_osver",
        "-Dusage=xxd_usage",
    ],
    includes = ["text_cmds/xxd"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_sha256sum",
    srcs = ["text_cmds/md5/md5.c"],
    hdrs = glob(["text_cmds/md5/*.h"]),
    copts = COMMON_COPTS + [
        "-Dmain=sha256sum_main",
        "-Dusage=sha256sum_usage",
    ],
    includes = ["text_cmds/md5"],
    deps = [":ios_system_support"],
)

objc_library(
    name = "cmd_base64",
    srcs = ["file_cmds/base64/base64.c"],
    hdrs = glob(["file_cmds/base64/*.h"]),
    copts = COMMON_COPTS + ["-Dusage=base64_usage"],
    includes = ["file_cmds/base64"],
    linkopts = ["-lresolv"],
    deps = [":ios_system_support"],
)

apple_resource_group(
    name = "native_command_notices",
    resources = [
        "NATIVE_COMMANDS.md",
        "NativeCommandLicenses.txt",
    ],
)

objc_library(
    name = "command_registry",
    srcs = ["ios_system_command_registry.c"],
    copts = COMMON_COPTS,
    includes = ["."],
    deps = [
        ":cmd_base64",
        ":cmd_basename",
        ":cmd_chmod",
        ":cmd_cmp",
        ":cmd_comm",
        ":cmd_cut",
        ":cmd_df",
        ":cmd_diff",
        ":cmd_dirname",
        ":cmd_du",
        ":cmd_join",
        ":cmd_mktemp",
        ":cmd_paste",
        ":cmd_realpath",
        ":cmd_sha256sum",
        ":cmd_split",
        ":cmd_sshpass",
        ":cmd_xxd",
        ":ios_system_support",
        ":registry_api",
        "//Vendors/FFmpeg:command",
        "//Vendors/InfoZip:unzip",
        "//Vendors/InfoZip:zip",
        "//Vendors/LibreOffice:command",
        "//Vendors/Ripgrep:api",
        "//Vendors/jq",
        "//Vendors/libcaca:img2txt",
        "@OpenSSH//:commands",
        "@ripgrep//:rg",
    ],
    alwayslink = True,
)

objc_library(
    name = "ios_system",
    # Reuse the API module so an embedded Swift command and its host can depend
    # on the API and full runtime together without defining ios_system twice.
    deps = [
        ":awk",
        ":cmd_git",
        ":command_registry",
        ":core",
        ":curl_http",
        ":files_basic",
        ":ios_system_api",
        ":shell",
        ":text_basic",
        "@OpenSSH//:commands",
    ],
)

objc_library(
    name = "native_command_validation_suite",
    srcs = ["NativeCommandValidation.m"],
    hdrs = ["NativeCommandValidation.h"],
    sdk_frameworks = ["Foundation"],
    deps = [
        ":ios_system",
        ":registry_api",
    ],
)

objc_library(
    name = "native_command_validation_main",
    srcs = ["NativeCommandValidationMain.m"],
    sdk_frameworks = ["Foundation"],
    deps = [":native_command_validation_suite"],
)

macos_command_line_application(
    name = "native_command_validation",
    bundle_id = "com.liuliu.ios-system-native-validation",
    minimum_os_version = "13.5",
    deps = [
        ":native_command_validation_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

objc_library(
    name = "validation_main",
    srcs = ["ValidationMain.m"],
    sdk_frameworks = ["UIKit"],
    deps = [":native_command_validation_suite"],
)

ios_application(
    name = "ios_system_validation_app",
    bundle_id = "com.liuliu.ios-system-validation",
    families = [
        "iphone",
        "ipad",
    ],
    infoplists = ["ValidationInfo.plist"],
    minimum_os_version = "15.4",
    tags = ["manual"],
    deps = [
        ":validation_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

objc_library(
    name = "openssh_validation_main",
    srcs = [
        "OpenSSHKeygenValidation.m",
        "OpenSSHValidationMain.m",
    ],
    sdk_frameworks = ["Foundation"],
    deps = [":ios_system"],
)

macos_command_line_application(
    name = "openssh_validation",
    bundle_id = "com.liuliu.ios-system-openssh-validation",
    minimum_os_version = "13.5",
    tags = ["manual"],
    deps = [
        ":openssh_validation_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

objc_library(
    name = "osh_validation_main",
    srcs = ["OSHValidationMain.m"],
    sdk_frameworks = ["Foundation"],
    deps = [":ios_system"],
)

macos_command_line_application(
    name = "osh_validation",
    bundle_id = "com.liuliu.ios-system-osh-validation",
    minimum_os_version = "13.5",
    tags = ["manual"],
    deps = [
        ":osh_validation_main",
        "//Vendors/NodeJS:NodeMobile",
        "//Vendors/PythonIOS:PythonRuntime",
    ],
)

sh_test(
    name = "NativeCommandTests",
    size = "medium",
    srcs = ["run-native-command-tests.sh"],
    data = [
        "validate-diff.py",
        "validate-infozip.py",
        "validate-jq.py",
        ":native_command_validation",
        ":osh_validation",
        "//Vendors/jq:test_data",
    ],
)

sh_test(
    name = "OSHIntegrationTests",
    size = "small",
    srcs = ["run-osh-tests.sh"],
    data = [":osh_validation"],
)

objc_library(
    name = "git_lfs_validation_main",
    testonly = True,
    srcs = ["GitLFSValidationMain.m"],
    sdk_frameworks = ["Foundation"],
    deps = [":git_lfs"],
)

macos_command_line_application(
    name = "GitLFSValidation",
    testonly = True,
    bundle_id = "com.liuliu.git-lfs-validation",
    minimum_os_version = "13.5",
    deps = [":git_lfs_validation_main"],
)

sh_test(
    name = "GitLFSTests",
    size = "small",
    srcs = ["run-git-lfs-tests.sh"],
    data = [
        "validate-git-lfs.py",
        ":GitLFSValidation",
    ],
)
