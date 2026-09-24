APP      = Videowall.app
BUNDLE_ID = dev.loopylim.videowall

all: $(APP)

$(APP): main.swift Info.plist Makefile
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O \
		-framework AppKit -framework AVFoundation \
		main.swift -o $(APP)/Contents/MacOS/Videowall
	cp Info.plist $(APP)/Contents/Info.plist
	touch $(APP)
	@codesign --force --deep --sign - $(APP)

clean:
	rm -rf $(APP)

install: $(APP)
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/

.PHONY: all clean install
