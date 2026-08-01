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
trap 'rm -f "$copy_flag" "$audit_flag" "$matches_file"' EXIT HUP INT TERM

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
					if [ ! -f "$dependency" ]; then
						echo "Missing Homebrew runtime library: $dependency" >&2
						exit 1
					fi

					target="$runtime_library_dir/$(basename -- "$dependency")"
					if [ ! -f "$target" ]; then
						cp -pL "$dependency" "$target"
						chmod u+w "$target"
						touch "$copy_flag"
					fi
					rewrite_dependency "$candidate" "$dependency" "$target"
					;;
				@rpath/*)
					target=$(find_packaged_library "$dependency")
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

echo "Bundled Homebrew libraries and converted Mach-O dependencies to portable paths."
