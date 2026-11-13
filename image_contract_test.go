package main

import (
	"os"
	"slices"
	"strings"
	"testing"
)

// TestDockerfileStampsTheVersions pins the build_info labels to the image's
// pins: the release pipeline's BUILD_VERSION build argument and the NUT_VERSION
// the image compiles, which a global ARG shares between the NUT build and the
// exporter build. An unstamped build reports "dev" and "unknown".
func TestDockerfileStampsTheVersions(t *testing.T) {
	t.Parallel()
	if version != "dev" || nutVersion != "unknown" {
		t.Errorf("unstamped versions = %q, %q, want dev, unknown", version, nutVersion)
	}
	b, err := os.ReadFile("Dockerfile")
	if err != nil {
		t.Fatalf("read Dockerfile: %v", err)
	}
	stages := map[string][]string{}
	stage := ""
	for line := range strings.SplitSeq(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || strings.HasPrefix(f[0], "#") {
			continue
		}
		if f[0] == "FROM" {
			stage = f[len(f)-1]
			continue
		}
		stages[stage] = append(stages[stage], strings.TrimSpace(line))
	}
	has := func(stage, want string) bool { return slices.Contains(stages[stage], want) }
	global := stages[""]
	if len(global) != 1 || !strings.HasPrefix(global[0], "ARG NUT_VERSION=v") {
		t.Errorf("global ARGs = %q, want only ARG NUT_VERSION=v<version>", global)
	}
	for _, s := range []string{"builder", "exporter-builder"} {
		if !has(s, "ARG NUT_VERSION") {
			t.Errorf("stage %s does not declare ARG NUT_VERSION", s)
		}
	}
	if !has("exporter-builder", "ARG BUILD_VERSION=dev") {
		t.Error("stage exporter-builder does not declare ARG BUILD_VERSION=dev")
	}
	var stamps bool
	for _, l := range stages["exporter-builder"] {
		if strings.Contains(l, "go build") &&
			strings.Contains(l, "-X main.version=${BUILD_VERSION}") &&
			strings.Contains(l, "-X main.nutVersion=${NUT_VERSION#v}") {
			stamps = true
		}
	}
	if !stamps {
		t.Error("the go build line does not pass -X main.version=${BUILD_VERSION} -X main.nutVersion=${NUT_VERSION#v}")
	}
}
