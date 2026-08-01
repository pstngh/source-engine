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

git submodule update --init --recursive

# Use explicit Homebrew dependencies instead of relying on the changing package
# set baked into GitHub's macOS runner image.
brew install pkgconf sdl2-compat sdl3 freetype fontconfig jpeg-turbo libpng curl zlib bzip2

pkg_config_path=${PKG_CONFIG_PATH:-}
cppflags=${CPPFLAGS:-}
ldflags=${LDFLAGS:-}

for formula in sdl2-compat freetype fontconfig jpeg-turbo libpng curl zlib bzip2; do
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

./waf configure \
	-T release \
	--build-games=cstrike \
	--disable-warns \
	--prefix="$install_prefix"

./waf install -j "$jobs"

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

{
	echo "Source Engine Counter-Strike: Source build"
	echo "Git commit: $(git rev-parse HEAD)"
	echo "Architecture: arm64"
	echo "Minimum macOS: $MACOSX_DEPLOYMENT_TARGET"
	echo "Build type: release"
	echo "Game: cstrike"
	echo "Mach-O files: $mach_o_count"
	echo "Runtime libraries: bundled and relocatable"
	echo "SDL runtime: SDL2 compatibility layer with bundled SDL3"
	echo "Code signature: ad hoc"
} > "$install_prefix/BUILD-INFO.txt"

echo "Apple Silicon Counter-Strike: Source build installed to $install_prefix"
