#!/usr/bin/env bash

set -e -o pipefail

# distro code name
DISTRO=$(basename "$0")
DISTRO=${DISTRO%.*}

if [ "${DISTRO}" = 'debian9' ]; then
    CODENAME='stretch'
    GEMFILE_LOCK='Debian9'
elif [ "${DISTRO}" = 'debian10' ]; then
    CODENAME='buster'
    GEMFILE_LOCK='Debian10'
elif [ "${DISTRO}" = 'ubuntu1604' ]; then
    CODENAME='xenial'
    GEMFILE_LOCK='Ubuntu1604'
elif [ "${DISTRO}" = 'ubuntu1804' ]; then
    CODENAME='bionic'
    GEMFILE_LOCK='Ubuntu1804'
elif [ "${DISTRO}" = 'ubuntu1810' ]; then
    CODENAME='cosmic'
    GEMFILE_LOCK='Ubuntu1810'
elif [ "${DISTRO}" = 'ubuntu1904' ]; then
    CODENAME='disco'
    GEMFILE_LOCK='Ubuntu1904'
elif [ "${DISTRO}" = 'ubuntu1910' ]; then
    CODENAME='eoan'
    GEMFILE_LOCK='Ubuntu1910'
elif [ "${DISTRO}" = 'ubuntu2004' ]; then
    CODENAME='focal'
    GEMFILE_LOCK='Ubuntu2004'
else
    echo "ERROR: Invalid target '${DISTRO}'" >&2
    exit 1
fi

###

cd "$(dirname "$0")"

BUILD_DIR=$(mktemp -d)
BUILD_DIR_SPKG=$(mktemp -d)
PACKAGES_DIR="${PWD}"
SOURCES_DIR="${PWD}/sources"

URL="$1"
PKG_VERSION=${2:-1}
LOCAL_URL=$(readlink -f "${URL}" || :)

SOURCE=`basename $URL` # opennebula-1.9.90.tar.gz
PACKAGE=${SOURCE%.tar.gz} # opennebula-1.9.90

NAME=$(echo "${PACKAGE}" | cut -d'-' -f1) # opennebula
VERSION=$(echo "${PACKAGE}" |cut -d'-' -f2) # 1.9.90
CONTACT=${CONTACT:-Unsupported Community Build}
BASE_NAME="${NAME}-${VERSION}-${PKG_VERSION}"
GEMS_RELEASE="${VERSION}-${PKG_VERSION}"
GIT_VERSION=${GIT_VERSION:-not known}
DATE=$(date -R)

# check for pbuilder-dist
if ! command -v pbuilder-dist >/dev/null 2>&1; then
    echo 'ERROR: Missing "pbuilder-dist" tool' >&2
    exit 1
fi

################################################################################
# Get all sources
################################################################################

cd "${BUILD_DIR_SPKG}"

shift || :
shift || :

echo '***** Prepare sources' >&2
for S in $URL $@; do
    case $S in
        http*)
            wget -q "${S}"
            ;;
        *)
            cp "$(readlink --canonicalize "${S}")" .
            ;;
    esac

    # with very first main source archive do
    # 1. unpack
    # 2. rename
    #   - from: opennebula-5.9.80.tar.gz
    #   - to:   opennebula_5.9.80.orig.tar.gz
    # 3. cd into the unpacked directory
    # 4. copy source package files into debian/
    if [ "${S}" = "${URL}" ]; then
        tar -xzf "${SOURCE}"
        rename 's/(opennebula)-/$1_/,s/\.tar\.gz/.orig.tar.gz/' "${SOURCE}"
        cd "${PACKAGE}"
        cp -r "${PACKAGES_DIR}/templates/${DISTRO}/" debian
    fi
done

# extra sources
wget -q http://downloads.opennebula.org/extra/xmlrpc-c.tar.gz
tar -czf build_opennebula.tar.gz \
    -C "${SOURCES_DIR}" \
    build_opennebula.sh \
    xml_parse_huge.patch

################################################################################
# Setup build environment
################################################################################

