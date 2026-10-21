// In-process Git LFS support for the libgit2 command frontend.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <curl/curl.h>
#include <git2.h>
#include <git2/sys/filter.h>
#include <git2/sys/config.h>
#include <git2/sys/errors.h>
#include <pthread.h>
#include <sys/stat.h>
#include <limits.h>
#include "ios_system/ios_system.h"

static int lfs_error(NSString *message) {
    git_error_set_str(GIT_ERROR_FILTER, message.UTF8String);
    return -1;
}

// Extension-bearing pointers require a corresponding extension implementation.
// Reject those rather than downloading bytes with the wrong transformation.
static NSDictionary *lfs_pointer(NSData *data) {
    if (data.length == 0 || data.length >= 1024) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count != 4 || ![lines[0] isEqual:@"version https://git-lfs.github.com/spec/v1"] ||
        ![lines[1] hasPrefix:@"oid sha256:"] || ![lines[2] hasPrefix:@"size "] ||
        ![lines[3] isEqual:@""]) return nil;
    NSString *oid = [lines[1] substringFromIndex:11];
    NSString *size = [lines[2] substringFromIndex:5];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    if (oid.length != 64 || [oid rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound ||
        size.length == 0 || [size rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound ||
        (size.length > 1 && [size hasPrefix:@"0"])) return nil;
    errno = 0;
    unsigned long long length = strtoull(size.UTF8String, NULL, 10);
    if (errno || length > LLONG_MAX) return nil;
    return @{@"oid": oid, @"size": @(length)};
}

static BOOL lfs_pointer_envelope(NSData *data) {
    const char *prefix = "version https://git-lfs.github.com/spec/";
    return data.length >= strlen(prefix) && !memcmp(data.bytes, prefix, strlen(prefix));
}

static NSString *lfs_object_path(git_repository *repo, NSString *oid) {
    NSString *root = @(git_repository_commondir(repo));
    return [root stringByAppendingPathComponent:[NSString stringWithFormat:
        @"lfs/objects/%@/%@/%@", [oid substringToIndex:2], [oid substringWithRange:NSMakeRange(2, 2)], oid]];
}

static BOOL lfs_verify(NSString *path, NSDictionary *pointer) {
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return NO;
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char bytes[65536], digest[CC_SHA256_DIGEST_LENGTH];
    unsigned long long length = 0;
    size_t count;
    BOOL cancelled = NO;
    while ((count = fread(bytes, 1, sizeof(bytes), file)) != 0) {
        if (ios_commandCancellationRequested(ios_getCommandCancellationContext())) {
            cancelled = YES;
            break;
        }
        CC_SHA256_Update(&hash, bytes, (CC_LONG)count);
        length += count;
    }
    BOOL valid = !ferror(file) && !cancelled && length == [pointer[@"size"] unsignedLongLongValue];
    fclose(file);
    CC_SHA256_Final(digest, &hash);
    NSMutableString *oid = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < sizeof(digest); i++) [oid appendFormat:@"%02x", digest[i]];
    return valid && [oid isEqual:pointer[@"oid"]];
}

static NSString *lfs_config(git_repository *repo, NSString *key) {
    git_config *config = NULL;
    git_buf value = GIT_BUF_INIT;
    NSString *result = nil;
    if (git_repository_config_snapshot(&config, repo) == 0 &&
        git_config_get_string_buf(&value, config, key.UTF8String) == 0) result = @(value.ptr);
    git_buf_dispose(&value);
    git_config_free(config);
    return result;
}

static NSString *lfs_default_remote(git_repository *repo) {
    git_reference *head = NULL;
    NSString *remote = nil;
    if (git_repository_head(&head, repo) == 0 && git_reference_is_branch(head))
        remote = lfs_config(repo, [NSString stringWithFormat:@"branch.%s.remote", git_reference_shorthand(head)]);
    git_reference_free(head);
    if (remote && ![remote isEqual:@"."]) return remote;
    git_strarray names = {0};
    remote = @"origin";
    if (git_remote_list(&names, repo) == 0 && names.count == 1) remote = @(names.strings[0]);
    git_strarray_dispose(&names);
    return remote;
}

