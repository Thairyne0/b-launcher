.PHONY: build test app run dev clean install

build:
	swift build

test:
	swift test

app:
	./scripts/make-app.sh

run: app
	open "dist/Backend Launcher.app"

# Installa in /Applications (build locale: niente quarantena Gatekeeper)
install: app
	rm -rf "/Applications/Backend Launcher.app"
	cp -R "dist/Backend Launcher.app" "/Applications/Backend Launcher.app"
	open "/Applications/Backend Launcher.app"
	@echo "✓ Installato in /Applications"

dev:
	swift run

clean:
	rm -rf .build dist
