#!/bin/sh
set -eu

export LC_ALL=C
export COPYFILE_DISABLE=1

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CPYTHON_DIR=${CPYTHON_DIR:-/private/tmp/cpython-3.14.7}
CPYTHON_REPO=${CPYTHON_REPO:-https://github.com/python/cpython.git}
CPYTHON_TAG=${CPYTHON_TAG:-v3.14.7}
CPYTHON_COMMIT=${CPYTHON_COMMIT:-823f0323ee6ec1402088b73bce1a38473cac36dc}
CPYTHON_CLEAN=${CPYTHON_CLEAN:-1}
CPYTHON_FETCH=${CPYTHON_FETCH:-1}
BUILD_DIR=${BUILD_DIR:-/private/tmp/python-3.14-ios-build}
CROSS_BUILD_DIR=${CROSS_BUILD_DIR:-$BUILD_DIR/cross-build}
APPLE_DEPS_CACHE_DIR=${APPLE_DEPS_CACHE_DIR:-/private/tmp/cpython-apple-source-deps}
PYTHON_VERSION_TAG=${PYTHON_VERSION_TAG:-3.14}
PYTHON_VERSION_FULL=${PYTHON_VERSION_FULL:-3.14.7}
IOS_HOST=${IOS_HOST:-arm64-apple-ios}
IOS_MULTIARCH=${IOS_MULTIARCH:-arm64-iphoneos}
IOS_SIMULATOR_HOST=${IOS_SIMULATOR_HOST:-arm64-apple-ios-simulator}
IOS_SIMULATOR_MULTIARCH=${IOS_SIMULATOR_MULTIARCH:-arm64-iphonesimulator}
MACOS_MINIMUM_OS_VERSION=${MACOS_MINIMUM_OS_VERSION:-13.0}
NUMPY_MACOS_MINIMUM_OS_VERSION=${NUMPY_MACOS_MINIMUM_OS_VERSION:-13.3}
PURE_PYTHON_REQUIREMENTS=${PURE_PYTHON_REQUIREMENTS:-$REPO_ROOT/Vendors/PythonIOS/pure_python_requirements.txt}
PURE_PYTHON_WHEEL_DIR=${PURE_PYTHON_WHEEL_DIR:-$BUILD_DIR/pure-python-wheels}
PYYAML_VERSION=6.0.3
PYYAML_SOURCE_FILENAME=pyyaml-$PYYAML_VERSION.tar.gz
PYYAML_SOURCE_URL=https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz
PYYAML_SOURCE_SHA256=d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f
PYYAML_SOURCE_DATE_EPOCH=1758834683
PYYAML_SOURCE_CACHE_DIR=${PYYAML_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
PYYAML_SOURCE_DIR=$BUILD_DIR/pyyaml-$PYYAML_VERSION
PYYAML_WHEEL_FILENAME=pyyaml-$PYYAML_VERSION-py3-none-any.whl
PYYAML_WHEEL_SHA256=717a12e2e669ac5ab431f9d59c8574eec76182378c7ef3aa958cb5962b14d254
PYYAML_FEATURE_POLICY="pure-python libyaml=disabled wheel=py3-none-any"
MACOS_DEPS_BUILD_DIR=${MACOS_DEPS_BUILD_DIR:-$BUILD_DIR/macos-deps}
MACOS_DEPS_PREFIX=${MACOS_DEPS_PREFIX:-$MACOS_DEPS_BUILD_DIR/prefix}
MACOS_DEPS_SOURCE_CACHE_DIR=${MACOS_DEPS_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/macos-source}
MACOS_OPENSSL_PREFIX=$MACOS_DEPS_PREFIX/openssl
MACOS_XZ_PREFIX=$MACOS_DEPS_PREFIX/xz
MACOS_ZSTD_PREFIX=$MACOS_DEPS_PREFIX/zstd
OPENSSL_VERSION=3.0.20
OPENSSL_SHA256=c80a01dfc70ece4dc21168932c37739042d404d46ccc81a5986dd75314ecda6f
XZ_VERSION=5.6.4
XZ_SHA256=269e3f2e512cbd3314849982014dc199a7b2148cf5c91cedc6db629acdf5e09b
ZSTD_VERSION=1.5.7
ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
IOS_MINIMUM_OS_VERSION=${IOS_MINIMUM_OS_VERSION:-13.0}
NUMPY_VERSION=2.4.6
NUMPY_SOURCE_FILENAME=numpy-$NUMPY_VERSION.tar.gz
NUMPY_SOURCE_URL=https://files.pythonhosted.org/packages/d0/ad/fed0499ce6a338d2a03ebae59cd15093910c8875328855781952abf6c2fe/numpy-2.4.6.tar.gz
NUMPY_SOURCE_SHA256=f3a3570c4a2a16746ac2c31a7c7c7b0c186b95ce902e33db6f28094ed7387dda
NUMPY_SOURCE_CACHE_DIR=${NUMPY_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
NUMPY_SOURCE_DIR=$BUILD_DIR/numpy-$NUMPY_VERSION
NUMPY_IOS_BUILD_DIR=$BUILD_DIR/numpy-ios-build
NUMPY_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/numpy-ios-simulator-build
NUMPY_MACOS_BUILD_DIR=$BUILD_DIR/numpy-macos-build
NUMPY_IOS_INSTALL_PREFIX=$BUILD_DIR/numpy-ios-install
NUMPY_IOS_SIMULATOR_INSTALL_PREFIX=$BUILD_DIR/numpy-ios-simulator-install
NUMPY_MACOS_INSTALL_PREFIX=$BUILD_DIR/numpy-macos-install
NUMPY_IOS_INSTALL_DESTDIR=$BUILD_DIR/numpy-ios-destdir
NUMPY_IOS_SIMULATOR_INSTALL_DESTDIR=$BUILD_DIR/numpy-ios-simulator-destdir
NUMPY_MACOS_INSTALL_DESTDIR=$BUILD_DIR/numpy-macos-destdir
NUMPY_BUILD_TOOLS_VENV=${NUMPY_BUILD_TOOLS_VENV:-$BUILD_DIR/python-build-tools}
NUMPY_BUILD_TOOLS_PYTHON=$NUMPY_BUILD_TOOLS_VENV/bin/python
NUMPY_BUILD_PIP_VERSION=26.1.2
NUMPY_BUILD_SETUPTOOLS_VERSION=82.0.1
NUMPY_BUILD_WHEEL_VERSION=0.47.0
NUMPY_BUILD_CYTHON_VERSION=3.2.5
NUMPY_BUILD_NINJA_VERSION=1.13.0
NUMPY_BUILD_PACKAGING_VERSION=26.2
NUMPY_BUILD_MESON_VERSION=1.9.1
NUMPY_BUILD_MESON_PYTHON_VERSION=0.16.0
NUMPY_BUILD_VERSIONEER_VERSION=0.29
NUMPY_BUILD_PYBIND11_VERSION=3.0.1
NUMPY_BUILD_CPPY_VERSION=1.3.0
NUMPY_BUILD_SETUPTOOLS_SCM_VERSION=9.2.2
PANDAS_VERSION=3.0.5
PANDAS_SOURCE_FILENAME=pandas-$PANDAS_VERSION.tar.gz
PANDAS_SOURCE_URL=https://files.pythonhosted.org/packages/be/4f/5f3422a2afec5ffc46308b79e53291365a93748b498ac2e58bead0197916/pandas-3.0.5.tar.gz
PANDAS_SOURCE_SHA256=dca3734d6ab7c906e6730f0788b0a1dbb9f2467731f9711f77995c8e9d62d712
PANDAS_SOURCE_CACHE_DIR=${PANDAS_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
PANDAS_SOURCE_DIR=$BUILD_DIR/pandas-$PANDAS_VERSION
PANDAS_IOS_BUILD_DIR=$BUILD_DIR/pandas-ios-build
PANDAS_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/pandas-ios-simulator-build
PANDAS_MACOS_BUILD_DIR=$BUILD_DIR/pandas-macos-build
PANDAS_IOS_INSTALL_PREFIX=$BUILD_DIR/pandas-ios-install
PANDAS_IOS_SIMULATOR_INSTALL_PREFIX=$BUILD_DIR/pandas-ios-simulator-install
PANDAS_MACOS_INSTALL_PREFIX=$BUILD_DIR/pandas-macos-install
PANDAS_IOS_INSTALL_DESTDIR=$BUILD_DIR/pandas-ios-destdir
PANDAS_IOS_SIMULATOR_INSTALL_DESTDIR=$BUILD_DIR/pandas-ios-simulator-destdir
PANDAS_MACOS_INSTALL_DESTDIR=$BUILD_DIR/pandas-macos-destdir
PANDAS_STATIC_SYMBOL_RENAMES="is_leapyear:pandas_datetime_is_leapyear add_minutes_to_datetimestruct:pandas_datetime_add_minutes_to_datetimestruct get_datetimestruct_days:pandas_datetime_get_datetimestruct_days get_datetime_metadata_from_dtype:pandas_datetime_get_datetime_metadata_from_dtype"
PILLOW_VERSION=12.3.0
PILLOW_SOURCE_FILENAME=pillow-$PILLOW_VERSION.tar.gz
PILLOW_SOURCE_URL=https://files.pythonhosted.org/packages/1c/3d/bb7fca845737cf9d7dbde16ed1843984665ff2e0a518f5db43e77ec540b9/pillow-12.3.0.tar.gz
PILLOW_SOURCE_SHA256=3b8182a766685eaa002637e28b4ec8d6b18819a0c71f579bf0dbaa5830297cce
PILLOW_SOURCE_CACHE_DIR=${PILLOW_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
PILLOW_SOURCE_DIR=$BUILD_DIR/pillow-$PILLOW_VERSION
PILLOW_IOS_BUILD_DIR=$BUILD_DIR/pillow-ios-build
PILLOW_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/pillow-ios-simulator-build
PILLOW_MACOS_BUILD_DIR=$BUILD_DIR/pillow-macos-build
PILLOW_FEATURE_POLICY="zlib=enabled jpeg=libjpeg-turbo freetype=matplotlib raqm=matplotlib tiff=disabled lcms=disabled webp=disabled jpeg2000=disabled imagequant=disabled xcb=disabled avif=disabled"
LIBJPEG_TURBO_VERSION=3.2.0
LIBJPEG_TURBO_SOURCE_FILENAME=libjpeg-turbo-$LIBJPEG_TURBO_VERSION.tar.gz
LIBJPEG_TURBO_SOURCE_URL=https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz
LIBJPEG_TURBO_SOURCE_SHA256=6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
LIBJPEG_TURBO_SOURCE_CACHE_DIR=${LIBJPEG_TURBO_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
LIBJPEG_TURBO_SOURCE_DIR=$BUILD_DIR/libjpeg-turbo-$LIBJPEG_TURBO_VERSION
LIBJPEG_TURBO_IOS_BUILD_DIR=$BUILD_DIR/libjpeg-turbo-ios-build
LIBJPEG_TURBO_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/libjpeg-turbo-ios-simulator-build
LIBJPEG_TURBO_MACOS_BUILD_DIR=$BUILD_DIR/libjpeg-turbo-macos-build
LIBJPEG_TURBO_IOS_PREFIX=$BUILD_DIR/libjpeg-turbo-ios-prefix
LIBJPEG_TURBO_IOS_SIMULATOR_PREFIX=$BUILD_DIR/libjpeg-turbo-ios-simulator-prefix
LIBJPEG_TURBO_MACOS_PREFIX=$BUILD_DIR/libjpeg-turbo-macos-prefix
LIBJPEG_TURBO_FEATURE_POLICY="library=static api=jpeg8 simd=required turbojpeg=disabled tools=disabled"
LIBXML2_VERSION=2.14.6
LIBXML2_SOURCE_FILENAME=libxml2-$LIBXML2_VERSION.tar.xz
LIBXML2_SOURCE_URL=https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.6.tar.xz
LIBXML2_SOURCE_SHA256=7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a
LIBXML2_SOURCE_CACHE_DIR=${LIBXML2_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
LIBXML2_SOURCE_DIR=$BUILD_DIR/libxml2-$LIBXML2_VERSION
LIBXML2_IOS_BUILD_DIR=$BUILD_DIR/libxml2-ios-build
LIBXML2_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/libxml2-ios-simulator-build
LIBXML2_MACOS_BUILD_DIR=$BUILD_DIR/libxml2-macos-build
LIBXML2_IOS_PREFIX=$BUILD_DIR/libxml2-ios-prefix
LIBXML2_IOS_SIMULATOR_PREFIX=$BUILD_DIR/libxml2-ios-simulator-prefix
LIBXML2_MACOS_PREFIX=$BUILD_DIR/libxml2-macos-prefix
LIBXSLT_VERSION=1.1.43
LIBXSLT_SOURCE_FILENAME=libxslt-$LIBXSLT_VERSION.tar.xz
LIBXSLT_SOURCE_URL=https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz
LIBXSLT_SOURCE_SHA256=5a3d6b383ca5afc235b171118e90f5ff6aa27e9fea3303065231a6d403f0183a
LIBXSLT_SOURCE_CACHE_DIR=${LIBXSLT_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
LIBXSLT_SOURCE_DIR=$BUILD_DIR/libxslt-$LIBXSLT_VERSION
LIBXSLT_IOS_BUILD_DIR=$BUILD_DIR/libxslt-ios-build
LIBXSLT_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/libxslt-ios-simulator-build
LIBXSLT_MACOS_BUILD_DIR=$BUILD_DIR/libxslt-macos-build
LXML_VERSION=6.1.2
LXML_SOURCE_FILENAME=lxml-$LXML_VERSION.tar.gz
LXML_SOURCE_URL=https://files.pythonhosted.org/packages/ad/a9/970b8fa0ecc4fbf1dfaed0d89bbc1fc1421b25ec26a2038c91e872dc6c8e/lxml-6.1.2.tar.gz
LXML_SOURCE_SHA256=1055241852f2b02068af4a625a5d32c087db193c12251928af2562ecd2239f18
LXML_SOURCE_CACHE_DIR=${LXML_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
LXML_SOURCE_DIR=$BUILD_DIR/lxml-$LXML_VERSION
LXML_IOS_BUILD_DIR=$BUILD_DIR/lxml-ios-build
LXML_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/lxml-ios-simulator-build
LXML_MACOS_BUILD_DIR=$BUILD_DIR/lxml-macos-build
LXML_FEATURE_POLICY="libxml2=static libxslt=static libexslt=static zlib=sdk iconv=sdk debugger=disabled profiler=enabled crypto=disabled plugins=disabled"
CONTOURPY_VERSION=1.3.3
CONTOURPY_SOURCE_FILENAME=contourpy-$CONTOURPY_VERSION.tar.gz
CONTOURPY_SOURCE_URL=https://files.pythonhosted.org/packages/source/c/contourpy/contourpy-1.3.3.tar.gz
CONTOURPY_SOURCE_SHA256=083e12155b210502d0bca491432bb04d56dc3432f95a979b429f2848c3dbe880
CONTOURPY_SOURCE_CACHE_DIR=${CONTOURPY_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
CONTOURPY_SOURCE_DIR=$BUILD_DIR/contourpy-$CONTOURPY_VERSION
CONTOURPY_IOS_BUILD_DIR=$BUILD_DIR/contourpy-ios-build
CONTOURPY_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/contourpy-ios-simulator-build
CONTOURPY_MACOS_BUILD_DIR=$BUILD_DIR/contourpy-macos-build
CONTOURPY_IOS_INSTALL_PREFIX=$BUILD_DIR/contourpy-ios-install
CONTOURPY_IOS_SIMULATOR_INSTALL_PREFIX=$BUILD_DIR/contourpy-ios-simulator-install
CONTOURPY_MACOS_INSTALL_PREFIX=$BUILD_DIR/contourpy-macos-install
CONTOURPY_IOS_INSTALL_DESTDIR=$BUILD_DIR/contourpy-ios-destdir
CONTOURPY_IOS_SIMULATOR_INSTALL_DESTDIR=$BUILD_DIR/contourpy-ios-simulator-destdir
CONTOURPY_MACOS_INSTALL_DESTDIR=$BUILD_DIR/contourpy-macos-destdir
KIWISOLVER_VERSION=1.5.1
KIWISOLVER_SOURCE_FILENAME=kiwisolver-$KIWISOLVER_VERSION.tar.gz
KIWISOLVER_SOURCE_URL=https://files.pythonhosted.org/packages/ba/07/bd78e6a8fae171ea041ef5bba3ed21a003522fa088834b069b1909981f30/kiwisolver-1.5.1.tar.gz
KIWISOLVER_SOURCE_SHA256=f1303ef2eec81262a4b708c3e858afe58d7c75ad91c1c05266eda7673369859a
KIWISOLVER_SOURCE_CACHE_DIR=${KIWISOLVER_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
KIWISOLVER_SOURCE_DIR=$BUILD_DIR/kiwisolver-$KIWISOLVER_VERSION
KIWISOLVER_IOS_BUILD_DIR=$BUILD_DIR/kiwisolver-ios-build
KIWISOLVER_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/kiwisolver-ios-simulator-build
KIWISOLVER_MACOS_BUILD_DIR=$BUILD_DIR/kiwisolver-macos-build
MATPLOTLIB_VERSION=3.11.1
MATPLOTLIB_SOURCE_FILENAME=matplotlib-$MATPLOTLIB_VERSION.tar.gz
MATPLOTLIB_SOURCE_URL=https://files.pythonhosted.org/packages/49/64/f9a391af28f518b11ad45a8a712353c94a0aefce09d3703200e5c54b610a/matplotlib-3.11.1.tar.gz
MATPLOTLIB_SOURCE_SHA256=69647db5746941c793d6e445a4cd349323ffb87d9cc958c2ad84a659b4832d30
MATPLOTLIB_SOURCE_CACHE_DIR=${MATPLOTLIB_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
MATPLOTLIB_SOURCE_DIR=$BUILD_DIR/matplotlib-$MATPLOTLIB_VERSION
MATPLOTLIB_IOS_BUILD_DIR=$BUILD_DIR/matplotlib-ios-build
MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/matplotlib-ios-simulator-build
MATPLOTLIB_MACOS_BUILD_DIR=$BUILD_DIR/matplotlib-macos-build
MATPLOTLIB_IOS_INSTALL_PREFIX=$BUILD_DIR/matplotlib-ios-install
MATPLOTLIB_IOS_SIMULATOR_INSTALL_PREFIX=$BUILD_DIR/matplotlib-ios-simulator-install
MATPLOTLIB_MACOS_INSTALL_PREFIX=$BUILD_DIR/matplotlib-macos-install
MATPLOTLIB_IOS_INSTALL_DESTDIR=$BUILD_DIR/matplotlib-ios-destdir
MATPLOTLIB_IOS_SIMULATOR_INSTALL_DESTDIR=$BUILD_DIR/matplotlib-ios-simulator-destdir
MATPLOTLIB_MACOS_INSTALL_DESTDIR=$BUILD_DIR/matplotlib-macos-destdir
MATPLOTLIB_FREETYPE_VERSION=2.14.3
MATPLOTLIB_FREETYPE_SOURCE_FILENAME=freetype-$MATPLOTLIB_FREETYPE_VERSION.tar.xz
MATPLOTLIB_FREETYPE_SOURCE_URL=https://download.savannah.nongnu.org/releases/freetype/freetype-2.14.3.tar.xz
MATPLOTLIB_FREETYPE_SOURCE_SHA256=36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
MATPLOTLIB_HARFBUZZ_VERSION=14.1.0
MATPLOTLIB_HARFBUZZ_SOURCE_FILENAME=harfbuzz-$MATPLOTLIB_HARFBUZZ_VERSION.tar.xz
MATPLOTLIB_HARFBUZZ_SOURCE_URL=https://github.com/harfbuzz/harfbuzz/releases/download/14.1.0/harfbuzz-14.1.0.tar.xz
MATPLOTLIB_HARFBUZZ_SOURCE_SHA256=ee0eb3a1da2c5a28147f12dff55f6c7d60aeeeb29ac7ef334eabe84c8476c105
MATPLOTLIB_SHEENBIDI_VERSION=3.0.0
MATPLOTLIB_SHEENBIDI_SOURCE_FILENAME=sheenbidi-$MATPLOTLIB_SHEENBIDI_VERSION.tar.gz
MATPLOTLIB_SHEENBIDI_SOURCE_URL=https://github.com/Tehreer/SheenBidi/archive/refs/tags/v3.0.0/sheenbidi-3.0.0.tar.gz
MATPLOTLIB_SHEENBIDI_SOURCE_SHA256=86c56014034739ba39a24c23eb00323b0bf6f737354f665786015fca842af786
MATPLOTLIB_LIBRAQM_VERSION=0.10.5
MATPLOTLIB_LIBRAQM_SOURCE_FILENAME=libraqm-$MATPLOTLIB_LIBRAQM_VERSION.tar.gz
MATPLOTLIB_LIBRAQM_SOURCE_URL=https://github.com/HOST-Oman/libraqm/archive/v0.10.5/libraqm-0.10.5.tar.gz
MATPLOTLIB_LIBRAQM_SOURCE_SHA256=7f3dd21b4b3bd28a36f2c911d31d91a9d69341697713923ef1aac65d56ebcafd
MATPLOTLIB_QHULL_VERSION=8.0.2
MATPLOTLIB_QHULL_SOURCE_FILENAME=qhull-8.0.2.tgz
MATPLOTLIB_QHULL_SOURCE_URL=https://github.com/qhull/qhull/archive/v8.0.2/qhull-8.0.2.tar.gz
MATPLOTLIB_QHULL_SOURCE_SHA256=8774e9a12c70b0180b95d6b0b563c5aa4bea8d5960c15e18ae3b6d2521d64f8b
MATPLOTLIB_FEATURE_POLICY="backend=Agg macosx=disabled tkagg=disabled freetype=bundled harfbuzz=bundled sheenbidi=bundled libraqm=bundled qhull=bundled lto=disabled"
PSDTOOLS_VERSION=1.18.0
PSDTOOLS_SOURCE_FILENAME=psd-tools-$PSDTOOLS_VERSION.tar.gz
PSDTOOLS_SOURCE_URL=https://github.com/psd-tools/psd-tools/archive/refs/tags/v$PSDTOOLS_VERSION.tar.gz
PSDTOOLS_SOURCE_SHA256=c0590044f714a51ced823e5011aaa14ea563a6438f735d89a84bfc482e9dac5c
PSDTOOLS_SOURCE_CACHE_DIR=${PSDTOOLS_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
PSDTOOLS_SOURCE_DIR=$BUILD_DIR/psd-tools-$PSDTOOLS_VERSION
PSDTOOLS_IOS_BUILD_DIR=$BUILD_DIR/psd-tools-ios-build
PSDTOOLS_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/psd-tools-ios-simulator-build
PSDTOOLS_MACOS_BUILD_DIR=$BUILD_DIR/psd-tools-macos-build
PSDTOOLS_FEATURE_POLICY="rle=static-cython limited-api=0x030D0000 composite-extra=disabled"
REGEX_VERSION=2026.7.19
REGEX_SOURCE_FILENAME=regex-$REGEX_VERSION.tar.gz
REGEX_SOURCE_URL=https://files.pythonhosted.org/packages/20/98/04b13f1ddfb63158025291c02e03eb42fbb7acb51d091d541050eb4e35e8/regex-2026.7.19.tar.gz
REGEX_SOURCE_SHA256=7e77b324909c1617cbb4c668677e2c6ae13f44d7c1de0d4f15f2e3c10f3315b5
REGEX_SOURCE_CACHE_DIR=${REGEX_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
REGEX_SOURCE_DIR=$BUILD_DIR/regex-$REGEX_VERSION
REGEX_IOS_BUILD_DIR=$BUILD_DIR/regex-ios-build
REGEX_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/regex-ios-simulator-build
REGEX_MACOS_BUILD_DIR=$BUILD_DIR/regex-macos-build
REGEX_FEATURE_POLICY="python=3.14 c-extension=static external-libraries=none interpreter=main-only"
TOKENIZERS_VERSION=0.22.2
TOKENIZERS_SOURCE_FILENAME=tokenizers-$TOKENIZERS_VERSION.tar.gz
TOKENIZERS_SOURCE_URL=https://files.pythonhosted.org/packages/73/6f/f80cfef4a312e1fb34baf7d85c72d4411afde10978d4657f8cdd811d3ccc/tokenizers-0.22.2.tar.gz
TOKENIZERS_SOURCE_SHA256=473b83b915e547aa366d1eee11806deaf419e17be16310ac0a14077f1e28f917
TOKENIZERS_CARGO_LOCK_SHA256=a3ff2022b3790e2f5863fe59732ab76da81dd75bc3a94905127206e87125170d
TOKENIZERS_SOURCE_CACHE_DIR=${TOKENIZERS_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
TOKENIZERS_SOURCE_DIR=$BUILD_DIR/tokenizers-$TOKENIZERS_VERSION
TOKENIZERS_CARGO_HOME=${TOKENIZERS_CARGO_HOME:-$APPLE_DEPS_CACHE_DIR/tokenizers-cargo-$TOKENIZERS_VERSION}
TOKENIZERS_IOS_BUILD_DIR=$BUILD_DIR/tokenizers-ios-build
TOKENIZERS_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/tokenizers-ios-simulator-build
TOKENIZERS_MACOS_BUILD_DIR=$BUILD_DIR/tokenizers-macos-build
TOKENIZERS_FEATURE_POLICY="pyo3=0.26.0 abi3=py39 onig=vendored esaxx=cpp progressbar=enabled rust-http=disabled lto=disabled interpreter=main-only"
SENTENCEPIECE_VERSION=0.2.2
SENTENCEPIECE_SOURCE_FILENAME=sentencepiece-$SENTENCEPIECE_VERSION.tar.gz
SENTENCEPIECE_SOURCE_URL=https://files.pythonhosted.org/packages/cc/33/ea3cb3839607eb175da835244a798f797f478c5ddf0e8ecdf57ea85a4c70/sentencepiece-0.2.2.tar.gz
SENTENCEPIECE_SOURCE_SHA256=3d2b5e824b5622038dc7b490897efe05ebbbb9e7350fc142f3ecc8789ef9bdf6
SENTENCEPIECE_SOURCE_CACHE_DIR=${SENTENCEPIECE_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
SENTENCEPIECE_SOURCE_DIR=$BUILD_DIR/sentencepiece-$SENTENCEPIECE_VERSION
SENTENCEPIECE_ABSEIL_COMMIT=5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a
SENTENCEPIECE_ABSEIL_ABI=lts_20260526
SENTENCEPIECE_ABSEIL_SOURCE_DIR=$SENTENCEPIECE_SOURCE_DIR/sentencepiece/third_party/abseil-cpp
SENTENCEPIECE_IOS_BUILD_DIR=$BUILD_DIR/sentencepiece-ios-build
SENTENCEPIECE_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/sentencepiece-ios-simulator-build
SENTENCEPIECE_MACOS_BUILD_DIR=$BUILD_DIR/sentencepiece-macos-build
SENTENCEPIECE_FEATURE_POLICY="pybind11=$NUMPY_BUILD_PYBIND11_VERSION extension=static core=@sentencepiece//:sentencepiece_train core-in-python-archive=none abseil=$SENTENCEPIECE_ABSEIL_ABI interpreter=main-only"
HF_XET_VERSION=1.5.2
HF_XET_SOURCE_FILENAME=hf_xet-$HF_XET_VERSION.tar.gz
HF_XET_SOURCE_URL=https://files.pythonhosted.org/packages/63/39/67be8d71f900d9a55761b6022821d6679fb56c64f1b6063d5af2c2606727/hf_xet-1.5.2.tar.gz
HF_XET_SOURCE_SHA256=73044bd31bae33c984af832d19c752a0dffb67518fee9ddbd91d616e1101cf47
HF_XET_CARGO_LOCK_SHA256=65e35c92eb55cfcac983851fb0768ad09dbb04cbaacbc349ad3f8ca8cbb8dc4c
HF_XET_SOURCE_CACHE_DIR=${HF_XET_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
HF_XET_SOURCE_DIR=$BUILD_DIR/hf_xet-$HF_XET_VERSION
HF_XET_RUST_VERSION=1.89.0
HF_XET_RUST_CACHE_DIR=${HF_XET_RUST_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/rust}
HF_XET_RUST_TOOLCHAIN_FILENAME=rust-$HF_XET_RUST_VERSION-aarch64-apple-darwin.tar.xz
HF_XET_RUST_TOOLCHAIN_URL=https://static.rust-lang.org/dist/2025-08-07/$HF_XET_RUST_TOOLCHAIN_FILENAME
HF_XET_RUST_TOOLCHAIN_SHA256=a62f8ae2011321297319e9e30e06f3c14bbbb67fabf273e6b9e1fd4e1143c86f
HF_XET_RUST_IOS_STD_FILENAME=rust-std-$HF_XET_RUST_VERSION-aarch64-apple-ios.tar.xz
HF_XET_RUST_IOS_STD_URL=https://static.rust-lang.org/dist/2025-08-07/$HF_XET_RUST_IOS_STD_FILENAME
HF_XET_RUST_IOS_STD_SHA256=b124d0ad673612ac394bffab3b783e430d1fe7dbe6b7de5093a7cc2be2f873ba
HF_XET_RUST_IOS_SIMULATOR_STD_FILENAME=rust-std-$HF_XET_RUST_VERSION-aarch64-apple-ios-sim.tar.xz
HF_XET_RUST_IOS_SIMULATOR_STD_URL=https://static.rust-lang.org/dist/2025-08-07/$HF_XET_RUST_IOS_SIMULATOR_STD_FILENAME
HF_XET_RUST_IOS_SIMULATOR_STD_SHA256=ee1e950db8abf50ef36828c7cfbf92451d6e76cb14cd5a5dff78dcff710dd39e
HF_XET_RUST_TOOLCHAIN_DIR=$BUILD_DIR/hf-xet-rust-$HF_XET_RUST_VERSION
HF_XET_CARGO_HOME=${HF_XET_CARGO_HOME:-$APPLE_DEPS_CACHE_DIR/hf-xet-cargo-$HF_XET_VERSION}
HF_XET_IOS_BUILD_DIR=$BUILD_DIR/hf-xet-ios-build
HF_XET_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/hf-xet-ios-simulator-build
HF_XET_MACOS_BUILD_DIR=$BUILD_DIR/hf-xet-macos-build
HF_XET_FEATURE_POLICY="pyo3=0.29.0 abi3=py38 tls=rustls lto=disabled sysinfo=disabled system-monitor=disabled log-cleanup=disabled interpreter=main-only c-api=download-in-python-archive"
SAFETENSORS_VERSION=0.8.0
SAFETENSORS_SOURCE_FILENAME=safetensors-$SAFETENSORS_VERSION.tar.gz
SAFETENSORS_SOURCE_URL=https://files.pythonhosted.org/packages/45/06/f955dbbb1859e3bd23c8ac6141af5106e7ad5fedec4a3a6e3d60f94b7001/safetensors-0.8.0.tar.gz
SAFETENSORS_SOURCE_SHA256=fabaf3e0f18a6618d9b36560682562157f77c2b71fcffc7b432be2baed9d753d
SAFETENSORS_CARGO_LOCK_SHA256=f7d484a57bc394042b3424d57dab0a17d6a343f5e57e30870b9dd72dfb90f6b7
SAFETENSORS_SOURCE_CACHE_DIR=${SAFETENSORS_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
SAFETENSORS_SOURCE_DIR=$BUILD_DIR/safetensors-$SAFETENSORS_VERSION
SAFETENSORS_CARGO_HOME=${SAFETENSORS_CARGO_HOME:-$APPLE_DEPS_CACHE_DIR/safetensors-cargo-$SAFETENSORS_VERSION}
SAFETENSORS_IOS_BUILD_DIR=$BUILD_DIR/safetensors-ios-build
SAFETENSORS_IOS_SIMULATOR_BUILD_DIR=$BUILD_DIR/safetensors-ios-simulator-build
SAFETENSORS_MACOS_BUILD_DIR=$BUILD_DIR/safetensors-macos-build
SAFETENSORS_FEATURE_POLICY="pyo3=0.28.3 abi3=py310 host-python=disabled mmap=enabled pread=enabled lto=disabled interpreter=main-only"
MLX_VERSION=0.32.2
MLX_SOURCE_FILENAME=mlx-$MLX_VERSION.tar.gz
MLX_SOURCE_URL=https://github.com/ml-explore/mlx/archive/refs/tags/v$MLX_VERSION.tar.gz
MLX_SOURCE_SHA256=bf892386ccac1d249acc9da21574fd7b95a995f4c58b03310105fe05f077b175
MLX_SOURCE_CACHE_DIR=${MLX_SOURCE_CACHE_DIR:-$APPLE_DEPS_CACHE_DIR/python-packages}
MLX_SOURCE_DIR=$BUILD_DIR/mlx-$MLX_VERSION
MLX_IOS_BUILD_DIR=$BUILD_DIR/mlx-ios-build
MLX_MACOS_BUILD_DIR=$BUILD_DIR/mlx-macos-build
MLX_METAL_LANGUAGE_STANDARD=metal3.1
MLX_IOS_METALLIB_NAME=mlx-ios.metallib
MLX_MACOS_METALLIB_NAME=mlx-macos.metallib
MLX_METAL_CPP_VERSION=26
MLX_JSON_VERSION=3.11.3
MLX_FMT_VERSION=12.1.0
MLX_NANOBIND_VERSION=2.13.0
MLX_GGUF_COMMIT=8fa6eb65236618e28fd7710a0fba565f7faa1848
MLX_FEATURE_POLICY="platforms=ios-arm64,macos-arm64 cpu=Accelerate metal=precompiled metal-jit=disabled metal-cpp-constants=dynamic gguf=enabled safetensors=enabled lto=disabled"
HOST_CPU_COUNT=${HOST_CPU_COUNT:-}
if [ -z "$HOST_CPU_COUNT" ]; then
    HOST_CPU_COUNT=$(sysctl -n hw.ncpu 2>/dev/null || true)
fi
if [ -z "$HOST_CPU_COUNT" ]; then
    HOST_CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
fi
case "$HOST_CPU_COUNT" in
    ''|*[!0-9]*|0)
        HOST_CPU_COUNT=4
        ;;
esac

. "$REPO_ROOT/Vendors/PythonIOS/cairosvg_build.sh"

sanitize_one_path() {
    root=$1
    path=$2
    replacement=$3
    if [ -n "$path" ]; then
        find "$root" -type f -exec grep -Il "$path" {} + | while IFS= read -r file; do
            sed -i.bak "s|$path|$replacement|g" "$file"
            rm -f "$file.bak"
        done
    fi
}

sanitize_darwin_host_version() {
    root=$1
    find "$root" -type f -exec grep -Il 'aarch64-apple-darwin[0-9]' {} + | while IFS= read -r file; do
        sed -E -i.bak 's/aarch64-apple-darwin[0-9]+(\.[0-9]+)*/aarch64-apple-darwin/g' "$file"
        rm -f "$file.bak"
    done
}

sanitize_absolute_paths() {
    root=$1
    sanitize_one_path "$root" "$CPYTHON_DIR" "@PYTHON_SOURCE_ROOT@"
    sanitize_one_path "$root" "$BUILD_DIR" "@PYTHON_BUILD_ROOT@"
    sanitize_one_path "$root" "$APPLE_DEPS_CACHE_DIR" "@PYTHON_DEPS_CACHE@"
    sanitize_one_path "$root" "$MACOS_DEPS_SOURCE_CACHE_DIR" "@MACOS_DEPS_SOURCE_CACHE@"
    sanitize_one_path "$root" "$MACOS_DEPS_PREFIX" "@MACOS_DEPS_PREFIX@"
    sanitize_one_path "$root" "$MACOS_OPENSSL_PREFIX" "@MACOS_OPENSSL_PREFIX@"
    sanitize_one_path "$root" "$MACOS_XZ_PREFIX" "@MACOS_XZ_PREFIX@"
    sanitize_one_path "$root" "$MACOS_ZSTD_PREFIX" "@MACOS_ZSTD_PREFIX@"
    sanitize_one_path "$root" "$NUMPY_SOURCE_DIR" "@NUMPY_SOURCE_ROOT@"
    sanitize_one_path "$root" "$PANDAS_SOURCE_DIR" "@PANDAS_SOURCE_ROOT@"
    sanitize_one_path "$root" "$PILLOW_SOURCE_DIR" "@PILLOW_SOURCE_ROOT@"
    sanitize_one_path "$root" "$LIBXML2_SOURCE_DIR" "@LIBXML2_SOURCE_ROOT@"
    sanitize_one_path "$root" "$LIBXML2_IOS_PREFIX" "@LIBXML2_IOS_PREFIX@"
    sanitize_one_path "$root" "$LIBXML2_IOS_SIMULATOR_PREFIX" "@LIBXML2_IOS_SIMULATOR_PREFIX@"
    sanitize_one_path "$root" "$LIBXML2_MACOS_PREFIX" "@LIBXML2_MACOS_PREFIX@"
    sanitize_one_path "$root" "$LIBXSLT_SOURCE_DIR" "@LIBXSLT_SOURCE_ROOT@"
    sanitize_one_path "$root" "$LXML_SOURCE_DIR" "@LXML_SOURCE_ROOT@"
    sanitize_one_path "$root" "$CONTOURPY_SOURCE_DIR" "@CONTOURPY_SOURCE_ROOT@"
    sanitize_one_path "$root" "$KIWISOLVER_SOURCE_DIR" "@KIWISOLVER_SOURCE_ROOT@"
    sanitize_one_path "$root" "$MATPLOTLIB_SOURCE_DIR" "@MATPLOTLIB_SOURCE_ROOT@"
    sanitize_one_path "$root" "$PSDTOOLS_SOURCE_DIR" "@PSDTOOLS_SOURCE_ROOT@"
    sanitize_one_path "$root" "$TOKENIZERS_SOURCE_DIR" "@TOKENIZERS_SOURCE_ROOT@"
    sanitize_one_path "$root" "$TOKENIZERS_CARGO_HOME" "@TOKENIZERS_CARGO_HOME@"
    sanitize_one_path "$root" "$SENTENCEPIECE_SOURCE_DIR" "@SENTENCEPIECE_SOURCE_ROOT@"
    sanitize_one_path "$root" "$HF_XET_SOURCE_DIR" "@HF_XET_SOURCE_ROOT@"
    sanitize_one_path "$root" "$SAFETENSORS_SOURCE_DIR" "@SAFETENSORS_SOURCE_ROOT@"
    sanitize_one_path "$root" "$MLX_SOURCE_DIR" "@MLX_SOURCE_ROOT@"
    sanitize_one_path "$root" "${HOME:-}" "@USER_HOME@"
    sanitize_darwin_host_version "$root"
}

remove_python_tools() {
    root=$1
    mkdir -p "$root/bin"
    find "$root/bin" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    touch "$root/bin/python3" "$root/bin/python$PYTHON_VERSION_TAG"
}

remove_pycache() {
    root=$1
    find "$root" -name __pycache__ -type d -prune -exec rm -rf {} +
}

disable_test_module_env() {
    env \
        py_cv_module__testbuffer=n/a \
        py_cv_module__testcapi=n/a \
        py_cv_module__testclinic=n/a \
        py_cv_module__testclinic_limited=n/a \
        py_cv_module__testimportmultiple=n/a \
        py_cv_module__testinternalcapi=n/a \
        py_cv_module__testlimitedcapi=n/a \
        py_cv_module__testmultiphase=n/a \
        py_cv_module__testsinglephase=n/a \
        py_cv_module__ctypes_test=n/a \
        py_cv_module__xxtestfuzz=n/a \
        py_cv_module_xxlimited=n/a \
        py_cv_module_xxlimited_35=n/a \
        py_cv_module_xxsubtype=n/a \
        "$@"
}

patch_static_python_makefile() {
    makefile=$1
    sed -i.bak \
        -e 's|^MODULE__MD5_LDFLAGS=.*|MODULE__MD5_LDFLAGS=|' \
        -e 's|^MODULE__SHA1_LDFLAGS=.*|MODULE__SHA1_LDFLAGS=|' \
        -e 's|^MODULE__SHA2_LDFLAGS=.*|MODULE__SHA2_LDFLAGS=|' \
        -e 's|^MODULE__SHA3_LDFLAGS=.*|MODULE__SHA3_LDFLAGS=|' \
        -e 's|^MODULE__BLAKE2_LDFLAGS=.*|MODULE__BLAKE2_LDFLAGS=|' \
        "$makefile"
    rm -f "$makefile.bak"
    sed -i.bak \
        -e 's|$(LIBRARY_OBJS) $(DTRACE_OBJS) $(SHLIBS)|$(LIBRARY_OBJS) $(DTRACE_OBJS) $(MODLIBS) $(SHLIBS)|g' \
        -e 's|-framework CoreFoundation $(LIBS);|-framework CoreFoundation $(MODLIBS) $(LIBS);|g' \
        "$makefile"
    rm -f "$makefile.bak"
}

create_static_python_library() {
    output=$1
    sdk=$2
    minimum_os_version=$3
    shift 3
    unencapsulated_archive="${output%.a}-unencapsulated.a"
    rm -f "$unencapsulated_archive"
    libtool -static -o "$unencapsulated_archive" "$@"
    run_with_log "$BUILD_DIR/encapsulate_$sdk.log" \
        env RUSTC="$HF_XET_RUST_TOOLCHAIN_DIR/bin/rustc" \
        bash "$REPO_ROOT/Vendors/PythonIOS/encapsulate_python.sh" \
        "$sdk" "$minimum_os_version" "$unencapsulated_archive" "$output"
    rm -f "$unencapsulated_archive"
}

prune_ios_resources() {
    root=$1
    stdlib="$root/lib/python$PYTHON_VERSION_TAG"

    remove_pycache "$root"
    rm -rf "$stdlib/test"
    remove_python_tools "$root"
    rm -rf "$stdlib/lib-dynload"
    rm -rf "$stdlib/site-packages/pip" \
        "$stdlib/site-packages"/pip-*.dist-info \
        "$root/lib/pkgconfig"
    rm -f "$root/lib"/libpython*.dylib "$root/lib"/libpython*.a
    rm -f "$stdlib/_sysconfigdata__darwin_darwin.py"

    if find "$root" \( -type f -o -type l \) \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.exe' -o \
        -name '*.fwork' \
    \) | grep -q .; then
        echo "Unexpected dynamic or binary iOS Python resource files remain:" >&2
        find "$root" \( -type f -o -type l \) \( \
            -name '*.so' -o \
            -name '*.dylib' -o \
            -name '*.a' -o \
            -name '*.exe' -o \
            -name '*.fwork' \
        \) | sort >&2
        exit 1
    fi

    sanitize_absolute_paths "$root"
}

prune_macos_resources() {
    root=$1
    stdlib="$root/lib/python$PYTHON_VERSION_TAG"

    remove_pycache "$root"
    rm -rf "$stdlib/test"
    remove_python_tools "$root"
    rm -rf "$stdlib/lib-dynload"
    rm -f "$root/lib/libpython$PYTHON_VERSION_TAG.dylib" \
        "$root/lib/libpython3.dylib" \
        "$root/lib/libpython$PYTHON_VERSION_TAG.a"
    rm -f "$stdlib"/config-*/libpython*.a

    rm -rf "$stdlib/site-packages/pip" \
        "$stdlib/site-packages"/pip-*.dist-info \
        "$root/lib/pkgconfig"
    rm -f "$stdlib/_sysconfigdata__ios_arm64-iphoneos.py"

    if find "$root" \( -type f -o -type l \) \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.exe' -o \
        -name '*.fwork' \
    \) | grep -q .; then
        echo "Unexpected dynamic or binary macOS Python resource files remain:" >&2
        find "$root" \( -type f -o -type l \) \( \
            -name '*.so' -o \
            -name '*.dylib' -o \
            -name '*.a' -o \
            -name '*.exe' -o \
            -name '*.fwork' \
        \) | sort >&2
        exit 1
    fi

    sanitize_absolute_paths "$root"
}

verify_source_files() {
    for path in Apple/__main__.py Apple/iOS/README.md configure Modules/Setup.stdlib.in; do
        if [ ! -f "$CPYTHON_DIR/$path" ]; then
            echo "Missing CPython source file: $CPYTHON_DIR/$path" >&2
            exit 1
        fi
    done
}

verify_macos_arm64_host() {
    if [ "$(uname -m)" != "arm64" ]; then
        echo "macos-arm64 Python generation requires running this script on an arm64 Mac." >&2
        exit 1
    fi
}

verify_macos_dependency() {
    prefix=$1
    header=$2
    library=$3
    name=$4
    if [ ! -f "$prefix/include/$header" ] || [ ! -f "$prefix/lib/$library" ]; then
        echo "Missing generated macOS Python dependency $name at $prefix." >&2
        exit 1
    fi
}

verify_sha256() {
    path=$1
    expected=$2
    actual=$(shasum -a 256 "$path" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $path" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    fi
}

download_macos_dependency() {
    url=$1
    filename=$2
    checksum=$3
    archive="$MACOS_DEPS_SOURCE_CACHE_DIR/$filename"
    mkdir -p "$MACOS_DEPS_SOURCE_CACHE_DIR"
    if [ ! -f "$archive" ]; then
        curl -Lf --retry 5 --retry-all-errors -o "$archive.tmp" "$url"
        mv "$archive.tmp" "$archive"
    fi
    verify_sha256 "$archive" "$checksum"
    echo "$archive"
}

build_macos_openssl() {
    archive=$(download_macos_dependency \
        "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
        "openssl-$OPENSSL_VERSION.tar.gz" \
        "$OPENSSL_SHA256")
    source_root="$MACOS_DEPS_BUILD_DIR/openssl-src"
    rm -rf "$source_root" "$MACOS_OPENSSL_PREFIX"
    mkdir -p "$source_root"
    tar -xzf "$archive" -C "$source_root"
    log_file="$BUILD_DIR/macos_openssl.log"
    (
        cd "$source_root/openssl-$OPENSSL_VERSION"
        ./Configure darwin64-arm64-cc no-shared no-tests no-module \
            --prefix="$MACOS_OPENSSL_PREFIX" \
            --openssldir="$MACOS_OPENSSL_PREFIX/ssl" \
            "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION"
        make -j "$HOST_CPU_COUNT"
        make install_sw
    ) > "$log_file" 2>&1 || {
        tail -120 "$log_file"
        exit 1
    }
    verify_macos_dependency "$MACOS_OPENSSL_PREFIX" "openssl/ssl.h" "libssl.a" "OpenSSL"
    verify_macos_dependency "$MACOS_OPENSSL_PREFIX" "openssl/crypto.h" "libcrypto.a" "OpenSSL"
}

build_macos_xz() {
    archive=$(download_macos_dependency \
        "https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION/xz-$XZ_VERSION.tar.gz" \
        "xz-$XZ_VERSION.tar.gz" \
        "$XZ_SHA256")
    source_root="$MACOS_DEPS_BUILD_DIR/xz-src"
    rm -rf "$source_root" "$MACOS_XZ_PREFIX"
    mkdir -p "$source_root"
    tar -xzf "$archive" -C "$source_root"
    log_file="$BUILD_DIR/macos_xz.log"
    (
        cd "$source_root/xz-$XZ_VERSION"
        CC=cc CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" ./configure \
            --prefix="$MACOS_XZ_PREFIX" \
            --disable-shared \
            --enable-static \
            --disable-doc \
            --disable-nls
        make -j "$HOST_CPU_COUNT"
        make install
    ) > "$log_file" 2>&1 || {
        tail -120 "$log_file"
        exit 1
    }
    verify_macos_dependency "$MACOS_XZ_PREFIX" "lzma.h" "liblzma.a" "XZ"
}

build_macos_zstd() {
    archive=$(download_macos_dependency \
        "https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz" \
        "zstd-$ZSTD_VERSION.tar.gz" \
        "$ZSTD_SHA256")
    source_root="$MACOS_DEPS_BUILD_DIR/zstd-src"
    rm -rf "$source_root" "$MACOS_ZSTD_PREFIX"
    mkdir -p "$source_root"
    tar -xzf "$archive" -C "$source_root"
    log_file="$BUILD_DIR/macos_zstd.log"
    (
        cd "$source_root/zstd-$ZSTD_VERSION"
        make -C lib -j "$HOST_CPU_COUNT" libzstd.a \
            CC=cc \
            CFLAGS="-O3 -arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION"
        make -C lib install-static install-includes \
            PREFIX="$MACOS_ZSTD_PREFIX" \
            CC=cc \
            CFLAGS="-O3 -arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION"
    ) > "$log_file" 2>&1 || {
        tail -120 "$log_file"
        exit 1
    }
    verify_macos_dependency "$MACOS_ZSTD_PREFIX" "zstd.h" "libzstd.a" "Zstandard"
}

prepare_macos_dependencies() {
    rm -rf "$MACOS_DEPS_BUILD_DIR"
    mkdir -p "$MACOS_DEPS_PREFIX"
    build_macos_openssl
    build_macos_xz
    build_macos_zstd
}

build_pure_pyyaml_wheel() {
    archive=$(download_cached_source \
        "$PYYAML_SOURCE_CACHE_DIR" \
        "$PYYAML_SOURCE_FILENAME" \
        "$PYYAML_SOURCE_URL" \
        "$PYYAML_SOURCE_SHA256")
    source_root="$BUILD_DIR/pyyaml-source"
    rm -rf "$PYYAML_SOURCE_DIR" "$source_root"
    mkdir -p "$source_root" "$PURE_PYTHON_WHEEL_DIR"
    tar -xzf "$archive" -C "$source_root"
    mv "$source_root/pyyaml-$PYYAML_VERSION" "$PYYAML_SOURCE_DIR"
    rmdir "$source_root"

    log_file="$BUILD_DIR/build_pyyaml.log"
    (
        cd "$PYYAML_SOURCE_DIR"
        SOURCE_DATE_EPOCH="$PYYAML_SOURCE_DATE_EPOCH" \
            PYYAML_FORCE_LIBYAML=0 \
            "$NUMPY_BUILD_TOOLS_PYTHON" setup.py --without-libyaml bdist_wheel
    ) > "$log_file" 2>&1 || {
        tail -120 "$log_file"
        exit 1
    }

    wheel="$PURE_PYTHON_WHEEL_DIR/$PYYAML_WHEEL_FILENAME"
    mv "$PYYAML_SOURCE_DIR/dist/$PYYAML_WHEEL_FILENAME" "$wheel"
    verify_sha256 "$wheel" "$PYYAML_WHEEL_SHA256"
    unzip -p "$wheel" "pyyaml-$PYYAML_VERSION.dist-info/WHEEL" |
        grep -qx "Root-Is-Purelib: true"
    unzip -p "$wheel" "pyyaml-$PYYAML_VERSION.dist-info/WHEEL" |
        grep -qx "Tag: py3-none-any"
    native_entry=$(
        unzip -Z1 "$wheel" |
            grep -E '\.(so|dylib|a|dll|pyd)$' |
            sed -n '1p' ||
            true
    )
    if [ -n "$native_entry" ]; then
        echo "Pure-Python PyYAML wheel contains a native binary: $native_entry" >&2
        exit 1
    fi
}

install_pure_python_packages() {
    root=$1
    site_packages="$root/lib/python$PYTHON_VERSION_TAG/site-packages"
    if [ ! -s "$PURE_PYTHON_REQUIREMENTS" ]; then
        return
    fi

    mkdir -p "$PURE_PYTHON_WHEEL_DIR" "$site_packages"
    python3 -m pip download \
        --require-hashes \
        --no-deps \
        --only-binary=:all: \
        --find-links "$PURE_PYTHON_WHEEL_DIR" \
        --platform any \
        --implementation py \
        --abi none \
        --python-version "$PYTHON_VERSION_TAG" \
        --dest "$PURE_PYTHON_WHEEL_DIR" \
        -r "$PURE_PYTHON_REQUIREMENTS"
    python3 -m pip install \
        --no-index \
        --find-links "$PURE_PYTHON_WHEEL_DIR" \
        --require-hashes \
        --no-deps \
        --only-binary=:all: \
        --no-compile \
        --target "$site_packages" \
        -r "$PURE_PYTHON_REQUIREMENTS"
    tqdm_std="$site_packages/tqdm/std.py"
    if [ -f "$tqdm_std" ]; then
        sed -i.bak \
            -e '/^    th_lock = TRLock()$/a\
    mp_lock = None  # embedded commands do not support process-fork locks' \
            -e 's|^    monitor_interval = 10  # set to 0 to disable the thread$|    monitor_interval = 0  # embedded commands must not leave background threads|' \
            "$tqdm_std"
        rm -f "$tqdm_std.bak"
        tqdm_record="$site_packages/tqdm-4.70.0.dist-info/RECORD"
        sed -i.bak \
            's|tqdm/std.py,sha256=t-7qDtaeZoxAw9_K7JWxYe7Wbn1c_GRsO4HEkluaYB0,58074|tqdm/std.py,sha256=hszFPDhpsf0t7ldMTlu1aYAtxrjJ5M6WQoZmZohN3Z8,58168|' \
            "$tqdm_record"
        rm -f "$tqdm_record.bak"
        grep -qF "tqdm/std.py,sha256=hszFPDhpsf0t7ldMTlu1aYAtxrjJ5M6WQoZmZohN3Z8,58168" \
            "$tqdm_record"
    fi
    rm -rf "$site_packages/bin"
    remove_pycache "$site_packages"
}

install_embedded_runtime_sitecustomize() {
    root=$1
    stdlib="$root/lib/python$PYTHON_VERSION_TAG"
    mkdir -p "$stdlib"
    cat > "$stdlib/sitecustomize.py" <<'PY'
"""LocalCode embedded Python startup policy."""

try:
    import mimetypes as _localcode_mimetypes
except Exception:
    pass
else:
    # iOS has no Unix /etc MIME database. Keep MIME lookup deterministic and
    # avoid probing host-specific locations such as /etc/apache2/mime.types.
    _localcode_mimetypes.knownfiles = []
PY
}

download_numpy_source() {
    archive="$NUMPY_SOURCE_CACHE_DIR/$NUMPY_SOURCE_FILENAME"
    mkdir -p "$NUMPY_SOURCE_CACHE_DIR"
    if [ ! -f "$archive" ]; then
        curl -Lf --retry 5 --retry-all-errors -o "$archive.tmp" "$NUMPY_SOURCE_URL"
        mv "$archive.tmp" "$archive"
    fi
    verify_sha256 "$archive" "$NUMPY_SOURCE_SHA256"
    echo "$archive"
}

prepare_numpy_source() {
    archive=$(download_numpy_source)
    rm -rf "$NUMPY_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/numpy-source"
    tar -xzf "$archive" -C "$BUILD_DIR/numpy-source"
    mv "$BUILD_DIR/numpy-source/numpy-$NUMPY_VERSION" "$NUMPY_SOURCE_DIR"
    rmdir "$BUILD_DIR/numpy-source"
}

prepare_numpy_build_tools() {
    rm -rf "$NUMPY_BUILD_TOOLS_VENV"
    DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" "$MACOS_INSTALL_ROOT/bin/python$PYTHON_VERSION_TAG" -m venv "$NUMPY_BUILD_TOOLS_VENV"
    DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" "$NUMPY_BUILD_TOOLS_PYTHON" -m pip install --upgrade \
        "pip==$NUMPY_BUILD_PIP_VERSION" \
        "setuptools==$NUMPY_BUILD_SETUPTOOLS_VERSION" \
        "wheel==$NUMPY_BUILD_WHEEL_VERSION" \
        "Cython==$NUMPY_BUILD_CYTHON_VERSION" \
        "ninja==$NUMPY_BUILD_NINJA_VERSION" \
        "packaging==$NUMPY_BUILD_PACKAGING_VERSION" \
        "meson==$NUMPY_BUILD_MESON_VERSION" \
        "meson-python==$NUMPY_BUILD_MESON_PYTHON_VERSION" \
        "versioneer==$NUMPY_BUILD_VERSIONEER_VERSION" \
        "pybind11==$NUMPY_BUILD_PYBIND11_VERSION" \
        "cppy==$NUMPY_BUILD_CPPY_VERSION" \
        "setuptools-scm==$NUMPY_BUILD_SETUPTOOLS_SCM_VERSION" \
        "cffi==$CFFI_VERSION" \
        "cairocffi==1.7.1"
}

write_numpy_ios_cross_file() {
    output=$1
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    cat > "$output" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'
python = '$NUMPY_BUILD_TOOLS_PYTHON'
cython = '$NUMPY_BUILD_TOOLS_VENV/bin/cython'

[built-in options]
c_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path', '-I$IOS_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_HOST']
cpp_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path', '-I$IOS_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_HOST']
c_link_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path']
cpp_link_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path']

[properties]
needs_exe_wrapper = true
skip_sanity_check = true
longdouble_format = 'IEEE_DOUBLE_LE'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

write_numpy_ios_simulator_cross_file() {
    output=$1
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    cat > "$output" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphonesimulator', 'clang']
cpp = ['xcrun', '--sdk', 'iphonesimulator', 'clang++']
ar = ['xcrun', '--sdk', 'iphonesimulator', 'ar']
strip = ['xcrun', '--sdk', 'iphonesimulator', 'strip']
pkg-config = 'pkg-config'
python = '$NUMPY_BUILD_TOOLS_PYTHON'
cython = '$NUMPY_BUILD_TOOLS_VENV/bin/cython'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path', '-I$IOS_SIMULATOR_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST']
cpp_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path', '-I$IOS_SIMULATOR_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST']
c_link_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path']
cpp_link_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path']

[properties]
needs_exe_wrapper = true
skip_sanity_check = true
longdouble_format = 'IEEE_DOUBLE_LE'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

run_numpy_meson() {
    log_file=$1
    shift
    run_with_log "$log_file" env \
        DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
        PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH" \
        "$@"
}

build_numpy_ios() {
    cross_file="$BUILD_DIR/numpy-ios-cross.ini"
    ios_sysconfig_dir="$IOS_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    write_numpy_ios_cross_file "$cross_file"
    rm -rf "$NUMPY_IOS_BUILD_DIR" "$NUMPY_IOS_INSTALL_PREFIX" "$NUMPY_IOS_INSTALL_DESTDIR"
    run_numpy_meson "$BUILD_DIR/numpy_configure_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" setup "$NUMPY_IOS_BUILD_DIR" \
            "$NUMPY_SOURCE_DIR" \
            --cross-file="$cross_file" \
            -Dblas=accelerate \
            -Dlapack=accelerate \
            -Dallow-noblas=false \
            -Dblas-symbol-suffix= \
            -Dcpu-baseline=NEON \
            -Dcpu-dispatch= \
            --prefix="$NUMPY_IOS_INSTALL_PREFIX"
    run_numpy_meson "$BUILD_DIR/numpy_make_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" compile -C "$NUMPY_IOS_BUILD_DIR"
    run_numpy_meson "$BUILD_DIR/numpy_install_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" install -C "$NUMPY_IOS_BUILD_DIR" --destdir "$NUMPY_IOS_INSTALL_DESTDIR"
}

build_numpy_ios_simulator() {
    cross_file="$BUILD_DIR/numpy-ios-simulator-cross.ini"
    ios_simulator_sysconfig_dir="$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    write_numpy_ios_simulator_cross_file "$cross_file"
    rm -rf "$NUMPY_IOS_SIMULATOR_BUILD_DIR" "$NUMPY_IOS_SIMULATOR_INSTALL_PREFIX" "$NUMPY_IOS_SIMULATOR_INSTALL_DESTDIR"
    run_numpy_meson "$BUILD_DIR/numpy_configure_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" setup "$NUMPY_IOS_SIMULATOR_BUILD_DIR" \
            "$NUMPY_SOURCE_DIR" \
            --cross-file="$cross_file" \
            -Dblas=accelerate \
            -Dlapack=accelerate \
            -Dallow-noblas=false \
            -Dblas-symbol-suffix= \
            -Dcpu-baseline=NEON \
            -Dcpu-dispatch= \
            --prefix="$NUMPY_IOS_SIMULATOR_INSTALL_PREFIX"
    run_numpy_meson "$BUILD_DIR/numpy_make_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" compile -C "$NUMPY_IOS_SIMULATOR_BUILD_DIR"
    run_numpy_meson "$BUILD_DIR/numpy_install_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" install -C "$NUMPY_IOS_SIMULATOR_BUILD_DIR" --destdir "$NUMPY_IOS_SIMULATOR_INSTALL_DESTDIR"
}

build_numpy_macos() {
    rm -rf "$NUMPY_MACOS_BUILD_DIR" "$NUMPY_MACOS_INSTALL_PREFIX" "$NUMPY_MACOS_INSTALL_DESTDIR"
    run_numpy_meson "$BUILD_DIR/numpy_configure_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$NUMPY_MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" setup "$NUMPY_MACOS_BUILD_DIR" \
            "$NUMPY_SOURCE_DIR" \
            -Dblas=accelerate \
            -Dlapack=accelerate \
            -Dallow-noblas=false \
            -Dcpu-baseline=NEON \
            -Dcpu-dispatch= \
            --prefix="$NUMPY_MACOS_INSTALL_PREFIX"
    run_numpy_meson "$BUILD_DIR/numpy_make_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$NUMPY_MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" compile -C "$NUMPY_MACOS_BUILD_DIR"
    run_numpy_meson "$BUILD_DIR/numpy_install_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$NUMPY_MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$NUMPY_SOURCE_DIR/vendored-meson/meson" \
        "$NUMPY_BUILD_TOOLS_PYTHON" "$NUMPY_SOURCE_DIR/vendored-meson/meson/meson.py" install -C "$NUMPY_MACOS_BUILD_DIR" --destdir "$NUMPY_MACOS_INSTALL_DESTDIR"
}

write_numpy_inittab_source() {
    output=$1
    cat > "$output" <<'EOF'
#include <Python.h>

extern PyObject *PyInit__multiarray_umath(void);
extern PyObject *PyInit__simd(void);
extern PyObject *PyInit__pocketfft_umath(void);
extern PyObject *PyInit_lapack_lite(void);
extern PyObject *PyInit__umath_linalg(void);
extern PyObject *PyInit__bounded_integers(void);
extern PyObject *PyInit__common(void);
extern PyObject *PyInit__generator(void);
extern PyObject *PyInit__mt19937(void);
extern PyObject *PyInit__pcg64(void);
extern PyObject *PyInit__philox(void);
extern PyObject *PyInit__sfc64(void);
extern PyObject *PyInit_bit_generator(void);
extern PyObject *PyInit_mtrand(void);

int ios_python_register_numpy(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = 0;
    status |= PyImport_AppendInittab("numpy._core._multiarray_umath", PyInit__multiarray_umath);
    status |= PyImport_AppendInittab("numpy._core._simd", PyInit__simd);
    status |= PyImport_AppendInittab("numpy.fft._pocketfft_umath", PyInit__pocketfft_umath);
    status |= PyImport_AppendInittab("numpy.linalg.lapack_lite", PyInit_lapack_lite);
    status |= PyImport_AppendInittab("numpy.linalg._umath_linalg", PyInit__umath_linalg);
    status |= PyImport_AppendInittab("numpy.random._bounded_integers", PyInit__bounded_integers);
    status |= PyImport_AppendInittab("numpy.random._common", PyInit__common);
    status |= PyImport_AppendInittab("numpy.random._generator", PyInit__generator);
    status |= PyImport_AppendInittab("numpy.random._mt19937", PyInit__mt19937);
    status |= PyImport_AppendInittab("numpy.random._pcg64", PyInit__pcg64);
    status |= PyImport_AppendInittab("numpy.random._philox", PyInit__philox);
    status |= PyImport_AppendInittab("numpy.random._sfc64", PyInit__sfc64);
    status |= PyImport_AppendInittab("numpy.random.bit_generator", PyInit_bit_generator);
    status |= PyImport_AppendInittab("numpy.random.mtrand", PyInit_mtrand);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
EOF
}

compile_numpy_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_numpy_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_numpy_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

numpy_runtime_objects() {
    build_root=$1
    find "$build_root/numpy" -path '*tests*' -prune -o \
        -path '*.so.p/*.o' \
        ! -path '*/_core/_simd*.so.p/src_common_npy_cpu_features.c.o' \
        ! -path '*/linalg/*/lapack_lite_python_xerbla.c.o' \
        -print
}

numpy_runtime_archives() {
    build_root=$1
    find "$build_root/numpy" -name '*.a' ! -name '*test*' -print
}

install_numpy_resources() {
    resource_root=$1
    install_destdir=$2
    install_prefix=$3
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    installed_site_packages="$install_destdir$install_prefix/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/numpy" "$site_packages"/numpy-*.dist-info
    cp -R "$installed_site_packages/numpy" "$site_packages/"

    dist_info="$site_packages/numpy-$NUMPY_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$NUMPY_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/numpy" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/numpy" -name tests -type d -prune -exec rm -rf {} +
    rm -rf "$site_packages/numpy/random/_examples"
    find "$site_packages/numpy" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
}

download_pandas_source() {
    archive="$PANDAS_SOURCE_CACHE_DIR/$PANDAS_SOURCE_FILENAME"
    mkdir -p "$PANDAS_SOURCE_CACHE_DIR"
    if [ ! -f "$archive" ]; then
        curl -Lf --retry 5 --retry-all-errors -o "$archive.tmp" "$PANDAS_SOURCE_URL"
        mv "$archive.tmp" "$archive"
    fi
    verify_sha256 "$archive" "$PANDAS_SOURCE_SHA256"
    echo "$archive"
}

prepare_pandas_source() {
    archive=$(download_pandas_source)
    rm -rf "$PANDAS_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/pandas-source"
    tar -xzf "$archive" -C "$BUILD_DIR/pandas-source"
    mv "$BUILD_DIR/pandas-source/pandas-$PANDAS_VERSION" "$PANDAS_SOURCE_DIR"
    rmdir "$BUILD_DIR/pandas-source"
    patch_pandas_static_symbol_collisions
}

patch_pandas_static_symbol_collisions() {
    datetime_source="$PANDAS_SOURCE_DIR/pandas/_libs/src/vendored/numpy/datetime/np_datetime.c"
    datetime_header="$PANDAS_SOURCE_DIR/pandas/_libs/include/pandas/vendored/numpy/datetime/np_datetime.h"
    datetime_strings_source="$PANDAS_SOURCE_DIR/pandas/_libs/src/vendored/numpy/datetime/np_datetime_strings.c"
    pandas_datetime_source="$PANDAS_SOURCE_DIR/pandas/_libs/src/datetime/pd_datetime.c"

    for file in "$datetime_source" "$datetime_header"; do
        sed -i.bak \
            -e 's/is_leapyear/pandas_datetime_is_leapyear/g' \
            -e 's/add_minutes_to_datetimestruct/pandas_datetime_add_minutes_to_datetimestruct/g' \
            -e 's/get_datetimestruct_days/pandas_datetime_get_datetimestruct_days/g' \
            -e 's/get_datetime_metadata_from_dtype/pandas_datetime_get_datetime_metadata_from_dtype/g' \
            "$file"
        rm -f "$file.bak"
    done

    sed -i.bak \
        -e 's/is_leapyear/pandas_datetime_is_leapyear/g' \
        "$datetime_strings_source"
    rm -f "$datetime_strings_source.bak"

    sed -i.bak \
        -e 's/add_minutes_to_datetimestruct/pandas_datetime_add_minutes_to_datetimestruct/g' \
        -e 's/capi->get_datetime_metadata_from_dtype = get_datetime_metadata_from_dtype;/capi->get_datetime_metadata_from_dtype = pandas_datetime_get_datetime_metadata_from_dtype;/' \
        "$pandas_datetime_source"
    rm -f "$pandas_datetime_source.bak"
}

write_pandas_ios_cross_file() {
    output=$1
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    cat > "$output" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'
python = '$NUMPY_BUILD_TOOLS_PYTHON'
cython = '$NUMPY_BUILD_TOOLS_VENV/bin/cython'

[built-in options]
c_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path', '-I$IOS_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_HOST']
cpp_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path', '-I$IOS_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_HOST']
c_link_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path']
cpp_link_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path']

[properties]
needs_exe_wrapper = true
skip_sanity_check = true

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

write_pandas_ios_simulator_cross_file() {
    output=$1
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    cat > "$output" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphonesimulator', 'clang']
cpp = ['xcrun', '--sdk', 'iphonesimulator', 'clang++']
ar = ['xcrun', '--sdk', 'iphonesimulator', 'ar']
strip = ['xcrun', '--sdk', 'iphonesimulator', 'strip']
pkg-config = 'pkg-config'
python = '$NUMPY_BUILD_TOOLS_PYTHON'
cython = '$NUMPY_BUILD_TOOLS_VENV/bin/cython'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path', '-I$IOS_SIMULATOR_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST']
cpp_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path', '-I$IOS_SIMULATOR_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST']
c_link_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path']
cpp_link_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path']

[properties]
needs_exe_wrapper = true
skip_sanity_check = true

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

run_package_meson() {
    log_file=$1
    shift
    run_with_log "$log_file" env \
        DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
        PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH" \
        "$@"
}

pandas_numpy_host_site_packages() {
    echo "$NUMPY_MACOS_INSTALL_DESTDIR$NUMPY_MACOS_INSTALL_PREFIX/lib/python$PYTHON_VERSION_TAG/site-packages"
}

build_pandas_ios() {
    cross_file="$BUILD_DIR/pandas-ios-cross.ini"
    ios_sysconfig_dir="$IOS_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    numpy_site_packages=$(pandas_numpy_host_site_packages)
    write_pandas_ios_cross_file "$cross_file"
    rm -rf "$PANDAS_IOS_BUILD_DIR" "$PANDAS_IOS_INSTALL_PREFIX" "$PANDAS_IOS_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/pandas_configure_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$PANDAS_IOS_BUILD_DIR" \
            "$PANDAS_SOURCE_DIR" \
            --cross-file="$cross_file" \
            --prefix="$PANDAS_IOS_INSTALL_PREFIX"
    run_package_meson "$BUILD_DIR/pandas_make_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$PANDAS_IOS_BUILD_DIR"
    run_package_meson "$BUILD_DIR/pandas_install_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$PANDAS_IOS_BUILD_DIR" --destdir "$PANDAS_IOS_INSTALL_DESTDIR"
}

build_pandas_ios_simulator() {
    cross_file="$BUILD_DIR/pandas-ios-simulator-cross.ini"
    ios_simulator_sysconfig_dir="$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    numpy_site_packages=$(pandas_numpy_host_site_packages)
    write_pandas_ios_simulator_cross_file "$cross_file"
    rm -rf "$PANDAS_IOS_SIMULATOR_BUILD_DIR" "$PANDAS_IOS_SIMULATOR_INSTALL_PREFIX" "$PANDAS_IOS_SIMULATOR_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/pandas_configure_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$PANDAS_IOS_SIMULATOR_BUILD_DIR" \
            "$PANDAS_SOURCE_DIR" \
            --cross-file="$cross_file" \
            --prefix="$PANDAS_IOS_SIMULATOR_INSTALL_PREFIX"
    run_package_meson "$BUILD_DIR/pandas_make_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$PANDAS_IOS_SIMULATOR_BUILD_DIR"
    run_package_meson "$BUILD_DIR/pandas_install_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$PANDAS_IOS_SIMULATOR_BUILD_DIR" --destdir "$PANDAS_IOS_SIMULATOR_INSTALL_DESTDIR"
}

build_pandas_macos() {
    numpy_site_packages=$(pandas_numpy_host_site_packages)
    rm -rf "$PANDAS_MACOS_BUILD_DIR" "$PANDAS_MACOS_INSTALL_PREFIX" "$PANDAS_MACOS_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/pandas_configure_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$numpy_site_packages" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$PANDAS_MACOS_BUILD_DIR" \
            "$PANDAS_SOURCE_DIR" \
            --prefix="$PANDAS_MACOS_INSTALL_PREFIX"
    run_package_meson "$BUILD_DIR/pandas_make_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$numpy_site_packages" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$PANDAS_MACOS_BUILD_DIR"
    run_package_meson "$BUILD_DIR/pandas_install_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$numpy_site_packages" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$PANDAS_MACOS_BUILD_DIR" --destdir "$PANDAS_MACOS_INSTALL_DESTDIR"
}

pandas_module_entries() {
    cat <<'EOF'
pandas._libs._cyutility PyInit__cyutility
pandas._libs.algos PyInit_algos
pandas._libs.arrays PyInit_arrays
pandas._libs.byteswap PyInit_byteswap
pandas._libs.groupby PyInit_groupby
pandas._libs.hashing PyInit_hashing
pandas._libs.hashtable PyInit_hashtable
pandas._libs.index PyInit_index
pandas._libs.indexing PyInit_indexing
pandas._libs.internals PyInit_internals
pandas._libs.interval PyInit_interval
pandas._libs.join PyInit_join
pandas._libs.json PyInit_json
pandas._libs.lib PyInit_lib
pandas._libs.missing PyInit_missing
pandas._libs.ops PyInit_ops
pandas._libs.ops_dispatch PyInit_ops_dispatch
pandas._libs.pandas_datetime PyInit_pandas_datetime
pandas._libs.pandas_parser PyInit_pandas_parser
pandas._libs.parsers PyInit_parsers
pandas._libs.properties PyInit_properties
pandas._libs.reshape PyInit_reshape
pandas._libs.sas PyInit_sas
pandas._libs.sparse PyInit_sparse
pandas._libs.testing PyInit_testing
pandas._libs.tslib PyInit_tslib
pandas._libs.tslibs.base PyInit_base
pandas._libs.tslibs.ccalendar PyInit_ccalendar
pandas._libs.tslibs.conversion PyInit_conversion
pandas._libs.tslibs.dtypes PyInit_dtypes
pandas._libs.tslibs.fields PyInit_fields
pandas._libs.tslibs.nattype PyInit_nattype
pandas._libs.tslibs.np_datetime PyInit_np_datetime
pandas._libs.tslibs.offsets PyInit_offsets
pandas._libs.tslibs.parsing PyInit_parsing
pandas._libs.tslibs.period PyInit_period
pandas._libs.tslibs.strptime PyInit_strptime
pandas._libs.tslibs.timedeltas PyInit_timedeltas
pandas._libs.tslibs.timestamps PyInit_timestamps
pandas._libs.tslibs.timezones PyInit_timezones
pandas._libs.tslibs.tzconversion PyInit_tzconversion
pandas._libs.tslibs.vectorized PyInit_vectorized
pandas._libs.window.aggregations PyInit_aggregations
pandas._libs.window.indexers PyInit_indexers
pandas._libs.writers PyInit_writers
EOF
}

write_pandas_inittab_source() {
    output=$1
    {
        echo '#include <Python.h>'
        echo
        pandas_module_entries | while IFS=' ' read -r module initfunc; do
            echo "extern PyObject *$initfunc(void);"
        done
        echo
        echo 'int ios_python_register_pandas(void) {'
        echo '    static int registered = 0;'
        echo '    if (registered) {'
        echo '        return 0;'
        echo '    }'
        echo '    int status = 0;'
        pandas_module_entries | while IFS=' ' read -r module initfunc; do
            echo "    status |= PyImport_AppendInittab(\"$module\", $initfunc);"
        done
        echo '    if (status == 0) {'
        echo '        registered = 1;'
        echo '    }'
        echo '    return status;'
        echo '}'
    } > "$output"
}

compile_pandas_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_pandas_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_pandas_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

pandas_runtime_objects() {
    build_root=$1
    find "$build_root/pandas" -path '*tests*' -prune -o \
        -path '*.so.p/*.o' \
        -print
    find "$build_root" -path "$build_root/_cyutility*.so.p/*.o" -print
}

install_pandas_resources() {
    resource_root=$1
    install_destdir=$2
    install_prefix=$3
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    installed_site_packages="$install_destdir$install_prefix/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/pandas" "$site_packages"/pandas-*.dist-info
    cp -R "$installed_site_packages/pandas" "$site_packages/"

    dist_info="$site_packages/pandas-$PANDAS_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$PANDAS_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/pandas" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/pandas" -name tests -type d -prune -exec rm -rf {} +
    rm -f "$site_packages/pandas/conftest.py"
    find "$site_packages/pandas" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
}

prepare_libjpeg_turbo_source() {
    archive=$(download_cached_source "$LIBJPEG_TURBO_SOURCE_CACHE_DIR" "$LIBJPEG_TURBO_SOURCE_FILENAME" "$LIBJPEG_TURBO_SOURCE_URL" "$LIBJPEG_TURBO_SOURCE_SHA256")
    rm -rf "$LIBJPEG_TURBO_SOURCE_DIR" "$BUILD_DIR/libjpeg-turbo-source"
    mkdir -p "$BUILD_DIR/libjpeg-turbo-source"
    tar -xzf "$archive" -C "$BUILD_DIR/libjpeg-turbo-source"
    mv "$BUILD_DIR/libjpeg-turbo-source/libjpeg-turbo-$LIBJPEG_TURBO_VERSION" "$LIBJPEG_TURBO_SOURCE_DIR"
    rmdir "$BUILD_DIR/libjpeg-turbo-source"
}

# Pillow's JPEG codec links libjpeg statically. Match Pillow's own wheels
# (jpeg8 API) and require the arm64 Neon SIMD path.
build_libjpeg_turbo_slice() {
    build_root=$1
    prefix=$2
    system_name=$3
    sdk_name=$4
    minimum_os_version=$5
    log_suffix=$6

    rm -rf "$build_root" "$prefix"
    run_with_log "$BUILD_DIR/libjpeg_turbo_configure_$log_suffix.log" \
        cmake \
            -S "$LIBJPEG_TURBO_SOURCE_DIR" \
            -B "$build_root" \
            -G Ninja \
            "-DCMAKE_MAKE_PROGRAM=$NUMPY_BUILD_TOOLS_VENV/bin/ninja" \
            "-DCMAKE_SYSTEM_NAME=$system_name" \
            -DCMAKE_SYSTEM_PROCESSOR=arm64 \
            "-DCMAKE_C_COMPILER=$(xcrun --sdk "$sdk_name" --find clang)" \
            "-DCMAKE_OSX_SYSROOT=$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=$minimum_os_version" \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
            -DCMAKE_BUILD_TYPE=Release \
            "-DCMAKE_INSTALL_PREFIX=$prefix" \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DENABLE_SHARED=OFF \
            -DENABLE_STATIC=ON \
            -DWITH_JPEG8=ON \
            -DWITH_TURBOJPEG=OFF \
            -DWITH_TOOLS=OFF \
            -DWITH_TESTS=OFF \
            -DREQUIRE_SIMD=ON
    run_with_log "$BUILD_DIR/libjpeg_turbo_build_$log_suffix.log" \
        cmake --build "$build_root" --parallel "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libjpeg_turbo_install_$log_suffix.log" \
        cmake --install "$build_root"
    test -f "$prefix/include/jpeglib.h"
    test -f "$prefix/lib/libjpeg.a"
}

libjpeg_turbo_runtime_archives() {
    echo "$1/lib/libjpeg.a"
}

download_pillow_source() {
    archive="$PILLOW_SOURCE_CACHE_DIR/$PILLOW_SOURCE_FILENAME"
    mkdir -p "$PILLOW_SOURCE_CACHE_DIR"
    if [ ! -f "$archive" ]; then
        curl -Lf --retry 5 --retry-all-errors -o "$archive.tmp" "$PILLOW_SOURCE_URL"
        mv "$archive.tmp" "$archive"
    fi
    verify_sha256 "$archive" "$PILLOW_SOURCE_SHA256"
    echo "$archive"
}

prepare_pillow_source() {
    archive=$(download_pillow_source)
    rm -rf "$PILLOW_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/pillow-source"
    tar -xzf "$archive" -C "$BUILD_DIR/pillow-source"
    mv "$BUILD_DIR/pillow-source/pillow-$PILLOW_VERSION" "$PILLOW_SOURCE_DIR"
    rmdir "$BUILD_DIR/pillow-source"
}

# FreeType and Raqm come from Matplotlib's bundled static build, so the Python
# archive carries one copy of each and Pillow must build after Matplotlib.
# Each slice sets PKG_CONFIG=/usr/bin/false so no host library is discovered.
pillow_build_options() {
    cat <<'EOF'
--enable-jpeg
--enable-freetype
--enable-raqm
--disable-tiff
--disable-lcms
--disable-webp
--disable-jpeg2000
--disable-imagequant
--disable-xcb
--disable-avif
--disable-platform-guessing
EOF
}

build_pillow_ios() {
    ios_sysconfig_dir="$IOS_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    rm -rf "$PILLOW_IOS_BUILD_DIR"
    mkdir -p "$PILLOW_IOS_BUILD_DIR/temp" "$PILLOW_IOS_BUILD_DIR/lib"
    (
        cd "$PILLOW_SOURCE_DIR"
        run_with_log "$BUILD_DIR/pillow_make_ios.log" \
            env \
                DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
                PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH" \
                PYTHONPATH="$ios_sysconfig_dir" \
                _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
                _PYTHON_HOST_PLATFORM=ios-13.0-arm64-iphoneos \
                PKG_CONFIG=/usr/bin/false \
                JPEG_ROOT="$LIBJPEG_TURBO_IOS_PREFIX" \
                FREETYPE_ROOT="$MATPLOTLIB_IOS_INSTALL_DESTDIR$MATPLOTLIB_IOS_INSTALL_PREFIX" \
                RAQM_ROOT="$MATPLOTLIB_IOS_INSTALL_DESTDIR$MATPLOTLIB_IOS_INSTALL_PREFIX" \
                CC="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_sdk_path" \
                LDSHARED="xcrun --sdk iphoneos clang -bundle -undefined dynamic_lookup -arch arm64 -miphoneos-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_sdk_path" \
                AR="xcrun --sdk iphoneos ar" \
                CFLAGS="-I$IOS_FRAMEWORK/Headers -I$ios_sdk_path/usr/include -Wno-nullability-completeness" \
                CPPFLAGS="-I$IOS_FRAMEWORK/Headers -I$ios_sdk_path/usr/include" \
                LDFLAGS="-L$ios_sdk_path/usr/lib" \
                "$NUMPY_BUILD_TOOLS_PYTHON" setup.py \
                    build_clib --build-temp "$PILLOW_IOS_BUILD_DIR/temp" \
                    build_ext --build-temp "$PILLOW_IOS_BUILD_DIR/temp" --build-lib "$PILLOW_IOS_BUILD_DIR/lib" -v \
                    $(pillow_build_options)
    )
}

build_pillow_ios_simulator() {
    ios_simulator_sysconfig_dir="$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    rm -rf "$PILLOW_IOS_SIMULATOR_BUILD_DIR"
    mkdir -p "$PILLOW_IOS_SIMULATOR_BUILD_DIR/temp" "$PILLOW_IOS_SIMULATOR_BUILD_DIR/lib"
    (
        cd "$PILLOW_SOURCE_DIR"
        run_with_log "$BUILD_DIR/pillow_make_ios_simulator.log" \
            env \
                DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
                PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH" \
                PYTHONPATH="$ios_simulator_sysconfig_dir" \
                _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
                _PYTHON_HOST_PLATFORM=ios-13.0-arm64-iphonesimulator \
                PKG_CONFIG=/usr/bin/false \
                JPEG_ROOT="$LIBJPEG_TURBO_IOS_SIMULATOR_PREFIX" \
                FREETYPE_ROOT="$MATPLOTLIB_IOS_SIMULATOR_INSTALL_DESTDIR$MATPLOTLIB_IOS_SIMULATOR_INSTALL_PREFIX" \
                RAQM_ROOT="$MATPLOTLIB_IOS_SIMULATOR_INSTALL_DESTDIR$MATPLOTLIB_IOS_SIMULATOR_INSTALL_PREFIX" \
                CC="xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_simulator_sdk_path" \
                LDSHARED="xcrun --sdk iphonesimulator clang -bundle -undefined dynamic_lookup -arch arm64 -mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_simulator_sdk_path" \
                AR="xcrun --sdk iphonesimulator ar" \
                CFLAGS="-I$IOS_SIMULATOR_FRAMEWORK/Headers -I$ios_simulator_sdk_path/usr/include -Wno-nullability-completeness" \
                CPPFLAGS="-I$IOS_SIMULATOR_FRAMEWORK/Headers -I$ios_simulator_sdk_path/usr/include" \
                LDFLAGS="-L$ios_simulator_sdk_path/usr/lib" \
                "$NUMPY_BUILD_TOOLS_PYTHON" setup.py \
                    build_clib --build-temp "$PILLOW_IOS_SIMULATOR_BUILD_DIR/temp" \
                    build_ext --build-temp "$PILLOW_IOS_SIMULATOR_BUILD_DIR/temp" --build-lib "$PILLOW_IOS_SIMULATOR_BUILD_DIR/lib" -v \
                    $(pillow_build_options)
    )
}

build_pillow_macos() {
    macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    rm -rf "$PILLOW_MACOS_BUILD_DIR"
    mkdir -p "$PILLOW_MACOS_BUILD_DIR/temp" "$PILLOW_MACOS_BUILD_DIR/lib"
    (
        cd "$PILLOW_SOURCE_DIR"
        run_with_log "$BUILD_DIR/pillow_make_macos.log" \
            env \
                DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
                PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH" \
                MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
                PKG_CONFIG=/usr/bin/false \
                JPEG_ROOT="$LIBJPEG_TURBO_MACOS_PREFIX" \
                FREETYPE_ROOT="$MATPLOTLIB_MACOS_INSTALL_DESTDIR$MATPLOTLIB_MACOS_INSTALL_PREFIX" \
                RAQM_ROOT="$MATPLOTLIB_MACOS_INSTALL_DESTDIR$MATPLOTLIB_MACOS_INSTALL_PREFIX" \
                CC="cc -arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION -isysroot $macos_sdk_path" \
                LDSHARED="cc -bundle -undefined dynamic_lookup -arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION -isysroot $macos_sdk_path" \
                AR=ar \
                CFLAGS="-I$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG -I$macos_sdk_path/usr/include" \
                CPPFLAGS="-I$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG -I$macos_sdk_path/usr/include" \
                LDFLAGS="-L$macos_sdk_path/usr/lib" \
                "$NUMPY_BUILD_TOOLS_PYTHON" setup.py \
                    build_clib --build-temp "$PILLOW_MACOS_BUILD_DIR/temp" \
                    build_ext --build-temp "$PILLOW_MACOS_BUILD_DIR/temp" --build-lib "$PILLOW_MACOS_BUILD_DIR/lib" -v \
                    $(pillow_build_options)
    )
}

pillow_module_entries() {
    cat <<'EOF'
PIL._imaging PyInit__imaging
PIL._imagingft PyInit__imagingft
PIL._imagingmath PyInit__imagingmath
PIL._imagingmorph PyInit__imagingmorph
PIL._imagingtk PyInit__imagingtk
EOF
}

write_pillow_inittab_source() {
    output=$1
    {
        echo '#include <Python.h>'
        echo
        pillow_module_entries | while IFS=' ' read -r module initfunc; do
            echo "extern PyObject *$initfunc(void);"
        done
        echo
        echo 'int ios_python_register_pillow(void) {'
        echo '    static int registered = 0;'
        echo '    if (registered) {'
        echo '        return 0;'
        echo '    }'
        echo '    int status = 0;'
        pillow_module_entries | while IFS=' ' read -r module initfunc; do
            echo "    status |= PyImport_AppendInittab(\"$module\", $initfunc);"
        done
        echo '    if (status == 0) {'
        echo '        registered = 1;'
        echo '    }'
        echo '    return status;'
        echo '}'
    } > "$output"
}

compile_pillow_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_pillow_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_pillow_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

pillow_runtime_objects() {
    build_root=$1
    find "$build_root/temp" -name '*.o' -print
}

install_pillow_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/PIL" "$site_packages"/pillow-*.dist-info "$site_packages"/Pillow-*.dist-info
    cp -R "$PILLOW_SOURCE_DIR/src/PIL" "$site_packages/"

    dist_info="$site_packages/pillow-$PILLOW_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$PILLOW_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
    licenses="$dist_info/licenses/native"
    mkdir -p "$licenses"
    cp "$LIBJPEG_TURBO_SOURCE_DIR/LICENSE.md" "$licenses/libjpeg-turbo-LICENSE.md"
    cp "$LIBJPEG_TURBO_SOURCE_DIR/README.ijg" "$licenses/libjpeg-turbo-README.ijg"

    find "$site_packages/PIL" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/PIL" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
}

download_cached_source() {
    cache_dir=$1
    filename=$2
    url=$3
    checksum=$4
    archive="$cache_dir/$filename"
    mkdir -p "$cache_dir"
    if [ ! -f "$archive" ]; then
        curl -Lf --retry 5 --retry-all-errors -o "$archive.tmp" "$url"
        mv "$archive.tmp" "$archive"
    fi
    verify_sha256 "$archive" "$checksum"
    echo "$archive"
}

prepare_libxml2_source() {
    archive=$(download_cached_source "$LIBXML2_SOURCE_CACHE_DIR" "$LIBXML2_SOURCE_FILENAME" "$LIBXML2_SOURCE_URL" "$LIBXML2_SOURCE_SHA256")
    rm -rf "$LIBXML2_SOURCE_DIR" "$BUILD_DIR/libxml2-source"
    mkdir -p "$BUILD_DIR/libxml2-source"
    tar -xf "$archive" -C "$BUILD_DIR/libxml2-source"
    mv "$BUILD_DIR/libxml2-source/libxml2-$LIBXML2_VERSION" "$LIBXML2_SOURCE_DIR"
    rmdir "$BUILD_DIR/libxml2-source"
}

prepare_libxslt_source() {
    archive=$(download_cached_source "$LIBXSLT_SOURCE_CACHE_DIR" "$LIBXSLT_SOURCE_FILENAME" "$LIBXSLT_SOURCE_URL" "$LIBXSLT_SOURCE_SHA256")
    rm -rf "$LIBXSLT_SOURCE_DIR" "$BUILD_DIR/libxslt-source"
    mkdir -p "$BUILD_DIR/libxslt-source"
    tar -xf "$archive" -C "$BUILD_DIR/libxslt-source"
    mv "$BUILD_DIR/libxslt-source/libxslt-$LIBXSLT_VERSION" "$LIBXSLT_SOURCE_DIR"
    rmdir "$BUILD_DIR/libxslt-source"
}

prepare_lxml_source() {
    archive=$(download_cached_source "$LXML_SOURCE_CACHE_DIR" "$LXML_SOURCE_FILENAME" "$LXML_SOURCE_URL" "$LXML_SOURCE_SHA256")
    rm -rf "$LXML_SOURCE_DIR" "$BUILD_DIR/lxml-source"
    mkdir -p "$BUILD_DIR/lxml-source"
    tar -xzf "$archive" -C "$BUILD_DIR/lxml-source"
    mv "$BUILD_DIR/lxml-source/lxml-$LXML_VERSION" "$LXML_SOURCE_DIR"
    rmdir "$BUILD_DIR/lxml-source"
}

copy_source_tree() {
    source_root=$1
    build_root=$2
    rm -rf "$build_root"
    mkdir -p "$build_root"
    cp -pR "$source_root/." "$build_root/"
}

build_libxml2_ios() {
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    copy_source_tree "$LIBXML2_SOURCE_DIR" "$LIBXML2_IOS_BUILD_DIR"
    rm -rf "$LIBXML2_IOS_PREFIX"
    (
        cd "$LIBXML2_IOS_BUILD_DIR"
        run_with_log "$BUILD_DIR/libxml2_configure_ios.log" \
            env \
                CC="xcrun --sdk iphoneos clang" \
                CFLAGS="-arch arm64 -miphoneos-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_sdk_path -O2 -fPIC" \
                LDFLAGS="-arch arm64 -miphoneos-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_sdk_path -lz" \
                ./configure \
                    --host=arm-apple-darwin \
                    --prefix="$LIBXML2_IOS_PREFIX" \
                    --enable-static \
                    --disable-shared \
                    --without-python \
                    --without-lzma \
                    --without-icu \
                    --without-readline \
                    --with-zlib \
                    --with-iconv=yes
    )
    run_with_log "$BUILD_DIR/libxml2_make_ios.log" make -C "$LIBXML2_IOS_BUILD_DIR" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libxml2_install_ios.log" make -C "$LIBXML2_IOS_BUILD_DIR" install
}

build_libxml2_ios_simulator() {
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    copy_source_tree "$LIBXML2_SOURCE_DIR" "$LIBXML2_IOS_SIMULATOR_BUILD_DIR"
    rm -rf "$LIBXML2_IOS_SIMULATOR_PREFIX"
    (
        cd "$LIBXML2_IOS_SIMULATOR_BUILD_DIR"
        run_with_log "$BUILD_DIR/libxml2_configure_ios_simulator.log" \
            env \
                CC="xcrun --sdk iphonesimulator clang" \
                CFLAGS="-arch arm64 -mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_simulator_sdk_path -O2 -fPIC" \
                LDFLAGS="-arch arm64 -mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_simulator_sdk_path -lz" \
                ./configure \
                    --host=arm-apple-darwin \
                    --prefix="$LIBXML2_IOS_SIMULATOR_PREFIX" \
                    --enable-static \
                    --disable-shared \
                    --without-python \
                    --without-lzma \
                    --without-icu \
                    --without-readline \
                    --with-zlib \
                    --with-iconv=yes
    )
    run_with_log "$BUILD_DIR/libxml2_make_ios_simulator.log" make -C "$LIBXML2_IOS_SIMULATOR_BUILD_DIR" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libxml2_install_ios_simulator.log" make -C "$LIBXML2_IOS_SIMULATOR_BUILD_DIR" install
}

build_libxml2_macos() {
    macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    copy_source_tree "$LIBXML2_SOURCE_DIR" "$LIBXML2_MACOS_BUILD_DIR"
    rm -rf "$LIBXML2_MACOS_PREFIX"
    (
        cd "$LIBXML2_MACOS_BUILD_DIR"
        run_with_log "$BUILD_DIR/libxml2_configure_macos.log" \
            env \
                CC=cc \
                CFLAGS="-arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION -isysroot $macos_sdk_path -O2 -fPIC" \
                LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION -isysroot $macos_sdk_path -lz" \
                ./configure \
                    --prefix="$LIBXML2_MACOS_PREFIX" \
                    --enable-static \
                    --disable-shared \
                    --without-python \
                    --without-lzma \
                    --without-icu \
                    --without-readline \
                    --with-zlib \
                    --with-iconv=yes
    )
    run_with_log "$BUILD_DIR/libxml2_make_macos.log" make -C "$LIBXML2_MACOS_BUILD_DIR" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libxml2_install_macos.log" make -C "$LIBXML2_MACOS_BUILD_DIR" install
}

build_libxslt_ios() {
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    copy_source_tree "$LIBXSLT_SOURCE_DIR" "$LIBXSLT_IOS_BUILD_DIR"
    (
        cd "$LIBXSLT_IOS_BUILD_DIR"
        run_with_log "$BUILD_DIR/libxslt_configure_ios.log" \
            env \
                CC="xcrun --sdk iphoneos clang" \
                CFLAGS="-arch arm64 -miphoneos-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_sdk_path -O2 -fPIC -I$LIBXML2_IOS_PREFIX/include/libxml2" \
                CPPFLAGS="-I$LIBXML2_IOS_PREFIX/include/libxml2 -I$LIBXML2_IOS_PREFIX/include" \
                LDFLAGS="-arch arm64 -miphoneos-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_sdk_path -L$LIBXML2_IOS_PREFIX/lib" \
                PKG_CONFIG=/usr/bin/false \
                LIBXML_CFLAGS="-I$LIBXML2_IOS_PREFIX/include/libxml2" \
                LIBXML_LIBS="-L$LIBXML2_IOS_PREFIX/lib -lxml2 -lz -liconv" \
                ./configure \
                    --host=arm-apple-darwin \
                    --prefix="$LIBXML2_IOS_PREFIX" \
                    --enable-static \
                    --disable-shared \
                    --without-python \
                    --without-debugger \
                    --without-crypto \
                    --without-plugins \
                    --with-libxml-prefix="$LIBXML2_IOS_PREFIX" \
                    --with-libxml-include-prefix="$LIBXML2_IOS_PREFIX/include" \
                    --with-libxml-libs-prefix="$LIBXML2_IOS_PREFIX/lib"
    )
    run_with_log "$BUILD_DIR/libxslt_make_ios.log" make -C "$LIBXSLT_IOS_BUILD_DIR/libxslt" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libexslt_make_ios.log" make -C "$LIBXSLT_IOS_BUILD_DIR/libexslt" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libxslt_install_ios.log" make -C "$LIBXSLT_IOS_BUILD_DIR/libxslt" install
    run_with_log "$BUILD_DIR/libexslt_install_ios.log" make -C "$LIBXSLT_IOS_BUILD_DIR/libexslt" install
}

build_libxslt_ios_simulator() {
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    copy_source_tree "$LIBXSLT_SOURCE_DIR" "$LIBXSLT_IOS_SIMULATOR_BUILD_DIR"
    (
        cd "$LIBXSLT_IOS_SIMULATOR_BUILD_DIR"
        run_with_log "$BUILD_DIR/libxslt_configure_ios_simulator.log" \
            env \
                CC="xcrun --sdk iphonesimulator clang" \
                CFLAGS="-arch arm64 -mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_simulator_sdk_path -O2 -fPIC -I$LIBXML2_IOS_SIMULATOR_PREFIX/include/libxml2" \
                CPPFLAGS="-I$LIBXML2_IOS_SIMULATOR_PREFIX/include/libxml2 -I$LIBXML2_IOS_SIMULATOR_PREFIX/include" \
                LDFLAGS="-arch arm64 -mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION -isysroot $ios_simulator_sdk_path -L$LIBXML2_IOS_SIMULATOR_PREFIX/lib" \
                PKG_CONFIG=/usr/bin/false \
                LIBXML_CFLAGS="-I$LIBXML2_IOS_SIMULATOR_PREFIX/include/libxml2" \
                LIBXML_LIBS="-L$LIBXML2_IOS_SIMULATOR_PREFIX/lib -lxml2 -lz -liconv" \
                ./configure \
                    --host=arm-apple-darwin \
                    --prefix="$LIBXML2_IOS_SIMULATOR_PREFIX" \
                    --enable-static \
                    --disable-shared \
                    --without-python \
                    --without-debugger \
                    --without-crypto \
                    --without-plugins \
                    --with-libxml-prefix="$LIBXML2_IOS_SIMULATOR_PREFIX" \
                    --with-libxml-include-prefix="$LIBXML2_IOS_SIMULATOR_PREFIX/include" \
                    --with-libxml-libs-prefix="$LIBXML2_IOS_SIMULATOR_PREFIX/lib"
    )
    run_with_log "$BUILD_DIR/libxslt_make_ios_simulator.log" make -C "$LIBXSLT_IOS_SIMULATOR_BUILD_DIR/libxslt" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libexslt_make_ios_simulator.log" make -C "$LIBXSLT_IOS_SIMULATOR_BUILD_DIR/libexslt" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libxslt_install_ios_simulator.log" make -C "$LIBXSLT_IOS_SIMULATOR_BUILD_DIR/libxslt" install
    run_with_log "$BUILD_DIR/libexslt_install_ios_simulator.log" make -C "$LIBXSLT_IOS_SIMULATOR_BUILD_DIR/libexslt" install
}

build_libxslt_macos() {
    macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    copy_source_tree "$LIBXSLT_SOURCE_DIR" "$LIBXSLT_MACOS_BUILD_DIR"
    (
        cd "$LIBXSLT_MACOS_BUILD_DIR"
        run_with_log "$BUILD_DIR/libxslt_configure_macos.log" \
            env \
                CC=cc \
                CFLAGS="-arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION -isysroot $macos_sdk_path -O2 -fPIC -I$LIBXML2_MACOS_PREFIX/include/libxml2" \
                CPPFLAGS="-I$LIBXML2_MACOS_PREFIX/include/libxml2 -I$LIBXML2_MACOS_PREFIX/include" \
                LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION -isysroot $macos_sdk_path -L$LIBXML2_MACOS_PREFIX/lib" \
                PKG_CONFIG=/usr/bin/false \
                LIBXML_CFLAGS="-I$LIBXML2_MACOS_PREFIX/include/libxml2" \
                LIBXML_LIBS="-L$LIBXML2_MACOS_PREFIX/lib -lxml2 -lz -liconv" \
                ./configure \
                    --prefix="$LIBXML2_MACOS_PREFIX" \
                    --enable-static \
                    --disable-shared \
                    --without-python \
                    --without-debugger \
                    --without-crypto \
                    --without-plugins \
                    --with-libxml-prefix="$LIBXML2_MACOS_PREFIX" \
                    --with-libxml-include-prefix="$LIBXML2_MACOS_PREFIX/include" \
                    --with-libxml-libs-prefix="$LIBXML2_MACOS_PREFIX/lib"
    )
    run_with_log "$BUILD_DIR/libxslt_make_macos.log" make -C "$LIBXSLT_MACOS_BUILD_DIR/libxslt" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libexslt_make_macos.log" make -C "$LIBXSLT_MACOS_BUILD_DIR/libexslt" -j "$HOST_CPU_COUNT"
    run_with_log "$BUILD_DIR/libxslt_install_macos.log" make -C "$LIBXSLT_MACOS_BUILD_DIR/libxslt" install
    run_with_log "$BUILD_DIR/libexslt_install_macos.log" make -C "$LIBXSLT_MACOS_BUILD_DIR/libexslt" install
}

lxml_module_sources() {
    cat <<'EOF'
lxml.etree PyInit_etree src/lxml/etree.c src_lxml_etree.o
lxml.objectify PyInit_objectify src/lxml/objectify.c src_lxml_objectify.o
lxml.builder PyInit_builder src/lxml/builder.c src_lxml_builder.o
lxml._elementpath PyInit__elementpath src/lxml/_elementpath.c src_lxml__elementpath.o
lxml.sax PyInit_sax src/lxml/sax.c src_lxml_sax.o
lxml.html.diff PyInit_diff src/lxml/html/diff.c src_lxml_html_diff.o
lxml.html._difflib PyInit__difflib src/lxml/html/_difflib.c src_lxml_html__difflib.o
EOF
}

lxml_module_entries() {
    lxml_module_sources | while IFS=' ' read -r module initfunc source object; do
        echo "$module $initfunc"
    done
}

build_lxml_ios() {
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    rm -rf "$LXML_IOS_BUILD_DIR"
    mkdir -p "$LXML_IOS_BUILD_DIR"
    lxml_module_sources | while IFS=' ' read -r module initfunc source object; do
        xcrun --sdk iphoneos clang -O2 -DNDEBUG -fPIC \
            -arch arm64 \
            -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
            -isysroot "$ios_sdk_path" \
            -I "$IOS_FRAMEWORK/Headers" \
            -I "$LXML_SOURCE_DIR/src" \
            -I "$LXML_SOURCE_DIR/src/lxml/includes" \
            -I "$LIBXML2_IOS_PREFIX/include" \
            -I "$LIBXML2_IOS_PREFIX/include/libxml2" \
            -Wno-unreachable-code-fallthrough \
            -Wno-deprecated-declarations \
            -Wno-unused-function \
            -Wno-incompatible-pointer-types-discards-qualifiers \
            -Wno-switch \
            -c "$LXML_SOURCE_DIR/$source" \
            -o "$LXML_IOS_BUILD_DIR/$object"
    done
}

build_lxml_ios_simulator() {
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    rm -rf "$LXML_IOS_SIMULATOR_BUILD_DIR"
    mkdir -p "$LXML_IOS_SIMULATOR_BUILD_DIR"
    lxml_module_sources | while IFS=' ' read -r module initfunc source object; do
        xcrun --sdk iphonesimulator clang -O2 -DNDEBUG -fPIC \
            -arch arm64 \
            -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
            -isysroot "$ios_simulator_sdk_path" \
            -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
            -I "$LXML_SOURCE_DIR/src" \
            -I "$LXML_SOURCE_DIR/src/lxml/includes" \
            -I "$LIBXML2_IOS_SIMULATOR_PREFIX/include" \
            -I "$LIBXML2_IOS_SIMULATOR_PREFIX/include/libxml2" \
            -Wno-unreachable-code-fallthrough \
            -Wno-deprecated-declarations \
            -Wno-unused-function \
            -Wno-incompatible-pointer-types-discards-qualifiers \
            -Wno-switch \
            -c "$LXML_SOURCE_DIR/$source" \
            -o "$LXML_IOS_SIMULATOR_BUILD_DIR/$object"
    done
}

build_lxml_macos() {
    macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    rm -rf "$LXML_MACOS_BUILD_DIR"
    mkdir -p "$LXML_MACOS_BUILD_DIR"
    lxml_module_sources | while IFS=' ' read -r module initfunc source object; do
        cc -O2 -DNDEBUG -fPIC \
            -arch arm64 \
            -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
            -isysroot "$macos_sdk_path" \
            -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
            -I "$LXML_SOURCE_DIR/src" \
            -I "$LXML_SOURCE_DIR/src/lxml/includes" \
            -I "$LIBXML2_MACOS_PREFIX/include" \
            -I "$LIBXML2_MACOS_PREFIX/include/libxml2" \
            -Wno-unreachable-code-fallthrough \
            -Wno-deprecated-declarations \
            -Wno-unused-function \
            -Wno-incompatible-pointer-types-discards-qualifiers \
            -Wno-switch \
            -c "$LXML_SOURCE_DIR/$source" \
            -o "$LXML_MACOS_BUILD_DIR/$object"
    done
}

write_lxml_inittab_source() {
    output=$1
    {
        echo '#include <Python.h>'
        echo
        lxml_module_entries | while IFS=' ' read -r module initfunc; do
            echo "extern PyObject *$initfunc(void);"
        done
        echo
        echo 'int ios_python_register_lxml(void) {'
        echo '    static int registered = 0;'
        echo '    if (registered) {'
        echo '        return 0;'
        echo '    }'
        echo '    int status = 0;'
        lxml_module_entries | while IFS=' ' read -r module initfunc; do
            echo "    status |= PyImport_AppendInittab(\"$module\", $initfunc);"
        done
        echo '    if (status == 0) {'
        echo '        registered = 1;'
        echo '    }'
        echo '    return status;'
        echo '}'
    } > "$output"
}

compile_lxml_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_lxml_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_lxml_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

lxml_runtime_objects() {
    build_root=$1
    find "$build_root" -name '*.o' -print
}

lxml_runtime_archives() {
    prefix=$1
    echo "$prefix/lib/libxml2.a"
    echo "$prefix/lib/libxslt.a"
    echo "$prefix/lib/libexslt.a"
}

install_lxml_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/lxml" "$site_packages"/lxml-*.dist-info
    cp -R "$LXML_SOURCE_DIR/src/lxml" "$site_packages/"

    dist_info="$site_packages/lxml-$LXML_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$LXML_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$LXML_SOURCE_DIR/LICENSE.txt" "$dist_info/"
    cp "$LXML_SOURCE_DIR/LICENSES.txt" "$dist_info/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/lxml" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/lxml" -name tests -type d -prune -exec rm -rf {} +
    find "$site_packages/lxml" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' -o \
        -name '*.c' \
    \) -delete
}

prepare_contourpy_source() {
    archive=$(download_cached_source "$CONTOURPY_SOURCE_CACHE_DIR" "$CONTOURPY_SOURCE_FILENAME" "$CONTOURPY_SOURCE_URL" "$CONTOURPY_SOURCE_SHA256")
    rm -rf "$CONTOURPY_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/contourpy-source"
    tar -xzf "$archive" -C "$BUILD_DIR/contourpy-source"
    mv "$BUILD_DIR/contourpy-source/contourpy-$CONTOURPY_VERSION" "$CONTOURPY_SOURCE_DIR"
    rmdir "$BUILD_DIR/contourpy-source"
}

prepare_kiwisolver_source() {
    archive=$(download_cached_source "$KIWISOLVER_SOURCE_CACHE_DIR" "$KIWISOLVER_SOURCE_FILENAME" "$KIWISOLVER_SOURCE_URL" "$KIWISOLVER_SOURCE_SHA256")
    rm -rf "$KIWISOLVER_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/kiwisolver-source"
    tar -xzf "$archive" -C "$BUILD_DIR/kiwisolver-source"
    mv "$BUILD_DIR/kiwisolver-source/kiwisolver-$KIWISOLVER_VERSION" "$KIWISOLVER_SOURCE_DIR"
    rmdir "$BUILD_DIR/kiwisolver-source"
}

patch_matplotlib_embedded_runtime() {
    enum_header="$MATPLOTLIB_SOURCE_DIR/src/_enums.h"
    font_manager="$MATPLOTLIB_SOURCE_DIR/lib/matplotlib/font_manager.py"

    cat > "$enum_header" <<'EOF'
#ifndef MPL_ENUMS_H
#define MPL_ENUMS_H

#include <pybind11/pybind11.h>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// Extension for pybind11: Pythonic enums.
// This allows creating classes based on ``enum.*`` types.
// This code was copied from mplcairo, with some slight tweaks.
// The API is:
//
// - P11X_DECLARE_ENUM(py_name: str, py_base_cls: str, ...: {str, enum value}):
//   py_name: The name to expose in the module.
//   py_base_cls: The name of the enum base class to use.
//   ...: The enum name/value pairs to expose.
//
//   Use this macro to declare an enum and its values.
//
// - py11x::bind_enums(m: pybind11::module):
//   m: The module to use to register the enum classes.
//
//   Place this in PYBIND11_MODULE to register the enums declared by P11X_DECLARE_ENUM.

// a1 includes the opening brace and a2 the closing brace.
// This definition is compatible with older compiler versions compared to
// #define P11X_ENUM_TYPE(...) decltype(std::map{std::pair __VA_ARGS__})::mapped_type
#define P11X_ENUM_TYPE(a1, a2, ...) decltype(std::pair a1, a2)::second_type

#define P11X_CAT2(a, b) a##b
#define P11X_CAT(a, b) P11X_CAT2(a, b)

namespace p11x {
  namespace {
    namespace py = pybind11;

    using enum_spec = std::pair<std::string, std::vector<std::pair<std::string, long long>>>;

    // Keep pre-init state as plain C++ data. This file is statically linked into
    // iOS/macOS apps, so process-load constructors must not touch Python.
    auto& enum_specs = *new std::unordered_map<std::string, enum_spec>{};
    auto& enums = *new std::unordered_map<std::string, py::object>{};

    auto bind_enums(py::module mod) -> void
    {
      for (auto& [py_name, spec]: enum_specs) {
        auto const& [py_base_cls, pairs] = spec;
        auto cls =
          py::module::import("enum").attr(py_base_cls.c_str())(
            py_name, pairs, py::arg("module") = mod.attr("__name__"));
        enums[py_name] = cls;
        mod.attr(py::cast(py_name)) = cls;
      }
    }
  }
}

// Immediately converting the args to a vector outside of the lambda avoids
// name collisions.
#define P11X_DECLARE_ENUM(py_name, py_base_cls, ...) \
  namespace p11x { \
    namespace { \
      [[maybe_unused]] auto const P11X_CAT(enum_placeholder_, __COUNTER__) = \
        [](auto args) { \
          using int_t = std::underlying_type_t<decltype(args[0].second)>; \
          auto pairs = std::vector<std::pair<std::string, long long>>{}; \
          for (auto& [k, v]: args) { \
            pairs.emplace_back(k, static_cast<long long>(int_t(v))); \
          } \
          p11x::enum_specs[py_name] = {py_base_cls, std::move(pairs)}; \
          return 0; \
        } (std::vector{std::pair __VA_ARGS__}); \
    } \
  } \
  namespace pybind11::detail { \
    template<> struct type_caster<P11X_ENUM_TYPE(__VA_ARGS__)> { \
      using type = P11X_ENUM_TYPE(__VA_ARGS__); \
      static_assert(std::is_enum_v<type>, "Not an enum"); \
      PYBIND11_TYPE_CASTER(type, _(py_name)); \
      bool load(handle src, bool) { \
        auto cls = p11x::enums.at(py_name); \
        PyObject* tmp = nullptr; \
        if (pybind11::isinstance(src, cls) \
            && (tmp = PyNumber_Index(src.attr("value").ptr()))) { \
          auto ival = PyLong_AsLong(tmp); \
          value = decltype(value)(ival); \
          Py_DECREF(tmp); \
          return !(ival == -1 && PyErr_Occurred()); \
        } else { \
          return false; \
        } \
      } \
      static handle cast(decltype(value) obj, return_value_policy, handle) { \
        auto cls = p11x::enums.at(py_name); \
        return cls(std::underlying_type_t<type>(obj)).inc_ref(); \
      } \
    }; \
  }

#endif /* MPL_ENUMS_H */
EOF

    python3 - "$font_manager" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

new = """@cache
def _get_fontconfig_fonts():
    \"\"\"Embedded build: system fontconfig is unavailable.\"\"\"
    return []


@cache
def _get_macos_fonts():
    \"\"\"Embedded build: system_profiler is unavailable.\"\"\"
    return []
"""
start_marker = "def _get_fontconfig_fonts():"
end_marker = "\ndef findSystemFonts("
start = text.find(start_marker)
end = text.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit("matplotlib font discovery patch no longer matches")
decorator_start = text.rfind("\n@", 0, start)
if decorator_start != -1 and text[decorator_start + 1:start].strip() in {"@cache", "@lru_cache"}:
    start = decorator_start + 1
text = text[:start] + new + text[end:]

old = """                for path in [*findSystemFonts(paths, fontext=fontext),
                             *findSystemFonts(fontext=fontext)]:
"""
new = """                for path in findSystemFonts(paths, fontext=fontext):
"""
if old not in text:
    raise SystemExit("matplotlib FontManager search patch no longer matches")
text = text.replace(old, new)

path.write_text(text)
PY
}

prepare_matplotlib_source() {
    archive=$(download_cached_source "$MATPLOTLIB_SOURCE_CACHE_DIR" "$MATPLOTLIB_SOURCE_FILENAME" "$MATPLOTLIB_SOURCE_URL" "$MATPLOTLIB_SOURCE_SHA256")
    freetype_archive=$(download_cached_source "$MATPLOTLIB_SOURCE_CACHE_DIR" "$MATPLOTLIB_FREETYPE_SOURCE_FILENAME" "$MATPLOTLIB_FREETYPE_SOURCE_URL" "$MATPLOTLIB_FREETYPE_SOURCE_SHA256")
    harfbuzz_archive=$(download_cached_source "$MATPLOTLIB_SOURCE_CACHE_DIR" "$MATPLOTLIB_HARFBUZZ_SOURCE_FILENAME" "$MATPLOTLIB_HARFBUZZ_SOURCE_URL" "$MATPLOTLIB_HARFBUZZ_SOURCE_SHA256")
    sheenbidi_archive=$(download_cached_source "$MATPLOTLIB_SOURCE_CACHE_DIR" "$MATPLOTLIB_SHEENBIDI_SOURCE_FILENAME" "$MATPLOTLIB_SHEENBIDI_SOURCE_URL" "$MATPLOTLIB_SHEENBIDI_SOURCE_SHA256")
    libraqm_archive=$(download_cached_source "$MATPLOTLIB_SOURCE_CACHE_DIR" "$MATPLOTLIB_LIBRAQM_SOURCE_FILENAME" "$MATPLOTLIB_LIBRAQM_SOURCE_URL" "$MATPLOTLIB_LIBRAQM_SOURCE_SHA256")
    qhull_archive=$(download_cached_source "$MATPLOTLIB_SOURCE_CACHE_DIR" "$MATPLOTLIB_QHULL_SOURCE_FILENAME" "$MATPLOTLIB_QHULL_SOURCE_URL" "$MATPLOTLIB_QHULL_SOURCE_SHA256")
    rm -rf "$MATPLOTLIB_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/matplotlib-source"
    tar -xzf "$archive" -C "$BUILD_DIR/matplotlib-source"
    mv "$BUILD_DIR/matplotlib-source/matplotlib-$MATPLOTLIB_VERSION" "$MATPLOTLIB_SOURCE_DIR"
    rmdir "$BUILD_DIR/matplotlib-source"
    patch_matplotlib_embedded_runtime
    mkdir -p "$MATPLOTLIB_SOURCE_DIR/subprojects/packagecache"
    cp "$freetype_archive" "$MATPLOTLIB_SOURCE_DIR/subprojects/packagecache/$MATPLOTLIB_FREETYPE_SOURCE_FILENAME"
    cp "$harfbuzz_archive" "$MATPLOTLIB_SOURCE_DIR/subprojects/packagecache/$MATPLOTLIB_HARFBUZZ_SOURCE_FILENAME"
    cp "$sheenbidi_archive" "$MATPLOTLIB_SOURCE_DIR/subprojects/packagecache/$MATPLOTLIB_SHEENBIDI_SOURCE_FILENAME"
    cp "$libraqm_archive" "$MATPLOTLIB_SOURCE_DIR/subprojects/packagecache/$MATPLOTLIB_LIBRAQM_SOURCE_FILENAME"
    cp "$qhull_archive" "$MATPLOTLIB_SOURCE_DIR/subprojects/packagecache/$MATPLOTLIB_QHULL_SOURCE_FILENAME"
}

write_matplotlib_ios_cross_file() {
    output=$1
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    cat > "$output" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
pkg-config = 'pkg-config'
python = '$NUMPY_BUILD_TOOLS_PYTHON'

[built-in options]
c_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path', '-I$IOS_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_HOST']
cpp_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path', '-I$IOS_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_HOST']
c_link_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path']
cpp_link_args = ['-arch', 'arm64', '-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_sdk_path']

[properties]
needs_exe_wrapper = true
skip_sanity_check = true
devnull = '/dev/null'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

write_matplotlib_ios_simulator_cross_file() {
    output=$1
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    cat > "$output" <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphonesimulator', 'clang']
cpp = ['xcrun', '--sdk', 'iphonesimulator', 'clang++']
ar = ['xcrun', '--sdk', 'iphonesimulator', 'ar']
strip = ['xcrun', '--sdk', 'iphonesimulator', 'strip']
pkg-config = 'pkg-config'
python = '$NUMPY_BUILD_TOOLS_PYTHON'

[built-in options]
c_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path', '-I$IOS_SIMULATOR_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST']
cpp_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path', '-I$IOS_SIMULATOR_FRAMEWORK/Headers', '-I$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST']
c_link_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path']
cpp_link_args = ['-arch', 'arm64', '-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION', '-isysroot', '$ios_simulator_sdk_path']

[properties]
needs_exe_wrapper = true
skip_sanity_check = true
devnull = '/dev/null'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
}

build_contourpy_ios() {
    cross_file="$BUILD_DIR/contourpy-ios-cross.ini"
    ios_sysconfig_dir="$IOS_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    write_matplotlib_ios_cross_file "$cross_file"
    rm -rf "$CONTOURPY_IOS_BUILD_DIR" "$CONTOURPY_IOS_INSTALL_PREFIX" "$CONTOURPY_IOS_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/contourpy_configure_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$CONTOURPY_IOS_BUILD_DIR" \
            "$CONTOURPY_SOURCE_DIR" \
            --cross-file="$cross_file" \
            --prefix="$CONTOURPY_IOS_INSTALL_PREFIX" \
            -Db_lto=false \
            --buildtype=release
    run_package_meson "$BUILD_DIR/contourpy_make_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$CONTOURPY_IOS_BUILD_DIR"
    run_package_meson "$BUILD_DIR/contourpy_install_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$CONTOURPY_IOS_BUILD_DIR" --destdir "$CONTOURPY_IOS_INSTALL_DESTDIR"
}

build_contourpy_ios_simulator() {
    cross_file="$BUILD_DIR/contourpy-ios-simulator-cross.ini"
    ios_simulator_sysconfig_dir="$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    write_matplotlib_ios_simulator_cross_file "$cross_file"
    rm -rf "$CONTOURPY_IOS_SIMULATOR_BUILD_DIR" "$CONTOURPY_IOS_SIMULATOR_INSTALL_PREFIX" "$CONTOURPY_IOS_SIMULATOR_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/contourpy_configure_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$CONTOURPY_IOS_SIMULATOR_BUILD_DIR" \
            "$CONTOURPY_SOURCE_DIR" \
            --cross-file="$cross_file" \
            --prefix="$CONTOURPY_IOS_SIMULATOR_INSTALL_PREFIX" \
            -Db_lto=false \
            --buildtype=release
    run_package_meson "$BUILD_DIR/contourpy_make_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$CONTOURPY_IOS_SIMULATOR_BUILD_DIR"
    run_package_meson "$BUILD_DIR/contourpy_install_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$CONTOURPY_IOS_SIMULATOR_BUILD_DIR" --destdir "$CONTOURPY_IOS_SIMULATOR_INSTALL_DESTDIR"
}

build_contourpy_macos() {
    rm -rf "$CONTOURPY_MACOS_BUILD_DIR" "$CONTOURPY_MACOS_INSTALL_PREFIX" "$CONTOURPY_MACOS_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/contourpy_configure_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$CONTOURPY_MACOS_BUILD_DIR" \
            "$CONTOURPY_SOURCE_DIR" \
            --prefix="$CONTOURPY_MACOS_INSTALL_PREFIX" \
            -Db_lto=false \
            --buildtype=release
    run_package_meson "$BUILD_DIR/contourpy_make_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$CONTOURPY_MACOS_BUILD_DIR"
    run_package_meson "$BUILD_DIR/contourpy_install_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$CONTOURPY_MACOS_BUILD_DIR" --destdir "$CONTOURPY_MACOS_INSTALL_DESTDIR"
}

build_kiwisolver_ios() {
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    cppy_include="$NUMPY_BUILD_TOOLS_VENV/lib/python$PYTHON_VERSION_TAG/site-packages/cppy/include"
    rm -rf "$KIWISOLVER_IOS_BUILD_DIR"
    mkdir -p "$KIWISOLVER_IOS_BUILD_DIR"
    (
        for source in "$KIWISOLVER_SOURCE_DIR"/py/src/*.cpp; do
            object="$KIWISOLVER_IOS_BUILD_DIR/$(basename "$source" .cpp).o"
            xcrun --sdk iphoneos clang++ -O3 -DNDEBUG -std=c++11 \
                -fvisibility=hidden -fvisibility-inlines-hidden \
                -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
                -isysroot "$ios_sdk_path" \
                -I "$IOS_FRAMEWORK/Headers" \
                -I "$KIWISOLVER_SOURCE_DIR" \
                -I "$cppy_include" \
                -c "$source" -o "$object"
        done
    ) > "$BUILD_DIR/kiwisolver_make_ios.log" 2>&1 || {
        tail -120 "$BUILD_DIR/kiwisolver_make_ios.log"
        exit 1
    }
}

build_kiwisolver_ios_simulator() {
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    cppy_include="$NUMPY_BUILD_TOOLS_VENV/lib/python$PYTHON_VERSION_TAG/site-packages/cppy/include"
    rm -rf "$KIWISOLVER_IOS_SIMULATOR_BUILD_DIR"
    mkdir -p "$KIWISOLVER_IOS_SIMULATOR_BUILD_DIR"
    (
        for source in "$KIWISOLVER_SOURCE_DIR"/py/src/*.cpp; do
            object="$KIWISOLVER_IOS_SIMULATOR_BUILD_DIR/$(basename "$source" .cpp).o"
            xcrun --sdk iphonesimulator clang++ -O3 -DNDEBUG -std=c++11 \
                -fvisibility=hidden -fvisibility-inlines-hidden \
                -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
                -isysroot "$ios_simulator_sdk_path" \
                -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
                -I "$KIWISOLVER_SOURCE_DIR" \
                -I "$cppy_include" \
                -c "$source" -o "$object"
        done
    ) > "$BUILD_DIR/kiwisolver_make_ios_simulator.log" 2>&1 || {
        tail -120 "$BUILD_DIR/kiwisolver_make_ios_simulator.log"
        exit 1
    }
}

build_kiwisolver_macos() {
    macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    cppy_include="$NUMPY_BUILD_TOOLS_VENV/lib/python$PYTHON_VERSION_TAG/site-packages/cppy/include"
    rm -rf "$KIWISOLVER_MACOS_BUILD_DIR"
    mkdir -p "$KIWISOLVER_MACOS_BUILD_DIR"
    (
        for source in "$KIWISOLVER_SOURCE_DIR"/py/src/*.cpp; do
            object="$KIWISOLVER_MACOS_BUILD_DIR/$(basename "$source" .cpp).o"
            c++ -O3 -DNDEBUG -std=c++11 \
                -fvisibility=hidden -fvisibility-inlines-hidden \
                -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
                -isysroot "$macos_sdk_path" \
                -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
                -I "$KIWISOLVER_SOURCE_DIR" \
                -I "$cppy_include" \
                -c "$source" -o "$object"
        done
    ) > "$BUILD_DIR/kiwisolver_make_macos.log" 2>&1 || {
        tail -120 "$BUILD_DIR/kiwisolver_make_macos.log"
        exit 1
    }
}

matplotlib_numpy_host_site_packages() {
    echo "$NUMPY_MACOS_INSTALL_DESTDIR$NUMPY_MACOS_INSTALL_PREFIX/lib/python$PYTHON_VERSION_TAG/site-packages"
}

build_matplotlib_ios() {
    cross_file="$BUILD_DIR/matplotlib-ios-cross.ini"
    ios_sysconfig_dir="$IOS_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    numpy_site_packages=$(matplotlib_numpy_host_site_packages)
    write_matplotlib_ios_cross_file "$cross_file"
    rm -rf "$MATPLOTLIB_IOS_BUILD_DIR" "$MATPLOTLIB_IOS_INSTALL_PREFIX" "$MATPLOTLIB_IOS_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/matplotlib_configure_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$MATPLOTLIB_IOS_BUILD_DIR" \
            "$MATPLOTLIB_SOURCE_DIR" \
            --cross-file="$cross_file" \
            --prefix="$MATPLOTLIB_IOS_INSTALL_PREFIX" \
            --wrap-mode=forcefallback \
            -Dsystem-freetype=false \
            -Dsystem-qhull=false \
            -Dmacosx=false \
            -Db_lto=false \
            --buildtype=release
    run_package_meson "$BUILD_DIR/matplotlib_make_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$MATPLOTLIB_IOS_BUILD_DIR"
    run_package_meson "$BUILD_DIR/matplotlib_install_ios.log" \
        PYTHONPATH="$ios_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphoneos \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$MATPLOTLIB_IOS_BUILD_DIR" --destdir "$MATPLOTLIB_IOS_INSTALL_DESTDIR"
}

build_matplotlib_ios_simulator() {
    cross_file="$BUILD_DIR/matplotlib-ios-simulator-cross.ini"
    ios_simulator_sysconfig_dir="$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG"
    numpy_site_packages=$(matplotlib_numpy_host_site_packages)
    write_matplotlib_ios_simulator_cross_file "$cross_file"
    rm -rf "$MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR" "$MATPLOTLIB_IOS_SIMULATOR_INSTALL_PREFIX" "$MATPLOTLIB_IOS_SIMULATOR_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/matplotlib_configure_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR" \
            "$MATPLOTLIB_SOURCE_DIR" \
            --cross-file="$cross_file" \
            --prefix="$MATPLOTLIB_IOS_SIMULATOR_INSTALL_PREFIX" \
            --wrap-mode=forcefallback \
            -Dsystem-freetype=false \
            -Dsystem-qhull=false \
            -Dmacosx=false \
            -Db_lto=false \
            --buildtype=release
    run_package_meson "$BUILD_DIR/matplotlib_make_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR"
    run_package_meson "$BUILD_DIR/matplotlib_install_ios_simulator.log" \
        PYTHONPATH="$ios_simulator_sysconfig_dir:$numpy_site_packages" \
        _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__ios_arm64-iphonesimulator \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR" --destdir "$MATPLOTLIB_IOS_SIMULATOR_INSTALL_DESTDIR"
}

build_matplotlib_macos() {
    numpy_site_packages=$(matplotlib_numpy_host_site_packages)
    rm -rf "$MATPLOTLIB_MACOS_BUILD_DIR" "$MATPLOTLIB_MACOS_INSTALL_PREFIX" "$MATPLOTLIB_MACOS_INSTALL_DESTDIR"
    run_package_meson "$BUILD_DIR/matplotlib_configure_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$numpy_site_packages" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" setup "$MATPLOTLIB_MACOS_BUILD_DIR" \
            "$MATPLOTLIB_SOURCE_DIR" \
            --prefix="$MATPLOTLIB_MACOS_INSTALL_PREFIX" \
            --wrap-mode=forcefallback \
            -Dsystem-freetype=false \
            -Dsystem-qhull=false \
            -Dmacosx=false \
            -Db_lto=false \
            --buildtype=release
    run_package_meson "$BUILD_DIR/matplotlib_make_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$numpy_site_packages" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" compile -C "$MATPLOTLIB_MACOS_BUILD_DIR"
    run_package_meson "$BUILD_DIR/matplotlib_install_macos.log" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION" \
        PYTHONPATH="$numpy_site_packages" \
        "$NUMPY_BUILD_TOOLS_VENV/bin/meson" install -C "$MATPLOTLIB_MACOS_BUILD_DIR" --destdir "$MATPLOTLIB_MACOS_INSTALL_DESTDIR"
}

matplotlib_module_entries() {
    cat <<'EOF'
contourpy._contourpy PyInit__contourpy
kiwisolver._cext PyInit__cext
matplotlib._c_internal_utils PyInit__c_internal_utils
matplotlib._image PyInit__image
matplotlib._path PyInit__path
matplotlib._qhull PyInit__qhull
matplotlib._tri PyInit__tri
matplotlib.backends._backend_agg PyInit__backend_agg
matplotlib.ft2font PyInit_ft2font
EOF
}

write_matplotlib_inittab_source() {
    output=$1
    {
        echo '#include <Python.h>'
        echo
        matplotlib_module_entries | while IFS=' ' read -r module initfunc; do
            echo "extern PyObject *$initfunc(void);"
        done
        echo
        echo 'int ios_python_register_matplotlib(void) {'
        echo '    static int registered = 0;'
        echo '    if (registered) {'
        echo '        return 0;'
        echo '    }'
        echo '    int status = 0;'
        matplotlib_module_entries | while IFS=' ' read -r module initfunc; do
            echo "    status |= PyImport_AppendInittab(\"$module\", $initfunc);"
        done
        echo '    if (status == 0) {'
        echo '        registered = 1;'
        echo '    }'
        echo '    return status;'
        echo '}'
    } > "$output"
}

compile_matplotlib_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_matplotlib_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_matplotlib_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

contourpy_runtime_objects() {
    build_root=$1
    find "$build_root/src" -path '*.so.p/*.o' -print
}

kiwisolver_runtime_objects() {
    build_root=$1
    find "$build_root" -name '*.o' -print
}

matplotlib_runtime_objects() {
    build_root=$1
    find "$build_root/src" -path '*_tkagg*.so.p' -prune -o \
        -path '*.so.p/*.o' \
        -print
}

matplotlib_runtime_archives() {
    build_root=$1
    for archive in \
        "$build_root/extern/agg24-svn/libagg.a" \
        "$build_root/subprojects/freetype-$MATPLOTLIB_FREETYPE_VERSION/libfreetype.a" \
        "$build_root/subprojects/qhull-$MATPLOTLIB_QHULL_VERSION/libqhull_r.a"
    do
        if [ -f "$archive" ]; then
            echo "$archive"
        fi
    done
    for archive_name in libharfbuzz.a libSheenBidi.a libraqm.a; do
        archive=$(find "$build_root/subprojects" -type f -name "$archive_name" -print -quit)
        if [ -z "$archive" ]; then
            echo "Missing Matplotlib runtime archive: $archive_name" >&2
            exit 1
        fi
        echo "$archive"
    done
}

install_contourpy_resources() {
    resource_root=$1
    install_destdir=$2
    install_prefix=$3
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    installed_site_packages="$install_destdir$install_prefix/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/contourpy" "$site_packages"/contourpy-*.dist-info
    cp -R "$installed_site_packages/contourpy" "$site_packages/"

    dist_info="$site_packages/contourpy-$CONTOURPY_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$CONTOURPY_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/contourpy" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/contourpy" -name tests -type d -prune -exec rm -rf {} +
    find "$site_packages/contourpy" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
}

install_kiwisolver_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/kiwisolver" "$site_packages"/kiwisolver-*.dist-info
    cp -R "$KIWISOLVER_SOURCE_DIR/py/kiwisolver" "$site_packages/"

    dist_info="$site_packages/kiwisolver-$KIWISOLVER_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$KIWISOLVER_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/kiwisolver" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/kiwisolver" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
}

install_matplotlib_resources() {
    resource_root=$1
    install_destdir=$2
    install_prefix=$3
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    installed_site_packages="$install_destdir$install_prefix/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/matplotlib" \
        "$site_packages/mpl_toolkits" \
        "$site_packages/pylab.py" \
        "$site_packages"/matplotlib-*.dist-info
    cp -R "$installed_site_packages/matplotlib" "$site_packages/"
    cp -R "$installed_site_packages/mpl_toolkits" "$site_packages/"
    cp "$installed_site_packages/pylab.py" "$site_packages/"

    dist_info="$site_packages/matplotlib-$MATPLOTLIB_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$MATPLOTLIB_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/matplotlib" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/mpl_toolkits" -name __pycache__ -type d -prune -exec rm -rf {} +
    rm -rf "$site_packages/matplotlib/tests" \
        "$site_packages/matplotlib/testing" \
        "$site_packages/matplotlib/sphinxext" \
        "$site_packages/matplotlib/backends/qt_editor" \
        "$site_packages/matplotlib/backends/web_backend" \
        "$site_packages/matplotlib/mpl-data/sample_data" \
        "$site_packages/matplotlib/mpl-data/plot_directive"
    find "$site_packages/mpl_toolkits" -name tests -type d -prune -exec rm -rf {} +
    find "$site_packages/matplotlib" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
    find "$site_packages/mpl_toolkits" \( -name '*.so' -o -name '*.dylib' -o -name '*.a' -o -name '*.dll' -o -name '*.exe' -o -name '*.pyc' \) -delete
    find "$site_packages/matplotlib" -name meson.build -delete
    find "$site_packages/mpl_toolkits" -name meson.build -delete
}

prepare_psd_tools_source() {
    archive=$(download_cached_source "$PSDTOOLS_SOURCE_CACHE_DIR" "$PSDTOOLS_SOURCE_FILENAME" "$PSDTOOLS_SOURCE_URL" "$PSDTOOLS_SOURCE_SHA256")
    rm -rf "$PSDTOOLS_SOURCE_DIR"
    mkdir -p "$BUILD_DIR/psd-tools-source"
    tar -xzf "$archive" -C "$BUILD_DIR/psd-tools-source"
    mv "$BUILD_DIR/psd-tools-source/psd-tools-$PSDTOOLS_VERSION" "$PSDTOOLS_SOURCE_DIR"
    rmdir "$BUILD_DIR/psd-tools-source"
    (
        cd "$PSDTOOLS_SOURCE_DIR"
        run_with_log "$BUILD_DIR/psd_tools_egg_info.log" \
            env \
                DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
                PATH="$NUMPY_BUILD_TOOLS_VENV/bin:$PATH" \
                "$NUMPY_BUILD_TOOLS_PYTHON" setup.py egg_info
    )
}

generate_psd_tools_rle_cpp() {
    output=$1
    DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" "$NUMPY_BUILD_TOOLS_VENV/bin/cython" \
        --cplus \
        --module-name psd_tools.compression._rle \
        -3 \
        -o "$output" \
        "$PSDTOOLS_SOURCE_DIR/src/psd_tools/compression/_rle.pyx"
}

build_psd_tools_ios() {
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    rm -rf "$PSDTOOLS_IOS_BUILD_DIR"
    mkdir -p "$PSDTOOLS_IOS_BUILD_DIR"
    source="$PSDTOOLS_IOS_BUILD_DIR/_rle.cpp"
    generate_psd_tools_rle_cpp "$source"
    run_with_log "$BUILD_DIR/psd_tools_make_ios.log" \
        xcrun --sdk iphoneos clang++ -O2 -std=c++11 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
            -isysroot "$ios_sdk_path" \
            -I "$IOS_FRAMEWORK/Headers" \
            -DPy_LIMITED_API=0x030D0000 \
            -Wno-unreachable-code-fallthrough \
            -Wno-unused-function \
            -Wno-nullability-completeness \
            -c "$source" \
            -o "$PSDTOOLS_IOS_BUILD_DIR/_rle.o"
}

build_psd_tools_ios_simulator() {
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    rm -rf "$PSDTOOLS_IOS_SIMULATOR_BUILD_DIR"
    mkdir -p "$PSDTOOLS_IOS_SIMULATOR_BUILD_DIR"
    source="$PSDTOOLS_IOS_SIMULATOR_BUILD_DIR/_rle.cpp"
    generate_psd_tools_rle_cpp "$source"
    run_with_log "$BUILD_DIR/psd_tools_make_ios_simulator.log" \
        xcrun --sdk iphonesimulator clang++ -O2 -std=c++11 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
            -isysroot "$ios_simulator_sdk_path" \
            -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
            -DPy_LIMITED_API=0x030D0000 \
            -Wno-unreachable-code-fallthrough \
            -Wno-unused-function \
            -Wno-nullability-completeness \
            -c "$source" \
            -o "$PSDTOOLS_IOS_SIMULATOR_BUILD_DIR/_rle.o"
}

build_psd_tools_macos() {
    macos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    rm -rf "$PSDTOOLS_MACOS_BUILD_DIR"
    mkdir -p "$PSDTOOLS_MACOS_BUILD_DIR"
    source="$PSDTOOLS_MACOS_BUILD_DIR/_rle.cpp"
    generate_psd_tools_rle_cpp "$source"
    run_with_log "$BUILD_DIR/psd_tools_make_macos.log" \
        c++ -O2 -std=c++11 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
            -isysroot "$macos_sdk_path" \
            -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
            -DPy_LIMITED_API=0x030D0000 \
            -Wno-unreachable-code-fallthrough \
            -Wno-unused-function \
            -c "$source" \
            -o "$PSDTOOLS_MACOS_BUILD_DIR/_rle.o"
}

write_psd_tools_inittab_source() {
    output=$1
    cat > "$output" <<'EOF'
#include <Python.h>

extern PyObject *PyInit__rle(void);

int ios_python_register_psd_tools(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab("psd_tools.compression._rle", PyInit__rle);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
EOF
}

compile_psd_tools_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_psd_tools_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_psd_tools_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

psd_tools_runtime_objects() {
    build_root=$1
    find "$build_root" -name '*.o' -print
}

install_psd_tools_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/psd_tools" "$site_packages"/psd_tools-*.dist-info "$site_packages"/psd_tools.egg-info
    cp -R "$PSDTOOLS_SOURCE_DIR/src/psd_tools" "$site_packages/"

    dist_info="$site_packages/psd_tools-$PSDTOOLS_VERSION.dist-info"
    mkdir -p "$dist_info"
    cp "$PSDTOOLS_SOURCE_DIR/src/psd_tools.egg-info/PKG-INFO" "$dist_info/METADATA"
    cp "$PSDTOOLS_SOURCE_DIR/LICENSE" "$dist_info/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    find "$site_packages/psd_tools" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/psd_tools" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' -o \
        -name '*.cpp' -o \
        -name '*.c' -o \
        -name '*.pyx' \
    \) -delete
}

prepare_regex_source() {
    archive=$(download_cached_source "$REGEX_SOURCE_CACHE_DIR" "$REGEX_SOURCE_FILENAME" "$REGEX_SOURCE_URL" "$REGEX_SOURCE_SHA256")
    rm -rf "$REGEX_SOURCE_DIR" "$BUILD_DIR/regex-source"
    mkdir -p "$BUILD_DIR/regex-source"
    tar -xzf "$archive" -C "$BUILD_DIR/regex-source"
    mv "$BUILD_DIR/regex-source/regex-$REGEX_VERSION" "$REGEX_SOURCE_DIR"
    rmdir "$BUILD_DIR/regex-source"
}

build_regex_slice() {
    sdk=$1
    build_root=$2
    deployment_flag=$3
    python_headers=$4
    log_file=$5
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    rm -rf "$build_root"
    mkdir -p "$build_root"
    run_with_log "$log_file" \
        xcrun --sdk "$sdk" clang -O3 -DNDEBUG -arch arm64 \
            "$deployment_flag" \
            -isysroot "$sdk_path" \
            -I "$python_headers" \
            -I "$REGEX_SOURCE_DIR/src" \
            -c "$REGEX_SOURCE_DIR/src/_regex.c" \
            -o "$build_root/regex_module.o"
    run_with_log "$build_root/regex_unicode.log" \
        xcrun --sdk "$sdk" clang -O3 -DNDEBUG -arch arm64 \
            "$deployment_flag" \
            -isysroot "$sdk_path" \
            -I "$python_headers" \
            -I "$REGEX_SOURCE_DIR/src" \
            -c "$REGEX_SOURCE_DIR/src/_regex_unicode.c" \
            -o "$build_root/regex_unicode.o"
}

install_regex_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    package_root="$site_packages/regex"
    dist_info="$site_packages/regex-$REGEX_VERSION.dist-info"
    rm -rf "$package_root" "$site_packages"/regex-*.dist-info "$site_packages"/regex.egg-info
    cp -R "$REGEX_SOURCE_DIR/regex" "$package_root"
    rm -rf "$package_root/tests"
    mkdir -p "$dist_info/licenses"
    cp "$REGEX_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$REGEX_SOURCE_DIR/LICENSE.txt" "$dist_info/licenses/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
    find "$package_root" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$package_root" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' \
    \) -delete
}

prepare_tokenizers_source() {
    archive=$(download_cached_source "$TOKENIZERS_SOURCE_CACHE_DIR" "$TOKENIZERS_SOURCE_FILENAME" "$TOKENIZERS_SOURCE_URL" "$TOKENIZERS_SOURCE_SHA256")
    rm -rf "$TOKENIZERS_SOURCE_DIR" "$BUILD_DIR/tokenizers-source"
    mkdir -p "$BUILD_DIR/tokenizers-source"
    tar -xzf "$archive" -C "$BUILD_DIR/tokenizers-source"
    mv "$BUILD_DIR/tokenizers-source/tokenizers-$TOKENIZERS_VERSION" "$TOKENIZERS_SOURCE_DIR"
    rmdir "$BUILD_DIR/tokenizers-source"
    verify_sha256 "$TOKENIZERS_SOURCE_DIR/bindings/python/Cargo.lock" "$TOKENIZERS_CARGO_LOCK_SHA256"
}

build_tokenizers_slice() {
    sdk=$1
    target=$2
    build_root=$3
    deployment_flag=$4
    log_file=$5
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    case "$sdk" in
        macosx)
            deployment_target="MACOSX_DEPLOYMENT_TARGET=$MACOS_MINIMUM_OS_VERSION"
            ;;
        *)
            deployment_target="IPHONEOS_DEPLOYMENT_TARGET=$IOS_MINIMUM_OS_VERSION"
            ;;
    esac
    rm -rf "$build_root"
    mkdir -p "$TOKENIZERS_CARGO_HOME"
    run_with_log "$log_file" \
        env \
            PATH="$HF_XET_RUST_TOOLCHAIN_DIR/bin:$PATH" \
            CARGO_HOME="$TOKENIZERS_CARGO_HOME" \
            CARGO_TARGET_DIR="$build_root" \
            CARGO_PROFILE_RELEASE_LTO=false \
            PYO3_CROSS=1 \
            PYO3_CROSS_PYTHON_VERSION="$PYTHON_VERSION_TAG" \
            PYO3_NO_PYTHON=1 \
            SDKROOT="$sdk_path" \
            "$deployment_target" \
            RUSTFLAGS="--remap-path-prefix=$TOKENIZERS_SOURCE_DIR=@TOKENIZERS_SOURCE_ROOT@ --remap-path-prefix=$TOKENIZERS_CARGO_HOME=@TOKENIZERS_CARGO_HOME@ --remap-path-prefix=$HF_XET_RUST_TOOLCHAIN_DIR=@HF_XET_RUST_TOOLCHAIN@ -C link-arg=$deployment_flag -C link-arg=-isysroot -C link-arg=$sdk_path" \
            "$HF_XET_RUST_TOOLCHAIN_DIR/bin/cargo" rustc \
                --manifest-path "$TOKENIZERS_SOURCE_DIR/bindings/python/Cargo.toml" \
                --release \
                --locked \
                --target "$target" \
                --lib \
                --crate-type staticlib \
                --jobs "$HOST_CPU_COUNT"
    test -f "$build_root/$target/release/libtokenizers.a"
}

install_tokenizers_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    package_root="$site_packages/tokenizers"
    dist_info="$site_packages/tokenizers-$TOKENIZERS_VERSION.dist-info"
    rm -rf "$package_root" "$site_packages"/tokenizers-*.dist-info
    cp -R "$TOKENIZERS_SOURCE_DIR/bindings/python/py_src/tokenizers" "$package_root"
    mkdir -p "$dist_info/licenses"
    cp "$TOKENIZERS_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$TOKENIZERS_SOURCE_DIR/tokenizers/LICENSE" "$dist_info/licenses/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
    find "$package_root" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$package_root" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' \
    \) -delete
}

prepare_sentencepiece_source() {
    archive=$(download_cached_source "$SENTENCEPIECE_SOURCE_CACHE_DIR" "$SENTENCEPIECE_SOURCE_FILENAME" "$SENTENCEPIECE_SOURCE_URL" "$SENTENCEPIECE_SOURCE_SHA256")
    rm -rf "$SENTENCEPIECE_SOURCE_DIR" "$BUILD_DIR/sentencepiece-source"
    mkdir -p "$BUILD_DIR/sentencepiece-source"
    tar -xzf "$archive" -C "$BUILD_DIR/sentencepiece-source"
    mv "$BUILD_DIR/sentencepiece-source/sentencepiece-$SENTENCEPIECE_VERSION" "$SENTENCEPIECE_SOURCE_DIR"
    rmdir "$BUILD_DIR/sentencepiece-source"
    grep -qx "#define ABSL_OPTION_INLINE_NAMESPACE_NAME $SENTENCEPIECE_ABSEIL_ABI" \
        "$SENTENCEPIECE_ABSEIL_SOURCE_DIR/absl/base/options.h"
}

build_sentencepiece_slice() {
    sdk=$1
    build_root=$2
    deployment_flag=$3
    python_headers=$4
    log_file=$5
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    pybind11_headers=$(DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" \
        "$NUMPY_BUILD_TOOLS_PYTHON" -c 'import pybind11; print(pybind11.get_include())')
    rm -rf "$build_root"
    mkdir -p "$build_root"
    run_with_log "$log_file" \
        xcrun --sdk "$sdk" clang++ -O3 -DNDEBUG -std=c++17 \
            -fvisibility=hidden \
            -Wno-deprecated-declarations \
            -Wno-unused-function \
            -arch arm64 \
            "$deployment_flag" \
            -isysroot "$sdk_path" \
            "-ffile-prefix-map=$SENTENCEPIECE_SOURCE_DIR=@SENTENCEPIECE_SOURCE_ROOT@" \
            "-ffile-prefix-map=$NUMPY_BUILD_TOOLS_VENV=@PYTHON_BUILD_TOOLS@" \
            -I "$python_headers" \
            -I "$pybind11_headers" \
            -I "$SENTENCEPIECE_ABSEIL_SOURCE_DIR" \
            -I "$SENTENCEPIECE_SOURCE_DIR/sentencepiece/src" \
            -I "$SENTENCEPIECE_SOURCE_DIR/sentencepiece/src/builtin_pb" \
            -I "$SENTENCEPIECE_SOURCE_DIR/sentencepiece/third_party/protobuf-lite" \
            -I "$SENTENCEPIECE_SOURCE_DIR/sentencepiece" \
            -c "$SENTENCEPIECE_SOURCE_DIR/src/sentencepiece/sentencepiece_pybind.cc" \
            -o "$build_root/sentencepiece_pybind.o"
}

install_sentencepiece_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    package_root="$site_packages/sentencepiece"
    dist_info="$site_packages/sentencepiece-$SENTENCEPIECE_VERSION.dist-info"
    rm -rf "$package_root" "$site_packages"/sentencepiece-*.dist-info
    cp -R "$SENTENCEPIECE_SOURCE_DIR/src/sentencepiece" "$package_root"
    mkdir -p "$dist_info/licenses"
    cp "$SENTENCEPIECE_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$SENTENCEPIECE_SOURCE_DIR/sentencepiece/LICENSE" "$dist_info/licenses/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
    find "$package_root" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$package_root" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' -o \
        -name '*.cc' \
    \) -delete
}

prepare_hf_xet_source() {
    archive=$(download_cached_source "$HF_XET_SOURCE_CACHE_DIR" "$HF_XET_SOURCE_FILENAME" "$HF_XET_SOURCE_URL" "$HF_XET_SOURCE_SHA256")
    rm -rf "$HF_XET_SOURCE_DIR" "$BUILD_DIR/hf-xet-source"
    mkdir -p "$BUILD_DIR/hf-xet-source"
    tar -xzf "$archive" -C "$BUILD_DIR/hf-xet-source"
    mv "$BUILD_DIR/hf-xet-source/hf_xet-$HF_XET_VERSION" "$HF_XET_SOURCE_DIR"
    rmdir "$BUILD_DIR/hf-xet-source"
    verify_sha256 "$HF_XET_SOURCE_DIR/hf_xet/Cargo.lock" "$HF_XET_CARGO_LOCK_SHA256"
    patch --batch --forward -d "$HF_XET_SOURCE_DIR" -p1 \
        < "$REPO_ROOT/Vendors/PythonIOS/Patches/hf-xet-no-sysinfo.patch"
    patch --batch --forward -d "$HF_XET_SOURCE_DIR" -p1 \
        < "$REPO_ROOT/Vendors/PythonIOS/Patches/hf-xet-c-api.patch"
}

prepare_hf_xet_rust_toolchain() {
    toolchain_archive=$(download_cached_source \
        "$HF_XET_RUST_CACHE_DIR" \
        "$HF_XET_RUST_TOOLCHAIN_FILENAME" \
        "$HF_XET_RUST_TOOLCHAIN_URL" \
        "$HF_XET_RUST_TOOLCHAIN_SHA256")
    ios_std_archive=$(download_cached_source \
        "$HF_XET_RUST_CACHE_DIR" \
        "$HF_XET_RUST_IOS_STD_FILENAME" \
        "$HF_XET_RUST_IOS_STD_URL" \
        "$HF_XET_RUST_IOS_STD_SHA256")
    ios_simulator_std_archive=$(download_cached_source \
        "$HF_XET_RUST_CACHE_DIR" \
        "$HF_XET_RUST_IOS_SIMULATOR_STD_FILENAME" \
        "$HF_XET_RUST_IOS_SIMULATOR_STD_URL" \
        "$HF_XET_RUST_IOS_SIMULATOR_STD_SHA256")
    source_root="$BUILD_DIR/hf-xet-rust-source"
    rm -rf "$HF_XET_RUST_TOOLCHAIN_DIR" "$source_root"
    mkdir -p "$source_root"
    tar -xJf "$toolchain_archive" -C "$source_root"
    tar -xJf "$ios_std_archive" -C "$source_root"
    tar -xJf "$ios_simulator_std_archive" -C "$source_root"
    "$source_root/rust-$HF_XET_RUST_VERSION-aarch64-apple-darwin/install.sh" \
        --prefix="$HF_XET_RUST_TOOLCHAIN_DIR" \
        --disable-ldconfig
    "$source_root/rust-std-$HF_XET_RUST_VERSION-aarch64-apple-ios/install.sh" \
        --prefix="$HF_XET_RUST_TOOLCHAIN_DIR" \
        --disable-ldconfig
    "$source_root/rust-std-$HF_XET_RUST_VERSION-aarch64-apple-ios-sim/install.sh" \
        --prefix="$HF_XET_RUST_TOOLCHAIN_DIR" \
        --disable-ldconfig
    rm -rf "$source_root"
    if ! "$HF_XET_RUST_TOOLCHAIN_DIR/bin/rustc" --version | grep -q "^rustc $HF_XET_RUST_VERSION "; then
        echo "Unexpected Rust compiler installed for hf-xet." >&2
        "$HF_XET_RUST_TOOLCHAIN_DIR/bin/rustc" --version >&2
        exit 1
    fi
}

build_hf_xet_slice() {
    sdk=$1
    target=$2
    build_root=$3
    deployment_flag=$4
    log_file=$5
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    case "$sdk" in
        macosx)
            deployment_target="MACOSX_DEPLOYMENT_TARGET=$MACOS_MINIMUM_OS_VERSION"
            ;;
        *)
            deployment_target="IPHONEOS_DEPLOYMENT_TARGET=$IOS_MINIMUM_OS_VERSION"
            ;;
    esac
    rm -rf "$build_root"
    mkdir -p "$HF_XET_CARGO_HOME"
    run_with_log "$log_file" \
        env \
            PATH="$HF_XET_RUST_TOOLCHAIN_DIR/bin:$PATH" \
            CARGO_HOME="$HF_XET_CARGO_HOME" \
            CARGO_TARGET_DIR="$build_root" \
            CARGO_PROFILE_RELEASE_LTO=false \
            PYO3_CROSS=1 \
            PYO3_CROSS_PYTHON_VERSION="$PYTHON_VERSION_TAG" \
            SDKROOT="$sdk_path" \
            "$deployment_target" \
            RUSTFLAGS="--remap-path-prefix=$HF_XET_SOURCE_DIR=@HF_XET_SOURCE_ROOT@ --remap-path-prefix=$HF_XET_CARGO_HOME=@HF_XET_CARGO_HOME@ --remap-path-prefix=$HF_XET_RUST_TOOLCHAIN_DIR=@HF_XET_RUST_TOOLCHAIN@ -C link-arg=$deployment_flag -C link-arg=-isysroot -C link-arg=$sdk_path" \
            "$HF_XET_RUST_TOOLCHAIN_DIR/bin/cargo" rustc \
                --manifest-path "$HF_XET_SOURCE_DIR/hf_xet/Cargo.toml" \
                --release \
                --locked \
                --target "$target" \
                --lib \
                --crate-type staticlib \
                --jobs "$HOST_CPU_COUNT" \
                --features c-api
    test -f "$build_root/$target/release/libhf_xet.a"
}

compile_pyo3_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_pyo3_inittab_ios_simulator() {
    source=$1
    output=$2
    ios_simulator_sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -O2 -arch arm64 -mios-simulator-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_simulator_sdk_path" \
        -I "$IOS_SIMULATOR_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_pyo3_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

install_hf_xet_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    package_root="$site_packages/hf_xet"
    dist_info="$site_packages/hf_xet-$HF_XET_VERSION.dist-info"
    rm -rf "$package_root" "$site_packages"/hf_xet-*.dist-info
    mkdir -p "$package_root" "$dist_info/licenses"
    printf '%s\n' \
        'from .hf_xet import *' \
        '' \
        '__doc__ = hf_xet.__doc__' \
        'if hasattr(hf_xet, "__all__"):' \
        '    __all__ = hf_xet.__all__' \
        > "$package_root/__init__.py"
    cp "$HF_XET_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$HF_XET_SOURCE_DIR/hf_xet/LICENSE" "$dist_info/licenses/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
}

prepare_safetensors_source() {
    archive=$(download_cached_source "$SAFETENSORS_SOURCE_CACHE_DIR" "$SAFETENSORS_SOURCE_FILENAME" "$SAFETENSORS_SOURCE_URL" "$SAFETENSORS_SOURCE_SHA256")
    rm -rf "$SAFETENSORS_SOURCE_DIR" "$BUILD_DIR/safetensors-source"
    mkdir -p "$BUILD_DIR/safetensors-source"
    tar -xzf "$archive" -C "$BUILD_DIR/safetensors-source"
    mv "$BUILD_DIR/safetensors-source/safetensors-$SAFETENSORS_VERSION" "$SAFETENSORS_SOURCE_DIR"
    rmdir "$BUILD_DIR/safetensors-source"
    verify_sha256 "$SAFETENSORS_SOURCE_DIR/bindings/python/Cargo.lock" "$SAFETENSORS_CARGO_LOCK_SHA256"
}

build_safetensors_slice() {
    sdk=$1
    target=$2
    build_root=$3
    deployment_flag=$4
    log_file=$5
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    case "$sdk" in
        macosx)
            deployment_target="MACOSX_DEPLOYMENT_TARGET=$MACOS_MINIMUM_OS_VERSION"
            ;;
        *)
            deployment_target="IPHONEOS_DEPLOYMENT_TARGET=$IOS_MINIMUM_OS_VERSION"
            ;;
    esac
    rm -rf "$build_root"
    mkdir -p "$SAFETENSORS_CARGO_HOME"
    run_with_log "$log_file" \
        env \
            PATH="$HF_XET_RUST_TOOLCHAIN_DIR/bin:$PATH" \
            CARGO_HOME="$SAFETENSORS_CARGO_HOME" \
            CARGO_TARGET_DIR="$build_root" \
            CARGO_PROFILE_RELEASE_LTO=false \
            PYO3_CROSS=1 \
            PYO3_CROSS_PYTHON_VERSION="$PYTHON_VERSION_TAG" \
            PYO3_NO_PYTHON=1 \
            SDKROOT="$sdk_path" \
            "$deployment_target" \
            RUSTFLAGS="--remap-path-prefix=$SAFETENSORS_SOURCE_DIR=@SAFETENSORS_SOURCE_ROOT@ --remap-path-prefix=$SAFETENSORS_CARGO_HOME=@SAFETENSORS_CARGO_HOME@ --remap-path-prefix=$HF_XET_RUST_TOOLCHAIN_DIR=@HF_XET_RUST_TOOLCHAIN@ -C link-arg=$deployment_flag -C link-arg=-isysroot -C link-arg=$sdk_path" \
            "$HF_XET_RUST_TOOLCHAIN_DIR/bin/cargo" rustc \
                --manifest-path "$SAFETENSORS_SOURCE_DIR/bindings/python/Cargo.toml" \
                --release \
                --locked \
                --target "$target" \
                --lib \
                --crate-type staticlib \
                --jobs "$HOST_CPU_COUNT"
    test -f "$build_root/$target/release/libsafetensors_rust.a"
}

install_safetensors_resources() {
    resource_root=$1
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    package_root="$site_packages/safetensors"
    dist_info="$site_packages/safetensors-$SAFETENSORS_VERSION.dist-info"
    rm -rf "$package_root" "$site_packages"/safetensors-*.dist-info
    cp -R "$SAFETENSORS_SOURCE_DIR/py_src/safetensors" "$package_root"
    mkdir -p "$dist_info/licenses"
    cp "$SAFETENSORS_SOURCE_DIR/PKG-INFO" "$dist_info/METADATA"
    cp "$SAFETENSORS_SOURCE_DIR/LICENSE" "$dist_info/licenses/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"
    find "$package_root" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$package_root" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' \
    \) -delete
}

prepare_mlx_source() {
    archive=$(download_cached_source "$MLX_SOURCE_CACHE_DIR" "$MLX_SOURCE_FILENAME" "$MLX_SOURCE_URL" "$MLX_SOURCE_SHA256")
    rm -rf "$MLX_SOURCE_DIR" "$BUILD_DIR/mlx-source"
    mkdir -p "$BUILD_DIR/mlx-source"
    tar -xzf "$archive" -C "$BUILD_DIR/mlx-source"
    mv "$BUILD_DIR/mlx-source/mlx-$MLX_VERSION" "$MLX_SOURCE_DIR"
    rmdir "$BUILD_DIR/mlx-source"
    patch --batch --forward -d "$MLX_SOURCE_DIR" -p1 \
        < "$REPO_ROOT/Vendors/PythonIOS/Patches/mlx-python-ios-static.patch"
}

resolve_mlx_metal_compiler() {
    candidate=$(xcrun --find metal 2>/dev/null || true)
    if [ -n "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
        echo "$candidate"
        return
    fi

    toolchain_root=$(xcodebuild -showComponent metalToolchain 2>/dev/null |
        sed -n 's/^[[:space:]]*Toolchain Search Path: //p' |
        sed -n '1p')
    candidate="$toolchain_root/Metal.xctoolchain/usr/bin/metal"
    if [ -n "$toolchain_root" ] && [ -x "$candidate" ] &&
        "$candidate" --version >/dev/null 2>&1; then
        echo "$candidate"
        return
    fi

    echo "MLX requires Xcode's optional Metal Toolchain." >&2
    echo "Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
}

build_mlx_slice() {
    build_root=$1
    system_name=$2
    sdk_name=$3
    minimum_os_version=$4
    metal_platform_flag=$5
    python_include_dir=$6
    python_library=$7
    metallib_relative_path=$8
    log_suffix=$9

    sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path)
    c_compiler=$(xcrun --sdk "$sdk_name" --find clang)
    cxx_compiler=$(xcrun --sdk "$sdk_name" --find clang++)
    host_python="$MACOS_INSTALL_ROOT/bin/python$PYTHON_VERSION_TAG"
    ninja="$NUMPY_BUILD_TOOLS_VENV/bin/ninja"

    test -x "$host_python"
    test -x "$ninja"
    rm -rf "$build_root"
    mkdir -p "$build_root/metal-module-cache"

    set -- \
        cmake \
        -S "$MLX_SOURCE_DIR" \
        -B "$build_root" \
        -G Ninja \
        "-DCMAKE_MAKE_PROGRAM=$ninja" \
        "-DCMAKE_SYSTEM_NAME=$system_name" \
        -DCMAKE_SYSTEM_PROCESSOR=arm64 \
        "-DCMAKE_C_COMPILER=$c_compiler" \
        "-DCMAKE_CXX_COMPILER=$cxx_compiler" \
        "-DCMAKE_OSX_SYSROOT=$sdk_path" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=$minimum_os_version" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DMLX_BUILD_TESTS=OFF \
        -DMLX_BUILD_EXAMPLES=OFF \
        -DMLX_BUILD_BENCHMARKS=OFF \
        -DMLX_BUILD_PYTHON_BINDINGS=ON \
        -DMLX_BUILD_PYTHON_STUBS=OFF \
        -DMLX_BUILD_CPU=ON \
        -DMLX_BUILD_METAL=ON \
        -DMLX_BUILD_CUDA=OFF \
        -DMLX_BUILD_GGUF=ON \
        -DMLX_BUILD_SAFETENSORS=ON \
        -DMLX_METAL_JIT=OFF \
        -DMLX_METALCPP_DYNAMIC_CONSTANTS=ON \
        -DMLX_USE_CCACHE=OFF \
        "-DMLX_VERSION=$MLX_VERSION" \
        "-DMLX_METAL_COMPILER=$MLX_METAL_COMPILER" \
        "-DMLX_METAL_LANGUAGE_STANDARD=$MLX_METAL_LANGUAGE_STANDARD" \
        "-DMLX_METAL_PLATFORM_FLAG=$metal_platform_flag" \
        "-DMLX_METAL_MODULE_CACHE_PATH=$build_root/metal-module-cache" \
        -DMLX_METAL_PATH=. \
        "-DMLX_PYTHON_METALLIB_RELATIVE_PATH=$metallib_relative_path" \
        "-DPython_EXECUTABLE=$host_python" \
        "-DPython_INCLUDE_DIR=$python_include_dir" \
        "-DPython_LIBRARY=$python_library"

    if [ "$build_root" != "$MLX_IOS_BUILD_DIR" ]; then
        dependency_source_root="$MLX_IOS_BUILD_DIR/_deps"
        for dependency in metal_cpp json fmt nanobind gguflib; do
            if [ ! -d "$dependency_source_root/$dependency-src" ]; then
                echo "Missing shared MLX dependency source: $dependency" >&2
                exit 1
            fi
        done
        set -- "$@" \
            "-DFETCHCONTENT_SOURCE_DIR_METAL_CPP=$dependency_source_root/metal_cpp-src" \
            "-DFETCHCONTENT_SOURCE_DIR_JSON=$dependency_source_root/json-src" \
            "-DFETCHCONTENT_SOURCE_DIR_FMT=$dependency_source_root/fmt-src" \
            "-DFETCHCONTENT_SOURCE_DIR_NANOBIND=$dependency_source_root/nanobind-src" \
            "-DFETCHCONTENT_SOURCE_DIR_GGUFLIB=$dependency_source_root/gguflib-src"
    fi

    run_with_log "$BUILD_DIR/mlx_configure_$log_suffix.log" \
        env \
            DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
            "$@"

    if [ "$build_root" = "$MLX_IOS_BUILD_DIR" ]; then
        patch --batch --forward -d "$build_root/_deps/metal_cpp-src" -p1 \
            < "$REPO_ROOT/Vendors/PythonIOS/Patches/metal-cpp-dynamic-constants.patch"
    fi

    run_with_log "$BUILD_DIR/mlx_build_$log_suffix.log" \
        env \
            DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
            cmake --build "$build_root" --target core --parallel "$HOST_CPU_COUNT"

    test -f "$build_root/libmlx.a"
    test -f "$build_root/python/src/libnanobind-static.a"
    test -f "$build_root/mlx/io/libgguflib.a"
    test -f "$build_root/mlx/backend/metal/kernels/mlx.metallib"
    test -n "$(find "$build_root/python/src/CMakeFiles/core.dir" -name '*.o' -print -quit)"
}

build_mlx_ios() {
    build_mlx_slice \
        "$MLX_IOS_BUILD_DIR" \
        iOS \
        iphoneos \
        "$IOS_MINIMUM_OS_VERSION" \
        "-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION" \
        "$IOS_FRAMEWORK/Headers" \
        "$CROSS_BUILD_DIR/$IOS_HOST/libpython$PYTHON_VERSION_TAG.a" \
        "lib/python$PYTHON_VERSION_TAG/site-packages/mlx/$MLX_IOS_METALLIB_NAME" \
        ios
}

build_mlx_macos() {
    build_mlx_slice \
        "$MLX_MACOS_BUILD_DIR" \
        Darwin \
        macosx \
        "$MACOS_MINIMUM_OS_VERSION" \
        "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" \
        "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        "$MACOS_BUILD_DIR/libpython$PYTHON_VERSION_TAG.a" \
        "lib/python$PYTHON_VERSION_TAG/site-packages/mlx/$MLX_MACOS_METALLIB_NAME" \
        macos
}

write_mlx_inittab_source() {
    output=$1
    {
        echo '#include <Python.h>'
        echo
        echo 'extern PyObject *PyInit_core(void);'
        echo
        echo 'int ios_python_register_mlx(void) {'
        echo '    static int registered = 0;'
        echo '    if (registered) {'
        echo '        return 0;'
        echo '    }'
        echo '    int status = PyImport_AppendInittab("mlx.core", PyInit_core);'
        echo '    if (status == 0) {'
        echo '        registered = 1;'
        echo '    }'
        echo '    return status;'
        echo '}'
    } > "$output"
}

compile_mlx_inittab_ios() {
    source=$1
    output=$2
    ios_sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
    xcrun --sdk iphoneos clang -O2 -arch arm64 -miphoneos-version-min="$IOS_MINIMUM_OS_VERSION" \
        -isysroot "$ios_sdk_path" \
        -I "$IOS_FRAMEWORK/Headers" \
        -c "$source" -o "$output"
}

compile_mlx_inittab_macos() {
    source=$1
    output=$2
    cc -O2 -arch arm64 -mmacosx-version-min="$MACOS_MINIMUM_OS_VERSION" \
        -I "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
        -c "$source" -o "$output"
}

mlx_runtime_objects() {
    build_root=$1
    find "$build_root/python/src/CMakeFiles/core.dir" -name '*.o' -print
}

mlx_runtime_archives() {
    build_root=$1
    echo "$build_root/libmlx.a"
    echo "$build_root/python/src/libnanobind-static.a"
    echo "$build_root/mlx/io/libgguflib.a"
}

install_mlx_resources() {
    resource_root=$1
    metallib_source=$2
    metallib_name=$3
    site_packages="$resource_root/lib/python$PYTHON_VERSION_TAG/site-packages"
    mkdir -p "$site_packages"
    rm -rf "$site_packages/mlx" "$site_packages"/mlx-*.dist-info "$site_packages"/mlx.egg-info
    cp -R "$MLX_SOURCE_DIR/python/mlx" "$site_packages/"

    dist_info="$site_packages/mlx-$MLX_VERSION.dist-info"
    mkdir -p "$dist_info"
    {
        echo "Metadata-Version: 2.4"
        echo "Name: mlx"
        echo "Version: $MLX_VERSION"
        echo "Summary: A framework for machine learning on Apple silicon."
        echo "Home-page: https://github.com/ml-explore/mlx"
        echo "License: MIT"
        echo "Requires-Python: >=3.10"
    } > "$dist_info/METADATA"
    cp "$MLX_SOURCE_DIR/LICENSE" "$dist_info/"
    echo "Vendors/PythonIOS/build_base_python.sh" > "$dist_info/INSTALLER"
    : > "$dist_info/RECORD"

    cp "$metallib_source" "$site_packages/mlx/$metallib_name"

    find "$site_packages/mlx" -name __pycache__ -type d -prune -exec rm -rf {} +
    find "$site_packages/mlx" \( \
        -name '*.so' -o \
        -name '*.dylib' -o \
        -name '*.a' -o \
        -name '*.dll' -o \
        -name '*.exe' -o \
        -name '*.pyc' \
    \) -delete
}

run_with_log() {
    log_file=$1
    shift
    "$@" > "$log_file" 2>&1 || {
        tail -120 "$log_file"
        exit 1
    }
}

create_checksums() {
    checksum_file=$1
    (
        cd "$REPO_ROOT/Vendors/PythonIOS"
        {
            for item in BUILD README.md PYTHON_BUILD_INFO build_base_python.sh encapsulate_python.sh exported_symbols.txt hf_xet_inittab.c safetensors_inittab.c regex_inittab.c tokenizers_inittab.c sentencepiece_inittab.c cairosvg_inittab.c cairosvg_build.sh generate_cairo_binding.py pure_python_requirements.txt verify_python_ios.sh python_runtime.c python_runtime.h HFXetHeaders CurlCFFI YTDLP Patches Tests Frameworks Resources ResourcesMacOS; do
                if [ -e "$item" ]; then
                    find "$item" -type f -print
                fi
            done
        } | sort | while IFS= read -r file; do
            shasum -a 256 "$file"
        done
    ) > "$checksum_file"
}

if [ "$PYTHON_VERSION_TAG" != "3.14" ] || [ "$PYTHON_VERSION_FULL" != "3.14.7" ]; then
    echo "This generator is pinned to CPython 3.14.7; override the source constants together." >&2
    exit 1
fi

verify_macos_arm64_host

if [ ! -d "$CPYTHON_DIR/.git" ]; then
    git clone "$CPYTHON_REPO" "$CPYTHON_DIR"
fi

cd "$CPYTHON_DIR"
if [ "$CPYTHON_FETCH" = 1 ]; then
    git fetch --tags origin "$CPYTHON_TAG"
fi
git checkout --detach "$CPYTHON_COMMIT"
if [ "$CPYTHON_CLEAN" = 1 ]; then
    git reset --hard "$CPYTHON_COMMIT"
    git clean -fdx
fi
verify_source_files

cd "$REPO_ROOT"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$APPLE_DEPS_CACHE_DIR"
prepare_hf_xet_rust_toolchain
# Check dependency isolation and mixed-language unwinding before compiling the
# native dependencies. Failure stops the build through run_with_log.
run_with_log "$BUILD_DIR/encapsulation_test.log" \
    env RUSTC="$HF_XET_RUST_TOOLCHAIN_DIR/bin/rustc" \
    bash "$REPO_ROOT/Vendors/PythonIOS/Tests/encapsulate_python_test.sh"
prepare_macos_dependencies

cd "$CPYTHON_DIR"
run_with_log "$BUILD_DIR/configure_build.log" \
    python3 Apple configure-build --cross-build-dir "$CROSS_BUILD_DIR" --clean
run_with_log "$BUILD_DIR/make_build.log" \
    python3 Apple make-build --cross-build-dir "$CROSS_BUILD_DIR"
run_with_log "$BUILD_DIR/configure_ios.log" \
    disable_test_module_env python3 Apple configure-host iOS "$IOS_HOST" \
        --cross-build-dir "$CROSS_BUILD_DIR" \
        --cache-dir "$APPLE_DEPS_CACHE_DIR" \
        --clean \
        -- \
        ac_cv_func_dup3=no \
        ac_cv_func_pipe2=no \
        MODULE_BUILDTYPE=static
IOS_MAKEFILE="$CROSS_BUILD_DIR/$IOS_HOST/Makefile"
patch_static_python_makefile "$IOS_MAKEFILE"
run_with_log "$BUILD_DIR/make_ios.log" \
    python3 Apple make-host iOS "$IOS_HOST" --cross-build-dir "$CROSS_BUILD_DIR"

IOS_INSTALL_ROOT="$CROSS_BUILD_DIR/$IOS_HOST/Apple/iOS/Frameworks/$IOS_MULTIARCH"
IOS_FRAMEWORK="$IOS_INSTALL_ROOT/Python.framework"
test -f "$IOS_FRAMEWORK/Python"
test -f "$IOS_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG/_sysconfigdata__ios_arm64-iphoneos.py"

run_with_log "$BUILD_DIR/configure_ios_simulator.log" \
    disable_test_module_env python3 Apple configure-host iOS "$IOS_SIMULATOR_HOST" \
        --cross-build-dir "$CROSS_BUILD_DIR" \
        --cache-dir "$APPLE_DEPS_CACHE_DIR" \
        --clean \
        -- \
        ac_cv_func_dup3=no \
        ac_cv_func_pipe2=no \
        MODULE_BUILDTYPE=static
IOS_SIMULATOR_MAKEFILE="$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/Makefile"
patch_static_python_makefile "$IOS_SIMULATOR_MAKEFILE"
run_with_log "$BUILD_DIR/make_ios_simulator.log" \
    python3 Apple make-host iOS "$IOS_SIMULATOR_HOST" --cross-build-dir "$CROSS_BUILD_DIR"

IOS_SIMULATOR_INSTALL_ROOT="$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/Apple/iOS/Frameworks/$IOS_SIMULATOR_MULTIARCH"
IOS_SIMULATOR_FRAMEWORK="$IOS_SIMULATOR_INSTALL_ROOT/Python.framework"
test -f "$IOS_SIMULATOR_FRAMEWORK/Python"
test -f "$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG/_sysconfigdata__ios_arm64-iphonesimulator.py"

MACOS_BUILD_DIR="$BUILD_DIR/macos-build"
MACOS_INSTALL_ROOT="$BUILD_DIR/macos-install/Library"
mkdir -p "$MACOS_BUILD_DIR" "$MACOS_INSTALL_ROOT"
cd "$MACOS_BUILD_DIR"
PREVIOUS_MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-}
PREVIOUS_MACOSX_DEPLOYMENT_TARGET_WAS_SET=${MACOSX_DEPLOYMENT_TARGET+x}
PREVIOUS_CPPFLAGS=${CPPFLAGS:-}
PREVIOUS_CPPFLAGS_WAS_SET=${CPPFLAGS+x}
PREVIOUS_LDFLAGS=${LDFLAGS:-}
PREVIOUS_LDFLAGS_WAS_SET=${LDFLAGS+x}
PREVIOUS_PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}
PREVIOUS_PKG_CONFIG_PATH_WAS_SET=${PKG_CONFIG_PATH+x}
PREVIOUS_INSTALL=${INSTALL:-}
PREVIOUS_INSTALL_WAS_SET=${INSTALL+x}
PREVIOUS_MKDIR_P=${MKDIR_P:-}
PREVIOUS_MKDIR_P_WAS_SET=${MKDIR_P+x}
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM_OS_VERSION"
export CPPFLAGS="-I$MACOS_OPENSSL_PREFIX/include -I$MACOS_XZ_PREFIX/include -I$MACOS_ZSTD_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$MACOS_OPENSSL_PREFIX/lib -L$MACOS_XZ_PREFIX/lib -L$MACOS_ZSTD_PREFIX/lib ${LDFLAGS:-}"
export PKG_CONFIG_PATH="$MACOS_OPENSSL_PREFIX/lib/pkgconfig:$MACOS_XZ_PREFIX/lib/pkgconfig:$MACOS_ZSTD_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export INSTALL="/usr/bin/install -c"
export MKDIR_P="/bin/mkdir -p"
run_with_log "$BUILD_DIR/configure_macos.log" \
    disable_test_module_env "$CPYTHON_DIR/configure" \
        --prefix="$MACOS_INSTALL_ROOT" \
        --with-openssl="$MACOS_OPENSSL_PREFIX" \
        --with-openssl-rpath=no \
        --with-app-store-compliance \
        --enable-shared \
        MODULE_BUILDTYPE=static \
        LIBLZMA_CFLAGS="-I$MACOS_XZ_PREFIX/include" \
        LIBLZMA_LIBS="-L$MACOS_XZ_PREFIX/lib -llzma" \
        LIBZSTD_CFLAGS="-I$MACOS_ZSTD_PREFIX/include" \
        LIBZSTD_LIBS="-L$MACOS_ZSTD_PREFIX/lib -lzstd"
MACOS_MAKEFILE="$MACOS_BUILD_DIR/Makefile"
patch_static_python_makefile "$MACOS_MAKEFILE"
run_with_log "$BUILD_DIR/make_macos.log" make -j "$HOST_CPU_COUNT"
run_with_log "$BUILD_DIR/install_macos.log" make install
if [ -n "$PREVIOUS_MACOSX_DEPLOYMENT_TARGET_WAS_SET" ]; then
    export MACOSX_DEPLOYMENT_TARGET="$PREVIOUS_MACOSX_DEPLOYMENT_TARGET"
else
    unset MACOSX_DEPLOYMENT_TARGET
fi
if [ -n "$PREVIOUS_CPPFLAGS_WAS_SET" ]; then
    export CPPFLAGS="$PREVIOUS_CPPFLAGS"
else
    unset CPPFLAGS
fi
if [ -n "$PREVIOUS_LDFLAGS_WAS_SET" ]; then
    export LDFLAGS="$PREVIOUS_LDFLAGS"
else
    unset LDFLAGS
fi
if [ -n "$PREVIOUS_PKG_CONFIG_PATH_WAS_SET" ]; then
    export PKG_CONFIG_PATH="$PREVIOUS_PKG_CONFIG_PATH"
else
    unset PKG_CONFIG_PATH
fi
if [ -n "$PREVIOUS_INSTALL_WAS_SET" ]; then
    export INSTALL="$PREVIOUS_INSTALL"
else
    unset INSTALL
fi
if [ -n "$PREVIOUS_MKDIR_P_WAS_SET" ]; then
    export MKDIR_P="$PREVIOUS_MKDIR_P"
else
    unset MKDIR_P
fi
test -f "$MACOS_INSTALL_ROOT/lib/libpython$PYTHON_VERSION_TAG.dylib"
if ! lipo -archs "$MACOS_INSTALL_ROOT/lib/libpython$PYTHON_VERSION_TAG.dylib" | grep -qw arm64; then
    echo "macOS libpython is not arm64:" >&2
    lipo -archs "$MACOS_INSTALL_ROOT/lib/libpython$PYTHON_VERSION_TAG.dylib" >&2
    exit 1
fi

prepare_numpy_source
prepare_numpy_build_tools
build_pure_pyyaml_wheel
build_numpy_ios
build_numpy_ios_simulator
build_numpy_macos
prepare_cairosvg_source
build_cairosvg_slice iphoneos "$IOS_MINIMUM_OS_VERSION" "$IOS_FRAMEWORK/Headers" "$CROSS_BUILD_DIR/$IOS_HOST/prefix/include"
build_cairosvg_slice iphonesimulator "$IOS_MINIMUM_OS_VERSION" "$IOS_SIMULATOR_FRAMEWORK/Headers" "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/include"
build_cairosvg_slice macosx "$MACOS_MINIMUM_OS_VERSION" "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" "$(xcrun --sdk macosx --show-sdk-path)/usr/include/ffi"
prepare_pandas_source
build_pandas_ios
build_pandas_ios_simulator
build_pandas_macos
prepare_libxml2_source
build_libxml2_ios
build_libxml2_ios_simulator
build_libxml2_macos
prepare_libxslt_source
build_libxslt_ios
build_libxslt_ios_simulator
build_libxslt_macos
prepare_lxml_source
build_lxml_ios
build_lxml_ios_simulator
build_lxml_macos
prepare_contourpy_source
build_contourpy_ios
build_contourpy_ios_simulator
build_contourpy_macos
prepare_kiwisolver_source
build_kiwisolver_ios
build_kiwisolver_ios_simulator
build_kiwisolver_macos
prepare_matplotlib_source
build_matplotlib_ios
build_matplotlib_ios_simulator
build_matplotlib_macos
prepare_libjpeg_turbo_source
build_libjpeg_turbo_slice "$LIBJPEG_TURBO_IOS_BUILD_DIR" "$LIBJPEG_TURBO_IOS_PREFIX" iOS iphoneos "$IOS_MINIMUM_OS_VERSION" ios
build_libjpeg_turbo_slice "$LIBJPEG_TURBO_IOS_SIMULATOR_BUILD_DIR" "$LIBJPEG_TURBO_IOS_SIMULATOR_PREFIX" iOS iphonesimulator "$IOS_MINIMUM_OS_VERSION" ios_simulator
build_libjpeg_turbo_slice "$LIBJPEG_TURBO_MACOS_BUILD_DIR" "$LIBJPEG_TURBO_MACOS_PREFIX" Darwin macosx "$MACOS_MINIMUM_OS_VERSION" macos
prepare_pillow_source
build_pillow_ios
build_pillow_ios_simulator
build_pillow_macos
prepare_psd_tools_source
build_psd_tools_ios
build_psd_tools_ios_simulator
build_psd_tools_macos
prepare_regex_source
build_regex_slice \
    iphoneos \
    "$REGEX_IOS_BUILD_DIR" \
    "-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$IOS_FRAMEWORK/Headers" \
    "$BUILD_DIR/regex_make_ios.log"
build_regex_slice \
    iphonesimulator \
    "$REGEX_IOS_SIMULATOR_BUILD_DIR" \
    "-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$IOS_SIMULATOR_FRAMEWORK/Headers" \
    "$BUILD_DIR/regex_make_ios_simulator.log"
build_regex_slice \
    macosx \
    "$REGEX_MACOS_BUILD_DIR" \
    "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" \
    "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
    "$BUILD_DIR/regex_make_macos.log"
prepare_hf_xet_source
build_hf_xet_slice \
    iphoneos \
    aarch64-apple-ios \
    "$HF_XET_IOS_BUILD_DIR" \
    "-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/hf_xet_make_ios.log"
build_hf_xet_slice \
    iphonesimulator \
    aarch64-apple-ios-sim \
    "$HF_XET_IOS_SIMULATOR_BUILD_DIR" \
    "-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/hf_xet_make_ios_simulator.log"
build_hf_xet_slice \
    macosx \
    aarch64-apple-darwin \
    "$HF_XET_MACOS_BUILD_DIR" \
    "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/hf_xet_make_macos.log"
prepare_safetensors_source
build_safetensors_slice \
    iphoneos \
    aarch64-apple-ios \
    "$SAFETENSORS_IOS_BUILD_DIR" \
    "-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/safetensors_make_ios.log"
build_safetensors_slice \
    iphonesimulator \
    aarch64-apple-ios-sim \
    "$SAFETENSORS_IOS_SIMULATOR_BUILD_DIR" \
    "-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/safetensors_make_ios_simulator.log"
build_safetensors_slice \
    macosx \
    aarch64-apple-darwin \
    "$SAFETENSORS_MACOS_BUILD_DIR" \
    "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/safetensors_make_macos.log"
prepare_tokenizers_source
build_tokenizers_slice \
    iphoneos \
    aarch64-apple-ios \
    "$TOKENIZERS_IOS_BUILD_DIR" \
    "-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/tokenizers_make_ios.log"
build_tokenizers_slice \
    iphonesimulator \
    aarch64-apple-ios-sim \
    "$TOKENIZERS_IOS_SIMULATOR_BUILD_DIR" \
    "-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/tokenizers_make_ios_simulator.log"
build_tokenizers_slice \
    macosx \
    aarch64-apple-darwin \
    "$TOKENIZERS_MACOS_BUILD_DIR" \
    "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" \
    "$BUILD_DIR/tokenizers_make_macos.log"
prepare_sentencepiece_source
build_sentencepiece_slice \
    iphoneos \
    "$SENTENCEPIECE_IOS_BUILD_DIR" \
    "-miphoneos-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$IOS_FRAMEWORK/Headers" \
    "$BUILD_DIR/sentencepiece_make_ios.log"
build_sentencepiece_slice \
    iphonesimulator \
    "$SENTENCEPIECE_IOS_SIMULATOR_BUILD_DIR" \
    "-mios-simulator-version-min=$IOS_MINIMUM_OS_VERSION" \
    "$IOS_SIMULATOR_FRAMEWORK/Headers" \
    "$BUILD_DIR/sentencepiece_make_ios_simulator.log"
build_sentencepiece_slice \
    macosx \
    "$SENTENCEPIECE_MACOS_BUILD_DIR" \
    "-mmacosx-version-min=$MACOS_MINIMUM_OS_VERSION" \
    "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
    "$BUILD_DIR/sentencepiece_make_macos.log"
prepare_mlx_source
MLX_METAL_COMPILER=$(resolve_mlx_metal_compiler)
build_mlx_ios
build_mlx_macos

rm -rf "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" \
    "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library" \
    "$REPO_ROOT/Vendors/PythonIOS/Frameworks"
mkdir -p "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" \
    "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS" \
    "$REPO_ROOT/Vendors/PythonIOS/Frameworks"
cp -R "$IOS_INSTALL_ROOT/bin" "$REPO_ROOT/Vendors/PythonIOS/Resources/Library/"
cp -R "$IOS_INSTALL_ROOT/include" "$REPO_ROOT/Vendors/PythonIOS/Resources/Library/"
cp -R "$IOS_INSTALL_ROOT/lib" "$REPO_ROOT/Vendors/PythonIOS/Resources/Library/"
cp "$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG/_sysconfigdata__ios_arm64-iphonesimulator.py" \
    "$REPO_ROOT/Vendors/PythonIOS/Resources/Library/lib/python$PYTHON_VERSION_TAG/"
cp "$IOS_SIMULATOR_INSTALL_ROOT/lib/python$PYTHON_VERSION_TAG/_sysconfig_vars__ios_arm64-iphonesimulator.json" \
    "$REPO_ROOT/Vendors/PythonIOS/Resources/Library/lib/python$PYTHON_VERSION_TAG/"
cp -R "$MACOS_INSTALL_ROOT" "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/"
install_pure_python_packages "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_pure_python_packages "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_cairosvg_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_cairosvg_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_numpy_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" "$NUMPY_IOS_INSTALL_DESTDIR" "$NUMPY_IOS_INSTALL_PREFIX"
install_numpy_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library" "$NUMPY_MACOS_INSTALL_DESTDIR" "$NUMPY_MACOS_INSTALL_PREFIX"
install_pandas_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" "$PANDAS_IOS_INSTALL_DESTDIR" "$PANDAS_IOS_INSTALL_PREFIX"
install_pandas_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library" "$PANDAS_MACOS_INSTALL_DESTDIR" "$PANDAS_MACOS_INSTALL_PREFIX"
install_pillow_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_pillow_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_lxml_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_lxml_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_contourpy_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" "$CONTOURPY_IOS_INSTALL_DESTDIR" "$CONTOURPY_IOS_INSTALL_PREFIX"
install_contourpy_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library" "$CONTOURPY_MACOS_INSTALL_DESTDIR" "$CONTOURPY_MACOS_INSTALL_PREFIX"
install_kiwisolver_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_kiwisolver_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_matplotlib_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" "$MATPLOTLIB_IOS_INSTALL_DESTDIR" "$MATPLOTLIB_IOS_INSTALL_PREFIX"
install_matplotlib_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library" "$MATPLOTLIB_MACOS_INSTALL_DESTDIR" "$MATPLOTLIB_MACOS_INSTALL_PREFIX"
install_psd_tools_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_psd_tools_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_regex_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_regex_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_hf_xet_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_hf_xet_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_safetensors_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_safetensors_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_tokenizers_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_tokenizers_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_sentencepiece_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_sentencepiece_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"
install_mlx_resources \
    "$REPO_ROOT/Vendors/PythonIOS/Resources/Library" \
    "$MLX_IOS_BUILD_DIR/mlx/backend/metal/kernels/mlx.metallib" \
    "$MLX_IOS_METALLIB_NAME"
install_mlx_resources \
    "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library" \
    "$MLX_MACOS_BUILD_DIR/mlx/backend/metal/kernels/mlx.metallib" \
    "$MLX_MACOS_METALLIB_NAME"
install_embedded_runtime_sitecustomize "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
install_embedded_runtime_sitecustomize "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"

mkdir -p "$BUILD_DIR/Python-ios" "$BUILD_DIR/Python-ios-simulator" "$BUILD_DIR/Python-macos"
NUMPY_INITTAB_SOURCE="$BUILD_DIR/ios_python_numpy_inittab.c"
NUMPY_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_numpy_inittab.o"
NUMPY_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_numpy_inittab.o"
NUMPY_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_numpy_inittab.o"
PANDAS_INITTAB_SOURCE="$BUILD_DIR/ios_python_pandas_inittab.c"
PANDAS_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_pandas_inittab.o"
PANDAS_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_pandas_inittab.o"
PANDAS_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_pandas_inittab.o"
PILLOW_INITTAB_SOURCE="$BUILD_DIR/ios_python_pillow_inittab.c"
PILLOW_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_pillow_inittab.o"
PILLOW_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_pillow_inittab.o"
PILLOW_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_pillow_inittab.o"
LXML_INITTAB_SOURCE="$BUILD_DIR/ios_python_lxml_inittab.c"
LXML_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_lxml_inittab.o"
LXML_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_lxml_inittab.o"
LXML_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_lxml_inittab.o"
MATPLOTLIB_INITTAB_SOURCE="$BUILD_DIR/ios_python_matplotlib_inittab.c"
MATPLOTLIB_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_matplotlib_inittab.o"
MATPLOTLIB_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_matplotlib_inittab.o"
MATPLOTLIB_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_matplotlib_inittab.o"
PSDTOOLS_INITTAB_SOURCE="$BUILD_DIR/ios_python_psd_tools_inittab.c"
PSDTOOLS_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_psd_tools_inittab.o"
PSDTOOLS_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_psd_tools_inittab.o"
PSDTOOLS_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_psd_tools_inittab.o"
REGEX_INITTAB_SOURCE="$REPO_ROOT/Vendors/PythonIOS/regex_inittab.c"
REGEX_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_regex_inittab.o"
REGEX_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_regex_inittab.o"
REGEX_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_regex_inittab.o"
HF_XET_INITTAB_SOURCE="$REPO_ROOT/Vendors/PythonIOS/hf_xet_inittab.c"
HF_XET_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_hf_xet_inittab.o"
HF_XET_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_hf_xet_inittab.o"
HF_XET_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_hf_xet_inittab.o"
SAFETENSORS_INITTAB_SOURCE="$REPO_ROOT/Vendors/PythonIOS/safetensors_inittab.c"
SAFETENSORS_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_safetensors_inittab.o"
SAFETENSORS_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_safetensors_inittab.o"
SAFETENSORS_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_safetensors_inittab.o"
TOKENIZERS_INITTAB_SOURCE="$REPO_ROOT/Vendors/PythonIOS/tokenizers_inittab.c"
TOKENIZERS_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_tokenizers_inittab.o"
TOKENIZERS_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_tokenizers_inittab.o"
TOKENIZERS_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_tokenizers_inittab.o"
SENTENCEPIECE_INITTAB_SOURCE="$REPO_ROOT/Vendors/PythonIOS/sentencepiece_inittab.c"
SENTENCEPIECE_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_sentencepiece_inittab.o"
SENTENCEPIECE_IOS_SIMULATOR_INITTAB_OBJECT="$BUILD_DIR/Python-ios-simulator/ios_python_sentencepiece_inittab.o"
SENTENCEPIECE_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_sentencepiece_inittab.o"
MLX_INITTAB_SOURCE="$BUILD_DIR/ios_python_mlx_inittab.c"
MLX_IOS_INITTAB_OBJECT="$BUILD_DIR/Python-ios/ios_python_mlx_inittab.o"
MLX_MACOS_INITTAB_OBJECT="$BUILD_DIR/Python-macos/ios_python_mlx_inittab.o"
write_numpy_inittab_source "$NUMPY_INITTAB_SOURCE"
compile_numpy_inittab_ios "$NUMPY_INITTAB_SOURCE" "$NUMPY_IOS_INITTAB_OBJECT"
compile_numpy_inittab_ios_simulator "$NUMPY_INITTAB_SOURCE" "$NUMPY_IOS_SIMULATOR_INITTAB_OBJECT"
compile_numpy_inittab_macos "$NUMPY_INITTAB_SOURCE" "$NUMPY_MACOS_INITTAB_OBJECT"
write_pandas_inittab_source "$PANDAS_INITTAB_SOURCE"
compile_pandas_inittab_ios "$PANDAS_INITTAB_SOURCE" "$PANDAS_IOS_INITTAB_OBJECT"
compile_pandas_inittab_ios_simulator "$PANDAS_INITTAB_SOURCE" "$PANDAS_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pandas_inittab_macos "$PANDAS_INITTAB_SOURCE" "$PANDAS_MACOS_INITTAB_OBJECT"
write_pillow_inittab_source "$PILLOW_INITTAB_SOURCE"
compile_pillow_inittab_ios "$PILLOW_INITTAB_SOURCE" "$PILLOW_IOS_INITTAB_OBJECT"
compile_pillow_inittab_ios_simulator "$PILLOW_INITTAB_SOURCE" "$PILLOW_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pillow_inittab_macos "$PILLOW_INITTAB_SOURCE" "$PILLOW_MACOS_INITTAB_OBJECT"
write_lxml_inittab_source "$LXML_INITTAB_SOURCE"
compile_lxml_inittab_ios "$LXML_INITTAB_SOURCE" "$LXML_IOS_INITTAB_OBJECT"
compile_lxml_inittab_ios_simulator "$LXML_INITTAB_SOURCE" "$LXML_IOS_SIMULATOR_INITTAB_OBJECT"
compile_lxml_inittab_macos "$LXML_INITTAB_SOURCE" "$LXML_MACOS_INITTAB_OBJECT"
write_matplotlib_inittab_source "$MATPLOTLIB_INITTAB_SOURCE"
compile_matplotlib_inittab_ios "$MATPLOTLIB_INITTAB_SOURCE" "$MATPLOTLIB_IOS_INITTAB_OBJECT"
compile_matplotlib_inittab_ios_simulator "$MATPLOTLIB_INITTAB_SOURCE" "$MATPLOTLIB_IOS_SIMULATOR_INITTAB_OBJECT"
compile_matplotlib_inittab_macos "$MATPLOTLIB_INITTAB_SOURCE" "$MATPLOTLIB_MACOS_INITTAB_OBJECT"
write_psd_tools_inittab_source "$PSDTOOLS_INITTAB_SOURCE"
compile_psd_tools_inittab_ios "$PSDTOOLS_INITTAB_SOURCE" "$PSDTOOLS_IOS_INITTAB_OBJECT"
compile_psd_tools_inittab_ios_simulator "$PSDTOOLS_INITTAB_SOURCE" "$PSDTOOLS_IOS_SIMULATOR_INITTAB_OBJECT"
compile_psd_tools_inittab_macos "$PSDTOOLS_INITTAB_SOURCE" "$PSDTOOLS_MACOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios "$REGEX_INITTAB_SOURCE" "$REGEX_IOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios_simulator "$REGEX_INITTAB_SOURCE" "$REGEX_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pyo3_inittab_macos "$REGEX_INITTAB_SOURCE" "$REGEX_MACOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios "$HF_XET_INITTAB_SOURCE" "$HF_XET_IOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios_simulator "$HF_XET_INITTAB_SOURCE" "$HF_XET_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pyo3_inittab_macos "$HF_XET_INITTAB_SOURCE" "$HF_XET_MACOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios "$SAFETENSORS_INITTAB_SOURCE" "$SAFETENSORS_IOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios_simulator "$SAFETENSORS_INITTAB_SOURCE" "$SAFETENSORS_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pyo3_inittab_macos "$SAFETENSORS_INITTAB_SOURCE" "$SAFETENSORS_MACOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios "$TOKENIZERS_INITTAB_SOURCE" "$TOKENIZERS_IOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios_simulator "$TOKENIZERS_INITTAB_SOURCE" "$TOKENIZERS_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pyo3_inittab_macos "$TOKENIZERS_INITTAB_SOURCE" "$TOKENIZERS_MACOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios "$SENTENCEPIECE_INITTAB_SOURCE" "$SENTENCEPIECE_IOS_INITTAB_OBJECT"
compile_pyo3_inittab_ios_simulator "$SENTENCEPIECE_INITTAB_SOURCE" "$SENTENCEPIECE_IOS_SIMULATOR_INITTAB_OBJECT"
compile_pyo3_inittab_macos "$SENTENCEPIECE_INITTAB_SOURCE" "$SENTENCEPIECE_MACOS_INITTAB_OBJECT"
write_mlx_inittab_source "$MLX_INITTAB_SOURCE"
compile_mlx_inittab_ios "$MLX_INITTAB_SOURCE" "$MLX_IOS_INITTAB_OBJECT"
compile_mlx_inittab_macos "$MLX_INITTAB_SOURCE" "$MLX_MACOS_INITTAB_OBJECT"
create_static_python_library "$BUILD_DIR/Python-ios/libpython$PYTHON_VERSION_TAG-ios.a" \
    iphoneos "$IOS_MINIMUM_OS_VERSION" \
    "$CROSS_BUILD_DIR/$IOS_HOST/libpython$PYTHON_VERSION_TAG.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/Modules/expat/libexpat.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/Modules/_hacl/libHacl_HMAC.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/libbz2.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/libcrypto.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/libffi.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/liblzma.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/libmpdec.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/libssl.a" \
    "$CROSS_BUILD_DIR/$IOS_HOST/prefix/lib/libzstd.a" \
    "$NUMPY_IOS_INITTAB_OBJECT" \
    "$PANDAS_IOS_INITTAB_OBJECT" \
    "$PILLOW_IOS_INITTAB_OBJECT" \
    "$LXML_IOS_INITTAB_OBJECT" \
    "$MATPLOTLIB_IOS_INITTAB_OBJECT" \
    "$PSDTOOLS_IOS_INITTAB_OBJECT" \
    "$REGEX_IOS_INITTAB_OBJECT" \
    "$REGEX_IOS_BUILD_DIR/regex_module.o" \
    "$REGEX_IOS_BUILD_DIR/regex_unicode.o" \
    "$HF_XET_IOS_INITTAB_OBJECT" \
    "$HF_XET_IOS_BUILD_DIR/aarch64-apple-ios/release/libhf_xet.a" \
    "$SAFETENSORS_IOS_INITTAB_OBJECT" \
    "$SAFETENSORS_IOS_BUILD_DIR/aarch64-apple-ios/release/libsafetensors_rust.a" \
    "$TOKENIZERS_IOS_INITTAB_OBJECT" \
    "$TOKENIZERS_IOS_BUILD_DIR/aarch64-apple-ios/release/libtokenizers.a" \
    "$SENTENCEPIECE_IOS_INITTAB_OBJECT" \
    "$SENTENCEPIECE_IOS_BUILD_DIR/sentencepiece_pybind.o" \
    "$MLX_IOS_INITTAB_OBJECT" \
    $(numpy_runtime_objects "$NUMPY_IOS_BUILD_DIR") \
    $(numpy_runtime_archives "$NUMPY_IOS_BUILD_DIR") \
    $(pandas_runtime_objects "$PANDAS_IOS_BUILD_DIR") \
    $(pillow_runtime_objects "$PILLOW_IOS_BUILD_DIR") \
    $(libjpeg_turbo_runtime_archives "$LIBJPEG_TURBO_IOS_PREFIX") \
    $(cairosvg_runtime_objects iphoneos) \
    $(lxml_runtime_objects "$LXML_IOS_BUILD_DIR") \
    $(lxml_runtime_archives "$LIBXML2_IOS_PREFIX") \
    $(contourpy_runtime_objects "$CONTOURPY_IOS_BUILD_DIR") \
    $(kiwisolver_runtime_objects "$KIWISOLVER_IOS_BUILD_DIR") \
    $(matplotlib_runtime_objects "$MATPLOTLIB_IOS_BUILD_DIR") \
    $(psd_tools_runtime_objects "$PSDTOOLS_IOS_BUILD_DIR") \
    $(matplotlib_runtime_archives "$MATPLOTLIB_IOS_BUILD_DIR") \
    $(mlx_runtime_objects "$MLX_IOS_BUILD_DIR") \
    $(mlx_runtime_archives "$MLX_IOS_BUILD_DIR")
create_static_python_library "$BUILD_DIR/Python-ios-simulator/libpython$PYTHON_VERSION_TAG-ios-simulator.a" \
    iphonesimulator "$IOS_MINIMUM_OS_VERSION" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/libpython$PYTHON_VERSION_TAG.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/Modules/expat/libexpat.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/Modules/_hacl/libHacl_HMAC.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/libbz2.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/libcrypto.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/libffi.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/liblzma.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/libmpdec.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/libssl.a" \
    "$CROSS_BUILD_DIR/$IOS_SIMULATOR_HOST/prefix/lib/libzstd.a" \
    "$NUMPY_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$PANDAS_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$PILLOW_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$LXML_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$MATPLOTLIB_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$PSDTOOLS_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$REGEX_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$REGEX_IOS_SIMULATOR_BUILD_DIR/regex_module.o" \
    "$REGEX_IOS_SIMULATOR_BUILD_DIR/regex_unicode.o" \
    "$HF_XET_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$HF_XET_IOS_SIMULATOR_BUILD_DIR/aarch64-apple-ios-sim/release/libhf_xet.a" \
    "$SAFETENSORS_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$SAFETENSORS_IOS_SIMULATOR_BUILD_DIR/aarch64-apple-ios-sim/release/libsafetensors_rust.a" \
    "$TOKENIZERS_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$TOKENIZERS_IOS_SIMULATOR_BUILD_DIR/aarch64-apple-ios-sim/release/libtokenizers.a" \
    "$SENTENCEPIECE_IOS_SIMULATOR_INITTAB_OBJECT" \
    "$SENTENCEPIECE_IOS_SIMULATOR_BUILD_DIR/sentencepiece_pybind.o" \
    $(numpy_runtime_objects "$NUMPY_IOS_SIMULATOR_BUILD_DIR") \
    $(numpy_runtime_archives "$NUMPY_IOS_SIMULATOR_BUILD_DIR") \
    $(pandas_runtime_objects "$PANDAS_IOS_SIMULATOR_BUILD_DIR") \
    $(pillow_runtime_objects "$PILLOW_IOS_SIMULATOR_BUILD_DIR") \
    $(libjpeg_turbo_runtime_archives "$LIBJPEG_TURBO_IOS_SIMULATOR_PREFIX") \
    $(cairosvg_runtime_objects iphonesimulator) \
    $(lxml_runtime_objects "$LXML_IOS_SIMULATOR_BUILD_DIR") \
    $(lxml_runtime_archives "$LIBXML2_IOS_SIMULATOR_PREFIX") \
    $(contourpy_runtime_objects "$CONTOURPY_IOS_SIMULATOR_BUILD_DIR") \
    $(kiwisolver_runtime_objects "$KIWISOLVER_IOS_SIMULATOR_BUILD_DIR") \
    $(matplotlib_runtime_objects "$MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR") \
    $(psd_tools_runtime_objects "$PSDTOOLS_IOS_SIMULATOR_BUILD_DIR") \
    $(matplotlib_runtime_archives "$MATPLOTLIB_IOS_SIMULATOR_BUILD_DIR")
create_static_python_library "$BUILD_DIR/Python-macos/libpython$PYTHON_VERSION_TAG-macos.a" \
    macosx "$NUMPY_MACOS_MINIMUM_OS_VERSION" \
    "$MACOS_BUILD_DIR/libpython$PYTHON_VERSION_TAG.a" \
    "$MACOS_BUILD_DIR/Modules/expat/libexpat.a" \
    "$MACOS_BUILD_DIR/Modules/_decimal/libmpdec/libmpdec.a" \
    "$MACOS_BUILD_DIR/Modules/_hacl/libHacl_HMAC.a" \
    "$MACOS_OPENSSL_PREFIX/lib/libssl.a" \
    "$MACOS_OPENSSL_PREFIX/lib/libcrypto.a" \
    "$MACOS_XZ_PREFIX/lib/liblzma.a" \
    "$MACOS_ZSTD_PREFIX/lib/libzstd.a" \
    "$NUMPY_MACOS_INITTAB_OBJECT" \
    "$PANDAS_MACOS_INITTAB_OBJECT" \
    "$PILLOW_MACOS_INITTAB_OBJECT" \
    "$LXML_MACOS_INITTAB_OBJECT" \
    "$MATPLOTLIB_MACOS_INITTAB_OBJECT" \
    "$PSDTOOLS_MACOS_INITTAB_OBJECT" \
    "$REGEX_MACOS_INITTAB_OBJECT" \
    "$REGEX_MACOS_BUILD_DIR/regex_module.o" \
    "$REGEX_MACOS_BUILD_DIR/regex_unicode.o" \
    "$HF_XET_MACOS_INITTAB_OBJECT" \
    "$HF_XET_MACOS_BUILD_DIR/aarch64-apple-darwin/release/libhf_xet.a" \
    "$SAFETENSORS_MACOS_INITTAB_OBJECT" \
    "$SAFETENSORS_MACOS_BUILD_DIR/aarch64-apple-darwin/release/libsafetensors_rust.a" \
    "$TOKENIZERS_MACOS_INITTAB_OBJECT" \
    "$TOKENIZERS_MACOS_BUILD_DIR/aarch64-apple-darwin/release/libtokenizers.a" \
    "$SENTENCEPIECE_MACOS_INITTAB_OBJECT" \
    "$SENTENCEPIECE_MACOS_BUILD_DIR/sentencepiece_pybind.o" \
    "$MLX_MACOS_INITTAB_OBJECT" \
    $(numpy_runtime_objects "$NUMPY_MACOS_BUILD_DIR") \
    $(numpy_runtime_archives "$NUMPY_MACOS_BUILD_DIR") \
    $(pandas_runtime_objects "$PANDAS_MACOS_BUILD_DIR") \
    $(pillow_runtime_objects "$PILLOW_MACOS_BUILD_DIR") \
    $(libjpeg_turbo_runtime_archives "$LIBJPEG_TURBO_MACOS_PREFIX") \
    $(cairosvg_runtime_objects macosx) \
    $(lxml_runtime_objects "$LXML_MACOS_BUILD_DIR") \
    $(lxml_runtime_archives "$LIBXML2_MACOS_PREFIX") \
    $(contourpy_runtime_objects "$CONTOURPY_MACOS_BUILD_DIR") \
    $(kiwisolver_runtime_objects "$KIWISOLVER_MACOS_BUILD_DIR") \
    $(matplotlib_runtime_objects "$MATPLOTLIB_MACOS_BUILD_DIR") \
    $(psd_tools_runtime_objects "$PSDTOOLS_MACOS_BUILD_DIR") \
    $(matplotlib_runtime_archives "$MATPLOTLIB_MACOS_BUILD_DIR") \
    $(mlx_runtime_objects "$MLX_MACOS_BUILD_DIR") \
    $(mlx_runtime_archives "$MLX_MACOS_BUILD_DIR")
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/Python-ios/libpython$PYTHON_VERSION_TAG-ios.a" \
    -headers "$IOS_FRAMEWORK/Headers" \
    -library "$BUILD_DIR/Python-ios-simulator/libpython$PYTHON_VERSION_TAG-ios-simulator.a" \
    -headers "$IOS_SIMULATOR_FRAMEWORK/Headers" \
    -library "$BUILD_DIR/Python-macos/libpython$PYTHON_VERSION_TAG-macos.a" \
    -headers "$MACOS_INSTALL_ROOT/include/python$PYTHON_VERSION_TAG" \
    -output "$BUILD_DIR/Python.xcframework"
cp -R "$BUILD_DIR/Python.xcframework" "$REPO_ROOT/Vendors/PythonIOS/Frameworks/"

DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" CFFI_BUILD_PYTHON="$NUMPY_BUILD_TOOLS_PYTHON" \
    bash "$REPO_ROOT/Vendors/PythonIOS/CurlCFFI/build.sh"
DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" "$NUMPY_BUILD_TOOLS_PYTHON" \
    "$REPO_ROOT/Vendors/PythonIOS/YTDLP/install.py"

prune_ios_resources "$REPO_ROOT/Vendors/PythonIOS/Resources/Library"
prune_macos_resources "$REPO_ROOT/Vendors/PythonIOS/ResourcesMacOS/Library"

if ! file "$REPO_ROOT/Vendors/PythonIOS/Frameworks/Python.xcframework/ios-arm64/libpython$PYTHON_VERSION_TAG-ios.a" | grep -q "current ar archive"; then
    echo "iOS Python XCFramework slice is not a static archive." >&2
    file "$REPO_ROOT/Vendors/PythonIOS/Frameworks/Python.xcframework/ios-arm64/libpython$PYTHON_VERSION_TAG-ios.a" >&2
    exit 1
fi
if ! file "$REPO_ROOT/Vendors/PythonIOS/Frameworks/Python.xcframework/ios-arm64-simulator/libpython$PYTHON_VERSION_TAG-ios-simulator.a" | grep -q "current ar archive"; then
    echo "iOS simulator Python XCFramework slice is not a static archive." >&2
    file "$REPO_ROOT/Vendors/PythonIOS/Frameworks/Python.xcframework/ios-arm64-simulator/libpython$PYTHON_VERSION_TAG-ios-simulator.a" >&2
    exit 1
fi
if ! file "$REPO_ROOT/Vendors/PythonIOS/Frameworks/Python.xcframework/macos-arm64/libpython$PYTHON_VERSION_TAG-macos.a" | grep -q "current ar archive"; then
    echo "macOS Python XCFramework slice is not a static archive." >&2
    file "$REPO_ROOT/Vendors/PythonIOS/Frameworks/Python.xcframework/macos-arm64/libpython$PYTHON_VERSION_TAG-macos.a" >&2
    exit 1
fi

{
    cat "$REPO_ROOT/Vendors/PythonIOS/CurlCFFI/BUILD_INFO" "$REPO_ROOT/Vendors/PythonIOS/YTDLP/BUILD_INFO"
    echo "CPYTHON_REPO=$CPYTHON_REPO"
    echo "CPYTHON_TAG=$CPYTHON_TAG"
    echo "CPYTHON_COMMIT=$(cd "$CPYTHON_DIR" && git rev-parse HEAD)"
    echo "PYTHON_VERSION=$(DYLD_LIBRARY_PATH="$MACOS_INSTALL_ROOT/lib" "$MACOS_INSTALL_ROOT/bin/python$PYTHON_VERSION_TAG" -c 'import sys; print(sys.version.split()[0])')"
    echo "PYTHON_BUILD_FLAVOR=regular-gil"
    echo "PYTHON_LINKAGE=static"
    echo "PYTHON_STATIC_ARCHIVE_STRIP=debug-and-local-symbols"
    echo "PYTHON_SYMBOL_VISIBILITY=export-list"
    echo "PYTHON_RUST_PERSONALITY=shared-weak"
    echo "PYTHON_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "PYTHON_EMBEDDED_RUNTIME_POLICY=mimetypes-knownfiles-disabled"
    echo "PYTHON_NATIVE_PACKAGES=numpy-$NUMPY_VERSION pandas-$PANDAS_VERSION pillow-$PILLOW_VERSION libjpeg-turbo-$LIBJPEG_TURBO_VERSION libxml2-$LIBXML2_VERSION libxslt-$LIBXSLT_VERSION lxml-$LXML_VERSION contourpy-$CONTOURPY_VERSION kiwisolver-$KIWISOLVER_VERSION matplotlib-$MATPLOTLIB_VERSION psd-tools-$PSDTOOLS_VERSION regex-$REGEX_VERSION hf-xet-$HF_XET_VERSION safetensors-$SAFETENSORS_VERSION tokenizers-$TOKENIZERS_VERSION sentencepiece-$SENTENCEPIECE_VERSION mlx-$MLX_VERSION cffi-$CFFI_VERSION cairo-$CAIRO_VERSION pixman-$PIXMAN_VERSION libpng-$LIBPNG_VERSION"
    echo "NUMPY_SOURCE_URL=$NUMPY_SOURCE_URL"
    echo "NUMPY_SOURCE_SHA256=$NUMPY_SOURCE_SHA256"
    echo "NUMPY_IOS_BLAS=Accelerate"
    echo "NUMPY_IOS_BLAS_SYMBOL_SUFFIX="
    echo "NUMPY_IOS_SIMULATOR_BLAS=Accelerate"
    echo "NUMPY_IOS_SIMULATOR_BLAS_SYMBOL_SUFFIX="
    echo "NUMPY_MACOS_BLAS=Accelerate"
    echo "NUMPY_MACOS_BLAS_SYMBOL_SUFFIX=auto"
    echo "NUMPY_MACOS_MINIMUM_OS_VERSION=$NUMPY_MACOS_MINIMUM_OS_VERSION"
    echo "NUMPY_BUILD_TOOLS=pip-$NUMPY_BUILD_PIP_VERSION setuptools-$NUMPY_BUILD_SETUPTOOLS_VERSION wheel-$NUMPY_BUILD_WHEEL_VERSION Cython-$NUMPY_BUILD_CYTHON_VERSION ninja-$NUMPY_BUILD_NINJA_VERSION packaging-$NUMPY_BUILD_PACKAGING_VERSION meson-$NUMPY_BUILD_MESON_VERSION meson-python-$NUMPY_BUILD_MESON_PYTHON_VERSION versioneer-$NUMPY_BUILD_VERSIONEER_VERSION pybind11-$NUMPY_BUILD_PYBIND11_VERSION cppy-$NUMPY_BUILD_CPPY_VERSION setuptools-scm-$NUMPY_BUILD_SETUPTOOLS_SCM_VERSION"
    echo "PANDAS_SOURCE_URL=$PANDAS_SOURCE_URL"
    echo "PANDAS_SOURCE_SHA256=$PANDAS_SOURCE_SHA256"
    echo "PANDAS_STATIC_SYMBOL_RENAMES=$PANDAS_STATIC_SYMBOL_RENAMES"
    echo "PILLOW_SOURCE_URL=$PILLOW_SOURCE_URL"
    echo "PILLOW_SOURCE_SHA256=$PILLOW_SOURCE_SHA256"
    echo "PILLOW_FEATURE_POLICY=$PILLOW_FEATURE_POLICY"
    echo "LIBJPEG_TURBO_SOURCE_URL=$LIBJPEG_TURBO_SOURCE_URL"
    echo "LIBJPEG_TURBO_SOURCE_SHA256=$LIBJPEG_TURBO_SOURCE_SHA256"
    echo "LIBJPEG_TURBO_FEATURE_POLICY=$LIBJPEG_TURBO_FEATURE_POLICY"
    echo "CFFI_SOURCE_URL=$CFFI_SOURCE_URL"
    echo "CFFI_SOURCE_SHA256=$CFFI_SOURCE_SHA256"
    echo "CAIRO_SOURCE_URL=$CAIRO_SOURCE_URL"
    echo "CAIRO_SOURCE_SHA256=$CAIRO_SOURCE_SHA256"
    echo "PIXMAN_SOURCE_URL=$PIXMAN_SOURCE_URL"
    echo "PIXMAN_SOURCE_SHA256=$PIXMAN_SOURCE_SHA256"
    echo "LIBPNG_SOURCE_URL=$LIBPNG_SOURCE_URL"
    echo "LIBPNG_SOURCE_SHA256=$LIBPNG_SOURCE_SHA256"
    echo "CAIRO_PKGCONF_SOURCE_URL=$CAIRO_PKGCONF_SOURCE_URL"
    echo "CAIRO_PKGCONF_SOURCE_SHA256=$CAIRO_PKGCONF_SOURCE_SHA256"
    echo "CAIRO_FEATURE_POLICY=$CAIRO_FEATURE_POLICY"
    echo "PYTHON_LD_CLASSIC=${PYTHON_LD_CLASSIC:-$(xcrun --find ld-classic)}"
    echo "LIBXML2_SOURCE_URL=$LIBXML2_SOURCE_URL"
    echo "LIBXML2_SOURCE_SHA256=$LIBXML2_SOURCE_SHA256"
    echo "LIBXSLT_SOURCE_URL=$LIBXSLT_SOURCE_URL"
    echo "LIBXSLT_SOURCE_SHA256=$LIBXSLT_SOURCE_SHA256"
    echo "LXML_SOURCE_URL=$LXML_SOURCE_URL"
    echo "LXML_SOURCE_SHA256=$LXML_SOURCE_SHA256"
    echo "LXML_FEATURE_POLICY=$LXML_FEATURE_POLICY"
    echo "CONTOURPY_SOURCE_URL=$CONTOURPY_SOURCE_URL"
    echo "CONTOURPY_SOURCE_SHA256=$CONTOURPY_SOURCE_SHA256"
    echo "KIWISOLVER_SOURCE_URL=$KIWISOLVER_SOURCE_URL"
    echo "KIWISOLVER_SOURCE_SHA256=$KIWISOLVER_SOURCE_SHA256"
    echo "MATPLOTLIB_SOURCE_URL=$MATPLOTLIB_SOURCE_URL"
    echo "MATPLOTLIB_SOURCE_SHA256=$MATPLOTLIB_SOURCE_SHA256"
    echo "MATPLOTLIB_FREETYPE_SOURCE_URL=$MATPLOTLIB_FREETYPE_SOURCE_URL"
    echo "MATPLOTLIB_FREETYPE_SOURCE_SHA256=$MATPLOTLIB_FREETYPE_SOURCE_SHA256"
    echo "MATPLOTLIB_HARFBUZZ_SOURCE_URL=$MATPLOTLIB_HARFBUZZ_SOURCE_URL"
    echo "MATPLOTLIB_HARFBUZZ_SOURCE_SHA256=$MATPLOTLIB_HARFBUZZ_SOURCE_SHA256"
    echo "MATPLOTLIB_SHEENBIDI_SOURCE_URL=$MATPLOTLIB_SHEENBIDI_SOURCE_URL"
    echo "MATPLOTLIB_SHEENBIDI_SOURCE_SHA256=$MATPLOTLIB_SHEENBIDI_SOURCE_SHA256"
    echo "MATPLOTLIB_LIBRAQM_SOURCE_URL=$MATPLOTLIB_LIBRAQM_SOURCE_URL"
    echo "MATPLOTLIB_LIBRAQM_SOURCE_SHA256=$MATPLOTLIB_LIBRAQM_SOURCE_SHA256"
    echo "MATPLOTLIB_QHULL_SOURCE_URL=$MATPLOTLIB_QHULL_SOURCE_URL"
    echo "MATPLOTLIB_QHULL_SOURCE_SHA256=$MATPLOTLIB_QHULL_SOURCE_SHA256"
    echo "MATPLOTLIB_FEATURE_POLICY=$MATPLOTLIB_FEATURE_POLICY"
    echo "PSDTOOLS_SOURCE_URL=$PSDTOOLS_SOURCE_URL"
    echo "PSDTOOLS_SOURCE_SHA256=$PSDTOOLS_SOURCE_SHA256"
    echo "PSDTOOLS_FEATURE_POLICY=$PSDTOOLS_FEATURE_POLICY"
    echo "REGEX_SOURCE_URL=$REGEX_SOURCE_URL"
    echo "REGEX_SOURCE_SHA256=$REGEX_SOURCE_SHA256"
    echo "REGEX_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "REGEX_FEATURE_POLICY=$REGEX_FEATURE_POLICY"
    echo "HF_XET_SOURCE_URL=$HF_XET_SOURCE_URL"
    echo "HF_XET_SOURCE_SHA256=$HF_XET_SOURCE_SHA256"
    echo "HF_XET_CARGO_LOCK_SHA256=$HF_XET_CARGO_LOCK_SHA256"
    echo "HF_XET_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "HF_XET_RUST_VERSION=$HF_XET_RUST_VERSION"
    echo "HF_XET_RUST_TOOLCHAIN_SHA256=$HF_XET_RUST_TOOLCHAIN_SHA256"
    echo "HF_XET_RUST_STD_SHA256=ios-arm64:$HF_XET_RUST_IOS_STD_SHA256 ios-arm64-simulator:$HF_XET_RUST_IOS_SIMULATOR_STD_SHA256"
    echo "HF_XET_FEATURE_POLICY=$HF_XET_FEATURE_POLICY"
    echo "SAFETENSORS_SOURCE_URL=$SAFETENSORS_SOURCE_URL"
    echo "SAFETENSORS_SOURCE_SHA256=$SAFETENSORS_SOURCE_SHA256"
    echo "SAFETENSORS_CARGO_LOCK_SHA256=$SAFETENSORS_CARGO_LOCK_SHA256"
    echo "SAFETENSORS_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "SAFETENSORS_RUST_VERSION=$HF_XET_RUST_VERSION"
    echo "SAFETENSORS_FEATURE_POLICY=$SAFETENSORS_FEATURE_POLICY"
    echo "TOKENIZERS_SOURCE_URL=$TOKENIZERS_SOURCE_URL"
    echo "TOKENIZERS_SOURCE_SHA256=$TOKENIZERS_SOURCE_SHA256"
    echo "TOKENIZERS_CARGO_LOCK_SHA256=$TOKENIZERS_CARGO_LOCK_SHA256"
    echo "TOKENIZERS_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "TOKENIZERS_RUST_VERSION=$HF_XET_RUST_VERSION"
    echo "TOKENIZERS_FEATURE_POLICY=$TOKENIZERS_FEATURE_POLICY"
    echo "SENTENCEPIECE_SOURCE_URL=$SENTENCEPIECE_SOURCE_URL"
    echo "SENTENCEPIECE_SOURCE_SHA256=$SENTENCEPIECE_SOURCE_SHA256"
    echo "SENTENCEPIECE_ABSEIL_COMMIT=$SENTENCEPIECE_ABSEIL_COMMIT"
    echo "SENTENCEPIECE_ABSEIL_ABI=$SENTENCEPIECE_ABSEIL_ABI"
    echo "SENTENCEPIECE_SLICES=ios-arm64 ios-arm64-simulator macos-arm64"
    echo "SENTENCEPIECE_FEATURE_POLICY=$SENTENCEPIECE_FEATURE_POLICY"
    echo "MLX_SOURCE_URL=$MLX_SOURCE_URL"
    echo "MLX_SOURCE_SHA256=$MLX_SOURCE_SHA256"
    echo "MLX_SLICES=ios-arm64 macos-arm64"
    echo "MLX_FEATURE_POLICY=$MLX_FEATURE_POLICY"
    echo "MLX_METAL_LANGUAGE_STANDARD=$MLX_METAL_LANGUAGE_STANDARD"
    echo "MLX_METAL_COMPILER_VERSION=$("$MLX_METAL_COMPILER" --version | sed -n '1p')"
    echo "MLX_BUILD_DEPENDENCIES=metal-cpp-$MLX_METAL_CPP_VERSION json-$MLX_JSON_VERSION fmt-$MLX_FMT_VERSION nanobind-$MLX_NANOBIND_VERSION gguf-$MLX_GGUF_COMMIT"
    echo "PYYAML_SOURCE_URL=$PYYAML_SOURCE_URL"
    echo "PYYAML_SOURCE_SHA256=$PYYAML_SOURCE_SHA256"
    echo "PYYAML_WHEEL_SHA256=$PYYAML_WHEEL_SHA256"
    echo "PYYAML_FEATURE_POLICY=$PYYAML_FEATURE_POLICY"
    echo "TQDM_FEATURE_POLICY=monitor-thread=disabled multiprocessing-lock=disabled"
    if [ -s "$PURE_PYTHON_REQUIREMENTS" ]; then
        echo "PYTHON_PURE_REQUIREMENTS_SHA256=$(shasum -a 256 "$PURE_PYTHON_REQUIREMENTS" | awk '{print $1}')"
    fi
    echo "IOS_MINIMUM_OS_VERSION=$IOS_MINIMUM_OS_VERSION"
    echo "MACOS_MINIMUM_OS_VERSION=$MACOS_MINIMUM_OS_VERSION"
    echo "MACOS_NATIVE_DEPS=openssl-$OPENSSL_VERSION xz-$XZ_VERSION zstd-$ZSTD_VERSION"
    echo "MACOS_NATIVE_DEPS_SHA256=openssl:$OPENSSL_SHA256 xz:$XZ_SHA256 zstd:$ZSTD_SHA256"
    echo "XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    echo "BAZEL_VERSION=$(cd "$REPO_ROOT" && bazel --version)"
} > "$REPO_ROOT/Vendors/PythonIOS/PYTHON_BUILD_INFO"

CHECKSUM_FILE="$BUILD_DIR/SHA256SUMS"
create_checksums "$CHECKSUM_FILE"
mv "$CHECKSUM_FILE" "$REPO_ROOT/Vendors/PythonIOS/SHA256SUMS"

# Validate the packaged slices and their checksums before reporting success.
run_with_log "$BUILD_DIR/verify_python_ios.log" \
    bash "$REPO_ROOT/Vendors/PythonIOS/verify_python_ios.sh"

echo "Updated Vendors/PythonIOS from $CPYTHON_DIR"
