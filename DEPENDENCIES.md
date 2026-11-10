# Vendored dependencies

All compilation and testing dependencies are ordinary source files under `lib/`; no installation, submodule, FFI, filesystem cheatcode permission, or network access is needed for the default build/test suite. The pinned Solidity compiler is supplied by the Foundry execution profile.

| Dependency | Pinned release | Included material | Upstream archive SHA-256 |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.0.2 | Unmodified transitive Solidity dependencies of the application and test ERC-20; MIT license | `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a` |
| forge-std | v1.9.7 | Unmodified `src/` Solidity files and MIT/Apache licenses | `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94` |

Sources: [OpenZeppelin v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2), [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7). Archive hashes refer to the GitHub codeload tag archives from which the retained files were extracted.

The application factory interface preserves the Uniswap v4 `PoolKey` ABI: `(address,address,uint24,int24,address)`. It intentionally uses addresses for the ABI representations of `Currency` and `IHooks`, avoiding an unnecessary full v4 dependency. [Canonical PoolKey](https://github.com/Uniswap/v4-core/blob/main/src/types/PoolKey.sol).

The additional launch/swap interfaces under `test/fork/` were checked against the named factory's verified ABI and source, including the eight-field provenance record. [Factory verification record](https://sourcify.dev/server/v2/contract/4663/0xa25b02a1e93903b790e6aaf7da1b8b8d50294645?fields=abi,sources). They are test fixtures and are not application contracts.
