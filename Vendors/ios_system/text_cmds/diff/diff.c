/*
 * Embedded diff frontend, using the git_patch_from_buffers / git_patch_free
 * pattern from libgit2's CC0 examples/diff.c. The comparison engine remains in
 * libgit2; this command owns input buffers, options, and diff(1) formatting.
 */
#include <ctype.h>
#include <errno.h>
#include <fnmatch.h>
#include <git2.h>
#include <limits.h>
#include <regex.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wchar.h>
#include <wctype.h>
#include "ios_system_support.h"

enum output_format { NORMAL, UNIFIED, CONTEXT, ED, FORWARD_ED, RCS, IFDEF };
struct pattern { regex_t regex; struct pattern *next; };
struct exclusion { char *text; struct exclusion *next; };
struct options {
    enum output_format format;
    unsigned int flags;
    int context, tabsize;
    bool text, brief, identical, recursive, new_file, new_left;
    bool ignore_case, file_case, expand_tabs, initial_tab, strip_cr, function;
    const char *labels[2], *starting_file, *ifdef_name;
    struct pattern *patterns;
    struct exclusion *exclusions;
    int argc;
    char **argv;
};
struct input {
    char *data, *comparison;
    size_t length, lines, *offsets;
    struct stat info;
};
struct change { size_t start[2], count[2]; };
struct ancestor {
    const struct ancestor *parent;
    struct stat info[2];
    unsigned depth;
};

static void usage(int status)
{
    fprintf(status ? stderr : stdout,
        "usage: diff [-abBdiNpqrsTtw] [-c | -C lines | -u | -U lines | -e | -f | -n | -D name]\n"
        "            [-I pattern] [-L label] [-S file] [-x pattern] [-X file] file1 file2\n"
        "       Exit status: 0 equal, 1 different, 2 error.\n");
    if (status != 0) exit(status);
}

static void *resize(void *pointer, size_t count, size_t size)
{
    void *result = ios_system_reallocarray(pointer, count, size);
    if (result == NULL) err(2, "allocation");
    return result;
}

static int number(const char *text, int minimum)
{
    char *end;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno || *text == '\0' || *end || value < minimum || value > INT_MAX)
        errx(2, "invalid number: %s", text);
    return (int)value;
}

static void exclude(struct options *options, const char *text)
{
    struct exclusion *entry = resize(NULL, 1, sizeof(*entry));
    entry->text = strdup(text);
    if (entry->text == NULL) err(2, "allocation");
    entry->next = options->exclusions;
    options->exclusions = entry;
}

static void read_exclusions(struct options *options, const char *path)
{
    FILE *file = strcmp(path, "-") ? ios_system_fopen(path, "r") : stdin;
    if (file == NULL) err(2, "%s", path);
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, file)) >= 0) {
        if (length && line[length - 1] == '\n') line[--length] = '\0';
        exclude(options, line);
    }
    if (ferror(file)) err(2, "%s", path);
    free(line);
    if (file != stdin) fclose(file);
}

static int read_input(struct input *input, const char *path, bool missing,
    const struct options *options)
{
    FILE *file = NULL;
    size_t capacity = BUFSIZ;
    if (!missing) {
        file = strcmp(path, "-") ? ios_system_fopen(path, "rb") : stdin;
        if (file == NULL) { warn("%s", path); return 2; }
        if (fstat(fileno(file), &input->info) != 0) {
            warn("%s", path);
            if (file != stdin) fclose(file);
            return 2;
        }
    }
    input->data = resize(NULL, capacity + 1, 1);
    while (file != NULL) {
        size_t count = fread(input->data + input->length, 1, capacity - input->length, file);
        input->length += count;
        if (ferror(file)) {
            warn("%s", path);
            if (file != stdin) fclose(file);
            return 2;
        }
        if (feof(file)) break;
        /* xdiff uses signed line/byte indexes internally (same bound as Git). */
        if (capacity >= 1023UL * 1024 * 1024) {
            warnx("%s: input exceeds xdiff's size limit", path);
            if (file != stdin) fclose(file);
            return 2;
        }
        capacity *= 2;
        if (capacity > 1023UL * 1024 * 1024) capacity = 1023UL * 1024 * 1024;
        input->data = resize(input->data, capacity + 1, 1);
    }
    if (file != NULL && file != stdin) fclose(file);
    input->data[input->length] = '\0';
    if (options->strip_cr) {
        size_t length = 0;
        for (size_t index = 0; index < input->length; ++index) {
            if (input->data[index] == '\r' && index + 1 < input->length && input->data[index + 1] == '\n')
                continue;
            input->data[length++] = input->data[index];
        }
        input->data[input->length = length] = '\0';
    }
    return 0;
}

