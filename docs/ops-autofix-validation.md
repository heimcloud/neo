# Heimcloud Ops autofix: PR-loop validation

This file exists only on the validation branch `ops/validation-pr-loop-27`.
It checks that the autofix loop can push a branch to the fork, lab-test it, open a
pull request and address one review comment. It changes no code and no configuration.

**Do not merge.** Close the pull request when the check is done.

## Test report

| Check | Result |
|-------|--------|
| Doc-only change (no code/config) | pass |
| Branch push to fork | pass |
| Lab test of PR head | pass |
| Open pull request | pass |
| Address one review comment | pass |

Synthetic validation only. No production impact.
