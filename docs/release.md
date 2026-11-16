# Release a version

A release is a tag `vX.Y.Z` on a commit of `main` where, on amd64 and arm64, the samples' full scenario run is green and each variant's run is red exactly on its `gaps.md`. It publishes the `cnpg-report` image. No e2e image is published: each run builds its own from the checkout.

1. Run every scenario of the samples on both architectures, on the commit you want to release:
   ```bash
   gh workflow run e2e.yml --ref main -f arm64=true
   gh run list --workflow e2e.yml --limit 1 --json databaseId,headSha,url
   ```
   Wait until every job is green. Note the run's `url` and `headSha`: the commit to release.
2. Run each variant of `variants/` the same way:
   ```bash
   gh workflow run e2e.yml --ref main -f variant=<variant> -f arm64=true
   gh run list --workflow e2e.yml --limit 1 --json databaseId,headSha,url
   ```
   Its `headSha` must be the commit to release; if `main` moved since step 1, start again at step 1. Check that its red scenarios are exactly the rows of its `gaps.md`, on both architectures ([a variant's gaps](e2e.md#a-variants-gaps)).
3. Tag the commit and push the tag:
   ```bash
   git tag vX.Y.Z <commit>
   git push origin vX.Y.Z
   ```
4. Wait for [`release.yml`](../.github/workflows/release.yml) on the tag to go green. It runs `ci.yml`, pushes `ghcr.io/djosh34/cnpg-report:vX.Y.Z`, and pulls it back to render the samples and run the [container example](report.md#in-a-container).
5. Write the release notes: what changed for someone running scenarios, and the links to the green samples run and each variant's run.
   ```bash
   gh release create vX.Y.Z --title vX.Y.Z --notes-file notes.md
   ```

A tag is never moved or deleted. If `release.yml` fails and needs a fix, leave the failed tag as it is and release the fix as the next patch version.
