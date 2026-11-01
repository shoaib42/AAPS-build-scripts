#!/usr/bin/bash

cd $(dirname $0)
source platform
source xdrip
source rsync_build

# Parse options using getopts
while getopts ":fcrs" opt; do
    case $opt in
    f)
        FORCE_REBUILD=true
        ;;
    c)
        FORCE_CLEAN_CACHE=true
        ;;
    r)
        REINSTALL_CMDTOOLS=true
        ;;
    s)
        ONLY_RSYNC=true
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        exit 1
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        exit 1
        ;;
    esac
done

if [[ "$ONLY_RSYNC" = "true"  && "${RSYNC:-}" = "yes" ]]; then
    sync_and_prune_vps
    exit 0
fi

install_soft_stack
#yup its a chicken and egg
# refresh_git gets us what build tools and version we need
# but we can't force a complete wipe of the artificats if
# tools have drastically changed, best attempt is done
# during build phase, where gradlew clean is used in these cases
# if tools haven't changed then existing cache and artificats are used
refresh_git
init_build_targets
setup_java_tools
if [ $? -eq 0 ]; then
    if [ -n "$COMPILE_SDK" ]; then
        echo "COMPILE_SDK is set to $COMPILE_SDK"
    else
        notify_exit "COMPILE_SDK is not set. Exiting."
    fi
else
    notify_exit "setup_java_tools failed. Exiting."
fi
genkey
if [ -n "$LASTEST_VER" ] && { [ "$FORCE_REBUILD" = "true" ] || ! check_if_latest_build_exists_and_validate; }; then
    if [ "$FORCE_CLEAN_CACHE" = "true" ]; then
        force_clean_cache_fn
    fi
    build_aaps
    check_if_latest_build_exists_and_validate
fi

mirror_xdrip
# mirror_DiaKEM_G7
mirror_xdrip_nightly
if [[ $RSYNC == "yes" ]]; then
    sync_and_prune_vps
fi
