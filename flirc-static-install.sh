#!/usr/bin/env bash
#
# flirc-static-install.sh
#
# Install Flirc's official static-binary distribution (latest tarball from
# apt.flirc.tv) on RPM- and DEB-based Linux distributions, bypassing the
# upstream package repos.
#
# Why this exists:
#   - The fury.io RPM repo lags significantly behind upstream (was at
#     3.25.3 in May 2026 while upstream had shipped 3.27.19 the previous
#     August). Users with newer Flirc v2 ("marlin") hardware running
#     firmware 4.x get "unsupported fw" errors from the packaged GUI.
#   - The tarball at apt.flirc.tv/arch/x86_64/flirc.latest.x86_64.tar.gz
#     tracks current upstream releases. Marlin firmware support landed in
#     3.27.17.
#   - Flirc's upstream Flirc.desktop has 'Exec=Flirc' (no absolute path),
#     so graphical session menu launches resolve through the session
#     PATH, which on many distros doesn't have /usr/local/bin first.
#     We write a corrected .desktop with an absolute Exec=.
#
# This script:
#   1. Detects the distribution and installs runtime deps (Qt5, hidapi).
#   2. Downloads + extracts the latest static archive.
#   3. Installs Flirc, flirc_util, and (optionally) irtools to
#      /usr/local/bin/.
#   4. Writes Flirc's udev rules (vendor 20a0, multiple PIDs) to
#      /etc/udev/rules.d/99-flirc.rules and triggers udev to apply them
#      to any already-plugged-in Flirc device.
#   5. Writes a Flirc.desktop file to /usr/local/share/applications/
#      with an absolute Exec= path.
#
# Run as root (or via sudo). Re-running is safe and idempotent.
#
# Uninstall (manual):
#   sudo rm -f /usr/local/bin/{Flirc,flirc_util,irtools}
#   sudo rm -f /usr/local/share/applications/Flirc.desktop
#   sudo rm -f /usr/local/share/icons/hicolor/*/apps/Flirc.*
#   sudo rm -f /etc/udev/rules.d/99-flirc.rules
#   sudo udevadm control --reload-rules
#   command -v gtk-update-icon-cache > /dev/null && \
#       sudo gtk-update-icon-cache --force --quiet /usr/local/share/icons/hicolor

set -euo pipefail

# ---- Tunables --------------------------------------------------------------

TARBALL_URL="http://apt.flirc.tv/arch/x86_64/flirc.latest.x86_64.tar.gz"

INSTALL_PREFIX="/usr/local"
BIN_DIR="${INSTALL_PREFIX}/bin"
APP_DIR="${INSTALL_PREFIX}/share/applications"
UDEV_RULES_FILE="/etc/udev/rules.d/99-flirc.rules"
DESKTOP_FILE="${APP_DIR}/Flirc.desktop"

# Install irtools (IR protocol troubleshooting CLI)? Set to "no" to skip.
INSTALL_IRTOOLS="${INSTALL_IRTOOLS:-yes}"

# ---- Preflight -------------------------------------------------------------

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "This script must be run as root. Try: sudo $0" >&2
	exit 1
fi

arch="$(uname -m)"
if [ "${arch}" != "x86_64" ]; then
	echo "This script currently supports x86_64 only. Detected: ${arch}" >&2
	echo "If Flirc publishes a tarball for ${arch}, set TARBALL_URL accordingly and re-run." >&2
	exit 1
fi

if ! [ -r /etc/os-release ]; then
	echo "/etc/os-release not found; cannot detect distribution." >&2
	exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_LIKE="${ID_LIKE:-}"

TMPDIR_WORK="$(mktemp -d -t flirc-install.XXXXXX)"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT INT TERM

echo "Detected distribution: ${PRETTY_NAME:-${DISTRO_ID}}"

# ---- Distro matching -------------------------------------------------------

# distro_is fedora rhel ...
#   Returns 0 if $DISTRO_ID matches any of the args, OR if any arg appears
#   in the space-separated $DISTRO_LIKE list.
distro_is() {
	local target
	for target in "$@"; do
		if [ "${DISTRO_ID}" = "${target}" ]; then
			return 0
		fi
		case " ${DISTRO_LIKE} " in
			*" ${target} "*) return 0 ;;
		esac
	done
	return 1
}

