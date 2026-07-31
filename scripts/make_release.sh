#!/bin/bash
set -e

# CHANGE THIS to the project name.
PLUGIN_NAME=godot-storekit2

# Check if godot headers were generated.
if [[ $(find godot -name '*.gen.h' | wc -l | awk '{$1=$1};1') == 0 ]]; then
	./scripts/generate_headers.sh
fi

# Build archives. Simulator slices are built as well as device ones: a
# device-only xcframework makes every consuming project fail to link the moment
# anyone builds for the Simulator, and the AdMob plugin this sits beside ships
# both. SKIP_INSTALL=NO is what puts the static library into the archive.
for CONFIG in Debug Release; do
	LOWER=$(echo "${CONFIG}" | tr '[:upper:]' '[:lower:]')
	xcrun xcodebuild archive -project ${PLUGIN_NAME}.xcodeproj -scheme ${PLUGIN_NAME} \
		-destination "generic/platform=iOS" \
		-archivePath "bin/archives/${PLUGIN_NAME}.${LOWER}" -configuration ${CONFIG} \
		SKIP_INSTALL=NO
	xcrun xcodebuild archive -project ${PLUGIN_NAME}.xcodeproj -scheme ${PLUGIN_NAME} \
		-destination "generic/platform=iOS Simulator" \
		-archivePath "bin/archives/${PLUGIN_NAME}.${LOWER}.sim" -configuration ${CONFIG} \
		SKIP_INSTALL=NO
done

# Build xcframework
for LOWER in debug release; do
	xcrun xcodebuild -create-xcframework \
			-archive bin/archives/${PLUGIN_NAME}.${LOWER}.xcarchive -library lib${PLUGIN_NAME}.a \
			-archive bin/archives/${PLUGIN_NAME}.${LOWER}.sim.xcarchive -library lib${PLUGIN_NAME}.a \
			-output bin/xcframeworks/${PLUGIN_NAME}.${LOWER}.xcframework
done

# Move all to release folder
rm -rf bin/${PLUGIN_NAME}
mkdir -p bin/${PLUGIN_NAME}

touch bin/${PLUGIN_NAME}/.gdignore
cp ${PLUGIN_NAME}/${PLUGIN_NAME}.gdip bin/${PLUGIN_NAME}/
mv bin/xcframeworks/${PLUGIN_NAME}.debug.xcframework bin/${PLUGIN_NAME}/
mv bin/xcframeworks/${PLUGIN_NAME}.release.xcframework bin/${PLUGIN_NAME}/

rm -rf bin/xcframeworks
rm -rf bin/archives

cd bin
rm -rf ${PLUGIN_NAME}.zip
zip -r ${PLUGIN_NAME} ${PLUGIN_NAME}
cd ..