static void index_lines(struct input *input)
{
    for (size_t index = 0; index < input->length; ++index)
        if (input->data[index] == '\n') ++input->lines;
    if (input->length && input->data[input->length - 1] != '\n') ++input->lines;
    input->offsets = resize(NULL, input->lines + 1, sizeof(size_t));
    size_t line = 0;
    input->offsets[line++] = 0;
    for (size_t index = 0; index < input->length; ++index)
        if (input->data[index] == '\n') input->offsets[line++] = index + 1;
    input->offsets[input->lines] = input->length;
}

static size_t fold_case(struct input *input)
{
    size_t capacity = input->length + 1;
    input->comparison = resize(NULL, capacity, 1);
    size_t offset = 0, length = 0;
    mbstate_t reader = {0}, writer = {0};
    while (offset < input->length) {
        wchar_t character;
        char encoded[MB_LEN_MAX];
        size_t written, count = mbrtowc(&character, input->data + offset, input->length - offset, &reader);
        if (count == (size_t)-1 || count == (size_t)-2 || count == 0) {
            count = written = 1;
            encoded[0] = input->data[offset];
            memset(&reader, 0, sizeof(reader));
        } else {
            written = wcrtomb(encoded, towlower(character), &writer);
            if (written == (size_t)-1) {
                memcpy(encoded, input->data + offset, count);
                written = count;
                memset(&writer, 0, sizeof(writer));
            }
        }
        if (length + written + 1 > capacity) {
            capacity = (length + written + 1) * 2;
            input->comparison = resize(input->comparison, capacity, 1);
        }
        memcpy(input->comparison + length, encoded, written);
        length += written;
        offset += count;
    }
    input->comparison[length] = '\0';
    return length;
}

static bool ignored(const struct options *options, const struct input *input, size_t line)
{
    size_t start = input->offsets[line], length = input->offsets[line + 1] - start;
    if (length && input->data[start + length - 1] == '\n') --length;
    for (struct pattern *pattern = options->patterns; pattern != NULL; pattern = pattern->next) {
        regmatch_t match = {0, (regoff_t)length};
        if (regexec(&pattern->regex, input->data + start, 1, &match, REG_STARTEND) == 0)
            return true;
    }
    return false;
}

static void print_line(const struct input *input, size_t line, const char *prefix,
    const struct options *options, bool marker)
{
    size_t begin = input->offsets[line], end = input->offsets[line + 1];
    if (*prefix && options->initial_tab) {
        putchar(prefix[0]);
        putchar('\t');
    } else fputs(prefix, stdout);
    if (options->expand_tabs) {
        size_t column = 0;
        for (size_t index = begin; index < end; ++index) {
            unsigned char character = input->data[index];
            if (character == '\t') {
                do { putchar(' '); ++column; } while (column % options->tabsize);
            } else {
                putchar(character);
                if (character == '\b' && column) --column;
                else if (character == '\r') column = 0;
                else if ((character & 0xc0) != 0x80) ++column;
            }
        }
    } else fwrite(input->data + begin, 1, end - begin, stdout);
    if (marker && end > begin && input->data[end - 1] != '\n')
        fputs("\n\\ No newline at end of file\n", stdout);
}

static void print_range(size_t start, size_t count, bool unified)
{
    printf("%zu", count ? start + 1 : start);
    if (unified) { if (count != 1) printf(",%zu", count); }
    else if (count > 1) printf(",%zu", start + count);
}

static void print_label(const struct options *options, const struct input *input,
    const char *path, int side, const char *prefix)
{
    printf("%s %s", prefix, options->labels[side] ? options->labels[side] : path);
    if (options->labels[side] == NULL) {
        struct tm time;
        char text[64];
        localtime_r(&input->info.st_mtime, &time);
        strftime(text, sizeof(text), "%Y-%m-%d %H:%M:%S", &time);
        printf("\t%s.%09ld ", text, input->info.st_mtimespec.tv_nsec);
        strftime(text, sizeof(text), "%z", &time);
        fputs(text, stdout);
    }
    putchar('\n');
}