# ---- Dependency installation ----------------------------------------------

# qt5-qtbase pulls in libQt5Core/Network/Xml/Widgets on Fedora; xmlpatterns
# is the one the upstream Flirc RPM forgets to require.
install_deps_dnf() {
	dnf install -y \
		curl tar \
		qt5-qtbase qt5-qtsvg qt5-qtxmlpatterns \
		hidapi
}

install_deps_apt() {
	apt-get update
	apt-get install -y \
		curl tar \
		libqt5core5a libqt5gui5 libqt5widgets5 libqt5network5 \
		libqt5svg5 libqt5xml5 libqt5xmlpatterns5 \
		libhidapi-hidraw0
}

install_deps_zypper() {
	# On openSUSE the runtime library packages use Capital-Q names with a
	# trailing 5 (libQt5Core5, libQt5Svg5, etc.), not the libqt5-<module>
	# pattern that some other openSUSE-family naming conventions suggest.
	# Only libqt5-qtbase exists as a Provides capability on libQt5Core5;
	# the rest of the modules don't, so name them directly.
	zypper --non-interactive install \
		curl tar \
		libQt5Core5 libQt5Gui5 libQt5Widgets5 libQt5Network5 \
		libQt5Svg5 libQt5Xml5 libQt5XmlPatterns5 \
		libhidapi-hidraw0
}

install_deps_pacman() {
	pacman -Sy --needed --noconfirm \
		curl tar \
		qt5-base qt5-svg qt5-xmlpatterns \
		hidapi
}

install_deps() {
	echo "Installing runtime dependencies..."
	if   distro_is fedora rhel centos rocky almalinux ol amzn; then
		install_deps_dnf
	elif distro_is debian ubuntu linuxmint pop neon raspbian elementary; then
		install_deps_apt
	elif distro_is opensuse opensuse-tumbleweed opensuse-leap suse sled sles; then
		install_deps_zypper
	elif distro_is arch manjaro endeavouros artix cachyos garuda; then
		install_deps_pacman
	else
		echo "Unsupported distribution: ${DISTRO_ID} (ID_LIKE=${DISTRO_LIKE})." >&2
		echo "Install Qt5 (Core, Network, Svg, Xml, XmlPatterns) and hidapi-hidraw" >&2
		echo "manually, then re-run with the dep-install step commented out." >&2
		exit 1
	fi
}

# ---- Tarball download + binary install -----------------------------------

# Populated by download_and_extract_tarball, consumed by later steps.
SRC_DIR=""
VERSION=""

download_and_extract_tarball() {
	echo "Downloading ${TARBALL_URL}..."
	curl -fSL --retry 3 -o "${TMPDIR_WORK}/flirc.tar.gz" "${TARBALL_URL}"

	echo "Extracting..."
	tar -xzf "${TMPDIR_WORK}/flirc.tar.gz" -C "${TMPDIR_WORK}"

	SRC_DIR="$(find "${TMPDIR_WORK}" -mindepth 1 -maxdepth 1 -type d -name 'Flirc-*' | head -n1)"
	if [ -z "${SRC_DIR}" ] || ! [ -d "${SRC_DIR}" ]; then
		echo "Could not find Flirc-*/ directory inside the tarball." >&2
		exit 1
	fi
	VERSION="$(basename "${SRC_DIR}" | sed 's/^Flirc-//')"
}

install_binaries() {
	echo "Installing Flirc ${VERSION} binaries to ${BIN_DIR}..."
	install -d "${BIN_DIR}"
	install -m 755 "${SRC_DIR}/Flirc"      "${BIN_DIR}/Flirc"
	install -m 755 "${SRC_DIR}/flirc_util" "${BIN_DIR}/flirc_util"
	if [ "${INSTALL_IRTOOLS}" = "yes" ] && [ -x "${SRC_DIR}/irtools" ]; then
		install -m 755 "${SRC_DIR}/irtools" "${BIN_DIR}/irtools"
	fi
}

# ---- Icon install (via AppImage that ships in the same tarball) -----------

