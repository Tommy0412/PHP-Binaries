#!/usr/bin/env bash
PHP_VERSIONS=("8.1.33" "8.2.29" "8.3.26" "8.4.13" "8.5.0RC1")

#### NOTE: Tags with "v" prefixes behave weirdly in the GitHub API. They'll be stripped in some places but not others.
#### Use commit hashes to avoid this.

ZLIB_VERSION="1.3.1"
GMP_VERSION="6.3.0"

### Think twice before updating the minor/major versions of curl.
### curl is by far the worst offender when it comes to random
### build breakages on updates.
CURL_VERSION="curl-8_13_0"

YAML_VERSION="0.2.5"
LEVELDB_VERSION="1c7564468b41610da4f498430e795ca4de0931ff" #release not tagged
LIBXML_VERSION="2.14.5"
LIBPNG_VERSION="1.6.50"
LIBJPEG_VERSION="9f"
OPENSSL_VERSION="3.5.2"
LIBZIP_VERSION="1.11.4"
SQLITE3_VERSION="3500400" #3.50.4
LIBDEFLATE_VERSION="96836d7d9d10e3e0d53e6edb54eb908514e336c4" #1.24 - see above note about "v" prefixes

EXT_PMMPTHREAD_VERSION="6.2.0"
EXT_YAML_VERSION="2.2.5"
EXT_LEVELDB_VERSION="88071eb1b1eae96af043229104b9d813f7cbe40c" #release not tagged
EXT_CHUNKUTILS2_VERSION="0.3.5"
EXT_XDEBUG_VERSION="3.4.5"
EXT_IGBINARY_VERSION="3.2.16"
EXT_CRYPTO_VERSION="999b3c7edbc7f8ca4fdeb0bb4bbae488ad0daf07" #release not tagged
EXT_RECURSIONGUARD_VERSION="0.1.0"
EXT_LIBDEFLATE_VERSION="0.2.1"

EXT_PMMPTHREAD_VERSION_PHP85="4aa34a27feaa43adba5f1e93939828d1d7afdefc"
EXT_XDEBUG_VERSION_PHP85="86727b0b05b5d0a9c4fb85021f05d7931e2c3a35"
EXT_IGBINARY_VERSION_PHP85="8f8b7175c7859f1845bcdee6f7d0baeea7d07cb8"

function write_out {
	echo "[$1] $2"
}

function write_error {
	write_out ERROR "$1" >&2
}

function write_status {
	echo -n " $1..."
}

function write_library {
  echo -n "[$1 $2]"
}

function write_caching {
  write_status "using cache"
}

function write_download {
	write_status "downloading"
}
function write_configure {
	write_status "configuring"
}
function write_compile {
	write_status "compiling"
}
function write_install {
	write_status "installing"
}
function write_done {
	echo " done!"
}
function cant_use_cache {
	if [ -f "$1/.compile.sh.cache" ]; then
		return 1
	else
		return 0
	fi
}
function mark_cache {
	touch "./.compile.sh.cache"
}

write_out "PHP compiler for Android"
DIR="$(pwd)"
BASE_BUILD_DIR="$DIR/install_data"
#libtool and autoconf have a "feature" where it looks for install.sh/install-sh in ./ ../ and ../../
#this extra subdir makes sure that it doesn't find anything it's not supposed to be looking for.
BUILD_DIR="$BASE_BUILD_DIR/subdir"
LIB_BUILD_DIR="$BUILD_DIR/lib"
INSTALL_DIR="$DIR/bin/php7"
SYMBOLS_DIR="$DIR/bin-debug/php7"
HEADERS_DIR="$DIR/headers"
SOURCE_HEADERS_DIR="$DIR/source-headers"

date > "$DIR/install.log" 2>&1

uname -a >> "$DIR/install.log" 2>&1
write_out "INFO" "Checking dependencies"

