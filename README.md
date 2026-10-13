# Perkshire IMDway (PERK)

A plain, fixed-supply ERC-20 token for an IMD custom-token launch on Ethereum (chain id 1).

| Item | Value |
| --- | --- |
| Token name (`name()`) | `Perkshire IMDway` |
| Symbol (`symbol()`) | `PERK` |
| Decimals | 18 |
| Total supply | 1,000,000,000 PERK = `1000000000000000000000000000` minor units |
| Solidity contract name | `PerkToken` (`src/PerkToken.sol`) |
| Constructor arguments | none |
| Minting | once, in the constructor, the whole supply to `msg.sender` (the deployer) |
| Owner / admin | none |

## What the contract does

`PerkToken` inherits OpenZeppelin v5.1.0 `ERC20` and adds nothing but three public constants
(`TOKEN_NAME`, `TOKEN_SYMBOL`, `TOTAL_SUPPLY`) and a constructor that mints `TOTAL_SUPPLY` to
`msg.sender`. There is:

- no owner, role, or privileged function of any kind;
- no mint path after the constructor, so `totalSupply()` can never exceed 1,000,000,000 PERK;
- no pause, blocklist, freeze, seize, or forced `burnFrom`;
- no fee, tax, reflection or burn on transfer: every transfer moves exactly the amount requested;
- no `receive`/`fallback`, so plain ether sent to the token reverts;
- no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime, and no external library calls
  (everything the token calls is internal and inlined).

Standard OpenZeppelin ERC-20 behaviour applies: transfers to the zero address revert, approvals to
the zero address revert, an allowance of `type(uint256).max` is not decremented, and `transfer` /
`transferFrom` / `approve` return `true` on success and revert with ERC-6093 custom errors on
failure.

## Assumptions

- **The deployer receives everything.** On the IMD launch the deployer is `ProjectFactory`
  (`launchCustom`), which receives the full supply and pays it out: 10% to the launch's
  `MerkleDistributor`, the pool share to the Uniswap v4 `PoolManager`, the remainder to the
  requester. Because the token applies no transfer rules, no exemptions for the factory, pool
  manager or distributor are needed and the token takes no launch addresses as constructor
  arguments.
- **No post-launch control is wanted.** The brief asks for a fixed-supply token and nothing else,
  so the token has no owner. Nobody, including the requester, can mint, pause, or move a holder's
  balance after deployment. If governance, taxes, vesting or burns are wanted they are a new
  request, not a setting.
- **Supply can only shrink.** There is no `burn` function; tokens can leave circulation only by
  being sent to an address nobody controls. This is deliberate for a minimal token.
- The constructor makes no external calls and requires no address to have code, so it deploys on
  an empty chain, as the launch's admission checks require.

## Deployment parameters

The token has **no constructor arguments**. The launch manifest (written by the manifest step after
acceptance, not by this repository) describes it as:

| Manifest field | Value |
| --- | --- |
| `token.contract` | `PerkToken` |
| `token.name` | `Perkshire IMDway` |
| `token.symbol` | `PERK` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| application contracts | none |

Launch-decided values (not open questions): chain id 1; pair currency IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`); `pool.fee` 12500; `pool.tickSpacing` 60;
`pool.initialPrice` `79228162514264337593543950336` (provenance only; the deployer derives the
opening price from the economics); economics `{"poolBps":8000,"initialMarketCapWei":
"2500000000000000000000","remainderTo":"0x206f5dbf4f135c6183b5a5b99327fa0be34cb4d9"}`.

Resulting distribution of the 1,000,000,000 PERK, performed entirely by the factory:

| Share | Amount | Recipient |
| --- | --- | --- |
| 10% | 100,000,000 PERK | the launch's MerkleDistributor (swarm: 2% contributors, 8% paired seats) |
| 80% | 800,000,000 PERK | single-sided liquidity in the PERK/IMD Uniswap v4 pool, opened at a 2,500 IMD market cap |
| 10% | 100,000,000 PERK | `0x206f5dbf4f135c6183b5a5b99327fa0be34cb4d9` (economics.remainderTo) |

### Build configuration

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, optimizer on (200 runs),
`bytecode_hash = "none"` and `cbor_metadata = false` so the deployed bytes are reproducible and
carry no metadata hash. `ffi` is off and `fs_permissions` is empty.

Dependencies are vendored as ordinary files under `lib/` (no submodules):

- `lib/forge-std` — forge-std v1.9.7 (`src/` only)
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.1.0 (`contracts/` only)

### Local / test deployment

`script/DeployPerkToken.s.sol` is a reviewable deployment for local or test networks only; the IMD
launch deploys the token from its creation code through the factory and does not use it. Its
`deploy()` function takes no configuration (there is nothing to configure) and is exercised directly
by `test/DeployPerkToken.t.sol`. `run()` wraps it in a broadcast:

```sh
forge script script/DeployPerkToken.s.sol:DeployPerkToken --rpc-url <RPC> --broadcast --sender <ADDR>
```

Whoever broadcasts receives the whole supply.

## After launch

There is nothing to configure: the token has no owner-settable values, no setters, and no outside
dependencies. Operational responsibilities are limited to:

- **Source verification on the explorer**: the launch's deployer/verifier publishes the attested
  source; nothing in this repository holds keys or broadcasts.
- **Custody of the remainder**: `0x206f5dbf4f135c6183b5a5b99327fa0be34cb4d9` receives 10% of the
  supply at launch and is the requester's responsibility to secure.
- **No recovery path**: tokens sent to the token contract itself, or to any other wrong address,
  cannot be recovered. There is no admin to intervene.

## Tests

```sh
forge build
forge test
forge fmt --check
```

`test/PerkToken.t.sol` (29 tests) covers metadata, exact supply and its minting to the deployer
(both an EOA and a contract deployer), the single mint `Transfer` event, transfer/approve/
`transferFrom` success paths and their failure paths (insufficient balance by one, zero-address
receiver/spender, missing and exceeded allowance, owner without balance), the absence of every
common mint/admin selector from both a stranger and the deployer, rejection of plain ether, an
opcode scan for `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, and four fuzz tests for conservation of
supply and exact movement. `test/DeployPerkToken.t.sol` (2 tests) calls the script's `deploy()`
directly. Tests read no environment variables and do not depend on the caller's address.

Run with the verifier's fuzz seed to reproduce its run:

```sh
FOUNDRY_FUZZ_SEED=0x9e806f24bbcdde5c63da423bd1e5b628bd559bd171e84105a9a29cdfd8625c36 forge test
```

## Security notes

Checked against the eth-security reference: no reentrancy surface (no external calls, no ether),
no access control to misconfigure (there is none), no oracle or external dependency, no upgradeability,
no `tx.origin`, no unchecked arithmetic beyond OpenZeppelin's audited ERC-20, Solidity 0.8 overflow
checks on. Only `forge build`, `forge test` and `forge fmt` were run; Slither/Mythril were not
available in this task. Passing tests are not an audit: an independent adversarial review before
release is still the launch policy's step.
