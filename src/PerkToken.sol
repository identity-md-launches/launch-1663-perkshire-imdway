// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Perkshire IMDway (PERK)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 PERK (18 decimals) is
///         minted once, in the constructor, to the deployer (`msg.sender`). On the IMD launch the
///         deployer is the ProjectFactory, which then pays the supply out: the swarm's share to the
///         MerkleDistributor, the pool share to the Uniswap v4 PoolManager, the remainder to the
///         requester.
/// @dev Deliberately minimal:
///      - no owner, no roles, no mint, no pause, no blocklist, no fee or burn on transfer;
///      - no further minting path exists, so `totalSupply()` can never exceed `TOTAL_SUPPLY`;
///      - no constructor arguments and no external calls in the constructor, so it deploys on an
///        empty chain and the launch manifest needs no `constructorArgs`.
///      The Solidity name `PerkToken` is the launch's contract name; `name()` returns the token's
///      full name.
contract PerkToken is ERC20 {
    /// @notice The token's full name, as `name()` returns it.
    string public constant TOKEN_NAME = "Perkshire IMDway";

    /// @notice The token's symbol, as `symbol()` returns it.
    string public constant TOKEN_SYMBOL = "PERK";

    /// @notice One billion whole tokens, in minor units (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire fixed supply to the deployer. Nothing else ever mints.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