COMPILE_SH_DEPENDENCIES=( make autoconf automake m4 getconf gzip bzip2 bison g++ git cmake pkg-config re2c)
ERRORS=0
for(( i=0; i<${#COMPILE_SH_DEPENDENCIES[@]}; i++ ))
do
	type "${COMPILE_SH_DEPENDENCIES[$i]}" >> "$DIR/install.log" 2>&1 || { write_error "Please install \"${COMPILE_SH_DEPENDENCIES[$i]}\""; ((ERRORS++)); }
done

type wget >> "$DIR/install.log" 2>&1 || type curl >> "$DIR/install.log" || { write_error "Please install \"wget\" or \"curl\""; ((ERRORS++)); }

if [ "$(uname -s)" == "Darwin" ]; then
	type glibtool >> "$DIR/install.log" 2>&1 || { write_error "Please install GNU libtool"; ((ERRORS++)); }
	export LIBTOOL=glibtool
	export LIBTOOLIZE=glibtoolize
	export PATH="/opt/homebrew/opt/bison/bin:$PATH"
	[[ $(bison --version) == "bison (GNU Bison) 3."* ]] || { write_error "MacOS bundled bison is too old. Install bison using Homebrew and update your PATH variable according to its instructions before running this script."; ((ERRORS++)); }
else
	type libtool >> "$DIR/install.log" 2>&1 || { write_error "Please install \"libtool\" or \"libtool-bin\""; ((ERRORS++)); }
	export LIBTOOL=libtool
	export LIBTOOLIZE=libtoolize
fi

if [ $ERRORS -ne 0 ]; then
	exit 1
fi

export CC="gcc"
export CXX="g++"
export RANLIB=ranlib
export STRIP="strip"

COMPILE_FOR_ANDROID=no
HAVE_MYSQLI="--enable-mysqlnd --with-mysqli=mysqlnd"
COMPILE_TARGET=""
IS_CROSSCOMPILE="no"
IS_WINDOWS="no"
DO_OPTIMIZE="yes"
DO_STATIC="no"  # Changed to no to build shared library
DO_CLEANUP="yes"
COMPILE_DEBUG="no"
HAVE_VALGRIND="--without-valgrind"
HAVE_OPCACHE="yes"
HAVE_XDEBUG="no"
FSANITIZE_OPTIONS=""
FLAGS_LTO="-flto -fvisibility=hidden"
HAVE_OPCACHE_JIT="no"

COMPILE_GD="no"

PM_VERSION_MAJOR=""

DOWNLOAD_INSECURE="no"
DOWNLOAD_CACHE="$DIR/download_cache"
SEPARATE_SYMBOLS="no"

PHP_VERSION_BASE="auto"
BUILD_SHARED_LIB="yes"  # New flag to build as shared library

while getopts "::t:j:sdDxfgnva:P:c:l:Jiz:" OPTION; do

	case $OPTION in
		l)
			mkdir "$OPTARG" 2> /dev/null
			LIB_BUILD_DIR="$(cd $OPTARG; pwd)"
			write_out opt "Reusing previously built libraries in $LIB_BUILD_DIR if found"
			write_out WARNING "Reusing previously built libraries may break if different args were used!"
			;;
		c)
			mkdir "$OPTARG" 2> /dev/null
			DOWNLOAD_CACHE="$(cd $OPTARG; pwd)"
			write_out opt "Caching downloaded files in $DOWNLOAD_CACHE and reusing if available"
			;;
		t)
			write_out "opt" "Set target to $OPTARG"
			COMPILE_TARGET="$OPTARG"
			;;
		j)
			write_out "opt" "Set make threads to $OPTARG"
			THREADS="$OPTARG"
			;;
		d)
			write_out "opt" "Will compile everything with debugging symbols, will not remove sources"
			COMPILE_DEBUG="yes"
			DO_CLEANUP="no"
			DO_OPTIMIZE="no"
			CFLAGS="$CFLAGS -g"
			CXXFLAGS="$CXXFLAGS -g"
			;;
		D)
			write_out "opt" "Compiling with separated debugging symbols, but leaving optimizations enabled"
			SEPARATE_SYMBOLS="yes"
			CFLAGS="$CFLAGS -g"
			CXXFLAGS="$CXXFLAGS -g"
			;;
		x)
			write_out "opt" "Doing cross-compile"
			IS_CROSSCOMPILE="yes"
			;;
		s)
			write_out "opt" "Will compile everything statically"
			DO_STATIC="yes"
			CFLAGS="$CFLAGS -static"
			;;
		f)
			write_out "deprecated" "The -f flag is deprecated, as optimizations are now enabled by default unless -d (debug mode) is specified"
			;;
		g)
			write_out "opt" "Will enable GD2"
			COMPILE_GD="yes"
			;;
		n)
			write_out "opt" "Will not remove sources after completing compilation"
			DO_CLEANUP="no"
			;;
		v)
			write_out "opt" "Will enable valgrind support in PHP"
			HAVE_VALGRIND="--with-valgrind"
			;;
		a)
			write_out "opt" "Will pass -fsanitize=$OPTARG to compilers and linkers"
			FSANITIZE_OPTIONS="$OPTARG"
			;;
		P)
			PM_VERSION_MAJOR="$OPTARG"
			;;
		J)
			write_out "opt" "Compiling JIT support in OPcache"
HAVE_OPCACHE_JIT="no"
			;;
		i)
			write_out "opt" "Disabling SSL certificate verification for downloads"
			write_out "WARNING" "This is a security risk, please only use this if you know what you are doing!"
			DOWNLOAD_INSECURE="yes"
			;;
		z)
			PHP_VERSION_BASE="$OPTARG"
			;;
		\?)
			write_error "Invalid option: -$OPTARG"
			exit 1
			;;
	esac
done

function php_version_id {
	local PHP_VERSION="$1"
	local PHP_VERSION_MAJOR=$(echo "$PHP_VERSION" | cut -d. -f1)
	local PHP_VERSION_MINOR=$(echo "$PHP_VERSION" | cut -d. -f2)
	#TODO: patch is a pain because of suffixes and we don't really need it anyway

	# Use this for switching PHP version specific logic
	local PHP_VERSION_ID=$(((PHP_VERSION_MAJOR * 10000) + (PHP_VERSION_MINOR * 100)))
	echo "$PHP_VERSION_ID"
}

