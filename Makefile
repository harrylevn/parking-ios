SCHEME      := Parking
PROJECT     := Parking.xcodeproj
DESTINATION := platform=iOS Simulator,name=iPhone 17 Pro
DERIVED     := .build/DerivedData

.PHONY: project build test uitest lint archive clean ci

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