# if host uses package mirror, use this for pbuilder as well
# but not for ubutnu2004
if [ -f /etc/apt/sources.list.d/local-mirror.list -a $DISTRO != 'ubuntu2004' ]; then
    MIRRORSITE="$(dirname "$(cut -d' ' -f2 /etc/apt/sources.list.d/local-mirror.list | head -1)")"
    if [[ "${DISTRO}" =~ ubuntu ]]; then
        export MIRRORSITE="${MIRRORSITE}/ubuntu/"
    elif [[ "${DISTRO}" =~ debian ]]; then
        export MIRRORSITE="${MIRRORSITE}/debian/"
    fi
fi

# use APT http proxy for pbuilder
HTTP_PROXY="$(apt-config dump --format '%v' Acquire::http::proxy)"
PB_HTTP_PROXY="${HTTP_PROXY:+--http-proxy "${HTTP_PROXY}"}"

# prepare pbuilder environment
echo '***** Prepare build environment' >&2
pbuilder-dist "${CODENAME}" amd64 create --updates-only ${PB_HTTP_PROXY}

################################################################################
# Build Ruby gems
################################################################################

RUBYGEMS_REQ=''
if [[ "${BUILD_COMPONENTS}" =~ rubygems ]]; then
    echo '***** Downloading Ruby gems' >&2

    bash -x "${PACKAGES_DIR}/rubygems/download.sh" \
        "${BUILD_DIR_SPKG}/${NAME}_${VERSION}.orig.tar.gz" \
        "${GEMFILE_LOCK}" \
        "opennebula-rubygems-${VERSION}.tar"
fi

################################################################################
# Generate source package content
################################################################################

# process control template
_BUILD_COMPONENTS_UC=${BUILD_COMPONENTS^^}
m4 -D_VERSION_="${VERSION}" \
    -D_PKG_VERSION_="${PKG_VERSION}" \
    -D_CONTACT_="${CONTACT}" \
    -D_DATE_="${DATE}" \
    -D_RUBYGEMS_REQ_="${RUBYGEMS_REQ}" \
    ${_BUILD_COMPONENTS_UC:+ -D_WITH_${_BUILD_COMPONENTS_UC//[[:space:]]/_ -D_WITH_}_} \
    debian/control.m4 >debian/control

# generate changelog
cat <<EOF >debian/changelog
${NAME} (${VERSION}-${PKG_VERSION}) unstable; urgency=low

  * Build for ${VERSION}-${PKG_VERSION} (Git revision ${GIT_VERSION})

 -- ${CONTACT}  ${DATE}

EOF

echo "${GIT_VERSION}" > debian/gitversion

################################################################################
# Build the package
################################################################################

# build source package
echo '***** Building source package' >&2
dpkg-source --include-binaries -b .

# build binary package
echo '***** Building binary package' >&2
PBUILDER_DIR=$(mktemp -d)
pbuilder-dist "${CODENAME}" amd64 \
    build ${PB_HTTP_PROXY} \
    ../*dsc \
    --buildresult "${PBUILDER_DIR}"

mkdir "${BUILD_DIR}/source/"
mv "${PBUILDER_DIR}"/*debian* "${PBUILDER_DIR}"/*orig*  "${PBUILDER_DIR}"/*dsc "${BUILD_DIR}/source/"
mv "${PBUILDER_DIR}"/*.deb "${BUILD_DIR}"
rm -rf "${PBUILDER_DIR}"

################################################################################
# Create archive with all packages
################################################################################

echo '***** Creating tar archive' >&2
cd "${BUILD_DIR}"
tar -czf "${BASE_NAME}.tar.gz" \
    --owner=root --group=root  \
    --transform "s,^,${BASE_NAME}/," \
    *deb source/

# copy tar to ~/tar
rm -rf ~/tar
mkdir -p ~/tar
cp -f "${BASE_NAME}.tar.gz" ~/tar

################################################################################
# Cleanups
################################################################################

rm -rf "${BUILD_DIR}" "${BUILD_DIR_SPKG}"
