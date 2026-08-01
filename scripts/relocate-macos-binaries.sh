#!/bin/sh

set -eu

if [ "$(uname -s)" != "Darwin" ]; then
	echo "Mach-O relocation must run on macOS." >&2
	exit 1
fi

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
	echo "Usage: $0 /path/to/install-root" >&2
	exit 1
fi

install_root=$(CDPATH='' cd -- "$1" && pwd)
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
brew_prefix=$(brew --prefix)
runtime_library_dir="$install_root/bin/third_party"
mkdir -p "$runtime_library_dir"

copy_flag=$(mktemp "${TMPDIR:-/tmp}/source-engine-copy.XXXXXX")
audit_flag=$(mktemp "${TMPDIR:-/tmp}/source-engine-audit.XXXXXX")
matches_file=$(mktemp "${TMPDIR:-/tmp}/source-engine-matches.XXXXXX")
source_map_file=$(mktemp "${TMPDIR:-/tmp}/source-engine-sources.XXXXXX")
probe_source=$(mktemp "${TMPDIR:-/tmp}/source-engine-sdl-probe.XXXXXX")
probe_binary=$(mktemp "${TMPDIR:-/tmp}/source-engine-sdl-probe-bin.XXXXXX")
trap 'rm -f "$copy_flag" "$audit_flag" "$matches_file" "$source_map_file" "$probe_source" "$probe_binary"' EXIT HUP INT TERM

find_macho_files()
{
	find "$install_root" -type f -print | while IFS= read -r candidate; do
		if file "$candidate" | grep -q 'Mach-O'; then
			printf '%s\n' "$candidate"
		fi
	done
}

dependency_paths()
{
	otool -L "$1" | sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p'
}

find_packaged_library()
{
	library_name=$(basename -- "$1")
	find "$install_root" -type f -name "$library_name" -print > "$matches_file"
	match_count=$(wc -l < "$matches_file" | tr -d ' ')

	if [ "$match_count" -ne 1 ]; then
		echo "Expected one packaged copy of $library_name, found $match_count." >&2
		return 1
	fi

	sed -n '1p' "$matches_file"
}

copy_homebrew_library()
{
	source_dependency=$1
	if [ ! -f "$source_dependency" ]; then
		echo "Missing Homebrew runtime library: $source_dependency" >&2
		return 1
	fi

	target="$runtime_library_dir/$(basename -- "$source_dependency")"
	if [ ! -f "$target" ]; then
		cp -pL "$source_dependency" "$target"
		chmod u+w "$target"
		printf '%s\t%s\n' "$target" "$(dirname -- "$source_dependency")" >> "$source_map_file"
		touch "$copy_flag"
	fi

	printf '%s\n' "$target"
}

resolve_rpath_dependency()
{
	rpath_candidate=$1
	rpath_dependency=$2
	library_name=$(basename -- "$rpath_dependency")
	find "$install_root" -type f -name "$library_name" -print > "$matches_file"
	match_count=$(wc -l < "$matches_file" | tr -d ' ')

	if [ "$match_count" -eq 1 ]; then
		sed -n '1p' "$matches_file"
		return
	fi

	if [ "$match_count" -gt 1 ]; then
		echo "Expected at most one packaged copy of $library_name, found $match_count." >&2
		return 1
	fi

	source_dir=$(awk -F '\t' -v candidate="$rpath_candidate" '$1 == candidate { print $2; exit }' "$source_map_file")
	if [ -z "$source_dir" ]; then
		echo "Cannot locate the Homebrew source for $rpath_dependency from $rpath_candidate." >&2
		return 1
	fi

	source_dependency="$source_dir/${rpath_dependency#@rpath/}"
	copy_homebrew_library "$source_dependency"
}