static void print_function(const struct input *input, size_t before)
{
    while (before > 0) {
        size_t index = --before, start = input->offsets[index];
        unsigned char character = input->data[start];
        if (!isalpha(character) && character != '_' && character != '$') continue;
        size_t length = input->offsets[index + 1] - start;
        while (length && isspace((unsigned char)input->data[start + length - 1])) --length;
        if (length > 40) length = 40;
        putchar(' ');
        fwrite(input->data + start, 1, length, stdout);
        return;
    }
}

static void print_context(const struct input inputs[2], const struct change *changes,
    size_t first, size_t last, const struct options *options)
{
    size_t begin[2], end[2];
    for (int side = 0; side < 2; ++side) {
        begin[side] = changes[first].start[side] > (size_t)options->context ?
            changes[first].start[side] - options->context : 0;
        end[side] = changes[last].start[side] + changes[last].count[side] + options->context;
        if (end[side] > inputs[side].lines) end[side] = inputs[side].lines;
    }
    if (options->format == UNIFIED) {
        fputs("@@ -", stdout); print_range(begin[0], end[0] - begin[0], true);
        fputs(" +", stdout); print_range(begin[1], end[1] - begin[1], true);
        fputs(" @@", stdout);
        if (options->function) print_function(&inputs[0], changes[first].start[0]);
        putchar('\n');
        size_t old = begin[0];
        for (size_t index = first; index <= last; ++index) {
            const struct change *change = &changes[index];
            while (old < change->start[0]) print_line(&inputs[0], old++, " ", options, true);
            for (size_t line = 0; line < change->count[0]; ++line)
                print_line(&inputs[0], old++, "-", options, true);
            for (size_t line = 0; line < change->count[1]; ++line)
                print_line(&inputs[1], change->start[1] + line, "+", options, true);
        }
        while (old < end[0]) print_line(&inputs[0], old++, " ", options, true);
    } else {
        fputs("***************", stdout);
        if (options->function) print_function(&inputs[0], changes[first].start[0]);
        putchar('\n');
        for (int side = 0; side < 2; ++side) {
            fputs(side ? "--- " : "*** ", stdout);
            print_range(begin[side], end[side] - begin[side], false);
            fputs(side ? " ----\n" : " ****\n", stdout);
            bool has_changes = false;
            for (size_t index = first; index <= last; ++index)
                has_changes |= changes[index].count[side] != 0;
            if (!has_changes) continue;
            size_t current = first;
            for (size_t line = begin[side]; line < end[side]; ++line) {
                while (current <= last && line >= changes[current].start[side] + changes[current].count[side]) ++current;
                const char *prefix = "  ";
                if (current <= last && line >= changes[current].start[side])
                    prefix = changes[current].count[1 - side] ? "! " : side ? "+ " : "- ";
                print_line(&inputs[side], line, prefix, options, true);
            }
        }
    }
}

