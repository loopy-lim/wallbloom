APP      = Wallbloom.app
BUNDLE_ID = dev.loopylim.wallbloom

all: $(APP)

$(APP): engine/main.swift Info.plist Makefile
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O \
		-framework AppKit -framework AVFoundation \
		engine/main.swift -o $(APP)/Contents/MacOS/Wallbloom
	cp Info.plist $(APP)/Contents/Info.plist
	touch $(APP)
	@codesign --force --deep --sign - $(APP)

clean:
	rm -rf $(APP)

install: $(APP)
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/

.PHONY: all clean install