relative_from_loader()
{
	python3 - "$1" "$2" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

resolved_special_path()
{
	python3 - "$1" "$2" "$3" <<'PY'
import os
import sys

base, dependency, prefix = sys.argv[1:]
print(os.path.normpath(os.path.join(base, dependency[len(prefix):])))
PY
}

rewrite_dependency()
{
	candidate=$1
	old_dependency=$2
	target=$3
	candidate_dir=$(dirname -- "$candidate")
	relative_target=$(relative_from_loader "$candidate_dir" "$target")
	new_dependency="@loader_path/$relative_target"
	install_name_tool -change "$old_dependency" "$new_dependency" "$candidate"
}

# Homebrew's SDL2 compatibility layer opens this leaf name with dlopen(), so it
# does not appear in otool output and must be seeded explicitly.
sdl3_library="$(brew --prefix sdl3)/lib/libSDL3.dylib"
copy_homebrew_library "$sdl3_library" > /dev/null

# Repeat until every newly copied Homebrew library has had its own transitive
# dependencies copied and rewritten as well.
while :; do
	rm -f "$copy_flag"

	find_macho_files | while IFS= read -r candidate; do
		case "$candidate" in
			*.dylib)
				chmod u+w "$candidate"
				install_name_tool -id "@loader_path/$(basename -- "$candidate")" "$candidate"
				;;
		esac

		dependency_paths "$candidate" | while IFS= read -r dependency; do
			case "$dependency" in
				/System/Library/*|/usr/lib/*|@loader_path/*|@executable_path/*)
					;;
				"$repo_root"/build/*)
					target=$(find_packaged_library "$dependency")
					rewrite_dependency "$candidate" "$dependency" "$target"
					;;
				"$brew_prefix"/*)
					target=$(copy_homebrew_library "$dependency")
					rewrite_dependency "$candidate" "$dependency" "$target"
					;;
				@rpath/*)
					target=$(resolve_rpath_dependency "$candidate" "$dependency")
					rewrite_dependency "$candidate" "$dependency" "$target"
					;;
				*)
					echo "Unsupported runtime dependency in $candidate: $dependency" >&2
					exit 1
					;;
			esac
		done
	done

	if [ ! -e "$copy_flag" ]; then
		break
	fi
done

# install_name_tool invalidates existing signatures. Ad-hoc signing makes the
# modified ARM64 Mach-O files loadable while keeping Developer ID credentials
# out of this public workflow.
find_macho_files | while IFS= read -r candidate; do
	codesign --force --sign - --timestamp=none "$candidate"
done

rm -f "$audit_flag"
find_macho_files | while IFS= read -r candidate; do
	dependency_paths "$candidate" | while IFS= read -r dependency; do
		case "$dependency" in
			/System/Library/*|/usr/lib/*)
				;;
			@loader_path/*)
				candidate_dir=$(dirname -- "$candidate")
				resolved=$(resolved_special_path "$candidate_dir" "$dependency" '@loader_path/')
				if [ ! -f "$resolved" ]; then
					echo "Unresolved packaged dependency in $candidate: $dependency" >&2
					touch "$audit_flag"
				fi
				;;
			@executable_path/*)
				resolved=$(resolved_special_path "$install_root" "$dependency" '@executable_path/')
				if [ ! -f "$resolved" ]; then
					echo "Unresolved executable dependency in $candidate: $dependency" >&2
					touch "$audit_flag"
				fi
				;;
			*)
				echo "Non-portable dependency remains in $candidate: $dependency" >&2
				touch "$audit_flag"
				;;
		esac
	done

	codesign --verify --strict "$candidate"
done

if [ -e "$audit_flag" ]; then
	echo "Packaged Mach-O dependency audit failed." >&2
	exit 1
fi

cat > "$probe_source" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef struct SDL_version
{
	uint8_t major;
	uint8_t minor;
	uint8_t patch;
} SDL_version;

typedef void (*SDL_GetVersionFunction)(SDL_version *version);

int main(int argc, char **argv)
{
	void *library;
	SDL_GetVersionFunction get_version;
	SDL_version version;

	if (argc != 2) {
		return 2;
	}

	library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (library == NULL) {
		fprintf(stderr, "SDL runtime probe could not load SDL2: %s\n", dlerror());
		return 1;
	}

	get_version = (SDL_GetVersionFunction)dlsym(library, "SDL_GetVersion");
	if (get_version == NULL) {
		fprintf(stderr, "SDL runtime probe could not resolve SDL_GetVersion: %s\n", dlerror());
		dlclose(library);
		return 1;
	}

	get_version(&version);
	printf("SDL compatibility runtime loaded: %u.%u.%u\n",
	       (unsigned int)version.major,
	       (unsigned int)version.minor,
	       (unsigned int)version.patch);
	dlclose(library);
	return 0;
}
C

clang -arch arm64 -Wall -Wextra -Werror -x c "$probe_source" -o "$probe_binary"
DYLD_LIBRARY_PATH="$runtime_library_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
	"$probe_binary" "$runtime_library_dir/libSDL2-2.0.0.dylib"

echo "Bundled Homebrew libraries and converted Mach-O dependencies to portable paths."
