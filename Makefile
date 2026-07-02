.PHONY: test build run install signing-identity clean

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

test:
	swift test

# Optional, run once: create a stable self-signed code-signing identity so the Keychain
# keeps trusting the app across rebuilds (no repeated "allow access" prompts).
signing-identity:
	bash scripts/make-signing-identity.sh

build:
	bash scripts/build-app.sh debug

run: build
	open build/Yap.app

# Install into /Applications so the app is findable in Spotlight and persists across
# rebuilds. Re-grant Microphone/Accessibility for this copy on first dictation (macOS
# ties those grants to the app's path). Installs a RELEASE (optimized) build — the
# debug -Onone binary is for development only — and restarts a running instance: the
# single-instance guard otherwise kept the OLD binary running while the new one sat
# unused on disk.
install:
	bash scripts/build-app.sh release
	rm -rf /Applications/Yap.app
	ditto build/Yap.app /Applications/Yap.app
	$(LSREGISTER) -f /Applications/Yap.app
	@pkill -x Yap 2>/dev/null && sleep 1 || true
	open /Applications/Yap.app
	@echo "Installed to /Applications/Yap.app (release build) and relaunched."

clean:
	rm -rf .build build
