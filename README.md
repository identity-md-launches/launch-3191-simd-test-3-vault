# SIMD TEST 3 vault set

**TEST ONLY. SIMD TEST 3 vault set. Not the real SIMD. Do not buy.**

This project implements the four contracts for the **SIMD TEST 3 - DO NOT BUY** launch on Robinhood Chain (4663). The test token has no value. This project deploys application contracts; it does not implement or deploy the launch token or its hook.

`SIMDVault` constructs and permanently links `StakeRewards`, `JobsVault`, and `SimdAirdrop`. There is no owner, general administrator, upgrade mechanism, pause, oracle, arbitrary execution, or recovery/withdrawal function. The fixed dev wallet has exactly two one-time setup actions: pay for a launch, and bind its factory position and token. The child contracts accept configuration only from their vault; its code provides no way to reconfigure them.

## Build and tests

```sh
forge build
FOUNDRY_FUZZ_SEED=0x9e36725fb14813eaa46e5ea329763a74a634ccdc31d0580c42ecc19eaff651a7 forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun EVM, optimizer enabled with 200 runs, and `bytecode_hash = "none"` are pinned in `foundry.toml`. All library sources and licenses are vendored; see [DEPENDENCIES.md](DEPENDENCIES.md). No environment variable is read or changed by a test. Setting the seed on the command line configures Foundry itself.

Local check result (2026-11-10): `forge build` and `forge fmt --check` passed; **52 offline tests passed**, with the fork suite skipped as intended; **12 live fork tests passed** separately. Both test runs used the seed above. All four application runtimes passed the supplied size/opcode rules and contain no unlinked library placeholders.

The default suite is offline. Fork tests skip when there is no active fork. To run them against the real Intake, IMD, HOOK factory and v4 pool manager:

```sh
FOUNDRY_FUZZ_SEED=0x9e36725fb14813eaa46e5ea329763a74a634ccdc31d0580c42ecc19eaff651a7 \
  forge test --match-contract RobinhoodForkTest --fork-url <Robinhood-RPC-URL> -vv
