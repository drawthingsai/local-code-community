#ifndef IOS_COMMAND_DIGEST_H
#define IOS_COMMAND_DIGEST_H

#include <CommonCrypto/CommonDigest.h>
#include <limits.h>

/* Keep the BSD command's digest interface while using the public SDK's
 * implementation. No additional cryptography library is linked. */
#define COMMAND_DIGEST(name, ccname, context_type, digest_size) \
    typedef context_type name##_CTX; \
    static void name##_Init(name##_CTX *context) { ccname##_Init(context); } \
    static void name##_Update(name##_CTX *context, const unsigned char *bytes, size_t length) { \
        while (length > UINT_MAX) { \
            ccname##_Update(context, bytes, UINT_MAX); \
            bytes += UINT_MAX; length -= UINT_MAX; \
        } \
        ccname##_Update(context, bytes, (CC_LONG)length); \
    } \
    static char *name##_End(name##_CTX *context, char *output) { \
        unsigned char digest[digest_size]; \
        static const char hex[] = "0123456789abcdef"; \
        ccname##_Final(digest, context); \
        for (size_t i = 0; i < digest_size; ++i) { \
            output[i * 2] = hex[digest[i] >> 4]; \
            output[i * 2 + 1] = hex[digest[i] & 15]; \
        } \
        output[digest_size * 2] = '\0'; \
        return output; \
    } \
    static char *name##_Data(const void *bytes, unsigned int length, char *output) { \
        name##_CTX context; \
        name##_Init(&context); name##_Update(&context, bytes, length); \
        return name##_End(&context, output); \
    }

COMMAND_DIGEST(BSD_MD5, CC_MD5, CC_MD5_CTX, CC_MD5_DIGEST_LENGTH)
typedef BSD_MD5_CTX MD5_CTX;
#define MD5Init BSD_MD5_Init
#define MD5Update BSD_MD5_Update
#define MD5End BSD_MD5_End
#define MD5Data BSD_MD5_Data
COMMAND_DIGEST(SHA1, CC_SHA1, CC_SHA1_CTX, CC_SHA1_DIGEST_LENGTH)
COMMAND_DIGEST(SHA224, CC_SHA224, CC_SHA256_CTX, CC_SHA224_DIGEST_LENGTH)
COMMAND_DIGEST(SHA256, CC_SHA256, CC_SHA256_CTX, CC_SHA256_DIGEST_LENGTH)
COMMAND_DIGEST(SHA384, CC_SHA384, CC_SHA512_CTX, CC_SHA384_DIGEST_LENGTH)
COMMAND_DIGEST(SHA512, CC_SHA512, CC_SHA512_CTX, CC_SHA512_DIGEST_LENGTH)
#undef COMMAND_DIGEST
#endif
