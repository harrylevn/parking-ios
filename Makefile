SCHEME      := Parking
PROJECT     := Parking.xcodeproj
SIM_PHONE   := iPhone 17 Pro
SIM_IPAD    := iPad Pro 13-inch (M5)
DESTINATION := platform=iOS Simulator,name=$(SIM_PHONE)
DERIVED     := .build/DerivedData

# The backend repo, cloned alongside this one. Override with PARKING_BACKEND=/path.
BACKEND     := $(or $(PARKING_BACKEND),$(CURDIR)/../parking-reservation)
COMPOSE     := $(BACKEND)/backend/docker-compose.yml

.PHONY: project build test uitest lint strings strings-check archive clean ci tls tls-pin pinning-demo rehearse trace concurrent device device-config \
        backend backend-now backend-off backend-reset backend-health backend-hour backend-down loadtest help

# Default target: list what there is to run.
help:
	@echo 'App'
	@echo '  make build          build the app'
	@echo '  make test           unit tests (no backend needed)'
	@echo '  make uitest         UI tests (no backend needed)'
	@echo '  make lint           SwiftLint, must be zero violations'
	@echo '  make strings        sync the String Catalog with the code'
	@echo '  make strings-check  fail if the catalog is behind or a key is untranslated'
	@echo '  make ci             everything CI runs'
	@echo '  make project        regenerate Parking.xcodeproj from project.yml'
	@echo '  make archive        archive, build number from the commit count'
	@echo ''
	@echo 'Backend (runs in the foreground — use a second terminal)'
	@echo '  make backend        gate ON, window 20:00 — the demo configuration'
	@echo '  make backend-now    gate ON, window = the current hour — open immediately'
	@echo '  make backend-off    gate BYPASSED — the shipped default, race code untested'
	@echo '  make backend-reset  empty the grid and the reservations, keep accounts'
	@echo '  make backend-health is it up?'
	@echo '  make backend-hour   which window hour and gate the running backend has'
	@echo '  make screenshots    regenerate docs/screenshots (needs the backend)'
	@echo '  make tls            TLS proxy on :8443 in front of the backend; prints the pin'
	@echo '  make pinning-demo   the app through the proxy, right pin then wrong pin'
	@echo '  make rehearse       the three demo rehearsals, unattended (ROUNDS=2 for two)'
	@echo '  make concurrent     two users confirm the same space at once: API and two simulators'
	@echo '  make device         build, install and launch on the connected iPhone, against this Mac'
	@echo '  make device-config  point Xcode device builds at this Mac (then press Run in Xcode)'
	@echo '  make trace          Instruments trace on the board: idle, then a 150-user race'
	@echo '  make backend-down   stop postgres and redis'
	@echo '  make loadtest       k6 stress scenario, 1000 VUs'
	@echo ''
	@echo 'Set PARKING_WINDOW_HOUR in the scheme to match a shifted backend window.'

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) build

# Unit tests, then the coverage gate: floors on Domain, Data and the view models, where the
# logic lives (scripts/coverage-gate.py says why not one overall number).
test: project
	rm -rf $(DERIVED)/unit-tests.xcresult
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) -only-testing:ParkingTests -enableCodeCoverage YES \
		-resultBundlePath $(DERIVED)/unit-tests.xcresult test
	python3 scripts/coverage-gate.py $(DERIVED)/unit-tests.xcresult

uitest: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) -only-testing:ParkingUITests test

lint:
	swiftlint lint --strict

# Regenerate every file in docs/screenshots from the real app against the live backend.
#
# Three passes, because a screenshot set needs two appearances and two devices and a test
# run is one of each: iPhone light, iPhone dark, then iPad. The appearance is set on the
# simulator rather than forced in the app, so what is captured is the palette the app
# actually adopts from the system.
#
# The env var needs the TEST_RUNNER_ prefix: xcodebuild passes those through to the test
# runner process and drops everything else, so a plain SCREENSHOTS=1 leaves the suite
# skipped — and a skipped suite still reports TEST SUCCEEDED, which is how it can look
# like it ran for weeks without producing anything.
SCREENSHOT_RUN = TEST_RUNNER_SCREENSHOTS=1 xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-derivedDataPath $(DERIVED) test

screenshots: project
	@$(MAKE) backend-health >/dev/null || (echo 'start the backend first: make backend-now'; exit 1)
	rm -rf $(DERIVED)/shots
	xcrun simctl boot '$(SIM_PHONE)' 2>/dev/null || true
	xcrun simctl ui '$(SIM_PHONE)' appearance light
	$(SCREENSHOT_RUN) -destination 'platform=iOS Simulator,name=$(SIM_PHONE)' \
		-resultBundlePath $(DERIVED)/shots/light.xcresult \
		-only-testing:ParkingUITests/ScreenshotTests \
		-skip-testing:ParkingUITests/ScreenshotTests/testCaptureDark \
		-skip-testing:ParkingUITests/ScreenshotTests/testCaptureIPad
	xcrun simctl ui '$(SIM_PHONE)' appearance dark
	$(SCREENSHOT_RUN) -destination 'platform=iOS Simulator,name=$(SIM_PHONE)' \
		-resultBundlePath $(DERIVED)/shots/dark.xcresult \
		-only-testing:ParkingUITests/ScreenshotTests/testCaptureDark
	xcrun simctl ui '$(SIM_PHONE)' appearance light
	xcrun simctl boot '$(SIM_IPAD)' 2>/dev/null || true
	xcrun simctl ui '$(SIM_IPAD)' appearance light
	$(SCREENSHOT_RUN) -destination 'platform=iOS Simulator,name=$(SIM_IPAD)' \
		-resultBundlePath $(DERIVED)/shots/ipad.xcresult \
		-only-testing:ParkingUITests/ScreenshotTests/testCaptureIPad
	@for bundle in light dark ipad; do \
		xcrun xcresulttool export attachments \
			--path $(DERIVED)/shots/$$bundle.xcresult \
			--output-path $(DERIVED)/shots/$$bundle-files >/dev/null; \
	done
	python3 scripts/collect-screenshots.py docs/screenshots \
		$(DERIVED)/shots/light-files $(DERIVED)/shots/dark-files $(DERIVED)/shots/ipad-files

