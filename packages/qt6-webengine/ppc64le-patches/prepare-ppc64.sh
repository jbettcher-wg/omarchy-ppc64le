#! /bin/bash
#
# Prepare ppc64le patchset for qtwebengine from Chromium patches using
# - https://quickbuild.io/~raptor-engineering-public/+archive/ubuntu/chromium/ or
# - https://gitlab.raptorengineering.com/raptor-engineering-public/chromium/openpower-patches
#
# Usage
# - check the base Chromium release in CHROMIUM_VERSION
# - get the patches from the URLs above
# - run "prepare-ppc64.sh <path_to_chromium_patches>"
#

patch_cleanup ()
{
    file=$1
    patch=$2

    [ -f $file ] || { echo "File $file doesn't exist"; exit 1; }

    remove=$(echo $patch | sed -e 's@\/@\\\/@g')

    echo "Removing changes for $patch from $file ..."

    sed -i -e "/Index: chromium-[0-9\.]*\/${remove}/,/^Index:/ {
/Index: chromium-[0-9\.]*\/${remove}/d;
/^[-@=+ ]/d;
/^$/d;
}" $file

}

dir=$1

[ -d $dir/ppc64le ] || { echo "Path $dir/ppc64le doesn't exist"; exit 1; }

# remove patches for files not included in the bundled chromium
patch_cleanup $dir/ppc64le/third_party/0001-Add-PPC64-support-for-boringssl.patch third_party/boringssl/src/crypto/test/abi_test.h
patch_cleanup $dir/ppc64le/crashpad/0001-Implement-support-for-PPC64-on-Linux.patch third_party/crashpad/crashpad/minidump/test/minidump_context_test_util.cc
patch_cleanup $dir/ppc64le/crashpad/0001-Implement-support-for-PPC64-on-Linux.patch third_party/crashpad/crashpad/minidump/test/minidump_context_test_util.h
patch_cleanup $dir/ppc64le/crashpad/0001-Implement-support-for-PPC64-on-Linux.patch third_party/crashpad/crashpad/snapshot/test/test_cpu_context.cc
patch_cleanup $dir/ppc64le/crashpad/0001-Implement-support-for-PPC64-on-Linux.patch third_party/crashpad/crashpad/snapshot/test/test_cpu_context.h
patch_cleanup $dir/ppc64le/crashpad/0001-Implement-support-for-PPC64-on-Linux.patch third_party/crashpad/crashpad/test/linux/get_tls.cc
patch_cleanup $dir/ppc64le/crashpad/0001-Implement-support-for-PPC64-on-Linux.patch third_party/crashpad/crashpad/test/multiprocess_posix.cc

# concatenate the patches from the series file to a single patchset
echo "Creating patchset ..."
cat series.ppc64 | while read line; do
    case $line in
        \#*) ;;
        *) [ -z "$line" ] && continue; cat $dir/$line ;;
    esac
done > qtwebengine-chromium-ppc64.patch