PREFERRED_PHP_VERSION_BASE=""
case $PM_VERSION_MAJOR in
	5)
		PREFERRED_PHP_VERSION_BASE="8.2"
		;;
	"")
		write_error "Please specify PocketMine-MP major version target with -P (e.g. -P5)"
		exit 1
		;;
	\?)
		write_error "PocketMine-MP $PM_VERSION_MAJOR is not supported by this version of the build script"
		exit 1
		;;
esac

write_out "opt" "Compiling with configuration for PocketMine-MP $PM_VERSION_MAJOR"

if [ "$PHP_VERSION_BASE" == "auto" ]; then
	PHP_VERSION_BASE="$PREFERRED_PHP_VERSION_BASE"
elif [ "$PHP_VERSION_BASE" != "$PREFERRED_PHP_VERSION_BASE" ]; then
	#TODO: validate that this PHP version is able to be used
	write_out "WARNING" "$PHP_VERSION_BASE is not the default for PocketMine-MP $PM_VERSION_MAJOR"
	write_out "WARNING" "The build may fail, or you may not be able to use the resulting PHP binary"
fi

for version in "${PHP_VERSIONS[@]}"; do
	if [[ "$version" == "$PHP_VERSION_BASE."* ]]; then
		PHP_VERSION="$version"
		break
	fi
done

if [ "$PHP_VERSION" == "" ]; then
	write_error "Unsupported PHP base version $PHP_VERSION_BASE"
	write_error "Example inputs: 8.2, 8.3"
	exit 1
fi

PHP_VERSION_ID=$(php_version_id "$PHP_VERSION")
write_out "opt" "Selected PHP $PHP_VERSION ($PHP_VERSION_ID)"

if [ $PHP_VERSION_ID -ge 80500 ]; then
  EXT_PMMPTHREAD_VERSION="$EXT_PMMPTHREAD_VERSION_PHP85"
  EXT_XDEBUG_VERSION="$EXT_XDEBUG_VERSION_PHP85"
  EXT_IGBINARY_VERSION="$EXT_IGBINARY_VERSION_PHP85"
fi
if [ $PHP_VERSION_ID -ge 80400 ]; then
  HAVE_OPCACHE_JIT="yes"
fi
if [ "$HAVE_OPCACHE_JIT" == "yes" ]; then
  if [ $PHP_VERSION_ID -lt 80400 ]; then
    write_out "WARNING" "JIT in versions below PHP 8.4 is highly unstable and not recommended"
  else
    write_out "WARNING" "JIT in PHP 8.4 has not been tested, use it with caution"
  fi
else
  write_out "INFO" "JIT support in OPcache won't be compiled"
fi

#Needed to use aliases
shopt -s expand_aliases
type wget >> "$DIR/install.log" 2>&1
if [ $? -eq 0 ]; then
	wget_flags=""
	if [ "$DOWNLOAD_INSECURE" == "yes" ]; then
		wget_flags="--no-check-certificate"
	fi
	alias _download_file="wget $wget_flags -nv -O -"
else
	type curl >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		curl_flags=""
		if [ "$DOWNLOAD_INSECURE" == "yes" ]; then
			curl_flags="--insecure"
		fi
		alias _download_file="curl $curl_flags --silent --show-error --location --globoff"
	else
		write_error "Neither curl nor wget found. Please install one and try again."
		exit 1
	fi
fi

function download_file {
	local url="$1"
	local prefix="$2"
	local cached_filename="$prefix-${url##*/}"

	if [[ "$DOWNLOAD_CACHE" != "" ]]; then
		if [[ ! -d "$DOWNLOAD_CACHE" ]]; then
			mkdir "$DOWNLOAD_CACHE" >> "$DIR/install.log" 2>&1
		fi
		if [[ -f "$DOWNLOAD_CACHE/$cached_filename" ]]; then
			echo "Cache hit for URL: $url" >> "$DIR/install.log"
		else
			echo "Downloading file to cache: $url" >> "$DIR/install.log"
			#download to a tmpfile first, so that we don't leave borked cache entries for later runs
			_download_file "$1" > "$DOWNLOAD_CACHE/.temp" 2>> "$DIR/install.log"
			mv "$DOWNLOAD_CACHE/.temp" "$DOWNLOAD_CACHE/$cached_filename" >> "$DIR/install.log" 2>&1
		fi
		cat "$DOWNLOAD_CACHE/$cached_filename" 2>> "$DIR/install.log"
	else
		echo "Downloading non-cached file: $url" >> "$DIR/install.log"
		_download_file "$1" 2>> "$DIR/install.log"
	fi
}

function download_from_mirror {
	download_file "https://github.com/pmmp/DependencyMirror/releases/download/mirror/$1" "$2"
}

#1: github repo
#2: tag or commit
#3: cache prefix
function download_github_src {
	download_file "https://github.com/$1/archive/$2.tar.gz" "$3"
}

GMP_ABI=""
TOOLCHAIN_PREFIX=""
OPENSSL_TARGET=""
CMAKE_GLOBAL_EXTRA_FLAGS=""