static NSDictionary *lfs_batch_headers(git_repository *repo, NSString *endpoint, NSString *remote) {
    NSMutableDictionary *headers = [@{@"Accept": @"application/vnd.git-lfs+json",
                                     @"Content-Type": @"application/vnd.git-lfs+json"} mutableCopy];
    // Use the same configured credentials as the existing Git frontend, but
    // never forward them to a different host selected by .lfsconfig.
    NSURL *url = [NSURL URLWithString:endpoint];
    NSURL *origin = [NSURL URLWithString:lfs_config(repo, [NSString stringWithFormat:@"remote.%@.url", remote]) ?: @""];
    if ([url.host.lowercaseString isEqual:origin.host.lowercaseString] &&
        [url.scheme.lowercaseString isEqual:origin.scheme.lowercaseString] &&
        ((url.port == nil && origin.port == nil) || [url.port isEqual:origin.port])) {
        NSString *username = origin.user.stringByRemovingPercentEncoding ?: lfs_config(repo, @"user.name");
        NSString *password = origin.password.stringByRemovingPercentEncoding ?: lfs_config(repo, @"user.password");
        if (username && password) {
            NSData *credentials = [[NSString stringWithFormat:@"%@:%@", username, password]
                dataUsingEncoding:NSUTF8StringEncoding];
            headers[@"Authorization"] = [@"Basic " stringByAppendingString:[credentials base64EncodedStringWithOptions:0]];
        }
    }
    // URL-scoped headers also allow bearer tokens without process-global state.
    NSString *extra = lfs_config(repo, [NSString stringWithFormat:@"http.%@.extraheader", endpoint]);
    if (extra) {
        NSRange colon = [extra rangeOfString:@":"];
        if (colon.location != NSNotFound) headers[[extra substringToIndex:colon.location]] =
            [[extra substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return headers;
}

static NSDictionary *lfs_action_headers(git_repository *repo, NSDictionary *action, NSString *endpoint, NSString *remote) {
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:action[@"header"] ?: @{}];
    NSURL *url = [NSURL URLWithString:action[@"href"]];
    NSURL *batch = [NSURL URLWithString:endpoint];
    if ([url.host.lowercaseString isEqual:batch.host.lowercaseString] &&
        [url.scheme.lowercaseString isEqual:batch.scheme.lowercaseString] &&
        ((url.port == nil && batch.port == nil) || [url.port isEqual:batch.port])) {
        NSDictionary *credentials = lfs_batch_headers(repo, endpoint, remote);
        for (NSString *key in credentials) {
            if ([key isEqual:@"Accept"] || [key isEqual:@"Content-Type"]) continue;
            BOOL supplied = NO;
            for (NSString *existing in headers) {
                if ([existing caseInsensitiveCompare:key] == NSOrderedSame) { supplied = YES; break; }
            }
            if (!supplied) headers[key] = credentials[key];
        }
    }
    return headers;
}

static NSString *lfs_endpoint(git_repository *repo, NSString *remote, BOOL upload) {
    NSString *url = upload ? lfs_config(repo, @"lfs.pushurl") : nil;
    if (!url && upload) url = lfs_config(repo, [NSString stringWithFormat:@"remote.%@.lfspushurl", remote]);
    if (!url) url = lfs_config(repo, @"lfs.url");
    if (!url) url = lfs_config(repo, [NSString stringWithFormat:@"remote.%@.lfsurl", remote]);
    if (url) return url;
    // Only the LFS URL is read from the repository-controlled .lfsconfig.
    const char *workdir = git_repository_workdir(repo);
    if (workdir) {
        git_config *config = NULL;
        git_buf value = GIT_BUF_INIT;
        NSString *path = [@(workdir) stringByAppendingPathComponent:@".lfsconfig"];
        if (git_config_open_ondisk(&config, path.fileSystemRepresentation) == 0 &&
            git_config_get_string_buf(&value, config, "lfs.url") == 0) url = @(value.ptr);
        git_buf_dispose(&value);
        git_config_free(config);
        if (!url) {
            git_object *blob = NULL;
            git_config_backend *backend = NULL;
            config = NULL;
            if (git_revparse_single(&blob, repo, "HEAD:.lfsconfig") == 0 &&
                git_object_type(blob) == GIT_OBJECT_BLOB && git_blob_rawsize((git_blob *)blob) < 65536 &&
                git_config_backend_from_string(&backend, git_blob_rawcontent((git_blob *)blob),
                    (size_t)git_blob_rawsize((git_blob *)blob), NULL) == 0) {
                if (git_config_new(&config) == 0 &&
                    git_config_add_backend(config, backend, GIT_CONFIG_LEVEL_LOCAL, NULL, 0) == 0) {
                    backend = NULL; // Owned by config after successful insertion.
                    if (git_config_get_string_buf(&value, config, "lfs.url") == 0) url = @(value.ptr);
                }
                if (backend) backend->free(backend);
                git_buf_dispose(&value);
                git_config_free(config);
            }
            git_object_free(blob);
        }
        if (url) return url;
    }
    url = lfs_config(repo, [NSString stringWithFormat:@"remote.%@.url", remote]);
    if (!url) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    if (![components.scheme.lowercaseString isEqual:@"http"] &&
        ![components.scheme.lowercaseString isEqual:@"https"]) return url;
    NSString *path = components.path;
    while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if (![path hasSuffix:@".git"]) path = [path stringByAppendingString:@".git"];
    components.path = [path stringByAppendingString:@"/info/lfs"];
    return components.string;
}

static NSString *lfs_batch_url(NSString *endpoint) {
    NSURLComponents *url = [NSURLComponents componentsWithString:endpoint];
    NSString *path = url.path;
    while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    url.path = [path stringByAppendingString:@"/objects/batch"];
    return url.string;
}

static size_t lfs_receive_json(char *bytes, size_t size, size_t count, void *context) {
    NSMutableData *data = (__bridge NSMutableData *)context;
    size_t length = size * count;
    if (length > 4 * 1024 * 1024 || data.length > 4 * 1024 * 1024 - length) return 0;
    [data appendBytes:bytes length:length];
    return length;
}

typedef struct {
    FILE *file;
    unsigned long long remaining;
} LFSDownloadSink;

static size_t lfs_receive_file(char *bytes, size_t size, size_t count, void *context) {
    LFSDownloadSink *sink = context;
    size_t length = size * count;
    if (length > sink->remaining) return 0;
    size_t written = fwrite(bytes, 1, length, sink->file);
    sink->remaining -= written;
    return written;
}

static int lfs_progress(void *context, curl_off_t total, curl_off_t now,
                        curl_off_t uploadTotal, curl_off_t uploadNow) {
    return ios_commandCancellationRequested(context);
}

static void lfs_initialize_curl(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

static int lfs_http(NSString *url, NSDictionary *headers, NSData *body,
                    NSMutableData *response, FILE *file, FILE *upload, unsigned long long transferSize) {
    if (ios_commandCancellationRequested(ios_getCommandCancellationContext()))
        return lfs_error(@"Git LFS transfer cancelled.");
    if (!url.length) return lfs_error(@"Invalid Git LFS endpoint URL.");
    NSURL *parsed = [NSURL URLWithString:url];
    if (!parsed.host || (![[parsed.scheme lowercaseString] isEqual:@"https"] &&
                         ![[parsed.scheme lowercaseString] isEqual:@"http"]))
        return lfs_error(@"Git LFS requires an HTTP(S) endpoint; configure lfs.url for SSH remotes.");
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, lfs_initialize_curl);
    CURL *curl = curl_easy_init();
    if (!curl) return lfs_error(@"Unable to initialize Git LFS HTTP transfer.");
    struct curl_slist *list = NULL;
    for (NSString *key in headers) {
        id value = headers[key];
        if (![value isKindOfClass:NSString.class] ||
            [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
            [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
            curl_slist_free_all(list);
            curl_easy_cleanup(curl);
            return lfs_error(@"Invalid Git LFS action header.");
        }
        list = curl_slist_append(list, [NSString stringWithFormat:@"%@: %@", key, value].UTF8String);
    }
    curl_easy_setopt(curl, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, list);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 60L);
    // Batch redirects can change POST semantics; object URLs may redirect to a CDN.
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, (body || upload) ? 0L : 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR,
                     [parsed.scheme.lowercaseString isEqual:@"https"] ? "https" : "http,https");
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, lfs_progress);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, ios_getCommandCancellationContext());
    if (upload) {
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(curl, CURLOPT_READDATA, upload);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)transferSize);
    }
    if (body) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.bytes);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body.length);
    }
    LFSDownloadSink sink = {file, transferSize};
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, file ? lfs_receive_file : lfs_receive_json);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, file ? (void *)&sink : (__bridge void *)response);
    CURLcode result = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(list);
    curl_easy_cleanup(curl);
    if (result != CURLE_OK) return lfs_error([NSString stringWithFormat:
        @"Git LFS transfer failed: %s", curl_easy_strerror(result)]);
    if (status < 200 || status >= 300) return lfs_error([NSString stringWithFormat:
        @"Git LFS server returned HTTP %ld.", status]);
    return 0;
}

