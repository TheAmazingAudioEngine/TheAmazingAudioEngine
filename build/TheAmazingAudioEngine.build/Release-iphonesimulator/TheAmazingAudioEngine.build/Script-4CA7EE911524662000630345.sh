#!/bin/sh
#
# Universal static library script
# http://github.com/michaeltyson/iOS-Universal-Library-Template
#
# Version 2.4
# 
# Purpose:
#   Create a static library for iPhone from within XCode
#   Because Apple staff DELIBERATELY broke Xcode to make this impossible from the GUI (Xcode 3.2.3 specifically states this in the Release notes!)
#   ...no, I don't understand why they did this!
#
# Author: Adam Martin - http://twitter.com/redglassesapps
# Tweaked and made into an Xcode template by Michael Tyson - http://atastypixel.com/blog
# Based on: original script from Eonil (main changes: Eonil's script WILL NOT WORK in Xcode GUI - it WILL CRASH YOUR COMPUTER)
#
# More info: see this Stack Overflow question: http://stackoverflow.com/questions/3520977/build-fat-static-library-device-simulator-using-xcode-and-sdk-4

#################[ Tests: helps workaround any future bugs in Xcode ]########
#
DEBUG_THIS_SCRIPT="false"

if [ $DEBUG_THIS_SCRIPT = "true" ]
then
echo "########### TESTS #############"
echo "Use the following variables when debugging this script; note that they may change on recursions"
echo "BUILD_DIR = $BUILD_DIR"
echo "BUILD_ROOT = $BUILD_ROOT"
echo "CONFIGURATION_BUILD_DIR = $CONFIGURATION_BUILD_DIR"
echo "BUILT_PRODUCTS_DIR = $BUILT_PRODUCTS_DIR"
echo "CONFIGURATION_TEMP_DIR = $CONFIGURATION_TEMP_DIR"
echo "TARGET_BUILD_DIR = $TARGET_BUILD_DIR"
fi

if [ "true" == ${ALREADYINVOKED:-false} ]
then
# This is the other build, called from the original instance
exit 0
fi


# Find the BASESDK version number
SDK_VERSION=$(echo ${SDK_NAME} | grep -o '.\{3\}$')

# Next, work out if we're in SIM or DEVICE
if [ ${PLATFORM_NAME} = "iphonesimulator" ]
then
OTHER_SDK_TO_BUILD=iphoneos${SDK_VERSION}
else
OTHER_SDK_TO_BUILD=iphonesimulator${SDK_VERSION}
fi

echo "XCode has selected SDK: ${PLATFORM_NAME} with version: ${SDK_VERSION} (although back-targetting: ${IPHONEOS_DEPLOYMENT_TARGET})"
echo "...therefore, OTHER_SDK_TO_BUILD = ${OTHER_SDK_TO_BUILD}"

# Build the other architecture
echo "xcodebuild -configuration \"${CONFIGURATION}\" -target \"${TARGET_NAME}\" -sdk \"${OTHER_SDK_TO_BUILD}\" ${ACTION} RUN_CLANG_STATIC_ANALYZER=NO"
xcodebuild -project "${PROJECT_FILE_PATH}" -configuration "${CONFIGURATION}" -target "${TARGET_NAME}" -sdk "${OTHER_SDK_TO_BUILD}" ${ACTION} RUN_CLANG_STATIC_ANALYZER=NO BUILD_DIR="${BUILD_DIR}" BUILD_ROOT="${BUILD_ROOT}" ALREADYINVOKED="true"

# Merge built architectures
CURRENTCONFIG_DEVICE_DIR="${SYMROOT}/${CONFIGURATION}-iphoneos"
CURRENTCONFIG_SIMULATOR_DIR="${SYMROOT}/${CONFIGURATION}-iphonesimulator"
CURRENTCONFIG_UNIVERSAL_DIR="${SYMROOT}/${CONFIGURATION}-universal"

echo "Taking device build from: ${CURRENTCONFIG_DEVICE_DIR}"
echo "Taking simulator build from: ${CURRENTCONFIG_SIMULATOR_DIR}"
echo "...I will output a universal build to: ${CURRENTCONFIG_UNIVERSAL_DIR}"

if [ ! -e "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}" -o \
"${CURRENTCONFIG_DEVICE_DIR}/${EXECUTABLE_NAME}" -nt "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}" -o \
"${CURRENTCONFIG_SIMULATOR_DIR}/${EXECUTABLE_NAME}" -nt "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}" ]
then
mkdir -p "${CURRENTCONFIG_UNIVERSAL_DIR}"
rm -f "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}"

echo "lipo: for current configuration (${CONFIGURATION}) creating output file: ${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}"
lipo -create -output "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}" "${CURRENTCONFIG_DEVICE_DIR}/${EXECUTABLE_NAME}" "${CURRENTCONFIG_SIMULATOR_DIR}/${EXECUTABLE_NAME}"

echo "Copying universal build back over to ${CURRENTCONFIG_DEVICE_DIR} and ${CURRENTCONFIG_SIMULATOR_DIR}"
cp "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}" "${CURRENTCONFIG_DEVICE_DIR}/${EXECUTABLE_NAME}"
cp "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}" "${CURRENTCONFIG_SIMULATOR_DIR}/${EXECUTABLE_NAME}"
touch "${CURRENTCONFIG_UNIVERSAL_DIR}/${EXECUTABLE_NAME}"

# Also copy public headers
if [ -d "${CURRENTCONFIG_DEVICE_DIR}/${PUBLIC_HEADERS_FOLDER_PATH}" ]
then
mkdir -p "${CURRENTCONFIG_UNIVERSAL_DIR}/${PUBLIC_HEADERS_FOLDER_PATH}"
cp "${CURRENTCONFIG_DEVICE_DIR}/${PUBLIC_HEADERS_FOLDER_PATH}/"* "${CURRENTCONFIG_UNIVERSAL_DIR}/${PUBLIC_HEADERS_FOLDER_PATH}"
fi
else
echo "Everything up to date."
fi

