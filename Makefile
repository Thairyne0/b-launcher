.PHONY: build test app run dev clean install update vsix

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

# Aggiorna dal repo e reinstalla: chiude l'app (se aperta — con backend attivi l'app
# chiede conferma: meglio fermarli prima), pull fast-forward, rebuild e riapertura.
update:
	-osascript -e 'quit app "Backend Launcher"' 2>/dev/null || true
	git pull --ff-only
	$(MAKE) install

# Costruisce il pacchetto .vsix dell'estensione VSCode (installabile con
# "Installa estensione VSCode…" dall'app o con code --install-extension).
vsix:
	cd vscode-extension && npm install && npm run package
	@echo "✓ .vsix in vscode-extension/"

dev:
	swift run

clean:
	rm -rf .build dist