# Build number derives from the commit count, never hand-edited (guardrail 6.4).
archive: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS' \
		-archivePath $(DERIVED)/Parking.xcarchive \
		CURRENT_PROJECT_VERSION=$$(git rev-list --count HEAD) \
		CODE_SIGNING_ALLOWED=NO archive

# The String Catalog follows the code: `strings` pulls in what the compiler extracted on the
# last build, `strings-check` fails if the catalog is behind or a key lacks its translation.
strings: build
	python3 scripts/check-strings.py --write

strings-check: build
	python3 scripts/check-strings.py

ci: lint build strings-check test uitest

clean:
	rm -rf $(DERIVED) $(PROJECT)

# --- Backend -----------------------------------------------------------------
# Wrappers over scripts/backend-up.sh so the commands are findable from here
# rather than only in docs/runbook.md. All of them need the backend cloned at
# $(BACKEND), on its master branch — main holds a LICENSE and nothing else.

# Certificate pinning (docs/security.md). `tls` terminates TLS on :8443 in front of the
# backend and prints the pin; `pinning-demo` runs the app through it with the right pin and
# with a wrong one. Both need the backend up.
tls:
	./scripts/tls-proxy.sh

tls-pin:
	@./scripts/tls-proxy.sh pin

pinning-demo: project
	./scripts/pinning-demo.sh

# The day-9 rehearsals, unattended: gate proved on, won race, lost race, backend killed
# mid-reservation, each checked against the database. Takes over :8080. ROUNDS=2 for two.
rehearse: project
	./scripts/rehearse.sh $(or $(ROUNDS),1)

# Two users confirming the same space at the same time: TRIALS API races released together
# (default 20), then two simulators tapping Confirm at an agreed instant. Needs backend-now.
concurrent: project
	./scripts/concurrent.sh $(or $(TRIALS),20)

# The app on the connected iPhone, pointed at this Mac's backend over the local network.
# Needs Config/Local.xcconfig (see Config/Local.xcconfig.example) and the backend up.
device: project
	./scripts/device.sh

# Only writes Config/Device.xcconfig, for building and running from Xcode instead.
device-config:
	./scripts/device.sh --config-only

# Instruments trace of the app on the board: idle under the poll, then a 150-user race.
# Needs the backend up with the window open. Summarise with scripts/trace-summary.py.
trace: project
	./scripts/trace.sh
	@./scripts/trace-summary.py "$$(ls -td .build/trace/board-*.trace | head -1)"

backend:
	./scripts/backend-up.sh

# Window set to the current hour, so the gate is on but already open. The app
# must agree: set PARKING_WINDOW_HOUR to the same hour in the scheme.
backend-now:
	@echo "==> window-hour $$(date +%-H); set PARKING_WINDOW_HOUR=$$(date +%-H) in the scheme"
	./scripts/backend-up.sh $$(date +%-H)

backend-off:
	./scripts/backend-up.sh off

backend-reset:
	docker exec parking-redis redis-cli FLUSHALL
	docker exec parking-postgres psql -U postgres -d parking -c \
		"TRUNCATE reservations, transactions RESTART IDENTITY CASCADE; \
		 UPDATE spaces SET user_id=NULL, plate_last3=NULL, reserved_date=NULL, version=0;"

backend-health:
	@curl -fsS localhost:8080/actuator/health && echo || echo 'backend is not up'

# The backend exposes no endpoint for its window hour, so read it from the running JVM's
# arguments. The app must be launched with the same value in PARKING_WINDOW_HOUR.
backend-hour:
	@pid=$$(lsof -tnP -iTCP:8080 -sTCP:LISTEN | head -1); \
	if [ -z "$$pid" ]; then echo 'backend is not up'; exit 1; fi; \
	args=$$(ps -o command= -p $$pid); \
	hour=$$(echo "$$args" | grep -oE 'window-hour=[0-9]+' | cut -d= -f2); \
	gate=$$(echo "$$args" | grep -oE 'bypass-time-check=(true|false)' | cut -d= -f2); \
	echo "window-hour: $${hour:-20 (default)}"; \
	if [ "$$gate" = false ]; then echo 'gate: ON'; \
	else echo 'gate: BYPASSED - every reservation succeeds regardless of the clock'; fi; \
	echo "launch the app with PARKING_WINDOW_HOUR=$${hour:-20}"

backend-down:
	docker compose -f $(COMPOSE) down

# Reports a crossed threshold even when behaving perfectly, because it counts
# 409 as a failure. The real pass criterion is reservation_success == 80 (D8).
loadtest:
	cd $(BACKEND) && k6 run --env BASE_URL=http://localhost:8080 \
		--env SCENARIO=stress tests/load-stress-test.js
