#!/bin/sh
                
# ---- this is added by cocoapods-binary ---
# Readlink cannot handle relative symlink well, so we override it to a new one
# If the path isn't an absolute path, we add a realtive prefix.
old_read_link=`which readlink`
readlink () {
    path=`$old_read_link $1`;
    if [ $(echo "$path" | cut -c 1-1) = '/' ]; then
        echo $path;
    else
        echo "`dirname $1`/$path";
    fi
}
# --- 
#!/bin/sh
set -e
set -u
set -o pipefail

function on_error {
  echo "$(realpath -mq "${0}"):$1: error: Unexpected failure"
}
trap 'on_error $LINENO' ERR

if [ -z ${FRAMEWORKS_FOLDER_PATH+x} ]; then
  # If FRAMEWORKS_FOLDER_PATH is not set, then there's nowhere for us to copy
  # frameworks to, so exit 0 (signalling the script phase was successful).
  exit 0
fi

echo "mkdir -p ${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

COCOAPODS_PARALLEL_CODE_SIGN="${COCOAPODS_PARALLEL_CODE_SIGN:-false}"
SWIFT_STDLIB_PATH="${DT_TOOLCHAIN_DIR}/usr/lib/swift/${PLATFORM_NAME}"

# Used as a return value for each invocation of `strip_invalid_archs` function.
STRIP_BINARY_RETVAL=0

# This protects against multiple targets copying the same framework dependency at the same time. The solution
# was originally proposed here: https://lists.samba.org/archive/rsync/2008-February/020158.html
RSYNC_PROTECT_TMP_FILES=(--filter "P .*.??????")

# Copies and strips a vendored framework
install_framework()
{
  if [ -r "${BUILT_PRODUCTS_DIR}/$1" ]; then
    local source="${BUILT_PRODUCTS_DIR}/$1"
  elif [ -r "${BUILT_PRODUCTS_DIR}/$(basename "$1")" ]; then
    local source="${BUILT_PRODUCTS_DIR}/$(basename "$1")"
  elif [ -r "$1" ]; then
    local source="$1"
  fi

  local destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

  if [ -L "${source}" ]; then
    echo "Symlinked..."
    source="$(readlink "${source}")"
  fi

  # Use filter instead of exclude so missing patterns don't throw errors.
  echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${source}\" \"${destination}\""
  rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${source}" "${destination}"

  local basename
  basename="$(basename -s .framework "$1")"
  binary="${destination}/${basename}.framework/${basename}"

  if ! [ -r "$binary" ]; then
    binary="${destination}/${basename}"
  elif [ -L "${binary}" ]; then
    echo "Destination binary is symlinked..."
    dirname="$(dirname "${binary}")"
    binary="${dirname}/$(readlink "${binary}")"
  fi

  # Strip invalid architectures so "fat" simulator / device frameworks work on device
  if [[ "$(file "$binary")" == *"dynamically linked shared library"* ]]; then
    strip_invalid_archs "$binary"
  fi

  # Resign the code if required by the build settings to avoid unstable apps
  code_sign_if_enabled "${destination}/$(basename "$1")"

  # Embed linked Swift runtime libraries. No longer necessary as of Xcode 7.
  if [ "${XCODE_VERSION_MAJOR}" -lt 7 ]; then
    local swift_runtime_libs
    swift_runtime_libs=$(xcrun otool -LX "$binary" | grep --color=never @rpath/libswift | sed -E s/@rpath\\/\(.+dylib\).*/\\1/g | uniq -u)
    for lib in $swift_runtime_libs; do
      echo "rsync -auv \"${SWIFT_STDLIB_PATH}/${lib}\" \"${destination}\""
      rsync -auv "${SWIFT_STDLIB_PATH}/${lib}" "${destination}"
      code_sign_if_enabled "${destination}/${lib}"
    done
  fi
}

