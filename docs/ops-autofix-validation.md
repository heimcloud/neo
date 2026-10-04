# Autofix: PR-loop validation

This file exists only on the validation branch `ops/validation-pr-loop-30`.
It checks that the autofix loop can push a branch to the fork, lab-test it, open a
pull request and address one review comment. It changes no code and no configuration.

**Do not merge.** Close the pull request when the check is done.

## Test plan

- [ ] Confirm this file is present on the PR branch and absent from `master`
- [ ] Confirm the diff is documentation-only (no Nix, CLI, or config changes)
- [ ] Confirm lab-test / CI accepts the branch
- [ ] Confirm a review reply can be posted and a follow-up commit lands on the same branch
- [ ] Close the PR without merging when validation is complete
