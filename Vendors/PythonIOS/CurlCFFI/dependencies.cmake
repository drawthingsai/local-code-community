# Versions and URLs
set(BROTLI_VERSION "1.2.1")
set(BROTLI_URL_HASH "SHA256=98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f")
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
set(ZLIB_VERSION "1.3.2")
set(ZLIB_URL_HASH "SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16")
set(ZSTD_VERSION "1.5.7")
set(ZSTD_URL_HASH "SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3")
set(CARES_VERSION "1.34.9")
set(CARES_URL_HASH "SHA256=9364b70a12eb59a06830fb488d9357f90100dff0d98b23ea3593a183d43e6f2f")
set(CURL_VERSION "curl-8_23_0")
set(CURL_URL_HASH "SHA256=d0605d5883124ef5ae64c6d2b307e1417c482b362583b57491fdf37d9a99a792")


set(ZLIB_URL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz")
set(ZSTD_URL "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz")
set(BROTLI_URL "https://github.com/google/brotli/archive/refs/tags/v${BROTLI_VERSION}.tar.gz")
set(BORINGSSL_URL "https://github.com/google/boringssl/archive/${BORINGSSL_COMMIT}.zip")
set(NGHTTP2_URL "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.bz2")
set(NGTCP2_URL "https://github.com/ngtcp2/ngtcp2/releases/download/v${NGTCP2_VERSION}/ngtcp2-${NGTCP2_VERSION}.tar.bz2")
set(NGHTTP3_URL "https://github.com/ngtcp2/nghttp3/releases/download/v${NGHTTP3_VERSION}/nghttp3-${NGHTTP3_VERSION}.tar.bz2")
set(CARES_URL "https://github.com/c-ares/c-ares/releases/download/v${CARES_VERSION}/c-ares-${CARES_VERSION}.tar.gz")
set(CURL_URL "https://github.com/curl/curl/archive/${CURL_VERSION}.tar.gz")