```

Use `--fork-block-number <block>` with an archive RPC for repeatability. The public RPC prunes historical state; an earlier attempt at block 111175216 returned “historical state ... is not available.” A subsequent latest-state fork run passed all its tests. No endpoint or credential is required by the committed tests.

Fork setup creates a disposable token/hook/pool **inside the fork** through the real factory, impersonating its recorded deployer with Foundry. The real factory sends its remainder to the airdrop. A real swap through the real pool manager earns fees that the vault collects and distributes. Balance provisioning uses Foundry `deal`. Neither the deployed protocol code nor its position storage is replaced; ArbSys is never mocked. This does not submit an actual paid job or launch, run off-chain admission, or broadcast transactions.

Tests cover one-time authorization, payment/approval rollback, both currency orders, invalid bindings, the split and burn, exact time boundaries, failed fee collection including gas exhaustion, rejecting native recipients, token callbacks, fee-on-transfer stakes, reward carry/restart/rounding, lock enforcement, and claim failures. The reward sequence fuzz test executes 48 mixed actions per input, checking paid IMD never exceeds deposits, balance covers `reserved`, and staked principal remains accounted for. There are 1,000 cases for each offline fuzz property and 256 cases for the fork reward property.

**Merkle test limitation:** only the commitment, total weight and wallet count were supplied, not the 457 wallet/weight records or proofs. Tests assert the actual production constants and reject invalid proofs against them. Positive claims use an explicitly labelled synthetic tree, replacing only the root constant in test EVM bytecode; all claim logic is the application's actual compiled logic. No production root setter, alternate list, or fabricated proof for the committed root is shipped. The actual dataset must be published and checked against this root before claimants can use it.

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| Chain | Robinhood Chain, 4663 |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| HOOK launch factory | `0xa25b02a1e93903b790e6aaf7da1b8b8d50294645` |
| Dev | `0xdfa1f1f6feaa04f7874eff0b7754b7ffaebd8bc0` |
| Marketing | Same address as dev |
| Burn recipient | `0x000000000000000000000000000000000000dEaD` |
| Airdrop root | `0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4` |
| Total weight | `633028988023500000000000000` raw units |
| Listed wallets | 457 |

Deploy **one** `src/SIMDVault.sol:SIMDVault`, with **no constructor arguments and zero ETH**. Its constructor creates all three children and calls `StakeRewards.setJobsVault` once. The constructor needs no code or state at external protocol addresses. The children are artifacts of this same deployment; independently deploying three more contracts would create an unrelated set.

| Constructor-created artifact | Constructor arguments, derived by the vault |
| --- | --- |
| StakeRewards | vault address |
| JobsVault | vault address, StakeRewards address |
| SimdAirdrop | vault address |

The parent getters `stakeRewards()`, `jobsVault()`, and `airdrop()` provide the authoritative child addresses. The launch service supplies confirmed addresses and the deployment receipt after acceptance. This repository contains no deployment manifest, key, guessed deployment address, or broadcast script.

## After launch

1. **Deployment service:** deploy the vault, record its three children, and verify all four sources on Sourcify for chain 4663. Use the accepted source tree and compiler settings unchanged:

   ```sh
   bash scripts/verify-sourcify.sh <Robinhood-RPC-URL> <confirmed-vault-address> <creation-transaction-hash>
   ```

   This script checks the network, notices and links, then submits four verification requests. It does not sign or broadcast transactions. The creation transaction hash helps Sourcify identify internal constructor creations. Source verification remains a post-deployment responsibility; no deployment addresses existed during this assignment. See [Sourcify verification documentation](https://docs.sourcify.dev/docs/how-to-verify/).

2. **Dev wallet:** prepare and validate the complete raw `launch.open` body for **SIMD TEST 3 - DO NOT BUY**. Set the launch's `economics.remainderTo` to the **confirmed `airdrop()` address**, pair the pool with the specified IMD, and allocate enough remainder to cover `TOTAL_WEIGHT`. This application does not invent the token supply, economics, future launch number, or token address. Those belong to the subsequent token launch. Keep the test notice in the token's public presentation.

3. **Funder and dev:** fund `SIMDVault` with the live `Intake.priceOf(bytes32("launch.open@launch-1"), IMD)`, then the fixed dev calls `launch(body)` once. IDs are padded ASCII, **not hashes**. Payment uses `request`, zero callback target/selector, exact approval, then an explicit reset to zero. A reverting on-chain request rolls back the one-time flag. An accepted payment that later fails off-chain remains spent and consumes this one launch opportunity; there is no callback or refund mechanism. Validate the body before paying.

4. **Dev:** after the launch exists, inspect the specified factory's `positionOf(number)`. The requester must be the vault; the pool must pair IMD with the deployed launch token. Call `bindLaunch(number, token)` once. Binding cannot change afterward. The airdrop also requires `number > 3187` and its token balance at least `TOTAL_WEIGHT`. If its bind fails, staking/jobs and weekly distribution still work. Anyone can retry via `vault.bindAirdrop()` after funding arrives. Binding does not require a prior local `launch()` flag: factory requester ownership is the binding authority specified in the brief.

5. **List publisher:** publish the original 457 distinct wallet/weight records and sorted-pair Merkle proofs, verifying their root and total against the constants. Claims use the raw integer weight, without an extra decimals conversion. The leaf is `keccak256(bytes.concat(keccak256(abi.encode(account, weight))))`. Each wallet sends its own `claim(weight, proof)` transaction; there is no recipient override or relayer authorization.

6. **Any keeper:** call `distribute()` immediately after binding, then at or after `nextDistributionAt()`. This is permissionless, not autonomous scheduling; someone must pay gas. Anyone may also call the factory's `claimFees(number)` directly, which still pays the vault. The next distribution splits accumulated funds. Anyone calls `burnUnclaimed()` at or after the airdrop's `claimEnd()`.

7. **Stakers/job requesters:** approve and stake the launch token, then claim IMD or withdraw when unlocked. A wallet with at least `JobsVault.minimumStake()` staked may call `requestJob(body)` once per 24 hours while the jobs vault has enough IMD for the current price. The full raw JSON body must be nonempty and at most 16,384 bytes; its off-chain meaning is the requester's responsibility. Jobs share the JobsVault payer identity, and are paid from the communal jobs budget. No continuation or callback feature is exposed.

## Accounting and boundary decisions

- Every distribution first attempts `claimFees` with **1,000,000 gas**. It then snapshots the entire IMD balance. Using full-precision `mulDiv`, 40% goes to staking (immediately followed by `notifyDeposit`), 25.72% to jobs, 17.14% to dev, and 17.14% to marketing. All shares floor; **the final marketing payment also receives the remaining 0–3 raw IMD units**, so the vault empties. Because dev and marketing are the same wallet, it receives two transfers totaling 34.28% plus that dust.
- The first distribution has no waiting period. Each successful call, even with no funds, schedules the next opportunity seven days later. This is a cooldown from the actual call, not a calendar-aligned week.
- All launched tokens held by the vault are sent to the dead address, not converted to IMD. The best-effort balance read gets **50,000 gas** and transfer **200,000 gas**, with bounded return-data copying. A failed read/burn leaves tokens for the next distribution. The “burn” is a dead-address transfer and does not reduce ERC-20 `totalSupply`.
- The entire native balance is pushed to marketing using **50,000 gas**. Rejection leaves ETH for the next weekly attempt and does not undo the split or token burn.
- Staking uses exactly the specified scaled Synthetix algorithm: `SCALE = 1e36`, `DURATION = 604800`. `reserved` includes all notified IMD less claims, including future streams, zero-staker carry, and dust. `rewardRate` is **scaled** units per second. Time with no stakes and rate-division remainder move into `carryScaled`; a new nonzero received deposit restarts the seven-day stream with that carry and the old unstreamed remainder. A zero-received notification updates accounting but does not restart the period or release carry.
- Per-staker and per-token divisions floor as specified. Their rounding dust remains reserved; there is no sweep or extra redistribution algorithm. Deposits divisible by the necessary time/stake factors pay exactly; other deposits can leave tiny raw-unit dust. Stake principal uses actual received balance differences, supporting transfer fees on staking deposits. Outgoing token fees, if any, reduce what the recipient receives.
- Jobs use `1_000_000 * 10**decimals`, fixed on token binding. Decimals above 71 are rejected because that threshold would not fit `uint256`. An accepted request locks **all** the account's stake for 24 hours; claims keep working and locked stakes keep earning. Locks only extend. At exactly the deadline both withdrawal and another job are allowed; a new job first extends the lock again. On-chain failure rolls back payment, cooldown and lock together.
- Airdrop binding snapshots its **whole** launched-token balance and starts the 30-day clock. Prebinding donations enlarge all shares. Later donations do not change payouts and are burned with unclaimed tokens. Claims require `now < claimEnd`; burning is allowed at `now >= claimEnd`. Burning can be repeated to remove late donations.

## Trust and operational limits

The fixed IMD is assumed to remain a standard non-rebasing, non-taxed ERC-20. The real IMD/Intake/factory integrations were exercised on a fork. Launch-token staking accounts for received transfer fees, but rebases, confiscation, blacklists and malicious token implementations can still prevent withdrawals or claims. Airdrop weights assume an honest published dataset with unique wallets and a total matching the commitment. Directly sent unrelated tokens, surplus staked-token donations, or IMD sent to the airdrop have no recovery route, as required.

The supplied reward formula uses checked `received * 1e36`; amounts and combined scaled streams must fit `uint256`. The test launch's normal supply/funding is far below that bound. Neither token restrictions nor protocol outages can be repaired through an admin setting: the addresses, percentages, list and logic are permanent. Anyone meeting the stake threshold may spend the communal jobs budget under the per-wallet cooldown; there is no job-content governance or Sybil limit beyond the staked amount and lock.

Automated tests and local source review are complete; they are not an independent security audit. The launch network's independent review and post-deployment source verification remain part of release.