if [ "$IS_CROSSCOMPILE" == "yes" ]; then
	export CROSS_COMPILER="$PATH"
	if [ "$COMPILE_TARGET" == "android-aarch64" ]; then
		COMPILE_FOR_ANDROID=yes
		[ -z "$march" ] && march="armv8-a";
		[ -z "$mtune" ] && mtune=generic;
		TOOLCHAIN_PREFIX="aarch64-linux-musl"
		CONFIGURE_FLAGS="--host=$TOOLCHAIN_PREFIX"
		CFLAGS="-static -Os -ffunction-sections -fdata-sections $CFLAGS"
		CXXFLAGS="-static -Os -ffunction-sections -fdata-sections $CXXFLAGS"
		LDFLAGS="-static -static-libgcc -Wl,--gc-sections -Wl,--strip-all"
		DO_STATIC="yes"
		OPENSSL_TARGET="linux-aarch64"
		export ac_cv_func_fnmatch_works=yes #musl should be OK

		write_out "INFO" "Cross-compiling for Android ARMv8 (aarch64)"
	elif [ "$COMPILE_TARGET" == "android-arm" ]; then
		COMPILE_FOR_ANDROID=yes
		[ -z "$march" ] && march="armv7-a"
		[ -z "$mtune" ] && mtune="generic-armv7-a"
		TOOLCHAIN_PREFIX="arm-linux-musleabihf"
		CONFIGURE_FLAGS="--host=$TOOLCHAIN_PREFIX"
		CFLAGS="-march=$march -mtune=$mtune -mfpu=neon -mfloat-abi=hard -static -Os -ffunction-sections -fdata-sections $CFLAGS"
		CXXFLAGS="-march=$march -mtune=$mtune -mfpu=neon -mfloat-abi=hard -static -Os -ffunction-sections -fdata-sections $CXXFLAGS"
		LDFLAGS="-static -static-libgcc -lc -Wl,--gc-sections -Wl,--strip-all"
		DO_STATIC="yes"
		OPENSSL_TARGET="linux-generic32"
		export ac_cv_func_fnmatch_works=yes
		write_out "INFO" "Cross-compiling for Android ARMv7 (arm)"
	else
		write_error "Please supply a proper platform [android-aarch64, android-arm] to cross-compile"
		exit 1
	fi
else
	write_error "Cross-compilation is required for Android builds"
	exit 1
fi

if [ "$TOOLCHAIN_PREFIX" != "" ]; then
		export CC="$TOOLCHAIN_PREFIX-gcc"
		export CXX="$TOOLCHAIN_PREFIX-g++"
		export AR="$TOOLCHAIN_PREFIX-ar"
		export RANLIB="$TOOLCHAIN_PREFIX-ranlib"
		export CPP="$TOOLCHAIN_PREFIX-cpp"
		export LD="$TOOLCHAIN_PREFIX-ld"
		export STRIP="$TOOLCHAIN_PREFIX-strip"
fi

echo "#include <stdio.h>" > test.c
echo "int main(void){" >> test.c
echo "printf(\"Hello world\n\");" >> test.c
echo "return 0;" >> test.c
echo "}" >> test.c

type $CC >> "$DIR/install.log" 2>&1 || { write_error "Please install \"$CC\""; exit 1; }

if [ -z "$THREADS" ]; then
	write_out "WARNING" "Only 1 thread is used by default. Increase thread count using -j (e.g. -j 4) to compile faster."	
	THREADS=1;
fi
[ -z "$march" ] && march=native;
[ -z "$mtune" ] && mtune=native;
[ -z "$CFLAGS" ] && CFLAGS="";

if [ "$DO_STATIC" == "no" ]; then
	[ -z "$LDFLAGS" ] && LDFLAGS="-Wl,-rpath='\$\$ORIGIN/../lib' -Wl,-rpath-link='\$\$ORIGIN/../lib'";
fi

[ -z "$CONFIGURE_FLAGS" ] && CONFIGURE_FLAGS="";

if [ "$mtune" != "none" ]; then
	$CC -march=$march -mtune=$mtune $CFLAGS -o test test.c >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		CFLAGS="-march=$march -mtune=$mtune $CFLAGS"
	fi
else
	$CC -march=$march $CFLAGS -o test test.c >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		CFLAGS="-march=$march $CFLAGS"
	fi
fi

if [ "$DO_OPTIMIZE" != "no" ]; then
	#FLAGS_LTO="-fvisibility=hidden -flto"
	CFLAGS="$CFLAGS -Os"  # Use -Os for size optimization instead of -O2
	GENERIC_CFLAGS="$CFLAGS -ftree-vectorize -fomit-frame-pointer"
	$CC $CFLAGS $GENERIC_CFLAGS -o test test.c >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		CFLAGS="$CFLAGS $GENERIC_CFLAGS"
	fi
	#clang does not understand the following and will fail
	GCC_CFLAGS="$CFLAGS -funsafe-loop-optimizations -fpredictive-commoning -ftracer -ftree-loop-im -frename-registers -fcx-limited-range -funswitch-loops -fivopts -fno-gcse"
	$CC $CFLAGS $GCC_CFLAGS -o test test.c >> "$DIR/install.log" 2>&1
	if [ $? -eq 0 ]; then
		CFLAGS="$CFLAGS $GCC_CFLAGS"
	fi
	#TODO: -ftree-parallelize-loops requires OpenMP - not sure if it will provide meaningful improvements yet