static int lfs_download(git_repository *repo, NSDictionary *pointer, NSString *remote) {
    NSString *path = lfs_object_path(repo, pointer[@"oid"]);
    if (lfs_verify(path, pointer)) return 0;
    if (ios_commandCancellationRequested(ios_getCommandCancellationContext()))
        return lfs_error(@"Git LFS transfer cancelled.");
    NSString *endpoint = lfs_endpoint(repo, remote, NO);
    if (!endpoint) return lfs_error(@"No Git LFS endpoint. Configure a remote or lfs.url.");
    while ([endpoint hasSuffix:@"/"]) endpoint = [endpoint substringToIndex:endpoint.length - 1];
    NSDictionary *request = @{@"operation": @"download", @"transfers": @[@"basic"],
                              @"objects": @[pointer], @"hash_algo": @"sha256"};
    NSData *body = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSMutableData *response = [NSMutableData data];
    if (lfs_http(lfs_batch_url(endpoint),
                 lfs_batch_headers(repo, endpoint, remote),
                 body, response, NULL, NULL, 0) < 0) return -1;
    id batch = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    if (![batch isKindOfClass:NSDictionary.class] ||
        (batch[@"transfer"] && ![batch[@"transfer"] isEqual:@"basic"]) ||
        (batch[@"hash_algo"] && ![batch[@"hash_algo"] isEqual:@"sha256"]) ||
        ![batch[@"objects"] isKindOfClass:NSArray.class] || [batch[@"objects"] count] != 1)
        return lfs_error(@"Invalid Git LFS batch response.");
    id object = batch[@"objects"][0];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"oid"] isEqual:pointer[@"oid"]] ||
        ![object[@"size"] isEqual:pointer[@"size"]] || object[@"error"])
        return lfs_error(@"Git LFS server did not provide the requested object.");
    id actions = object[@"actions"];
    id action = [actions isKindOfClass:NSDictionary.class] ? actions[@"download"] : nil;
    if (![action isKindOfClass:NSDictionary.class] || ![action[@"href"] isKindOfClass:NSString.class] ||
        (action[@"header"] && ![action[@"header"] isKindOfClass:NSDictionary.class]))
        return lfs_error(@"Missing Git LFS download action.");
    NSError *error = nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES attributes:nil error:&error]) return lfs_error(error.localizedDescription);
    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    FILE *file = fopen(temporary.fileSystemRepresentation, "wbx");
    if (!file) return lfs_error(@"Unable to create Git LFS temporary object.");
    int result = lfs_http(action[@"href"], lfs_action_headers(repo, action, endpoint, remote), nil, nil, file, NULL, [pointer[@"size"] unsignedLongLongValue]);
    if (fclose(file) != 0 && result == 0) result = lfs_error(@"Unable to write Git LFS object.");
    if (result == 0 && !lfs_verify(temporary, pointer)) result = lfs_error(@"Git LFS object hash or size mismatch.");
    if (result == 0 && rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0)
        result = lfs_error(@"Unable to store Git LFS object.");
    [manager removeItemAtPath:temporary error:nil];
    return result;
}