# The standalone Flirc binary doesn't ship icon files, but the FlircApp
# AppImage in the same tarball contains a full hicolor icon tree. We use
# `--appimage-extract` (FUSE-free; just unpacks the embedded squashfs)
# to pull icons out, then rename FlircApp.* to Flirc.* so they match the
# Icon=Flirc reference in our .desktop file (and any pre-existing entry
# from the upstream RPM).
install_icon() {
	local appimage
	appimage="$(find "${SRC_DIR}" -maxdepth 1 -name 'FlircApp*.AppImage' -type f | head -n1)"
	if [ -z "${appimage}" ]; then
		echo "No AppImage found in tarball; skipping icon install."
		echo "(Menu entry will fall back to a generic icon.)"
		return 0
	fi

	echo "Extracting icons from $(basename "${appimage}")..."
	(
		cd "${TMPDIR_WORK}"
		"${appimage}" --appimage-extract > /dev/null 2>&1
	) || {
		echo "AppImage extraction failed; skipping icon install."
		echo "(Menu entry will fall back to a generic icon.)"
		return 0
	}

	local extracted="${TMPDIR_WORK}/squashfs-root"
	local hicolor_dst="${INSTALL_PREFIX}/share/icons/hicolor"
	local installed_any=no

	# --- Strategy 1: hicolor icon tree inside the AppImage ---
	# Best case: multi-resolution. Some AppImages ship the full Freedesktop
	# tree. Rename to Flirc.<ext> so our .desktop's Icon=Flirc resolves.
	local hicolor_src="${extracted}/usr/share/icons/hicolor"
	if [ -d "${hicolor_src}" ]; then
		local size_dir size_name icon
		while IFS= read -r -d '' size_dir; do
			size_name="$(basename "${size_dir}")"
			for icon in "${size_dir}/apps"/*.png "${size_dir}/apps"/*.svg; do
				[ -f "${icon}" ] && [ -s "${icon}" ] || continue
				install -d "${hicolor_dst}/${size_name}/apps"
				install -m 644 "${icon}" \
					"${hicolor_dst}/${size_name}/apps/Flirc.${icon##*.}"
				installed_any=yes
			done
		done < <(find "${hicolor_src}" -mindepth 1 -maxdepth 1 -type d -print0)
	fi

	# --- Strategy 2: .DirIcon at the squashfs root (AppImageKit standard) ---
	# Per the AppImage spec, .DirIcon is always a symlink (or sometimes a
	# regular file) pointing to the application's icon. Resolving it is
	# the canonical way to find the icon without guessing filenames.
	# Flirc's current AppImage uses this: .DirIcon -> Logo.svg.
	if [ "${installed_any}" = "no" ] && [ -e "${extracted}/.DirIcon" ]; then
		local real_icon ext target_size
		real_icon="$(readlink -f "${extracted}/.DirIcon" 2>/dev/null || true)"
		if [ -n "${real_icon}" ] && [ -f "${real_icon}" ] && [ -s "${real_icon}" ]; then
			ext="${real_icon##*.}"
			target_size="256x256"
			[ "${ext}" = "svg" ] && target_size="scalable"
			install -d "${hicolor_dst}/${target_size}/apps"
			install -m 644 "${real_icon}" \
				"${hicolor_dst}/${target_size}/apps/Flirc.${ext}"
			installed_any=yes
		fi
	fi

	# --- Strategy 3: parse Icon= from the embedded .desktop ---
	# Last resort: read the Icon= line from the AppImage's root .desktop
	# file (Flirc's says Icon=Logo) and look for a matching file. Skip
	# zero-byte placeholders like the default.png Flirc ships alongside
	# the real Logo.svg.
	if [ "${installed_any}" = "no" ]; then
		local desktop_in_appimage iconname
		desktop_in_appimage="$(find "${extracted}" -maxdepth 1 -name '*.desktop' -type f | head -n1)"
		if [ -n "${desktop_in_appimage}" ]; then
			iconname="$(grep -m1 '^Icon=' "${desktop_in_appimage}" | cut -d= -f2- | tr -d '[:space:]')"
			if [ -n "${iconname}" ]; then
				local candidate ext target_size
				for candidate in \
					"${extracted}/${iconname}.svg" \
					"${extracted}/${iconname}.png"; do
					[ -f "${candidate}" ] && [ -s "${candidate}" ] || continue
					ext="${candidate##*.}"
					target_size="256x256"
					[ "${ext}" = "svg" ] && target_size="scalable"
					install -d "${hicolor_dst}/${target_size}/apps"
					install -m 644 "${candidate}" \
						"${hicolor_dst}/${target_size}/apps/Flirc.${ext}"
					installed_any=yes
					break
				done
			fi
		fi
	fi

	if [ "${installed_any}" = "no" ]; then
		echo "No usable icon found inside the AppImage; skipping."
		echo "(Menu entry will fall back to a generic icon.)"
		return 0
	fi

	# Refresh GTK icon cache so menus pick up the new icon without a
	# session restart. KDE/Plasma rebuilds its own caches automatically.
	if command -v gtk-update-icon-cache > /dev/null; then
		gtk-update-icon-cache --force --quiet "${hicolor_dst}" 2>/dev/null || true
	fi

	echo "Icons installed under ${hicolor_dst}/*/apps/Flirc.*"
}

