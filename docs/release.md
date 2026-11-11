# Release a version

A release is a tag `vX.Y.Z` on a commit of `main` whose full scenario run is green. It publishes the `cnpg-report` image and makes `pgfallback` gettable at that version. No e2e image is published: each run builds its own from the checkout.

1. Run every scenario on the commit you want to release:
   ```bash
   gh workflow run e2e.yml --ref main
   gh run list --workflow e2e.yml --limit 1 --json databaseId,headSha,url
   ```
   Wait until every job is green. Note the run's `url` and `headSha`: the commit to release, even if `main` moved since.
2. Tag that commit and push the tag:
   ```bash
   git tag vX.Y.Z <commit>
   git push origin vX.Y.Z
   ```
3. Wait for [`release.yml`](../.github/workflows/release.yml) on the tag to go green. It runs `ci.yml`, pushes `ghcr.io/djosh34/cnpg-report:vX.Y.Z`, pulls it back to render the samples and run the [container example](report.md#in-a-container), and last runs `go get` of `pgfallback` at the tag through proxy.golang.org.
4. Write the release notes: what changed for someone running scenarios, and the link to the green `e2e.yml` run.
   ```bash
   gh release create vX.Y.Z --title vX.Y.Z --notes-file notes.md
   ```

A tag is never moved or deleted. If `release.yml` fails and needs a fix, leave the failed tag as it is and release the fix as the next patch version: proxy.golang.org keeps the first version it saw for good.