static int lfs_upload(git_repository *repo, NSDictionary *pointer, NSString *remote) {
    NSString *endpoint = lfs_endpoint(repo, remote, YES);
    if (!endpoint) return lfs_error(@"No Git LFS upload endpoint.");
    while ([endpoint hasSuffix:@"/"]) endpoint = [endpoint substringToIndex:endpoint.length - 1];
    NSData *body = [NSJSONSerialization dataWithJSONObject:
        @{@"operation": @"upload", @"transfers": @[@"basic"], @"objects": @[pointer], @"hash_algo": @"sha256"}
        options:0 error:nil];
    NSMutableData *response = [NSMutableData data];
    if (lfs_http(lfs_batch_url(endpoint),
                 lfs_batch_headers(repo, endpoint, remote),
                 body, response, NULL, NULL, 0) < 0) return -1;
    id batch = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    if (![batch isKindOfClass:NSDictionary.class] ||
        (batch[@"transfer"] && ![batch[@"transfer"] isEqual:@"basic"]) ||
        (batch[@"hash_algo"] && ![batch[@"hash_algo"] isEqual:@"sha256"]) ||
        ![batch[@"objects"] isKindOfClass:NSArray.class] || [batch[@"objects"] count] != 1)
        return lfs_error(@"Invalid Git LFS upload batch response.");
    id object = batch[@"objects"][0];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"oid"] isEqual:pointer[@"oid"]] ||
        ![object[@"size"] isEqual:pointer[@"size"]] || object[@"error"])
        return lfs_error(@"Git LFS server rejected the upload object.");
    id actions = object[@"actions"];
    if (!actions) return 0; // Server already has this object, including historical objects absent locally.
    if (![actions isKindOfClass:NSDictionary.class]) return lfs_error(@"Invalid Git LFS upload actions.");
    id action = actions[@"upload"];
    if (!action) return 0;
    if (![action isKindOfClass:NSDictionary.class] || ![action[@"href"] isKindOfClass:NSString.class] ||
        (action[@"header"] && ![action[@"header"] isKindOfClass:NSDictionary.class]))
        return lfs_error(@"Invalid Git LFS upload action.");
    NSString *path = lfs_object_path(repo, pointer[@"oid"]);
    if (!lfs_verify(path, pointer)) return lfs_error(@"Required Git LFS upload object is missing or corrupt. Git refs were not pushed.");
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return lfs_error(@"Unable to open Git LFS upload object.");
    NSMutableData *ignored = [NSMutableData data];
    int result = lfs_http(action[@"href"], lfs_action_headers(repo, action, endpoint, remote), nil, ignored, NULL, file,
                          [pointer[@"size"] unsignedLongLongValue]);
    fclose(file);
    id verify = actions[@"verify"];
    if (result == 0 && verify) {
        if (![verify isKindOfClass:NSDictionary.class] || ![verify[@"href"] isKindOfClass:NSString.class] ||
            (verify[@"header"] && ![verify[@"header"] isKindOfClass:NSDictionary.class]))
            return lfs_error(@"Invalid Git LFS verification action.");
        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:lfs_action_headers(repo, verify, endpoint, remote)];
        headers[@"Content-Type"] = @"application/vnd.git-lfs+json";
        NSData *verification = [NSJSONSerialization dataWithJSONObject:pointer options:0 error:nil];
        [ignored setLength:0];
        result = lfs_http(verify[@"href"], headers, verification, ignored, NULL, NULL, 0);
    }
    return result;
}

