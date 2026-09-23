# ─────────────────────────────────────────────────────────────────────────────
# VCAMLight — built for RootHide (Dopamine-RootHide).
#
# This project MUST be built with the roothide fork of Theos, which is where the
# `roothide` package scheme lives (vendor/mod/roothide):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
#
# With upstream theos the scheme below is silently ignored and you get a
# rootless package that Sileo on RootHide will not install into the hidden
# bootstrap, so nothing loads.
#
# What the roothide scheme does: rewrites the .deb Architecture to
# `iphoneos-arm64e` and installs into RootHide's randomized bootstrap path.
# ─────────────────────────────────────────────────────────────────────────────
THEOS_PACKAGE_SCHEME = roothide

# iPhone 7 Plus is A10 Fusion: arm64 only, there is no arm64e slice on this SoC
# (arm64e starts at A12). Building both would produce a package the loader
# cannot map.
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMLight

VCAMLight_FILES = Tweak.xm VCAMOverlay.mm
VCAMLight_CFLAGS = -fobjc-arc -fno-modules
VCAMLight_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo PhotosUI Foundation
VCAMLight_LIBRARIES = substrate

# -fno-modules keeps us off clang modules, so <roothide.h> is not pulled in
# implicitly. Link libroothide explicitly to keep the roothide API (jbroot)
# available; without this the roothide scheme emits a warning and the roothide
# helpers resolve to nothing.
VCAMLight_LDFLAGS = -lroothide
VCAMLight_ENTITLEMENTS = entitlements.plist

ADDITIONAL_CFLAGS = -fno-modules

include $(THEOS_MAKE_PATH)/tweak.mk
