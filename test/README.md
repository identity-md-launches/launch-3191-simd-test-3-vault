# SIMD TEST 3 test coverage

All additions are tests or test helpers. Application sources, dependencies and Foundry configuration are unchanged.

Run the complete suite with the assignment's seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x9e36725fb14813eaa46e5ea329763a74a634ccdc31d0580c42ecc19eaff651a7 forge test
```

The fork suite reads `ROBINHOOD_RPC_URL` with `vm.envOr`, passes its value directly to `vm.createSelectFork`, and pins Robinhood Chain block **111189501**. A URL or socket path works without any format checks. Only an empty variable skips the fork tests. This replaces the old manual `--fork-url` instructions in the repository README. No RPC endpoint or credential is committed and no test changes the environment. An offline run can use `env -u ROBINHOOD_RPC_URL forge test`.

The fork fixtures exercise the real Intake, IMD, HOOK launch factory and pool manager. They create a disposable launch by impersonating the factory's recorded deployer and generate fees through a real swap. Only local fork state changes; nothing is broadcast. They do not replace protocol bytecode/storage or mock ArbSys. `vm.roll` and `vm.warp` advance simulated execution; the fork itself is never moved to another remote block. Robinhood's EVM `block.number` can be its parent-chain number, so it is not used to validate the RPC block identifier.

| Test file | Additional coverage |
| --- | --- |
| `invariant/VaultSystem.invariant.t.sol` | Independent custody and payout ledgers across SIMDVault, StakeRewards and JobsVault; random stakes, withdrawals, exits, claims, donations, fee collection, distributions, jobs, launch attempts, unauthorized calls and time changes. |
| `invariant/Airdrop.invariant.t.sol` | A separate campaign against the original Merkle commitment, and a campaign for successful claims using an explicitly synthetic commitment. Both check custody, fixed allocation/window, rejected calls, donation accounting and final burning. |
| `FailureAtomicity.t.sol` | Rollback of collected fees, reward notifications and cooldowns when a split fails; exit rollback when reward payment fails; job payment failures; setter failures; all supported decimals and the exact stake threshold. |
| `RewardProperties.t.sol` | Fuzzed time-weighted reward allocation when a staker exits, midstream topups preserving earned and future rewards, and exact scaled carry after periods without stakers. |
| `fork/RobinhoodFork.t.sol` | Pinned automatic fork setup; real Intake events and failed-payment rollback; wrong-token binding; delayed airdrop funding/retry; forged claims and expiry against the unchanged commitment, alongside the existing fork scenarios. |

Each invariant campaign specifies **256 runs of 96 calls** in its Solidity source: **73,728 randomized calls** across three campaigns. Every application holding value is included. Handler inputs include invalid and adversarial operations. The handlers catch application reverts and latch unexpected outcomes into a checked flag, so an invariant runner that tolerates reverted handler calls cannot hide those failures. Deterministic handler tests also exercise successful operations, failed transfers, duplicate attempts, retained-fund retries and deadlines. After each sequence, unlocked principal must be withdrawable and expired airdrop balances must be burnable.

The joint handler checks that total externally funded IMD equals every remaining balance plus payouts, that claims never exceed notified rewards, that balance covers reserved and currently earned rewards, and that staked principal equals per-account liabilities plus explicit token donations. Jobs spend only their tracked budget, keep allowances at zero, and change cooldowns/locks only after successful payments. Native ETH and burned tokens have separate conservation checks. Ordinary-token custody is the invariant model; fee-on-transfer, callback and malformed-transfer behaviors also have the existing focused unit tests.

New arithmetic fuzz tests run **1,000 cases each**. Reward expectations use economic time/stake fractions rather than the contract's reward getters as their payout oracle. Absolute rounding tolerances are in raw token units and are bounded by the number of rounded intervals and stakes smaller than `SCALE`.

The original **457 wallet/weight entries and proofs were not supplied**. Tests verify the real root, total weight and count and reject forged claims against that unchanged root. Positive-claim tests use the existing `MerkleFixture` helper to replace only the test instance's root constant with a labelled synthetic tree. They prove claim mechanics, not membership or the weight sum of the real list. They are not a substitute for validating the actual dataset against its commitment.

These are application tests on disposable local deployments. They do not establish Sourcify verification of a future deployed vault or its three children; that requires the confirmed deployment addresses and transaction. No application defect was reproduced by these tests.

## RPC compatibility diagnosis

The reported external check rejected an RPC response saying `eth_getAccountInfo` is unavailable on Robinhood Chain. This method is an optional Foundry optimization. Its absence alone does not establish that historical state is unavailable.

Foundry 1.8.3 pins `foundry-fork-db` at commit `327739f0d2b848725b462271276f27aecd8b8ff9`. In that version, `BackendHandler::get_account_req` initially races `eth_getAccountInfo` against `eth_getBalance`, `eth_getTransactionCount` and `eth_getCode`. If the optional request fails, it uses the standard requests and switches subsequent account reads to them. See the pinned [dependency revision](https://github.com/foundry-rs/foundry/blob/cae51ad458f6abb64852b7709eb784352429825d/Cargo.lock#L5936) and [fallback implementation](https://github.com/foundry-rs/foundry-core/blob/327739f0d2b848725b462271276f27aecd8b8ff9/crates/fork-db/src/backend.rs#L357).

To distinguish a successful cached run from working RPC reads, repeat the fork suite with disk RPC caching disabled and the required environment variable provided by the runner:

```sh
FOUNDRY_FUZZ_SEED=0x9e36725fb14813eaa46e5ea329763a74a634ccdc31d0580c42ecc19eaff651a7 forge test --no-storage-caching --match-path 'test/fork/RobinhoodFork.t.sol' -vv
```

The repair check completed this command with **16 passed, 0 failed, 0 skipped**, including the real Intake payments, factory launch and fee-generating swap. The tests continue to fork block **111189501** directly through `ROBINHOOD_RPC_URL`.

`forge build` also succeeded, and the complete `forge test` run with the required seed and RPC variable set finished with **82 passed, 0 failed, 0 skipped**. All three invariant campaigns completed their 256 runs of 96 calls.

A separate checker that treats every rejected RPC method as a fatal archive-state failure can still reject this successful Foundry run. Addressing that requires the RPC gateway to support the optional method or the checker to distinguish an unsupported capability probe from failed required state reads. That behavior is outside this assignment's test-only write scope. The existing Solidity tests and assertions are preserved; warming a local cache is not a portable repair for that checker.