# Copies and strips a vendored dSYM
install_dsym() {
  local source="$1"
  if [ -r "$source" ]; then
    # Copy the dSYM into a the targets temp dir.
    echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${source}\" \"${DERIVED_FILES_DIR}\""
    rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${source}" "${DERIVED_FILES_DIR}"

    local basename
    basename="$(basename -s .framework.dSYM "$source")"
    binary="${DERIVED_FILES_DIR}/${basename}.framework.dSYM/Contents/Resources/DWARF/${basename}"

    # Strip invalid architectures so "fat" simulator / device frameworks work on device
    if [[ "$(file "$binary")" == *"Mach-O "*"dSYM companion"* ]]; then
      strip_invalid_archs "$binary"
    fi

    if [[ $STRIP_BINARY_RETVAL == 1 ]]; then
      # Move the stripped file into its final destination.
      echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${DERIVED_FILES_DIR}/${basename}.framework.dSYM\" \"${DWARF_DSYM_FOLDER_PATH}\""
      rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${DERIVED_FILES_DIR}/${basename}.framework.dSYM" "${DWARF_DSYM_FOLDER_PATH}"
    else
      # The dSYM was not stripped at all, in this case touch a fake folder so the input/output paths from Xcode do not reexecute this script because the file is missing.
      touch "${DWARF_DSYM_FOLDER_PATH}/${basename}.framework.dSYM"
    fi
  fi
}

# Copies the bcsymbolmap files of a vendored framework
install_bcsymbolmap() {
    local bcsymbolmap_path="$1"
    local destination="${BUILT_PRODUCTS_DIR}"
    echo "rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${bcsymbolmap_path}" "${destination}""
    rsync --copy-links --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${bcsymbolmap_path}" "${destination}"
}

# Signs a framework with the provided identity
code_sign_if_enabled() {
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" -a "${CODE_SIGNING_REQUIRED:-}" != "NO" -a "${CODE_SIGNING_ALLOWED}" != "NO" ]; then
    # Use the current code_sign_identity
    echo "Code Signing $1 with Identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME}"
    local code_sign_cmd="/usr/bin/codesign --force --sign ${EXPANDED_CODE_SIGN_IDENTITY} ${OTHER_CODE_SIGN_FLAGS:-} --preserve-metadata=identifier,entitlements '$1'"

    if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
      code_sign_cmd="$code_sign_cmd &"
    fi
    echo "$code_sign_cmd"
    eval "$code_sign_cmd"
  fi
}

# Strip invalid architectures
strip_invalid_archs() {
  binary="$1"
  # Get architectures for current target binary
  binary_archs="$(lipo -info "$binary" | rev | cut -d ':' -f1 | awk '{$1=$1;print}' | rev)"
  # Intersect them with the architectures we are building for
  intersected_archs="$(echo ${ARCHS[@]} ${binary_archs[@]} | tr ' ' '\n' | sort | uniq -d)"
  # If there are no archs supported by this binary then warn the user
  if [[ -z "$intersected_archs" ]]; then
    echo "warning: [CP] Vendored binary '$binary' contains architectures ($binary_archs) none of which match the current build architectures ($ARCHS)."
    STRIP_BINARY_RETVAL=0
    return
  fi
  stripped=""
  for arch in $binary_archs; do
    if ! [[ "${ARCHS}" == *"$arch"* ]]; then
      # Strip non-valid architectures in-place
      lipo -remove "$arch" -output "$binary" "$binary"
      stripped="$stripped $arch"
    fi
  done
  if [[ "$stripped" ]]; then
    echo "Stripped $binary of architectures:$stripped"
  fi
  STRIP_BINARY_RETVAL=1
}