typedef struct {
    git_repository *repo;
    void *objects;
    void *blobs;
} LFSTreeContext;

static int lfs_collect_tree(const char *root, const git_tree_entry *entry, void *payload) {
    LFSTreeContext *context = payload;
    if (ios_commandCancellationRequested(ios_getCommandCancellationContext()))
        return lfs_error(@"Git LFS push cancelled.");
    if (git_tree_entry_type(entry) != GIT_OBJECT_BLOB) return 0;
    char id[GIT_OID_MAX_HEXSIZE + 1];
    git_oid_tostr(id, sizeof(id), git_tree_entry_id(entry));
    NSMutableSet *blobs = (__bridge NSMutableSet *)context->blobs;
    if ([blobs containsObject:@(id)]) return 0;
    [blobs addObject:@(id)];
    git_blob *blob = NULL;
    if (git_blob_lookup(&blob, context->repo, git_tree_entry_id(entry)) < 0) return -1;
    NSDictionary *pointer = nil;
    BOOL invalid = NO;
    if (git_blob_rawsize(blob) < 1024) {
        NSData *data = [NSData dataWithBytes:git_blob_rawcontent(blob) length:(NSUInteger)git_blob_rawsize(blob)];
        pointer = lfs_pointer(data);
        invalid = !pointer && lfs_pointer_envelope(data);
    }
    git_blob_free(blob);
    if (invalid) return lfs_error(@"Unsupported or malformed Git LFS pointer in pushed history.");
    if (pointer) ((__bridge NSMutableDictionary *)context->objects)[pointer[@"oid"]] = pointer;
    return 0;
}

int ios_git_lfs_push(git_repository *repo, const char *remote, const git_strarray *refspecs) {
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    int result = 0;
    @autoreleasepool {
        git_revwalk *walk = NULL;
        result = git_revwalk_new(&walk, repo);
        for (size_t i = 0; i < refspecs->count && result == 0; i++) {
            NSString *spec = @(refspecs->strings[i]);
            if ([spec hasPrefix:@"-"]) { result = lfs_error(@"Unsupported Git LFS push option."); break; }
            if ([spec hasPrefix:@"+"]) spec = [spec substringFromIndex:1];
            NSString *source = [spec componentsSeparatedByString:@":"][0];
            if (!source.length) continue; // Deleting a ref does not upload content.
            if ([source containsString:@"*"]) {
                result = git_revwalk_push_glob(walk, source.UTF8String);
            } else {
                git_object *object = NULL, *commit = NULL;
                result = git_revparse_single(&object, repo, source.UTF8String);
                if (result == 0) result = git_object_peel(&commit, object, GIT_OBJECT_COMMIT);
                if (result == 0) result = git_revwalk_push(walk, git_object_id(commit));
                git_object_free(commit);
                git_object_free(object);
            }
        }
        NSMutableDictionary *objects = [NSMutableDictionary dictionary];
        NSMutableSet *blobs = [NSMutableSet set];
        LFSTreeContext context = {repo, (__bridge void *)objects, (__bridge void *)blobs};
        git_oid oid;
        int next = GIT_ITEROVER;
        while (result == 0 && (next = git_revwalk_next(&oid, walk)) == 0) {
            git_commit *commit = NULL;
            git_tree *tree = NULL;
            result = git_commit_lookup(&commit, repo, &oid);
            if (result == 0) result = git_commit_tree(&tree, commit);
            if (result == 0) result = git_tree_walk(tree, GIT_TREEWALK_PRE, lfs_collect_tree, &context);
            git_tree_free(tree);
            git_commit_free(commit);
        }
        if (result == 0 && next != GIT_ITEROVER) result = next;
        git_revwalk_free(walk);
        for (NSDictionary *pointer in objects.allValues) {
            if (result != 0) break;
            result = lfs_upload(repo, pointer, @(remote));
        }
    }
    pthread_setcancelstate(previous, NULL);
    return result;
}

// Keep both directions streaming: model files can exceed the app's memory budget.
typedef struct {
    git_writestream stream;
    git_writestream *next;
    git_repository *repo;
    git_filter_mode_t mode;
    FILE *file;
    char *temporary;
    CC_SHA256_CTX hash;
    unsigned long long length;
    unsigned char prefix[1024];
    int failed;
} LFSFilterStream;

