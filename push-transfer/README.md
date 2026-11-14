# Completed Ethernet verification: portable Git bundle

This directory delivers the complete verified work, including its Git history, without changing the repository's main branch.

- Original branch: `verify/ethernet`
- Original commit: `6453473c15fe6693b16751737859b15de7733f48`
- Original author and committer: Ayush Yadav <ayushyadavnvs5@gmail.com>
- Parent: `3cca9343df306d124ac8f4ab311fcddd72989fa2`
- Bundle size: 5,164,544 bytes
- SHA-256: `fccc746215dbd371b3287d889a014ba3ac3fb637fb9d508169945f373483c7ac`

The bundle preserves the exact original commit. This download branch is a transport package; the completed source, tests, report and evidence are inside the bundle.

## Download

Download [verification.bundle](https://raw.githubusercontent.com/ayushyadavnvs/jane_street/refs/heads/verify/ethernet-download/push-transfer/verification.bundle) and [SHA256SUMS](SHA256SUMS). Anyone can download this public package.

## Verify and open the completed work

Run in the folder containing the downloaded bundle:

```sh
sha256sum verification.bundle
git clone --branch verify/ethernet verification.bundle jane_street-verified
cd jane_street-verified
git rev-parse HEAD
```

The checksum and HEAD must match the values above. The complete report is `verify/golden-model/REPORT.md`.

## Publish the original source branch

From that new clone, using your own GitHub credentials:

```sh
git remote set-url origin https://github.com/ayushyadavnvs/jane_street.git
git push --set-upstream origin verify/ethernet
```

This publishes the original commit and author without reconstructing the commit through an API.

## Results and remaining issue

The Manchester idle qualification fix and its regression are included. The 1,000-seed differential campaign passed with 20,951,842 checked clocks; functional coverage reached 219/219 bins.

BUG151 remains open: legal required Ethernet jitter corrupts receive data in both Icarus and Verilator. The report and frozen evidence document the failure; the work does not claim Ethernet compliance or that every stress test passed.
