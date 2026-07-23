#!/bin/sh
set -eux

cd "$(dirname $0)/.."

TARGET="${1:-all}"
JOBS="$(sysctl -n hw.logicalcpu)"

sign_macos_app() {
	if [ ! -d ITGmania.app ]; then
		echo "Missing ITGmania.app before code signing." >&2
		exit 1
	fi

	# CMake's linker signature only covers the executable. Seal the complete
	# bundle so macOS accepts the resources copied beside it.
	xattr -cr ITGmania.app
	codesign --force --deep --sign - ITGmania.app
	codesign --verify --deep --strict --verbose=2 ITGmania.app
}

case "$TARGET" in
	all|arm64|x86_64|portable) ;;
	*)
		echo "Usage: $0 [all|arm64|x86_64|portable]" >&2
		exit 2
		;;
esac

if [ "$TARGET" = "all" ] || [ "$TARGET" = "arm64" ]; then
	cmake -B Build/release-arm64 -DCMAKE_BUILD_TYPE=Release -DWITH_FULL_RELEASE=On -DCMAKE_OSX_ARCHITECTURES=arm64 -DWITH_CLUB_FANTASTIC=On
	cmake --build Build/release-arm64 -j "$JOBS"
	sign_macos_app
	cmake --build Build/release-arm64 --target package
	cmake -B Build/release-arm64 -DCMAKE_BUILD_TYPE=Release -DWITH_FULL_RELEASE=On -DCMAKE_OSX_ARCHITECTURES=arm64 -DWITH_CLUB_FANTASTIC=Off
	cmake --build Build/release-arm64 -j "$JOBS"
	sign_macos_app
	cmake --build Build/release-arm64 --target package
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "x86_64" ]; then
	cmake -B Build/release-x86_64 -DCMAKE_BUILD_TYPE=Release -DWITH_FULL_RELEASE=On -DCMAKE_OSX_ARCHITECTURES=x86_64 -DWITH_CLUB_FANTASTIC=On
	cmake --build Build/release-x86_64 -j "$JOBS"
	sign_macos_app
	cmake --build Build/release-x86_64 --target package
	cmake -B Build/release-x86_64 -DCMAKE_BUILD_TYPE=Release -DWITH_FULL_RELEASE=On -DCMAKE_OSX_ARCHITECTURES=x86_64 -DWITH_CLUB_FANTASTIC=Off
	cmake --build Build/release-x86_64 -j "$JOBS"
	sign_macos_app
	cmake --build Build/release-x86_64 --target package
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "portable" ]; then
	cmake -B Build/release-x86_64-portable -DCMAKE_BUILD_TYPE=Release -DWITH_FULL_RELEASE=On -DCMAKE_OSX_ARCHITECTURES=x86_64 -DWITH_CLUB_FANTASTIC=Off -DWITH_MACOS_PORTABLE_APP=On
	cmake --build Build/release-x86_64-portable -j "$JOBS"
	sign_macos_app
	# The portable app deliberately doesn't have a .dmg target, so we just move the .app bundle to the right place.
	mv ITGmania.app Build/release-x86_64-portable/ITGmania.app
fi