static int lfs_filter_write(git_writestream *base, const char *bytes, size_t length) {
    LFSFilterStream *stream = (LFSFilterStream *)base;
    if (stream->failed) return -1;
    if (ios_commandCancellationRequested(ios_getCommandCancellationContext())) {
        stream->failed = 1;
        return lfs_error(@"Git LFS filtering cancelled.");
    }
    if (stream->length < sizeof(stream->prefix))
        memcpy(stream->prefix + stream->length, bytes, MIN(length, sizeof(stream->prefix) - stream->length));
    for (size_t offset = 0; offset < length;) {
        size_t count = MIN(length - offset, 65536);
        CC_SHA256_Update(&stream->hash, bytes + offset, (CC_LONG)count);
        offset += count;
    }
    if (length > LLONG_MAX - stream->length || fwrite(bytes, 1, length, stream->file) != length) {
        stream->failed = 1;
        return lfs_error(@"Unable to spool Git LFS input.");
    }
    stream->length += length;
    return 0;
}

static int lfs_filter_close(git_writestream *base) {
    LFSFilterStream *stream = (LFSFilterStream *)base;
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    int result = 0;
    @autoreleasepool {
        if (fclose(stream->file) != 0) stream->failed = 1;
        stream->file = NULL;
        if (stream->failed || ios_commandCancellationRequested(ios_getCommandCancellationContext())) {
            result = lfs_error(@"Git LFS filtering failed or was cancelled.");
        } else {
            NSData *prefix = [NSData dataWithBytes:stream->prefix length:(NSUInteger)MIN(stream->length, sizeof(stream->prefix))];
            NSDictionary *pointer = stream->length < 1024 ? lfs_pointer(prefix) : nil;
            NSString *path = @(stream->temporary);
            NSData *output = nil;
            if (!pointer && lfs_pointer_envelope(prefix)) {
                result = lfs_error(@"Unsupported or malformed Git LFS pointer.");
            } else if (stream->mode == GIT_FILTER_SMUDGE) {
                const char *skip = ios_getenv("GIT_LFS_SKIP_SMUDGE");
                if (pointer && !(skip && (!strcmp(skip, "1") || !strcmp(skip, "true")))) {
                    result = lfs_download(stream->repo, pointer, lfs_default_remote(stream->repo));
                    path = lfs_object_path(stream->repo, pointer[@"oid"]);
                }
            } else if (!pointer && stream->length != 0) {
                unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256_Final(digest, &stream->hash);
                NSMutableString *oid = [NSMutableString stringWithCapacity:64];
                for (int i = 0; i < sizeof(digest); i++) [oid appendFormat:@"%02x", digest[i]];
                NSString *object = lfs_object_path(stream->repo, oid);
                NSError *error = nil;
                if (![NSFileManager.defaultManager createDirectoryAtPath:object.stringByDeletingLastPathComponent
                      withIntermediateDirectories:YES attributes:nil error:&error]) {
                    result = lfs_error(error.localizedDescription);
                } else if (rename(stream->temporary, object.fileSystemRepresentation) != 0) {
                    result = lfs_error(@"Unable to store cleaned Git LFS object.");
                } else {
                    output = [[NSString stringWithFormat:
                        @"version https://git-lfs.github.com/spec/v1\noid sha256:%@\nsize %llu\n", oid, stream->length]
                        dataUsingEncoding:NSUTF8StringEncoding];
                }
            }
            if (result == 0 && output) {
                result = stream->next->write(stream->next, output.bytes, output.length);
            } else if (result == 0) {
                FILE *file = fopen(path.fileSystemRepresentation, "rb");
                if (!file) result = lfs_error(@"Unable to read Git LFS filter result.");
                else {
                    char bytes[65536];
                    size_t count;
                    while (result == 0 && (count = fread(bytes, 1, sizeof(bytes), file)) != 0) {
                        if (ios_commandCancellationRequested(ios_getCommandCancellationContext()))
                            result = lfs_error(@"Git LFS filtering cancelled.");
                        else result = stream->next->write(stream->next, bytes, count);
                    }
                    if (ferror(file) && result == 0) result = lfs_error(@"Unable to read Git LFS filter result.");
                    fclose(file);
                }
            }
        }
        const git_error *error = result != 0 ? git_error_last() : NULL;
        NSString *message = error ? @(error->message) : @"Git LFS filtering failed.";
        int closed = stream->next->close(stream->next);
        if (result != 0) lfs_error(message);
        else result = closed;
    }
    pthread_setcancelstate(previous, NULL);
    return result;
}

static void lfs_filter_free(git_writestream *base) {
    LFSFilterStream *stream = (LFSFilterStream *)base;
    if (stream->file) fclose(stream->file);
    if (stream->temporary) unlink(stream->temporary);
    free(stream->temporary);
    free(stream);
}