static void print_changes(const struct input inputs[2], const struct change *changes,
    size_t count, const struct options *options)
{
    size_t unchanged = 0;
    for (size_t index = 0; index < count; ++index) {
        const struct change *change = &changes[options->format == ED ? count - index - 1 : index];
        size_t old = change->count[0], new = change->count[1];
        char action = !old ? 'a' : !new ? 'd' : 'c';
        if (options->format == UNIFIED || options->format == CONTEXT) {
            size_t last = index;
            while (last + 1 < count && changes[last + 1].start[0] -
                (changes[last].start[0] + changes[last].count[0]) <= 2UL * options->context &&
                changes[last + 1].start[1] - (changes[last].start[1] + changes[last].count[1]) <= 2UL * options->context) ++last;
            print_context(inputs, changes, index, last, options);
            index = last;
        } else if (options->format == IFDEF) {
            while (unchanged < change->start[0]) print_line(&inputs[0], unchanged++, "", options, false);
            printf(old ? "#ifndef %s\n" : "#ifdef %s\n", options->ifdef_name);
            for (size_t line = 0; line < old; ++line) print_line(&inputs[0], change->start[0] + line, "", options, false);
            if (old && new) printf("#else /* %s */\n", options->ifdef_name);
            for (size_t line = 0; line < new; ++line) print_line(&inputs[1], change->start[1] + line, "", options, false);
            printf("#endif /* %s */\n", options->ifdef_name);
            unchanged = change->start[0] + old;
        } else if (options->format == RCS) {
            if (old) printf("d%zu %zu\n", change->start[0] + 1, old);
            if (new) printf("a%zu %zu\n", change->start[0] + old, new);
            for (size_t line = 0; line < new; ++line) print_line(&inputs[1], change->start[1] + line, "", options, false);
        } else {
            if (options->format == FORWARD_ED) {
                printf("%c%zu", action, old ? change->start[0] + 1 : change->start[0]);
                if (old > 1) printf(" %zu", change->start[0] + old);
            } else print_range(change->start[0], old, false);
            if (options->format != FORWARD_ED) putchar(action);
            if (options->format == NORMAL) print_range(change->start[1], new, false);
            putchar('\n');
            if (options->format == NORMAL) {
                for (size_t line = 0; line < old; ++line) print_line(&inputs[0], change->start[0] + line, "< ", options, true);
                if (old && new) fputs("---\n", stdout);
            }
            for (size_t line = 0; line < new; ++line) {
                size_t start = inputs[1].offsets[change->start[1] + line];
                size_t length = inputs[1].offsets[change->start[1] + line + 1] - start;
                bool dot = options->format == ED && length == 2 && !memcmp(inputs[1].data + start, ".\n", 2);
                if (dot) printf("..\n.\n%zus/.//\n", change->start[0] + line + 1);
                else print_line(&inputs[1], change->start[1] + line, options->format == NORMAL ? "> " : "", options, options->format == NORMAL);
                if (dot && line + 1 < new) printf("%zua\n", change->start[0] + line + 1);
                if (dot && line + 1 == new) new = 0; /* insertion already terminated */
            }
            if (options->format != NORMAL && new) fputs(".\n", stdout);
        }
    }
    if (options->format == IFDEF)
        while (unchanged < inputs[0].lines) print_line(&inputs[0], unchanged++, "", options, false);
}

static int compare_files(const char *paths[2], const bool missing[2],
    const struct options *options, bool directory)
{
    struct input inputs[2] = {0};
    struct change *changes = NULL;
    git_patch *patch = NULL;
    int status = 2;
    for (int side = 0; side < 2; ++side) {
        if (side == 1 && !strcmp(paths[0], "-") && !strcmp(paths[1], "-")) {
            inputs[1].length = inputs[0].length;
            inputs[1].info = inputs[0].info;
            inputs[1].data = resize(NULL, inputs[0].length + 1, 1);
            memcpy(inputs[1].data, inputs[0].data, inputs[0].length + 1);
        } else if (read_input(&inputs[side], paths[side], missing[side], options)) goto done;
    }
    bool binary = !options->text && (memchr(inputs[0].data, 0, inputs[0].length) || memchr(inputs[1].data, 0, inputs[1].length));
    size_t count = 0;
    if (binary) {
        status = inputs[0].length != inputs[1].length || memcmp(inputs[0].data, inputs[1].data, inputs[0].length);
        status = status != 0;
    } else {
        git_diff_options settings = GIT_DIFF_OPTIONS_INIT;
        settings.flags = options->flags | GIT_DIFF_FORCE_TEXT;
        settings.context_lines = 0;
        const char *data[2];
        size_t lengths[2];
        for (int side = 0; side < 2; ++side) {
            index_lines(&inputs[side]);
            lengths[side] = options->ignore_case ? fold_case(&inputs[side]) : inputs[side].length;
            data[side] = options->ignore_case ? inputs[side].comparison : inputs[side].data;
        }
        if (git_patch_from_buffers(&patch, data[0], lengths[0], paths[0], data[1], lengths[1], paths[1], &settings) < 0) {
            const git_error *error = git_error_last();
            warnx("%s", error ? error->message : "cannot generate diff");
            goto done;
        }
        size_t hunks = git_patch_num_hunks(patch);
        if (hunks) changes = resize(NULL, hunks, sizeof(*changes));
        for (size_t index = 0; index < hunks; ++index) {
            const git_diff_hunk *hunk;
            if (git_patch_get_hunk(&hunk, NULL, patch, index) < 0) goto done;
            struct change change = {{hunk->old_start - (hunk->old_lines != 0), hunk->new_start - (hunk->new_lines != 0)},
                {hunk->old_lines, hunk->new_lines}};
            bool skip = options->patterns != NULL;
            for (int side = 0; skip && side < 2; ++side)
                for (size_t line = 0; skip && line < change.count[side]; ++line)
                    skip = ignored(options, &inputs[side], change.start[side] + line);
            if (!skip) changes[count++] = change;
        }
        status = count != 0;
    }
    const char *labels[2] = {options->labels[0] ? options->labels[0] : paths[0], options->labels[1] ? options->labels[1] : paths[1]};
    if (!status && options->identical) printf("Files %s and %s are identical\n", labels[0], labels[1]);
    if (status && (options->brief || binary))
        printf("%s %s and %s differ\n", binary && !options->brief ? "Binary files" : "Files", labels[0], labels[1]);
    else if (!binary && !options->brief) {
        if (count && directory) {
            fputs("diff", stdout);
            for (int index = 1; index < options->argc; ++index) printf(" %s", options->argv[index]);
            printf(" %s %s\n", paths[0], paths[1]);
        }
        if (count && (options->format == UNIFIED || options->format == CONTEXT)) {
            print_label(options, &inputs[0], paths[0], 0, options->format == UNIFIED ? "---" : "***");
            print_label(options, &inputs[1], paths[1], 1, options->format == UNIFIED ? "+++" : "---");
        }
        print_changes(inputs, changes, count, options);
    }
    if (ferror(stdout)) status = 2;
done:
    git_patch_free(patch);
    free(changes);
    for (int side = 0; side < 2; ++side) {
        free(inputs[side].data);
        free(inputs[side].comparison);
        free(inputs[side].offsets);
    }
    return status;
}

