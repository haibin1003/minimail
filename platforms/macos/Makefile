# MiniMail Makefile — 编译 macOS 套壳应用
# 用法：
#   make         编译 .app 包
#   make run     编译并运行
#   make clean   清理

APP_NAME = MiniMail
APP_DIR = $(APP_NAME).app
CONTENTS_DIR = $(APP_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

SWIFT_SRC = $(APP_NAME).swift
INFO_PLIST = Info.plist
APP_ICON ?= AppIcon.icns

SWIFT_FLAGS = -O -parse-as-library -framework Cocoa -framework WebKit -framework SwiftUI
SWIFTC = swiftc

# 默认目标：编译 + 打包 .app
all: $(APP_DIR)

# 编译为 Mach-O 可执行文件
$(APP_NAME): $(SWIFT_SRC) $(INFO_PLIST)
	$(SWIFTC) $(SWIFT_FLAGS) \
		$(SWIFT_SRC) \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(INFO_PLIST) \
		-o $@

# 构建 .app 包
$(APP_DIR): $(APP_NAME)
	mkdir -p $(MACOS_DIR)
	mkdir -p $(RESOURCES_DIR)
	cp $(APP_NAME) $(MACOS_DIR)/
	cp $(INFO_PLIST) $(CONTENTS_DIR)/
	# 设置 App 包标识
	/usr/bin/plutil -replace CFBundleDisplayName -string "$(APP_NAME)" $(CONTENTS_DIR)/Info.plist 2>/dev/null || true
	# 如果有图标则复制
	if [ -n "$(APP_ICON)" ] && [ -f "$(APP_ICON)" ]; then \
		cp "$(APP_ICON)" $(RESOURCES_DIR)/; \
		/usr/bin/plutil -replace CFBundleIconFile -string "$(basename $(APP_ICON))" $(CONTENTS_DIR)/Info.plist; \
	fi

# 运行
run: $(APP_DIR)
	open $(APP_DIR)

# 打包 DMG
DMG_NAME = $(APP_NAME)-Installer.dmg
STAGING_DIR = $(APP_NAME)-dmg

dmg: $(APP_DIR)
	rm -rf $(STAGING_DIR)
	mkdir -p $(STAGING_DIR)
	cp -R $(APP_DIR) $(STAGING_DIR)/
	# 创建 /Applications 别名
	ln -s /Applications $(STAGING_DIR)/Applications
	# 生成 DMG（压缩只读映像）
	rm -f $(DMG_NAME)
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(STAGING_DIR) \
		-ov -format UDZO \
		$(DMG_NAME)
	rm -rf $(STAGING_DIR)
	@echo ""
	@echo "✅ DMG 打包完成: $(DMG_NAME)"
	@echo "   打开并拖拽 MiniMail.app 到 Applications 即可安装。"

# 清理
clean:
	rm -rf $(APP_NAME) $(APP_DIR) $(DMG_NAME) $(STAGING_DIR)

.PHONY: all run clean dmg