static int lfs_filter_stream(git_writestream **out, git_filter *filter, void **payload,
                             const git_filter_source *source, git_writestream *next) {
    LFSFilterStream *stream = calloc(1, sizeof(*stream));
    if (!stream) return lfs_error(@"Unable to allocate Git LFS filter.");
    stream->stream.write = lfs_filter_write;
    stream->stream.close = lfs_filter_close;
    stream->stream.free = lfs_filter_free;
    stream->next = next;
    stream->repo = git_filter_source_repo(source);
    stream->mode = git_filter_source_mode(source);
    CC_SHA256_Init(&stream->hash);
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    int result = 0;
    @autoreleasepool {
        NSString *directory = [@(git_repository_commondir(stream->repo)) stringByAppendingPathComponent:@"lfs/tmp"];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            result = lfs_error(error.localizedDescription);
        } else {
            stream->temporary = strdup([directory stringByAppendingPathComponent:@"filter-XXXXXX"].fileSystemRepresentation);
            int fd = stream->temporary ? mkstemp(stream->temporary) : -1;
            if (fd >= 0) {
                stream->file = fdopen(fd, "w+b");
                if (!stream->file) close(fd);
            }
            if (!stream->file) result = lfs_error(@"Unable to create Git LFS filter spool.");
        }
    }
    if (result == 0) *out = &stream->stream;
    else lfs_filter_free(&stream->stream);
    pthread_setcancelstate(previous, NULL);
    return result;
}

int ios_git_lfs_register(void) {
    static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    static git_filter filter = { .version = GIT_FILTER_VERSION, .attributes = "filter=lfs", .stream = lfs_filter_stream };
    pthread_mutex_lock(&mutex);
    int result = git_filter_lookup("lfs") ? 0 : git_filter_register("lfs", &filter, GIT_FILTER_DRIVER_PRIORITY);
    pthread_mutex_unlock(&mutex);
    return result;
}