static int select_entry(const struct dirent *entry)
{
    return strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..");
}

static int compare_names(void *context, const void *a, const void *b)
{
    const struct options *options = context;
    const struct dirent *left = *(struct dirent *const *)a, *right = *(struct dirent *const *)b;
    return options->file_case ? strcasecmp(left->d_name, right->d_name) : strcmp(left->d_name, right->d_name);
}

static int compare_paths(const char *paths[2], const struct options *options,
    const struct ancestor *ancestor, bool nested)
{
    struct ancestor current = {.parent = ancestor, .depth = ancestor ? ancestor->depth + 1 : 0};
    bool missing[2] = {false, false}, directory[2] = {false, false};
    for (int side = 0; side < 2; ++side) {
        if (!strcmp(paths[side], "-")) continue;
        if (ios_system_stat(paths[side], &current.info[side]) != 0) {
            if (errno != ENOENT || !(options->new_file || (!side && options->new_left))) {
                warn("%s", paths[side]); return 2;
            }
            missing[side] = true;
        } else directory[side] = S_ISDIR(current.info[side].st_mode);
    }
    if (missing[0]) directory[0] = directory[1];
    if (missing[1]) directory[1] = directory[0];
    if (directory[0] != directory[1]) {
        if (nested) {
            printf("File %s is a %s while file %s is a %s\n", paths[0], directory[0] ? "directory" : "regular file", paths[1], directory[1] ? "directory" : "regular file");
            return 1;
        }
        int side = directory[0] ? 0 : 1;
        if (!strcmp(paths[1 - side], "-")) { warnx("cannot compare stdin to a directory"); return 2; }
        const char *base = strrchr(paths[1 - side], '/');
        base = base ? base + 1 : paths[1 - side];
        char *child;
        if (asprintf(&child, "%s/%s", paths[side], base) < 0) err(2, "allocation");
        const char *pair[2] = {side ? paths[0] : child, side ? child : paths[1]};
        int status = compare_paths(pair, options, ancestor, true);
        free(child);
        return status;
    }
    if (!directory[0]) {
        if (nested) {
            for (int side = 0; side < 2; ++side)
                if (!missing[side] && !S_ISREG(current.info[side].st_mode)) {
                    printf("File %s is not a regular file; skipped\n", paths[side]);
                    return 0;
                }
        }
        return compare_files(paths, missing, options, nested);
    }
    if (nested && !options->recursive) {
        printf("Common subdirectories: %s and %s\n", paths[0], paths[1]);
        return 0;
    }
    if (options->format == IFDEF) { warnx("-D does not support directory comparisons"); return 2; }
    for (const struct ancestor *parent = ancestor; parent != NULL; parent = parent->parent)
        for (int side = 0; side < 2; ++side)
            if (!missing[side] && parent->info[side].st_ino == current.info[side].st_ino &&
                parent->info[side].st_dev == current.info[side].st_dev) {
                warnx("%s: recursive directory loop", paths[side]); return 2;
            }
    if (current.depth >= 128) { warnx("directory nesting exceeds 128 levels"); return 2; }
    struct dirent **entries[2] = {NULL, NULL};
    int counts[2] = {0, 0}, positions[2] = {0, 0}, status = 0;
    for (int side = 0; side < 2; ++side) {
        if (!missing[side]) counts[side] = ios_system_scandir(paths[side], &entries[side], select_entry, NULL);
        if (counts[side] < 0) { warn("%s", paths[side]); status = 2; goto done; }
        if (counts[side] > 1) qsort_r(entries[side], counts[side], sizeof(*entries[side]), (void *)options, compare_names);
    }
    while (positions[0] < counts[0] || positions[1] < counts[1]) {
        const char *names[2] = {positions[0] < counts[0] ? entries[0][positions[0]]->d_name : NULL,
            positions[1] < counts[1] ? entries[1][positions[1]]->d_name : NULL};
        int comparison = !names[0] ? 1 : !names[1] ? -1 : options->file_case ? strcasecmp(names[0], names[1]) : strcmp(names[0], names[1]);
        int side = comparison > 0;
        const char *name = names[side];
        bool skip = !nested && options->starting_file && strcmp(name, options->starting_file) < 0;
        for (struct exclusion *entry = options->exclusions; !skip && entry != NULL; entry = entry->next)
            skip = fnmatch(entry->text, name, 0) == 0;
        if (!skip) {
            if (comparison && !options->new_file && !(side && options->new_left)) {
                printf("Only in %s: %s\n", paths[side], name);
                if (status < 1) status = 1;
            } else {
                char *children[2];
                for (int index = 0; index < 2; ++index)
                    if (asprintf(&children[index], "%s/%s", paths[index], comparison ? name : names[index]) < 0) err(2, "allocation");
                const char *pair[2] = {children[0], children[1]};
                int result = compare_paths(pair, options, &current, true);
                if (result > status) status = result;
                free(children[0]); free(children[1]);
            }
        }
        if (comparison <= 0) ++positions[0];
        if (comparison >= 0) ++positions[1];
    }
done:
    for (int side = 0; side < 2; ++side) {
        for (int index = 0; index < counts[side]; ++index) free(entries[side][index]);
        free(entries[side]);
    }
    return status;
}