# ---- Udev rules -----------------------------------------------------------

install_udev_rules() {
	echo "Installing udev rules to ${UDEV_RULES_FILE}..."
	install -d "$(dirname "${UDEV_RULES_FILE}")"
	cat > "${UDEV_RULES_FILE}" <<'EOF'
# Flirc Devices
# Bootloader
SUBSYSTEM=="usb",    ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="20a0",  ATTR{idProduct}=="0000",  MODE="0666"
SUBSYSTEM=="usb",    ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="20a0",  ATTR{idProduct}=="0002",  MODE="0666"
SUBSYSTEM=="hidraw",                             ATTRS{idVendor}=="20a0", ATTRS{idProduct}=="0005", MODE="0666"

# Flirc Application
SUBSYSTEM=="usb",    ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="20a0",  ATTR{idProduct}=="0001",  MODE="0666"
SUBSYSTEM=="usb",    ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="20a0",  ATTR{idProduct}=="0004",  MODE="0666"
SUBSYSTEM=="hidraw",                             ATTRS{idVendor}=="20a0", ATTRS{idProduct}=="0006", MODE="0666"
EOF

	# Reload + re-trigger only Flirc devices so an already-plugged-in
	# device picks up the new permissions without a physical replug.
	if command -v udevadm > /dev/null; then
		udevadm control --reload-rules
		udevadm trigger --attr-match=idVendor=20a0 || true
	fi
}

# ---- Desktop entry --------------------------------------------------------

install_desktop_file() {
	echo "Installing desktop entry to ${DESKTOP_FILE}..."
	install -d "${APP_DIR}"
	# Upstream's /usr/share/applications/Flirc.desktop uses 'Exec=Flirc'
	# (no absolute path), which fails for graphical menu launches when
	# the session PATH doesn't have /usr/local/bin ahead of /usr/bin.
	# Use the absolute path so this entry always launches our binary.
	cat > "${DESKTOP_FILE}" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Flirc
Comment=Pair Your TV Remote with your PC
GenericName=Flirc
Exec=${BIN_DIR}/Flirc %u
Terminal=false
X-MultipleArgs=false
Icon=Flirc
Categories=Utility;
StartupNotify=true
EOF

	# /usr/local/share takes precedence over /usr/share in XDG_DATA_DIRS,
	# so this entry overrides any pre-existing one from the upstream RPM
	# or .deb package.
	if command -v update-desktop-database > /dev/null; then
		update-desktop-database "${APP_DIR}" > /dev/null 2>&1 || true
	fi
}

# ---- Run -----------------------------------------------------------------

install_deps
download_and_extract_tarball
install_binaries
install_icon
install_udev_rules
install_desktop_file

echo
echo "Flirc ${VERSION} installed."
echo
echo "  Binaries:    ${BIN_DIR}/Flirc, ${BIN_DIR}/flirc_util"
if [ "${INSTALL_IRTOOLS}" = "yes" ]; then
	echo "               ${BIN_DIR}/irtools"
fi
echo "  Icons:       ${INSTALL_PREFIX}/share/icons/hicolor/*/apps/Flirc.*"
echo "  Udev rules:  ${UDEV_RULES_FILE}"
echo "  Desktop:     ${DESKTOP_FILE}"
echo
echo "Launch from a terminal with 'Flirc' or from your application menu."
echo "If the device was plugged in before this script ran, the udev trigger"
echo "should have already updated its permissions; if not, replug the device."


# End of File #
