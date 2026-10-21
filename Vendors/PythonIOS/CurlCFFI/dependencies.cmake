# Versions and URLs
set(BROTLI_VERSION "1.2.0")
set(BROTLI_URL_HASH "SHA256=816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec")
# Chrome 150
set(BORINGSSL_COMMIT "156c7b75ae9b8c3b3f847acf264f17594c3859fb")
set(BORINGSSL_URL_HASH "SHA256=450e169b284697c6eafe523cb7679f4221fbe1a0993f773a566c33b188762844")
# We need to pin to 1.64 or lower, since the priority flag was removed.
# See: https://nghttp2.org/blog/2025/03/02/nghttp2-v1-65-0/
set(NGHTTP2_VERSION "1.63.0")
set(NGHTTP2_URL_HASH "SHA256=607b174554d22a828bc532d1d734fe0f729b5d5ed207f2f12e96a62e83f29c55")
set(NGTCP2_VERSION "1.20.0")
set(NGTCP2_URL_HASH "SHA256=871ec97ad86803cf312901b0c393b0ee70163e25a87c9b2894d1234341ce4e97")
set(NGHTTP3_VERSION "1.15.0")
set(NGHTTP3_URL_HASH "SHA256=c6c491a52804814098e446630e6efc459afc0d3da7952ffe6cbdc0b3f99b2b62")
set(ZLIB_VERSION "1.3.1")
set(ZLIB_URL_HASH "SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23")
set(ZSTD_VERSION "1.5.7")
set(ZSTD_URL_HASH "SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3")
set(CURL_VERSION "curl-8_21_0")
set(CURL_URL_HASH "SHA256=ec753aa6f408a3ca9f0d6d5f7a77417aecd1544db13c03ae5d443612bf367364")

set(ZLIB_URL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz")
set(ZSTD_URL "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz")
set(BROTLI_URL "https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}.tar.gz")
set(BORINGSSL_URL "https://github.com/google/boringssl/archive/${BORINGSSL_COMMIT}.zip")
set(NGHTTP2_URL "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.bz2")
set(NGTCP2_URL "https://github.com/ngtcp2/ngtcp2/releases/download/v${NGTCP2_VERSION}/ngtcp2-${NGTCP2_VERSION}.tar.bz2")
set(NGHTTP3_URL "https://github.com/ngtcp2/nghttp3/releases/download/v${NGHTTP3_VERSION}/nghttp3-${NGHTTP3_VERSION}.tar.bz2")
set(CURL_URL "https://github.com/curl/curl/archive/${CURL_VERSION}.tar.gz")

