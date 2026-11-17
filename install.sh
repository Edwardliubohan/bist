#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

fail() { print -u2 -- "$*"; exit 1; }
install_dir="$HOME/Applications"
launch_app=true
while (( $# )); do
    case "$1" in
        --destination)
            (( $# >= 2 )) || fail 'Supply a folder after --destination.'
            install_dir="$2"
            shift 2
            ;;
        --no-open) launch_app=false; shift ;;
        --help)
            print 'Run ./install.sh to build, check, install and open bist.'
            print 'Use --destination FOLDER for another install folder, or --no-open to skip launching.'
            exit 0
            ;;
        *) fail "Unknown option $1. Run ./install.sh --help." ;;
    esac
done
install_dir="${install_dir:A}"
destination="$install_dir/bist.app"
[[ ! -L "$destination" ]] || fail "The app at $destination is a symbolic link. Choose another install folder."

check_not_running() {
    if ps -axww -o comm= | grep -Fx -- "$destination/Contents/MacOS/bist" >/dev/null; then
        fail 'Quit the installed bist app before installing or updating.'
    fi
}

check_bundle() {
    local bundle="$1"
    [[ -x "$bundle/Contents/MacOS/bist" ]] || fail "The app executable is missing from $bundle. Installation stopped."
    plutil -lint "$bundle/Contents/Info.plist"
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist") == bist ]] ||
        fail 'The app executable does not match its Info.plist. Installation stopped.'
    codesign --verify --deep --strict "$bundle"
}

check_not_running
./build.sh
check_bundle "$PWD/build/bist.app"
mkdir -p "$install_dir"
stage=$(mktemp -d "$install_dir/.bist-install.XXXXXX")
cleanup() {
    local install_exit_code=$?
    if [[ -e "$stage/previous.app" && ! -e "$destination" ]]; then
        if ! mv "$stage/previous.app" "$destination"; then
            print -u2 -- "The previous app is preserved at $stage/previous.app. Restore it before retrying."
            return 1
        fi
    fi
    rm -rf "$stage"
    return "$install_exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto build/bist.app "$stage/bist.app"
check_bundle "$stage/bist.app"
check_not_running
if [[ -e "$destination" ]]; then
    mv "$destination" "$stage/previous.app"
fi
mv "$stage/bist.app" "$destination"
print -- "Installed $destination"
if $launch_app; then
    open "$destination"
fi
