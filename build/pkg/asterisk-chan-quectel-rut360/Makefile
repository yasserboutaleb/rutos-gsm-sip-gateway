#
# asterisk-chan-quectel (vendored mpmc/RoEdAl rev 5552c365) + RUT360/RutOS coexistence patch
# Built with OpenWrt SDK 21.02.7 ath79/generic (gcc 8.4.0, musl 1.1.24) for RutOS 7.04.x
#
include $(TOPDIR)/rules.mk

PKG_NAME:=asterisk-chan-quectel
PKG_VERSION:=0.0.0-5552c365
PKG_RELEASE:=rut360.1
PKG_LICENSE:=GPL-2.0
PKG_INSTALL:=1

MODULES_DIR:=/usr/lib/asterisk/modules
CMAKE_OPTIONS += -DCHECK_SOURCE_DATE_EPOCH=OFF -DBUILD_OPENWRT_MAKEFILE=OFF -DASTERISK_VERSION_NUM=181501

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/asterisk-chan-quectel
  SUBMENU:=Telephony
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=asterisk +alsa-lib +libsqlite3
  TITLE:=Quectel channel driver (RUT360 / RutOS coexistence build)
endef

define Build/Prepare
	$(CP) /src/. $(PKG_BUILD_DIR)/
	rm -rf $(PKG_BUILD_DIR)/.git
	printf '%s\n' \
		'SET(CHAN_SOURCE_VERSION "5552c365bfb319eed7cbbf6300a67028ab70db9e")' \
		'SET(CHAN_SOURCE_TS 0)' \
		'SET(CHAN_VER_MAJOR "0")' 'SET(CHAN_VER_MINOR "0")' 'SET(CHAN_VER_PATCH "0")' 'SET(CHAN_VER_TWEAK "0")' \
		'SET(CHAN_STATUS "-5552c365-rut360.1")' \
		'SET(ASTERISK_VERSION_NUM "181501")' > $(PKG_BUILD_DIR)/pkg-vars.cmake
endef

define Package/asterisk-chan-quectel/install
	$(INSTALL_DIR) $(1)$(MODULES_DIR)
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)$(MODULES_DIR)/chan_quectel.so $(1)$(MODULES_DIR)
endef

$(eval $(call BuildPackage,asterisk-chan-quectel))