int diff_main(int argc, char **argv)
{
    ios_system_support_init(argv);
    struct options options = {.context = 3, .tabsize = 8, .argv = argv};
    enum { STRIP_CR = 256, TABSIZE, FILE_CASE, NO_FILE_CASE, NORMAL_FORMAT, HELP, VERSION };
    static const struct option long_options[] = {
        {"text", no_argument, NULL, 'a'}, {"ignore-space-change", no_argument, NULL, 'b'},
        {"ignore-blank-lines", no_argument, NULL, 'B'}, {"context", optional_argument, NULL, 'C'},
        {"minimal", no_argument, NULL, 'd'}, {"ifdef", required_argument, NULL, 'D'},
        {"ed", no_argument, NULL, 'e'}, {"forward-ed", no_argument, NULL, 'f'},
        {"speed-large-files", no_argument, NULL, 'H'}, {"ignore-case", no_argument, NULL, 'i'},
        {"ignore-matching-lines", required_argument, NULL, 'I'}, {"label", required_argument, NULL, 'L'},
        {"paginate", no_argument, NULL, 'l'}, {"new-file", no_argument, NULL, 'N'},
        {"rcs", no_argument, NULL, 'n'}, {"unidirectional-new-file", no_argument, NULL, 'P'},
        {"show-c-function", no_argument, NULL, 'p'}, {"brief", no_argument, NULL, 'q'},
        {"recursive", no_argument, NULL, 'r'}, {"report-identical-files", no_argument, NULL, 's'},
        {"starting-file", required_argument, NULL, 'S'}, {"expand-tabs", no_argument, NULL, 't'},
        {"initial-tab", no_argument, NULL, 'T'}, {"unified", optional_argument, NULL, 'U'},
        {"ignore-all-space", no_argument, NULL, 'w'}, {"exclude", required_argument, NULL, 'x'},
        {"exclude-from", required_argument, NULL, 'X'}, {"strip-trailing-cr", no_argument, NULL, STRIP_CR},
        {"tabsize", required_argument, NULL, TABSIZE}, {"ignore-file-name-case", no_argument, NULL, FILE_CASE},
        {"no-ignore-file-name-case", no_argument, NULL, NO_FILE_CASE}, {"normal", no_argument, NULL, NORMAL_FORMAT},
        {"help", no_argument, NULL, HELP}, {"version", no_argument, NULL, VERSION}, {NULL, 0, NULL, 0}
    };
    int option, status = 0;
    while ((option = getopt_long(argc, argv, "abBC:c::dD:efHhiI:L:lNnPpqrsS:tTU:u::wx:X:", long_options, NULL)) != -1) {
        switch (option) {
        case 'a': options.text = true; break;
        case 'b': options.flags |= GIT_DIFF_IGNORE_WHITESPACE_CHANGE; break;
        case 'B': options.flags |= GIT_DIFF_IGNORE_BLANK_LINES; break;
        case 'c': case 'C': options.format = CONTEXT; if (optarg) options.context = number(optarg, 0); break;
        case 'd': options.flags |= GIT_DIFF_MINIMAL; break;
        case 'D': options.format = IFDEF; options.ifdef_name = optarg; break;
        case 'e': options.format = ED; break;
        case 'f': options.format = FORWARD_ED; break;
        case 'H': case 'h': break;
        case 'i': options.ignore_case = true; break;
        case 'I': {
            struct pattern *pattern = resize(NULL, 1, sizeof(*pattern));
            int error = regcomp(&pattern->regex, optarg, REG_EXTENDED);
            if (error) { char text[256]; regerror(error, &pattern->regex, text, sizeof(text)); errx(2, "%s", text); }
            pattern->next = options.patterns; options.patterns = pattern;
            break;
        }
        case 'L':
            if (!options.labels[0]) options.labels[0] = optarg;
            else if (!options.labels[1]) options.labels[1] = optarg;
            else usage(2);
            break;
        case 'l': errx(2, "-l/--paginate is unavailable in the embedded shell");
        case 'N': options.new_file = true; break;
        case 'n': options.format = RCS; break;
        case 'P': options.new_left = true; break;
        case 'p': options.function = true; if (options.format == NORMAL) options.format = CONTEXT; break;
        case 'q': options.brief = true; break;
        case 'r': options.recursive = true; break;
        case 's': options.identical = true; break;
        case 'S': options.starting_file = optarg; break;
        case 't': options.expand_tabs = true; break;
        case 'T': options.initial_tab = true; break;
        case 'u': case 'U': options.format = UNIFIED; if (optarg) options.context = number(optarg, 0); break;
        case 'w': options.flags |= GIT_DIFF_IGNORE_WHITESPACE; break;
        case 'x': exclude(&options, optarg); break;
        case 'X': read_exclusions(&options, optarg); break;
        case STRIP_CR: options.strip_cr = true; break;
        case TABSIZE: options.tabsize = number(optarg, 1); break;
        case FILE_CASE: options.file_case = true; break;
        case NO_FILE_CASE: options.file_case = false; break;
        case NORMAL_FORMAT: options.format = NORMAL; break;
        case HELP: usage(0); goto cleanup;
        case VERSION: printf("diff (libgit2 %s)\n", LIBGIT2_VERSION); goto cleanup;
        default: usage(2);
        }
    }
    if (argc - optind != 2) usage(2);
    options.argc = optind;
    const char *paths[2] = {argv[optind], argv[optind + 1]};
    if (git_libgit2_init() < 0) errx(2, "cannot initialize libgit2");
    status = compare_paths(paths, &options, NULL, false);
    git_libgit2_shutdown();
cleanup:
    while (options.patterns) {
        struct pattern *next = options.patterns->next;
        regfree(&options.patterns->regex); free(options.patterns); options.patterns = next;
    }
    while (options.exclusions) {
        struct exclusion *next = options.exclusions->next;
        free(options.exclusions->text); free(options.exclusions); options.exclusions = next;
    }
    if (fflush(stdout) != 0 || ferror(stdout)) status = 2;
    ios_system_support_cleanup(NULL);
    exit(status);
}