fi

if [ "$FSANITIZE_OPTIONS" != "" ]; then
	CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" $CC -fsanitize=$FSANITIZE_OPTIONS -o asan-test test.c >> "$DIR/install.log" 2>&1 && \
		chmod +x asan-test >> "$DIR/install.log" 2>&1 && \
		./asan-test >> "$DIR/install.log" 2>&1 && \
		rm asan-test >> "$DIR/install.log" 2>&1
	if [ $? -ne 0 ]; then
		write_out "ERROR" "One or more sanitizers are not working. Check install.log for details."
		exit 1
	else
		write_out "INFO" "All selected sanitizers are working"
	fi
fi

rm test.* >> "$DIR/install.log" 2>&1
rm test >> "$DIR/install.log" 2>&1

export CC="$CC"
export CXX="$CXX"
export CFLAGS="-O2 -fPIC $CFLAGS"
export CXXFLAGS="$CFLAGS $CXXFLAGS"
export LDFLAGS="$LDFLAGS"
export CPPFLAGS="$CPPFLAGS"
export LIBRARY_PATH="$INSTALL_DIR/lib:$LIBRARY_PATH"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"

#some stuff (like curl) makes assumptions about library paths that break due to different behaviour in pkgconf vs pkg-config
export PKG_CONFIG_ALLOW_SYSTEM_LIBS="yes"
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS="yes"

rm -r -f "$BASE_BUILD_DIR" >> "$DIR/install.log" 2>&1
rm -r -f bin/ >> "$DIR/install.log" 2>&1
mkdir -m 0755 "$BASE_BUILD_DIR" >> "$DIR/install.log" 2>&1
mkdir -m 0755 "$BUILD_DIR" >> "$DIR/install.log" 2>&1
mkdir -m 0755 -p $INSTALL_DIR >> "$DIR/install.log" 2>&1
mkdir -m 0755 -p "$LIB_BUILD_DIR" >> "$DIR/install.log" 2>&1
mkdir -m 0755 -p "$HEADERS_DIR" >> "$DIR/install.log" 2>&1
mkdir -m 0755 -p "$SOURCE_HEADERS_DIR" >> "$DIR/install.log" 2>&1
cd "$BUILD_DIR"
set -e

#PHP
write_library "PHP" "$PHP_VERSION"
write_download

download_github_src "php/php-src" "php-$PHP_VERSION" "php" | tar -zx >> "$DIR/install.log" 2>&1
mv php-src-php-$PHP_VERSION php
write_done

function build_zlib {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--static"
	else
		local EXTRA_FLAGS="--shared"
	fi

	write_library zlib "$ZLIB_VERSION"
	local zlib_dir="./zlib-$ZLIB_VERSION"

	if cant_use_cache "$zlib_dir"; then
		rm -rf "$zlib_dir"
		write_download
		download_github_src "madler/zlib" "v$ZLIB_VERSION" "zlib" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$zlib_dir"
		RANLIB=$RANLIB ./configure --prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$zlib_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	if [ "$DO_STATIC" != "yes" ]; then
		rm -f "$INSTALL_DIR/lib/libz.a"
	fi
	write_done
}

