package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
)

// nodeImagesPinned checks that every image on every node is one the
// manifest names: an image it pins by digest (versions.Manifest.Pinned),
// matched by repository and digest, or one of k3s's airgap images
// (k3s.images), matched by repository and tag. An error names each other
// image. It runs once the cluster is up, before the scenario, and as the
// last line of always.feature.
func nodeImagesPinned(ctx context.Context) error {
	var errs []error
	for i := range nodeCount {
		node := nodeName(i)
		out, err := command(ctx, "docker", "exec", node, "crictl", "images", "-o", "json")
		if err != nil {
			errs = append(errs, err)
			continue
		}
		images, err := parseImages(out)
		if err != nil {
			errs = append(errs, fmt.Errorf("the images of %s: %w", node, err))
			continue
		}
		for _, image := range notInManifest(images, manifest) {
			errs = append(errs, fmt.Errorf("%s has an image the manifest does not name: %s", node, image))
		}
	}
	return errors.Join(errs...)
}

// nodeImage is an image of crictl images -o json.
type nodeImage struct {
	ID          string   `json:"id"`
	RepoTags    []string `json:"repoTags"`
	RepoDigests []string `json:"repoDigests"`
}

func parseImages(out string) ([]nodeImage, error) {
	var list struct {
		Images []nodeImage `json:"images"`
	}
	if err := json.Unmarshal([]byte(out), &list); err != nil {
		return nil, err
	}
	return list.Images, nil
}

// notInManifest names each image that is neither pinned by the manifest
// nor one of its airgap images, by its tags and digests.
func notInManifest(images []nodeImage, m *versions.Manifest) []string {
	airgap := map[string]bool{}
	for _, ref := range m.K3s.Images {
		airgap[versions.Reference(ref)] = true
	}
	var other []string
	for _, image := range images {
		known := slices.ContainsFunc(image.RepoTags, func(tag string) bool { return airgap[versions.Reference(tag)] }) ||
			slices.ContainsFunc(image.RepoDigests, func(d string) bool {
				name, digest, _ := strings.Cut(d, "@")
				return slices.Contains(m.Pinned(), versions.Repository(name)+"@"+digest)
			})
		if !known {
			other = append(other, strings.Join(append(append([]string{}, image.RepoTags...), image.RepoDigests...), " ")+" ("+image.ID+")")
		}
	}
	return other
}

// imagesPinned: every image on the nodes is one the manifest names.
func imagesPinned(ctx context.Context, _ *scenario, _ args) error {
	return nodeImagesPinned(ctx)
}
