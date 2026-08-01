#!/bin/sh

set -eu

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
	echo "This build must run natively on an Apple Silicon Mac (Darwin/arm64)." >&2
	exit 1
fi

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

install_prefix=${BUILD_PREFIX:-out/cstrike-macos-arm64}
jobs=${JOBS:-$(sysctl -n hw.ncpu)}

sdl_version=2.32.10
sdl_sha256=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
sdl_work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/source-engine-sdl2.XXXXXX")
sdl_archive="$sdl_work_dir/SDL2-$sdl_version.tar.gz"
sdl_source="$sdl_work_dir/SDL2-$sdl_version"
sdl_build="$sdl_work_dir/build"
sdl_prefix="$sdl_work_dir/install"
trap 'rm -rf "$sdl_work_dir"' EXIT HUP INT TERM

git submodule update --init --recursive

# Homebrew now supplies sdl2-compat, which translates SDL2 calls through SDL3.
# Source's legacy Cocoa/OpenGL window path needs native SDL2 behavior, so build
# the final official SDL2 release from its checksum-pinned source archive.
brew install pkgconf cmake freetype fontconfig jpeg-turbo libpng curl zlib bzip2
curl --fail --location --retry 3 \
	"https://github.com/libsdl-org/SDL/releases/download/release-$sdl_version/SDL2-$sdl_version.tar.gz" \
	--output "$sdl_archive"
printf '%s  %s\n' "$sdl_sha256" "$sdl_archive" | shasum -a 256 --check
tar -xzf "$sdl_archive" -C "$sdl_work_dir"
cmake -S "$sdl_source" -B "$sdl_build" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$sdl_prefix" \
	-DCMAKE_INSTALL_NAME_DIR="$sdl_prefix/lib" \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}" \
	-DSDL_SHARED=ON \
	-DSDL_STATIC=OFF \
	-DSDL_TEST=OFF \
	-DSDL_TESTS=OFF \
	-DSDL_RPATH=OFF
cmake --build "$sdl_build" --parallel "$jobs"
cmake --install "$sdl_build"

pkg_config_path=${PKG_CONFIG_PATH:-}
cppflags=${CPPFLAGS:-}
ldflags=${LDFLAGS:-}

pkg_config_path="$sdl_prefix/lib/pkgconfig:$pkg_config_path"
cppflags="-I$sdl_prefix/include -I$sdl_prefix/include/SDL2 $cppflags"
ldflags="-L$sdl_prefix/lib $ldflags"

for formula in freetype fontconfig jpeg-turbo libpng curl zlib bzip2; do
	formula_prefix=$(brew --prefix "$formula")
	pkg_config_path="$formula_prefix/lib/pkgconfig:$formula_prefix/share/pkgconfig:$pkg_config_path"
	cppflags="-I$formula_prefix/include $cppflags"
	ldflags="-L$formula_prefix/lib $ldflags"
done

export CC=clang
export CXX=clang++
export CFLAGS="-arch arm64 ${CFLAGS:-}"
export CXXFLAGS="-arch arm64 ${CXXFLAGS:-}"
export CPPFLAGS="$cppflags"
export LDFLAGS="-arch arm64 $ldflags"
export PKG_CONFIG_PATH="$pkg_config_path"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
export SDL2_RUNTIME_PREFIX="$sdl_prefix"

./waf configure \
	-T release \
	--build-games=cstrike \
	--disable-warns \
	--prefix="$install_prefix"

./waf install -j "$jobs"

# The filesystem probes the unprefixed module name first.  Ship the verified
# GameUI under both names so merged standalone installs cannot load a stale
# GameUI.dylib ahead of libGameUI.dylib.
cp -p "$install_prefix/bin/libGameUI.dylib" "$install_prefix/bin/GameUI.dylib"

launcher_script="$install_prefix/launch-cstrike.command"
{
	echo '#!/bin/sh'
	echo "cd \"\$(dirname \"\$0\")\" || exit 1"
	echo "runtime_library_dir=\"\$PWD/bin/third_party\""
	echo "export DYLD_LIBRARY_PATH=\"\$runtime_library_dir\${DYLD_LIBRARY_PATH:+:\$DYLD_LIBRARY_PATH}\""
	echo "exec ./hl2_launcher -game cstrike \"\$@\""
} > "$launcher_script"
chmod +x "$launcher_script"

if [ ! -d "$install_prefix/cstrike/bin" ]; then
	echo "Counter-Strike: Source client/server output was not installed." >&2
	exit 1
fi

bash scripts/relocate-macos-binaries.sh "$install_prefix"

mach_o_count=$(find "$install_prefix" -type f -exec file {} \; | awk '/Mach-O/ { count++ } END { print count + 0 }')
if [ "$mach_o_count" -eq 0 ]; then
	echo "The build produced no Mach-O binaries." >&2
	exit 1
fi

find "$install_prefix" -type f -print | while IFS= read -r candidate; do
	if file "$candidate" | grep -q 'Mach-O'; then
		architectures=$(lipo -archs "$candidate")
		if [ "$architectures" != "arm64" ]; then
			echo "Unexpected architecture '$architectures' in $candidate" >&2
			exit 1
		fi
	fi
done

for gameui_module in "$install_prefix/bin/GameUI.dylib" "$install_prefix/bin/libGameUI.dylib"; do
	if ! strings "$gameui_module" | grep -Fq "GameUI: standalone Apple Silicon menu enabled"; then
		echo "The Apple Silicon GameUI bootstrap is missing from $gameui_module." >&2
		exit 1
	fi
	if ! strings "$gameui_module" | grep -Fq "GameUI diagnostic: initialized macOS GameUI module"; then
		echo "The macOS GameUI diagnostic is missing from $gameui_module." >&2
		exit 1
	fi
	if ! strings "$gameui_module" | grep -Fq -- "-gameui_drawtest"; then
		echo "The macOS GameUI draw test is missing from $gameui_module." >&2
		exit 1
	fi
done

if ! strings "$install_prefix/bin/libengine.dylib" | grep -Fq "EngineVGui diagnostic: dispatching GameUI RunFrame"; then
	echo "The macOS EngineVGui diagnostic is missing from libengine.dylib." >&2
	exit 1
fi

if ! strings "$install_prefix/bin/libtogl.dylib" | grep -Fq "Apple ARM64 native sampler binding enabled"; then
	echo "The Apple Silicon native sampler path is missing from libtogl.dylib." >&2
	exit 1
fi

{
	echo "Source Engine Counter-Strike: Source build"
	echo "Git commit: $(git rev-parse HEAD)"
	echo "Architecture: arm64"
	echo "Minimum macOS: $MACOSX_DEPLOYMENT_TARGET"
	echo "Build type: release"
	echo "Game: cstrike"
	echo "Mach-O files: $mach_o_count"
	echo "Runtime libraries: bundled and relocatable"
	echo "SDL runtime: native SDL2 $sdl_version"
	echo "Code signature: ad hoc"
} > "$install_prefix/BUILD-INFO.txt"

echo "Apple Silicon Counter-Strike: Source build installed to $install_prefix"