function build_gmp {
	export jm_cv_func_working_malloc=yes
	export ac_cv_func_malloc_0_nonnull=yes
	export jm_cv_func_working_realloc=yes
	export ac_cv_func_realloc_0_nonnull=yes

	if [ "$IS_CROSSCOMPILE" == "yes" ]; then
		local EXTRA_FLAGS=""
	else
		local EXTRA_FLAGS="--disable-assembly"
	fi

	write_library gmp "$GMP_VERSION"
	local gmp_dir="./gmp-$GMP_VERSION"

	if cant_use_cache "$gmp_dir"; then
		rm -rf "$gmp_dir"
		write_download
		download_from_mirror "gmp-$GMP_VERSION.tar.xz" "gmp" | tar -Jx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$gmp_dir"
		RANLIB=$RANLIB ./configure --prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		--disable-posix-threads \
		--enable-static \
		--disable-shared \
		$CONFIGURE_FLAGS ABI="$GMP_ABI" >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$gmp_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_openssl {
	#OpenSSL
	OPENSSL_CMD="./config"
	if [ "$OPENSSL_TARGET" != "" ]; then
		local OPENSSL_CMD="./Configure $OPENSSL_TARGET"
	fi
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="no-shared -static"
	else
		local EXTRA_FLAGS="shared"
	fi

	write_library openssl "$OPENSSL_VERSION"
	local openssl_dir="./openssl-openssl-$OPENSSL_VERSION"

	if cant_use_cache "$openssl_dir"; then
		rm -rf "$openssl_dir"
		write_download
		download_github_src "openssl/openssl" "openssl-$OPENSSL_VERSION" "openssl" | tar -zx >> "$DIR/install.log" 2>&1

		write_configure
		cd "$openssl_dir"
		RANLIB=$RANLIB $OPENSSL_CMD \
		--prefix="$INSTALL_DIR" \
		--openssldir="$INSTALL_DIR" \
		--libdir="$INSTALL_DIR/lib" \
		no-asm \
		no-hw \
		no-engine \
		$EXTRA_FLAGS >> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$openssl_dir"
	fi
	write_install
	make install_sw >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_curl {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--enable-static --disable-shared"
	else
		local EXTRA_FLAGS="--disable-static --enable-shared"
	fi

	write_library curl "$CURL_VERSION"
	local curl_dir="./curl-$CURL_VERSION"
	if cant_use_cache "$curl_dir"; then
		rm -rf "$curl_dir"
		write_download
		download_github_src "curl/curl" "$CURL_VERSION" "curl" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$curl_dir"
		if [[ "$(uname -s)" == "Darwin" ]]; then
			sed -i'.bak' 's/^CURL_CONVERT_INCLUDE_TO_ISYSTEM//' ./configure.ac
		fi
		./buildconf --force >> "$DIR/install.log" 2>&1
		RANLIB=$RANLIB ./configure --disable-dependency-tracking \
		--enable-ipv6 \
		--enable-optimize \
		--enable-http \
		--enable-ftp \
		--disable-dict \
		--enable-file \
		--without-librtmp \
		--disable-gopher \
		--disable-imap \
		--disable-pop3 \
		--disable-rtsp \
		--disable-smtp \
		--disable-telnet \
		--disable-tftp \
		--disable-ldap \
		--disable-ldaps \
		--without-libidn \
		--without-libidn2 \
		--without-brotli \
		--without-nghttp2 \
		--without-zstd \
		--without-libpsl \
		--with-zlib="$INSTALL_DIR" \
		--with-ssl="$INSTALL_DIR" \
		--enable-threaded-resolver \
		--prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$curl_dir"
	fi

	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_yaml {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--disable-shared --enable-static"
	else
		local EXTRA_FLAGS="--enable-shared --disable-static"
	fi

	write_library yaml "$YAML_VERSION"
	local yaml_dir="./libyaml-$YAML_VERSION"
	if cant_use_cache "$yaml_dir"; then
		rm -rf "$yaml_dir"
		write_download
		download_github_src "yaml/libyaml" "$YAML_VERSION" "yaml" | tar -zx >> "$DIR/install.log" 2>&1
		cd "$yaml_dir"
		./bootstrap >> "$DIR/install.log" 2>&1

		write_configure

		RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		sed -i=".backup" 's/ tests win32/ win32/g' Makefile

		write_compile
		make -j $THREADS all >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$yaml_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_leveldb {
	write_library leveldb "$LEVELDB_VERSION"
	local leveldb_dir="./leveldb-$LEVELDB_VERSION"
	if cant_use_cache "$leveldb_dir"; then
		rm -rf "$leveldb_dir"
		write_download
		download_github_src "pmmp/leveldb" "$LEVELDB_VERSION" "leveldb" | tar -zx >> "$DIR/install.log" 2>&1

		write_configure
		cd "$leveldb_dir"
		if [ "$DO_STATIC" != "yes" ]; then
			local EXTRA_FLAGS="-DBUILD_SHARED_LIBS=ON"
		else
			local EXTRA_FLAGS=""
		fi
		cmake . \
			-DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
			-DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
			-DCMAKE_INSTALL_LIBDIR=lib \
			-DLEVELDB_BUILD_TESTS=OFF \
			-DLEVELDB_BUILD_BENCHMARKS=OFF \
			-DLEVELDB_SNAPPY=OFF \
			-DLEVELDB_ZSTD=OFF \
			-DLEVELDB_TCMALLOC=OFF \
			-DCMAKE_BUILD_TYPE=Release \
			$CMAKE_GLOBAL_EXTRA_FLAGS \
			$EXTRA_FLAGS \
			>> "$DIR/install.log" 2>&1

		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$leveldb_dir"
	fi

	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libpng {
	if [ "$DO_STATIC" == "yes" ]; then
		local PNG_EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
	else
		local PNG_EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
	fi

	write_library libpng "$LIBPNG_VERSION"
	local libpng_dir="./libpng-$LIBPNG_VERSION"
	if cant_use_cache "$libpng_dir"; then
		rm -rf "$libpng_dir"
		write_download
		download_from_mirror "libpng-$LIBPNG_VERSION.tar.gz" "libpng" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$libpng_dir"
		LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib" CPPFLAGS="$CPPFLAGS -I${INSTALL_DIR}/include" RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		$PNG_EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libpng_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libjpeg {
	if [ "$DO_STATIC" == "yes" ]; then
		local JPEG_EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
	else
		local JPEG_EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
	fi

	write_library libjpeg "$LIBJPEG_VERSION"
	local libjpeg_dir="./libjpeg-$LIBJPEG_VERSION"
	if cant_use_cache "$libjpeg_dir"; then
		rm -rf "$libjpeg_dir"
		write_download
		download_from_mirror "libjpeg-$LIBJPEG_VERSION.tar.gz" "libjpeg" | tar -zx >> "$DIR/install.log" 2>&1
		mv libjpeg "$libjpeg_dir"
		write_configure
		cd "$libjpeg_dir"
		LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib" CPPFLAGS="$CPPFLAGS -I${INSTALL_DIR}/include" RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		$JPEG_EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libjpeg_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libxml2 {
	write_library libxml2 "$LIBXML_VERSION"
	local libxml2_dir="./libxml2-$LIBXML_VERSION"

	if cant_use_cache "$libxml2_dir"; then
		rm -rf "$libxml2_dir"
		write_download
		download_from_mirror "libxml2-v$LIBXML_VERSION.tar.gz" "libxml2" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$libxml2_dir"
		if [ "$DO_STATIC" == "yes" ]; then
			local EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
		else
			local EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
		fi
		sed -i.bak 's{libtoolize --version{"$LIBTOOLIZE" --version{' autogen.sh #needed for glibtool on macos
		./autogen.sh --prefix="$INSTALL_DIR" \
			--without-iconv \
			--without-python \
			--without-lzma \
			--with-zlib="$INSTALL_DIR" \
			--config-cache \
			$EXTRA_FLAGS \
			$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libxml2_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libzip {
	#libzip
	if [ "$DO_STATIC" == "yes" ]; then
		local CMAKE_LIBZIP_EXTRA_FLAGS="-DBUILD_SHARED_LIBS=OFF"
	fi

	write_library libzip "$LIBZIP_VERSION"
	local libzip_dir="./libzip-$LIBZIP_VERSION"
	if cant_use_cache "$libzip_dir"; then
		rm -rf "$libzip_dir"
		write_download
		download_github_src "nih-at/libzip" "v$LIBZIP_VERSION" "libzip" | tar -zx >> "$DIR/install.log" 2>&1
		write_configure
		cd "$libzip_dir"

		#we're using OpenSSL for crypto
		cmake . \
			-DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
			-DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
			-DCMAKE_INSTALL_LIBDIR=lib \
			$CMAKE_LIBZIP_EXTRA_FLAGS \
			$CMAKE_GLOBAL_EXTRA_FLAGS \
			-DBUILD_TOOLS=OFF \
			-DBUILD_REGRESS=OFF \
			-DBUILD_EXAMPLES=OFF \
			-DBUILD_DOC=OFF \
			-DOPENSSL_USE_STATIC_LIBS=TRUE \
			-DENABLE_BZIP2=OFF \
			-DENABLE_COMMONCRYPTO=OFF \
			-DENABLE_GNUTLS=OFF \
			-DENABLE_MBEDTLS=OFF \
			-DENABLE_LZMA=OFF \
			-DENABLE_ZSTD=OFF \
			-DENABLE_OPENSSL=ON >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libzip_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_sqlite3 {
	if [ "$DO_STATIC" == "yes" ]; then
		local EXTRA_FLAGS="--enable-static=yes --enable-shared=no"
	else
		local EXTRA_FLAGS="--enable-static=no --enable-shared=yes"
	fi

	write_library sqlite3 "$SQLITE3_VERSION"
	local sqlite3_dir="./sqlite3-$SQLITE3_VERSION"

	if cant_use_cache "$sqlite3_dir"; then
		rm -rf "$sqlite3_dir"
		write_download
		download_from_mirror "sqlite-autoconf-$SQLITE3_VERSION.tar.gz" "sqlite3" | tar -zx >> "$DIR/install.log" 2>&1
		mv sqlite-autoconf-$SQLITE3_VERSION "$sqlite3_dir" >> "$DIR/install.log" 2>&1
		write_configure
		cd "$sqlite3_dir"
		LDFLAGS="$LDFLAGS -L${INSTALL_DIR}/lib" CPPFLAGS="$CPPFLAGS -I${INSTALL_DIR}/include" RANLIB=$RANLIB ./configure \
		--prefix="$INSTALL_DIR" \
		--disable-dependency-tracking \
		--enable-static-shell=no \
		$EXTRA_FLAGS \
		$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$sqlite3_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

function build_libdeflate {
	write_library libdeflate "$LIBDEFLATE_VERSION"
	local libdeflate_dir="./libdeflate-$LIBDEFLATE_VERSION"

	if cant_use_cache "$libdeflate_dir"; then
		rm -rf "$libdeflate_dir"
		write_download
		download_github_src "ebiggers/libdeflate" "$LIBDEFLATE_VERSION" "libdeflate" | tar -zx >> "$DIR/install.log" 2>&1
		cd "$libdeflate_dir"
		write_configure
		if [ "$DO_STATIC" == "yes" ]; then
			local EXTRA_FLAGS="--enable-shared=no --enable-static=yes"
		else
			local EXTRA_FLAGS="--enable-shared=yes --enable-static=no"
		fi
		cmake . \
			-DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
			-DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
			-DCMAKE_INSTALL_LIBDIR=lib \
			-DCMAKE_BUILD_TYPE=Release \
			$CMAKE_GLOBAL_EXTRA_FLAGS \
			$EXTRA_FLAGS >> "$DIR/install.log" 2>&1
		write_compile
		make -j $THREADS >> "$DIR/install.log" 2>&1 && mark_cache
	else
		write_caching
		cd "$libdeflate_dir"
	fi
	write_install
	make install >> "$DIR/install.log" 2>&1
	cd ..
	write_done
}

build_zlib
build_gmp
build_openssl
build_curl
build_yaml
if [ "$COMPILE_GD" == "yes" ]; then
	build_libpng
	build_libjpeg
fi
# build_libxml2
build_libzip
build_sqlite3
build_libdeflate

# PECL libraries

# 1: extension name
# 2: extension version
# 3: URL to get .tar.gz from
# 4: Name of extracted directory to move
function get_extension_tar_gz {
	echo -n "  $1: downloading $2..."
	download_file "$3" "php-$1" | tar -zx >> "$DIR/install.log" 2>&1
	mv "$4" "$BUILD_DIR/php/ext/$1"
	write_done
}

# 1: extension name
# 2: extension version
# 3: github user/org
# 4: github repo name
# 5: version prefix (optional)
function get_github_extension {
	get_extension_tar_gz "$1" "$2" "https://github.com/$3/$4/archive/$5$2.tar.gz" "$4-$2"
}

# 1: extension name
# 2: extension version
function get_pecl_extension {
	get_extension_tar_gz "$1" "$2" "https://pecl.php.net/get/$1-$2.tgz" "$1-$2"
}

cd "$BUILD_DIR/php"
write_out "PHP" "Fetching extensions"

# get_github_extension "pthreads" "$EXT_PMMPTHREAD_VERSION" "pmmp" "ext-pmmpthread"

get_github_extension "yaml" "$EXT_YAML_VERSION" "php" "pecl-file_formats-yaml"
# get_github_extension "leveldb" "$EXT_LEVELDB_VERSION" "php" "pecl-database-leveldb"
# get_github_extension "chunkutils2" "$EXT_CHUNKUTILS2_VERSION" "pmmp" "ext-chunkutils2"
get_github_extension "libdeflate" "$EXT_LIBDEFLATE_VERSION" "pmmp" "ext-libdeflate"

get_github_extension "xdebug" "$EXT_XDEBUG_VERSION" "xdebug" "xdebug"

#vget_github_extension "igbinary" "$EXT_IGBINARY_VERSION" "igbinary" "igbinary"

# get_github_extension "recursionguard" "$EXT_RECURSIONGUARD_VERSION" "pmmp" "ext-recursionguard"

write_library "PHP" "$PHP_VERSION"

write_configure
cd php
rm -f ./aclocal.m4 >> "$DIR/install.log" 2>&1
rm -rf ./autom4te.cache/ >> "$DIR/install.log" 2>&1
rm -f ./configure >> "$DIR/install.log" 2>&1

./buildconf --force >> "$DIR/install.log" 2>&1

# SIMPLE Android PHP build - just build it as static binary
RANLIB=$RANLIB CFLAGS="$CFLAGS $FLAGS_LTO" CXXFLAGS="$CXXFLAGS $FLAGS_LTO" LDFLAGS="$LDFLAGS $FLAGS_LTO" ./configure $PHP_OPTIMIZATION --prefix="$INSTALL_DIR" \
--exec-prefix="$INSTALL_DIR" \
--with-curl \
--with-zlib \
--with-zlib-dir="$INSTALL_DIR" \
--with-gmp \
--with-yaml \
--with-openssl \
--with-openssl-dir="$INSTALL_DIR" \
--with-zip \
--with-zip-dir="$INSTALL_DIR" \
$HAS_LIBJPEG \
$HAS_GD \
--without-readline \
$HAS_DEBUG \
--enable-mbstring \
--disable-mbregex \
--enable-calendar \
--enable-fileinfo \
--with-libxml \
--with-libxml-dir="$INSTALL_DIR" \
--enable-xml \
--enable-dom \
--enable-simplexml \
--enable-xmlreader \
--enable-xmlwriter \
--disable-cgi \
--disable-phpdbg \
--disable-session \
--without-pear \
--without-iconv \
--with-pdo-sqlite \
--with-sqlite3="$INSTALL_DIR" \
--with-pdo-mysql=mysqlnd \
--with-pic \
--enable-phar \
--enable-ctype \
--enable-sockets \
--enable-shared=no \
--enable-static=yes \
--enable-shmop \
--enable-zts \
$HAVE_PCNTL \
$HAVE_MYSQLI \
--enable-bcmath \
--enable-cli \
--enable-ftp \
--enable-opcache=$HAVE_OPCACHE \
--enable-opcache-jit=$HAVE_OPCACHE_JIT \
$HAVE_VALGRIND \
$CONFIGURE_FLAGS >> "$DIR/install.log" 2>&1

write_compile
make -j $THREADS >> "$DIR/install.log" 2>&1
write_install
make install >> "$DIR/install.log" 2>&1
write_done

cd "$DIR"

if [ "$DO_CLEANUP" == "yes" ]; then
	write_out "INFO" "Cleaning up"
	rm -r -f "$BUILD_DIR" >> "$DIR/install.log" 2>&1
	rm -f "$INSTALL_DIR/bin/phpize" >> "$DIR/install.log" 2>&1
	rm -f "$INSTALL_DIR/bin/php-config" >> "$DIR/install.log" 2>&1
fi

date >> "$DIR/install.log" 2>&1