int lg2_lfs(git_repository *providedRepo, int argc, char **argv) {
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    int result = 0;
    @autoreleasepool {
        NSString *command = argc > 1 ? @(argv[1]) : @"help";
        FILE *output = ios_stdout() ?: stdout;
        if ([command isEqual:@"version"] || [command isEqual:@"--version"]) {
            fprintf(output, "git-lfs (ios_system native client)\n");
        } else if ([command isEqual:@"help"] || [command isEqual:@"--help"]) {
            fprintf(output, "usage: git lfs <install|track [patterns...]|fetch [remote]|pull [remote]|checkout|push remote [refs...]|ls-files|version>\n"
                    "Downloads LFS objects for the current index; checkout preserves modified files.\n"
                    "HTTP(S) basic transfers only. Locking, migration, custom transfers and pointer extensions are unsupported.\n");
        } else if (![command isEqual:@"fetch"] && ![command isEqual:@"pull"] &&
                   ![command isEqual:@"checkout"] && ![command isEqual:@"ls-files"] &&
                   ![command isEqual:@"track"] && ![command isEqual:@"install"] && ![command isEqual:@"push"]) {
            result = lfs_error(@"Unsupported Git LFS command. Run 'git lfs help' for supported commands.");
        } else if ((![command isEqual:@"track"] && ![command isEqual:@"push"] &&
                    argc > (([command isEqual:@"fetch"] || [command isEqual:@"pull"]) ? 3 : 2)) ||
                   (argc >= 3 && argv[2][0] == '-') || ([command isEqual:@"push"] && argc < 3)) {
            result = lfs_error(@"Unsupported Git LFS arguments. Run 'git lfs help'.");
        } else {
            git_repository *repo = providedRepo;
            git_index *index = NULL;
            if ((!repo && git_repository_open_ext(&repo, ".", 0, NULL) < 0) || git_repository_index(&index, repo) < 0) {
                result = -1;
            } else if (!git_repository_workdir(repo)) {
                result = lfs_error(@"Git LFS requires a working tree.");
            } else if ([command isEqual:@"install"]) {
                // Native filters and the pre-push path are always registered.
                fprintf(output, "Git LFS initialized (native clean/smudge and pre-push).\n");
            } else if ([command isEqual:@"track"]) {
                NSString *path = [@(git_repository_workdir(repo)) stringByAppendingPathComponent:@".gitattributes"];
                NSError *error = nil;
                NSMutableString *attributes = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error] mutableCopy];
                if (!attributes && error.code != NSFileReadNoSuchFileError) {
                    result = lfs_error(error.localizedDescription);
                } else {
                    if (!attributes) attributes = [NSMutableString string];
                    for (int i = 2; i < argc && result == 0; i++) {
                        NSString *pattern = @(argv[i]);
                        if (!pattern.length || [pattern hasPrefix:@"!"] || [pattern hasPrefix:@"-"] ||
                            [pattern rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
                            result = lfs_error(@"Invalid Git LFS tracking pattern."); break;
                        }
                        pattern = [[pattern stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                                   stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
                        pattern = [pattern stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
                        NSString *line = [NSString stringWithFormat:@"\"%@\" filter=lfs diff=lfs merge=lfs -text", pattern];
                        if (![[attributes componentsSeparatedByString:@"\n"] containsObject:line]) {
                            if (attributes.length && ![attributes hasSuffix:@"\n"]) [attributes appendString:@"\n"];
                            [attributes appendFormat:@"%@\n", line];
                        }
                    }
                    if (argc == 2) fprintf(output, "%s", attributes.UTF8String);
                    else if (result == 0 && ![attributes writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error])
                        result = lfs_error(error.localizedDescription);
                }
            } else if ([command isEqual:@"push"]) {
                char *head = "HEAD";
                git_strarray refs = argc > 3 ? (git_strarray){argv + 3, (size_t)argc - 3} : (git_strarray){&head, 1};
                result = ios_git_lfs_push(repo, argv[2], &refs);
            } else {
                NSString *remote = argc == 3 ? @(argv[2]) : lfs_default_remote(repo);
                for (size_t i = 0; i < git_index_entrycount(index) && result == 0; i++) {
                    const git_index_entry *entry = git_index_get_byindex(index, i);
                    if (GIT_INDEX_ENTRY_STAGE(entry) != 0 ||
                        (entry->mode != GIT_FILEMODE_BLOB && entry->mode != GIT_FILEMODE_BLOB_EXECUTABLE)) continue;
                    git_blob *blob = NULL;
                    if (git_blob_lookup(&blob, repo, &entry->id) < 0) { result = -1; break; }
                    NSDictionary *pointer = nil;
                    BOOL invalid = NO;
                    if (git_blob_rawsize(blob) < 1024) {
                        NSData *data = [NSData dataWithBytes:git_blob_rawcontent(blob) length:(NSUInteger)git_blob_rawsize(blob)];
                        pointer = lfs_pointer(data);
                        invalid = !pointer && lfs_pointer_envelope(data);
                    }
                    git_blob_free(blob);
                    if (invalid) { result = lfs_error(@"Unsupported or malformed Git LFS pointer in index."); break; }
                    if (!pointer) continue;
                    if ([command isEqual:@"ls-files"]) {
                        fprintf(output, "%s - %s\n", [pointer[@"oid"] UTF8String], entry->path);
                        continue;
                    }
                    if (![command isEqual:@"checkout"] && lfs_download(repo, pointer, remote) < 0) { result = -1; break; }
                    if ([command isEqual:@"fetch"]) continue;
                    NSString *object = lfs_object_path(repo, pointer[@"oid"]);
                    if (!lfs_verify(object, pointer)) { result = lfs_error(@"Git LFS object missing or corrupt; run 'git lfs fetch'."); break; }
                    NSString *path = [@(git_repository_workdir(repo)) stringByAppendingPathComponent:@(entry->path)];
                    // Only replace the exact indexed pointer, never edits, missing
                    // files or symlinks. Foundation resolves path components, so
                    // also reject symlinks in every parent beneath the worktree.
                    NSString *parent = path;
                    BOOL symlink = NO;
                    while (parent.length > strlen(git_repository_workdir(repo))) {
                        struct stat st;
                        if (lstat(parent.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode)) { symlink = YES; break; }
                        parent = parent.stringByDeletingLastPathComponent;
                    }
                    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
                    if (symlink || [attributes fileSize] >= 1024 || ![attributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
                    NSData *current = [NSData dataWithContentsOfFile:path];
                    if (![lfs_pointer(current) isEqual:pointer]) continue;
                    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
                    NSError *error = nil;
                    if (![NSFileManager.defaultManager copyItemAtPath:object toPath:temporary error:&error]) {
                        result = lfs_error(error.localizedDescription); break;
                    }
                    if (chmod(temporary.fileSystemRepresentation, entry->mode & 0777) != 0 ||
                        rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0)
                        result = lfs_error(@"Unable to check out Git LFS object.");
                    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
                }
            }
            git_index_free(index);
            if (!providedRepo) git_repository_free(repo);
        }
    }
    pthread_setcancelstate(previous, NULL);
    return result;
}

extern int lg2_main(int, char **);
int git_lfs_main(int argc, char **argv) {
    char **arguments = calloc((size_t)argc + 2, sizeof(char *));
    if (!arguments) return 1;
    arguments[0] = "git";
    arguments[1] = "lfs";
    for (int i = 1; i < argc; i++) arguments[i + 1] = argv[i];
    int result = lg2_main(argc + 1, arguments);
    free(arguments);
    return result;
}
