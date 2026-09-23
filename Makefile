SCHEME      := Parking
PROJECT     := Parking.xcodeproj
DESTINATION := platform=iOS Simulator,name=iPhone 17 Pro
DERIVED     := .build/DerivedData

# The backend repo, cloned alongside this one. Override with PARKING_BACKEND=/path.
BACKEND     := $(or $(PARKING_BACKEND),$(CURDIR)/../parking-reservation)
COMPOSE     := $(BACKEND)/backend/docker-compose.yml

.PHONY: project build test uitest lint archive clean ci \
        backend backend-now backend-off backend-reset backend-health backend-down loadtest help

# Default target: list what there is to run.
help:
	@echo 'App'
	@echo '  make build          build the app'
	@echo '  make test           unit tests (no backend needed)'
	@echo '  make uitest         UI tests (no backend needed)'
	@echo '  make lint           SwiftLint, must be zero violations'
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
	@echo '  make backend-down   stop postgres and redis'
	@echo '  make loadtest       k6 stress scenario, 1000 VUs'
	@echo ''
	@echo 'Set PARKING_WINDOW_HOUR in the scheme to match a shifted backend window.'

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) build

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) -only-testing:ParkingTests test

uitest: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) -only-testing:ParkingUITests test

lint:
	swiftlint lint --strict

# Build number derives from the commit count, never hand-edited (guardrail 6.4).
archive: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'generic/platform=iOS' \
		-archivePath $(DERIVED)/Parking.xcarchive \
		CURRENT_PROJECT_VERSION=$$(git rev-list --count HEAD) \
		CODE_SIGNING_ALLOWED=NO archive

ci: lint build test uitest

clean:
	rm -rf $(DERIVED) $(PROJECT)

# --- Backend -----------------------------------------------------------------
# Wrappers over scripts/backend-up.sh so the commands are findable from here
# rather than only in docs/runbook.md. All of them need the backend cloned at
# $(BACKEND), on its master branch — main holds a LICENSE and nothing else.

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

backend-down:
	docker compose -f $(COMPOSE) down

# Reports a crossed threshold even when behaving perfectly, because it counts
# 409 as a failure. The real pass criterion is reservation_success == 80 (D8).
loadtest:
	cd $(BACKEND) && k6 run --env BASE_URL=http://localhost:8080 \
		--env SCENARIO=stress tests/load-stress-test.js
