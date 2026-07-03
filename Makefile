.PHONY: build test app run dev clean

build:
	swift build

test:
	swift test

app:
	./scripts/make-app.sh

run: app
	open "dist/Backend Launcher.app"

dev:
	swift run

clean:
	rm -rf .build dist
