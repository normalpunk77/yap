.PHONY: test build run install clean

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

test:
	swift test

build:
	bash scripts/build-app.sh debug

run: build
	open build/Yap.app

# Install into /Applications so the app is findable in Spotlight and persists across
# rebuilds. Re-grant Microphone/Accessibility for this copy on first dictation (macOS
# ties those grants to the app's path).
install: build
	rm -rf /Applications/Yap.app
	ditto build/Yap.app /Applications/Yap.app
	$(LSREGISTER) -f /Applications/Yap.app
	@echo "Installed to /Applications/Yap.app — search 'Yap' in Spotlight."

clean:
	rm -rf .build build