if [[ "$CONFIGURATION" == "Debug" ]]; then
  install_framework "${PODS_ROOT}/Alamofire/Alamofire.framework"
  install_dsym "${PODS_ROOT}/Alamofire/Alamofire.framework.dSYM"
  install_framework "${PODS_ROOT}/AlamofireImage/AlamofireImage.framework"
  install_dsym "${PODS_ROOT}/AlamofireImage/AlamofireImage.framework.dSYM"
  install_framework "${PODS_ROOT}/FaveButton/FaveButton.framework"
  install_dsym "${PODS_ROOT}/FaveButton/FaveButton.framework.dSYM"
  install_framework "${PODS_ROOT}/GTProgressBar/GTProgressBar.framework"
  install_dsym "${PODS_ROOT}/GTProgressBar/GTProgressBar.framework.dSYM"
  install_framework "${PODS_ROOT}/Highlightr/Highlightr.framework"
  install_dsym "${PODS_ROOT}/Highlightr/Highlightr.framework.dSYM"
  install_framework "${PODS_ROOT}/KSToastView/KSToastView.framework"
  install_dsym "${PODS_ROOT}/KSToastView/KSToastView.framework.dSYM"
  install_framework "${PODS_ROOT}/Koloda/Koloda.framework"
  install_dsym "${PODS_ROOT}/Koloda/Koloda.framework.dSYM"
  install_framework "${PODS_ROOT}/MaryPopin/MaryPopin.framework"
  install_dsym "${PODS_ROOT}/MaryPopin/MaryPopin.framework.dSYM"
  install_framework "${PODS_ROOT}/PureLayout/PureLayout.framework"
  install_dsym "${PODS_ROOT}/PureLayout/PureLayout.framework.dSYM"
  install_framework "${PODS_ROOT}/RSLoadingView/RSLoadingView.framework"
  install_dsym "${PODS_ROOT}/RSLoadingView/RSLoadingView.framework.dSYM"
  install_framework "${PODS_ROOT}/THLabel/THLabel.framework"
  install_dsym "${PODS_ROOT}/THLabel/THLabel.framework.dSYM"
  install_framework "${PODS_ROOT}/Version/Version.framework"
  install_dsym "${PODS_ROOT}/Version/Version.framework.dSYM"
  install_framework "${PODS_ROOT}/lottie-ios/Lottie.framework"
  install_dsym "${PODS_ROOT}/lottie-ios/Lottie.framework.dSYM"
  install_framework "${PODS_ROOT}/pop/pop.framework"
  install_dsym "${PODS_ROOT}/pop/pop.framework.dSYM"
fi
if [[ "$CONFIGURATION" == "Release" ]]; then
  install_framework "${PODS_ROOT}/Alamofire/Alamofire.framework"
  install_dsym "${PODS_ROOT}/Alamofire/Alamofire.framework.dSYM"
  install_framework "${PODS_ROOT}/AlamofireImage/AlamofireImage.framework"
  install_dsym "${PODS_ROOT}/AlamofireImage/AlamofireImage.framework.dSYM"
  install_framework "${PODS_ROOT}/FaveButton/FaveButton.framework"
  install_dsym "${PODS_ROOT}/FaveButton/FaveButton.framework.dSYM"
  install_framework "${PODS_ROOT}/GTProgressBar/GTProgressBar.framework"
  install_dsym "${PODS_ROOT}/GTProgressBar/GTProgressBar.framework.dSYM"
  install_framework "${PODS_ROOT}/Highlightr/Highlightr.framework"
  install_dsym "${PODS_ROOT}/Highlightr/Highlightr.framework.dSYM"
  install_framework "${PODS_ROOT}/KSToastView/KSToastView.framework"
  install_dsym "${PODS_ROOT}/KSToastView/KSToastView.framework.dSYM"
  install_framework "${PODS_ROOT}/Koloda/Koloda.framework"
  install_dsym "${PODS_ROOT}/Koloda/Koloda.framework.dSYM"
  install_framework "${PODS_ROOT}/MaryPopin/MaryPopin.framework"
  install_dsym "${PODS_ROOT}/MaryPopin/MaryPopin.framework.dSYM"
  install_framework "${PODS_ROOT}/PureLayout/PureLayout.framework"
  install_dsym "${PODS_ROOT}/PureLayout/PureLayout.framework.dSYM"
  install_framework "${PODS_ROOT}/RSLoadingView/RSLoadingView.framework"
  install_dsym "${PODS_ROOT}/RSLoadingView/RSLoadingView.framework.dSYM"
  install_framework "${PODS_ROOT}/THLabel/THLabel.framework"
  install_dsym "${PODS_ROOT}/THLabel/THLabel.framework.dSYM"
  install_framework "${PODS_ROOT}/Version/Version.framework"
  install_dsym "${PODS_ROOT}/Version/Version.framework.dSYM"
  install_framework "${PODS_ROOT}/lottie-ios/Lottie.framework"
  install_dsym "${PODS_ROOT}/lottie-ios/Lottie.framework.dSYM"
  install_framework "${PODS_ROOT}/pop/pop.framework"
  install_dsym "${PODS_ROOT}/pop/pop.framework.dSYM"
fi
if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
  wait
fi
