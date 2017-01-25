NAME=TheAmazingAudioEngine
XCODEPROJ=TheAmazingAudioEngine.xcodeproj
CONFIGURATION=Release
SCHEME="TheAmazingAudioEngine Framework"
SIMULATOR='platform=iOS Simulator,name=iPhone 6s Plus'

FRAMEWORK_FOLDER=$(NAME).framework

### Paths

BUILD_PATH=$(PWD)/Build
BUILD_PATH_SIMULATOR=$(BUILD_PATH)/$(CONFIGURATION)-iphonesimulator
BUILD_PATH_IPHONE=$(BUILD_PATH)/$(CONFIGURATION)-iphoneos
BUILD_PATH_UNIVERSAL=$(BUILD_PATH)/$(CONFIGURATION)-universal
BUILD_PATH_UNIVERSAL_FRAMEWORK_FOLDER=$(BUILD_PATH_UNIVERSAL)/$(FRAMEWORK_FOLDER)
BUILD_PATH_UNIVERSAL_FRAMEWORK_BINARY=$(BUILD_PATH_UNIVERSAL_FRAMEWORK_FOLDER)/$(NAME)

DISTRIBUTION_PATH=$(PWD)/Distribution
ZIPBALL_NAME=$(NAME).framework.zip
ZIPBALL_PATH=$(DISTRIBUTION_PATH)/$(ZIPBALL_NAME)

### Colors

RESET=\033[0;39m
RED=\033[0;31m
GREEN=\033[0;32m

### Tools

PRETTY=$(shell which xcpretty)

# Fallback to 'cat' if pretty is not installed
ifeq (, $(PRETTY))
PRETTY=cat
endif

### Actions

.PHONY: all archive clean test build validate zip

default: test

archive: build validate zip

test:
ifneq ($(TRAVIS),)
	open -b com.apple.iphonesimulator # fixes a bug when the simulator doesn't open in travis CI
endif
	xcodebuild -project $(XCODEPROJ) \
                   -scheme $(SCHEME) \
                   -sdk iphonesimulator \
                   -destination $(SIMULATOR) \
                   clean test \
                   CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
                   GCC_TREAT_WARNINGS_AS_ERRORS=YES \
                   ONLY_ACTIVE_ARCH=YES \
                   | $(PRETTY)

build:
	xcodebuild -project $(XCODEPROJ) \
                   -scheme $(SCHEME) \
                   -sdk iphonesimulator \
                   -destination $(SIMULATOR) \
                   -configuration $(CONFIGURATION) \
                   CONFIGURATION_BUILD_DIR=$(BUILD_PATH_SIMULATOR) \
                   clean build \
                   CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
                   GCC_TREAT_WARNINGS_AS_ERRORS=YES \
                   | $(PRETTY)
	xcodebuild -project $(XCODEPROJ) \
                   -scheme $(SCHEME) \
                   -sdk iphoneos \
                   -configuration $(CONFIGURATION) \
                   CONFIGURATION_BUILD_DIR=$(BUILD_PATH_IPHONE) \
                   clean build \
                   CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
                   GCC_TREAT_WARNINGS_AS_ERRORS=YES \
                   | $(PRETTY)

	rm -rf $(BUILD_PATH_UNIVERSAL)
	mkdir -p $(BUILD_PATH_UNIVERSAL)

	cp -Rv $(BUILD_PATH_IPHONE)/$(FRAMEWORK_FOLDER) $(BUILD_PATH_UNIVERSAL)

	lipo $(BUILD_PATH_SIMULATOR)/$(FRAMEWORK_FOLDER)/$(NAME) $(BUILD_PATH_IPHONE)/$(FRAMEWORK_FOLDER)/$(NAME) -create -output $(BUILD_PATH_UNIVERSAL_FRAMEWORK_BINARY)

validate: validate.i386 validate.x86_64 validate.armv7 validate.arm64

validate.%:
	@printf "Validating $*... "
	@lipo -info $(BUILD_PATH_UNIVERSAL_FRAMEWORK_BINARY) | grep -q '$*' && echo "$(GREEN)Passed$(RESET)" || (echo "$(RED)Failed$(RESET)"; exit 1)

zip:
	mkdir -p $(DISTRIBUTION_PATH)
	cp -R $(BUILD_PATH_UNIVERSAL)/$(FRAMEWORK_FOLDER) $(DISTRIBUTION_PATH)
	cd $(DISTRIBUTION_PATH) && zip -r -FS $(ZIPBALL_NAME) $(FRAMEWORK_FOLDER)

clean:
	rm -rf $(BUILD_PATH)
	rm -rf $(DISTRIBUTION_PATH)
