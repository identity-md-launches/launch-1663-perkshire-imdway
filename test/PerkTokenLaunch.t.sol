// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PerkToken} from "../src/PerkToken.sol";

/// @notice Stands in for ProjectFactory: deploys the token through CREATE2 and pays the supply out
///         in the launch's order, all from one address. `launch` does the deployment and the three
///         payouts in a single call, the way `launchCustom` does in a single transaction.
contract FactoryProbe {
    uint256 public constant SWARM_BPS = 1_000;

    function deploy(bytes32 salt) public returns (PerkToken token) {
        bytes memory code = type(PerkToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
        token = PerkToken(deployed);
    }

    /// @dev Deploy, then: swarm share to the distributor, pool share to the pool manager, the rest
    ///      to the requester. Reverts if any transfer returns false.
    function launch(bytes32 salt, address distributor, address poolManager, address remainderTo, uint256 poolBps)
        external
        returns (PerkToken token, uint256 swarm, uint256 pool, uint256 remainder)
    {
        token = deploy(salt);
        uint256 supply = token.totalSupply();
        swarm = (supply * SWARM_BPS) / 10_000;
        pool = (supply * poolBps) / 10_000;
        remainder = supply - swarm - pool;
        require(token.transfer(distributor, swarm), "swarm transfer returned false");
        require(token.transfer(poolManager, pool), "pool transfer returned false");
        require(token.transfer(remainderTo, remainder), "remainder transfer returned false");
    }

    function move(PerkToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @title Launch-flow simulation and remaining edge cases for PerkToken
/// @dev Complements test/PerkToken.t.sol (metadata, basic success/failure paths, stateless fuzz) and
///      test/PerkTokenInvariant.t.sol (random call sequences). Nothing here reads the environment.
/// forge-config: default.fuzz.runs = 1000
contract PerkTokenLaunchTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    uint64 internal constant LAUNCH_NUMBER = 42;

    address internal distributor = makeAddr("distributor");
    address internal poolManager = makeAddr("poolManager");
    address internal requester = makeAddr("requester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    FactoryProbe internal factory;

    function setUp() public {
        factory = new FactoryProbe();
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment through a factory, as the launch does it
    // ---------------------------------------------------------------------------------------------

    /// @dev The manifest declares no constructor arguments, so the creation code alone is the init
    ///      code and the CREATE2 address is predictable from it. The factory, not the test, is the
    ///      constructor's msg.sender and receives everything.
    function test_create2DeploymentIsPredictableAndMintsToFactory() public {
        bytes32 salt = bytes32(uint256(LAUNCH_NUMBER));
        address predicted = vm.computeCreate2Address(salt, keccak256(type(PerkToken).creationCode), address(factory));

        vm.recordLogs();
        PerkToken token = factory.deploy(salt);

        assertEq(address(token), predicted, "address differs from the no-argument prediction");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY, "the factory does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0);

        // Exactly one event during construction: the mint Transfer from the zero address.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "constructor emitted more than the mint");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(factory));
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
    }

    /// @dev The same salt from the same factory cannot be reused: a second launch at the same
    ///      address fails in CREATE2 rather than silently handing back the old token.
    function test_redeployingSameSaltFromSameFactoryReverts() public {
        bytes32 salt = bytes32(uint256(LAUNCH_NUMBER));
        factory.deploy(salt);
        vm.expectRevert(bytes("constructor failed"));
        factory.deploy(salt);
    }

    /// @dev The whole launch in one call: 10% swarm, 80% pool, 10% requester, every leg exact.
    function test_launchPaysOutExactlyInOneCall() public {
        (PerkToken token, uint256 swarm, uint256 pool, uint256 remainder) =
            factory.launch(bytes32(uint256(LAUNCH_NUMBER)), distributor, poolManager, requester, 8_000);

        assertEq(swarm, 100_000_000 ether);
        assertEq(pool, 800_000_000 ether);
        assertEq(remainder, 100_000_000 ether);
        assertEq(token.balanceOf(distributor), swarm, "the swarm's share arrived short");
        assertEq(token.balanceOf(poolManager), pool, "the pool share arrived short");
        assertEq(token.balanceOf(requester), remainder, "the remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the launch flows changed the supply");
    }

    /// @dev Whatever poolBps the job sets, the three legs are exact and exhaust the supply.
    function testFuzz_launchPaysOutExactlyForAnyPoolShare(uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 9_000);
        (PerkToken token, uint256 swarm, uint256 pool, uint256 remainder) =
            factory.launch(bytes32(uint256(LAUNCH_NUMBER)), distributor, poolManager, requester, poolBps);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(requester), remainder);
        assertEq(swarm + pool + remainder, EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    /// @dev Claims out of the distributor arrive whole for every claimant, down to the last one who
    ///      takes exactly what is left. A token that taxed or rounded any claim would short them.
    function test_distributorClaimsArriveWholeIncludingTheLast() public {
        (PerkToken token, uint256 swarm,,) =
            factory.launch(bytes32(uint256(LAUNCH_NUMBER)), distributor, poolManager, requester, 8_000);

        // 2% split three ways among contributors, 8% split seven ways among seats: uneven shares
        // with dust left for the last claimant.
        uint256 contributors = (EXPECTED_SUPPLY * 200) / 10_000;
        uint256 seats = swarm - contributors;
        uint256 perContributor = contributors / 3;
        uint256 perSeat = seats / 7;

        uint256 paid;
        for (uint256 i = 0; i < 3; i++) {
            address claimant = makeAddr(string.concat("contributor", vm.toString(i)));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, perContributor));
            assertEq(token.balanceOf(claimant), perContributor, "a contributor claim arrived short");
            paid += perContributor;
        }
        for (uint256 i = 0; i < 7; i++) {
            address claimant = makeAddr(string.concat("seat", vm.toString(i)));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, perSeat));
            assertEq(token.balanceOf(claimant), perSeat, "a seat claim arrived short");
            paid += perSeat;
        }
        uint256 dust = swarm - paid;
        assertGt(dust, 0, "pick shares that leave dust so the last claim is tested");
        vm.prank(distributor);
        assertTrue(token.transfer(alice, dust));
        assertEq(token.balanceOf(distributor), 0, "the distributor kept something back");
        assertEq(token.balanceOf(alice), dust);

        // One more wei than it has: the distributor cannot over-claim.
        vm.prank(distributor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, 0, 1));
        token.transfer(alice, 1);
    }

    /// @dev Uniswap v4 settles in int128 deltas and liquidity in uint128. The whole supply, which
    ///      is more than any single pool movement, must fit, or the seed and swaps would overflow.
    function test_supplyFitsPoolManagerArithmetic() public pure {
        assertLe(EXPECTED_SUPPLY, uint256(uint128(type(int128).max)), "supply does not fit int128");
        assertLe(EXPECTED_SUPPLY, type(uint128).max, "supply does not fit uint128");
        // 1e27 also fits the 112-bit reserves older AMMs use, so the token pairs anywhere.
        assertLe(EXPECTED_SUPPLY, type(uint112).max, "supply does not fit uint112");
    }

    /// @dev The manifest records the Solidity identifier in 32 bytes. `PerkToken` fits; the token's
    ///      full name is returned by `name()` and is not the identifier.
    function test_contractIdentifierFitsThirtyTwoBytes() public pure {
        string memory identifier = type(PerkToken).name;
        assertEq(identifier, "PerkToken");
        assertLe(bytes(identifier).length, 32);
        assertTrue(bytes(identifier).length != bytes("Perkshire IMDway").length);
    }

    /// @dev Constants exposed on the contract agree with what the ERC-20 getters report, so a
    ///      manifest written from either source says the same thing.
    function test_publicConstantsAgreeWithGetters() public {
        PerkToken token = factory.deploy(bytes32(0));
        assertEq(token.TOKEN_NAME(), token.name());
        assertEq(token.TOKEN_SYMBOL(), token.symbol());
        assertEq(token.TOTAL_SUPPLY(), token.totalSupply());
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance edge cases
    // ---------------------------------------------------------------------------------------------

    PerkToken internal t;
    address internal holder = makeAddr("holder");

    function _fresh() internal returns (PerkToken token) {
        vm.prank(holder);
        token = new PerkToken();
    }

    /// @dev approve overwrites; it never accumulates.
    function test_approveOverwritesRatherThanAccumulates() public {
        t = _fresh();
        vm.startPrank(holder);
        t.approve(alice, 10 ether);
        t.approve(alice, 3 ether);
        vm.stopPrank();
        assertEq(t.allowance(holder, alice), 3 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 3 ether, 3 ether + 1)
        );
        t.transferFrom(holder, bob, 3 ether + 1);
    }

    /// @dev Approving zero revokes: a spender who could spend can no longer spend one wei.
    function test_approveZeroRevokes() public {
        t = _fresh();
        vm.prank(holder);
        t.approve(alice, 5 ether);
        vm.prank(alice);
        t.transferFrom(holder, bob, 1 ether);
        vm.prank(holder);
        t.approve(alice, 0);
        assertEq(t.allowance(holder, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        t.transferFrom(holder, bob, 1);
    }

    /// @dev An allowance spent to exactly zero is zero: the next wei is refused.
    function test_allowanceSpentToZeroThenRefused() public {
        t = _fresh();
        vm.prank(holder);
        t.approve(alice, 2 ether);
        vm.startPrank(alice);
        t.transferFrom(holder, bob, 1 ether);
        t.transferFrom(holder, bob, 1 ether);
        assertEq(t.allowance(holder, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        t.transferFrom(holder, bob, 1);
        vm.stopPrank();
        assertEq(t.balanceOf(bob), 2 ether);
    }

    /// @dev The owner has no implicit allowance over its own tokens through transferFrom.
    function test_ownerNeedsSelfAllowanceForTransferFrom() public {
        t = _fresh();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 0, 1));
        t.transferFrom(holder, alice, 1);

        vm.prank(holder);
        t.approve(holder, 1);
        vm.prank(holder);
        assertTrue(t.transferFrom(holder, alice, 1));
        assertEq(t.balanceOf(alice), 1);
        assertEq(t.allowance(holder, holder), 0);
    }

    /// @dev Spending an allowance emits only the Transfer: no Approval event (OpenZeppelin v5), so
    ///      an indexer must read `allowance()` rather than wait for an event.
    function test_transferFromEmitsTransferOnly() public {
        t = _fresh();
        vm.prank(holder);
        t.approve(alice, 10 ether);
        vm.recordLogs();
        vm.prank(alice);
        t.transferFrom(holder, bob, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), holder);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 4 ether);
    }

    /// @dev transferFrom to the zero address is refused even with allowance and balance.
    function test_transferFromToZeroAddressReverts() public {
        t = _fresh();
        vm.prank(holder);
        t.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        t.transferFrom(holder, address(0), 1 ether);
        assertEq(t.allowance(holder, alice), 1 ether, "a failed transferFrom spent allowance");
    }

    /// @dev The spender may be the recipient: pulling to itself works and is exact.
    function test_spenderCanPullToItself() public {
        t = _fresh();
        vm.prank(holder);
        t.approve(alice, 7 ether);
        vm.prank(alice);
        assertTrue(t.transferFrom(holder, alice, 7 ether));
        assertEq(t.balanceOf(alice), 7 ether);
        assertEq(t.balanceOf(holder), EXPECTED_SUPPLY - 7 ether);
        assertEq(t.allowance(holder, alice), 0);
    }

    /// @dev Two spenders share nothing: one spending does not touch the other's allowance.
    function test_allowancesAreIndependentPerSpender() public {
        t = _fresh();
        vm.startPrank(holder);
        t.approve(alice, 5 ether);
        t.approve(bob, 5 ether);
        vm.stopPrank();
        vm.prank(alice);
        t.transferFrom(holder, alice, 5 ether);
        assertEq(t.allowance(holder, alice), 0);
        assertEq(t.allowance(holder, bob), 5 ether);
    }

    /// @dev An allowance survives the owner's balance going to zero and back; it is not tied to
    ///      balance.
    function test_allowanceIsIndependentOfBalance() public {
        t = _fresh();
        vm.prank(holder);
        t.approve(alice, 1 ether);
        vm.prank(holder);
        t.transfer(bob, EXPECTED_SUPPLY);
        assertEq(t.allowance(holder, alice), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1 ether));
        t.transferFrom(holder, alice, 1 ether);
        vm.prank(bob);
        t.transfer(holder, 1 ether);
        vm.prank(alice);
        assertTrue(t.transferFrom(holder, alice, 1 ether));
    }

    // ---------------------------------------------------------------------------------------------
    // Transfer edge cases
    // ---------------------------------------------------------------------------------------------

    /// @dev The maximum uint256 is just another amount above balance: no wrap, no special case.
    function test_transferOfMaxUintReverts() public {
        t = _fresh();
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, holder, EXPECTED_SUPPLY, type(uint256).max
            )
        );
        t.transfer(alice, type(uint256).max);
    }

    /// @dev The same whole-balance transfer twice: the second one fails and moves nothing.
    function test_sameTransferTwiceFailsTheSecondTime() public {
        t = _fresh();
        vm.startPrank(holder);
        t.transfer(alice, EXPECTED_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, EXPECTED_SUPPLY)
        );
        t.transfer(alice, EXPECTED_SUPPLY);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), EXPECTED_SUPPLY);
    }

    /// @dev The zero address cannot be a sender either, even for zero.
    function test_transferFromZeroAddressSenderReverts() public {
        t = _fresh();
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        t.transfer(alice, 0);
    }

    /// @dev Tokens sent to the token contract are not refused and cannot be recovered: there is no
    ///      admin, no rescue function. They stay counted in the supply.
    function test_tokensSentToTokenContractAreStuckButCounted() public {
        t = _fresh();
        vm.prank(holder);
        assertTrue(t.transfer(address(t), 1 ether));
        assertEq(t.balanceOf(address(t)), 1 ether);
        assertEq(t.totalSupply(), EXPECTED_SUPPLY);
        (bool ok,) = address(t).call(abi.encodeWithSignature("rescue(address,uint256)", alice, 1 ether));
        assertFalse(ok);
        (ok,) = address(t).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(t), 1 ether));
        assertFalse(ok);
        assertEq(t.balanceOf(address(t)), 1 ether);
    }

    /// @dev A holder with nothing can still make a zero transfer, and only a zero transfer.
    function test_emptyHolderCanOnlyTransferZero() public {
        t = _fresh();
        vm.startPrank(alice);
        assertTrue(t.transfer(bob, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        t.transfer(bob, 1);
        vm.stopPrank();
    }

    /// @dev A self-transfer of more than held still reverts: the balance check comes first.
    function test_selfTransferAboveBalanceReverts() public {
        t = _fresh();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        t.transfer(alice, 1);
    }

    /// @dev Ether attached to any token function is refused: nothing on the token is payable.
    function test_etherAttachedToAnyFunctionReverts() public {
        t = _fresh();
        vm.deal(holder, 3 ether);
        bytes[4] memory calls = [
            abi.encodeWithSelector(t.transfer.selector, alice, 0),
            abi.encodeWithSelector(t.approve.selector, alice, 0),
            abi.encodeWithSelector(t.transferFrom.selector, holder, alice, 0),
            abi.encodeWithSelector(t.balanceOf.selector, holder)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(holder);
            (bool ok,) = address(t).call{value: 1 wei}(calls[i]);
            assertFalse(ok, "a token function accepted ether");
        }
        assertEq(address(t).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: edges of arithmetic and roles
    // ---------------------------------------------------------------------------------------------

    /// @dev Any approve from any owner to any non-zero spender is recorded exactly and overwrites.
    function testFuzz_approveOverwritesExactly(address spender, uint256 first, uint256 second) public {
        vm.assume(spender != address(0));
        t = _fresh();
        vm.startPrank(holder);
        t.approve(spender, first);
        assertEq(t.allowance(holder, spender), first);
        t.approve(spender, second);
        assertEq(t.allowance(holder, spender), second);
        vm.stopPrank();
    }

    /// @dev A round trip leaves both parties exactly where they started; no dust is created or lost.
    function testFuzz_roundTripIsExact(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        t = _fresh();
        vm.prank(holder);
        t.transfer(alice, amount);
        vm.prank(alice);
        t.transfer(holder, amount);
        assertEq(t.balanceOf(holder), EXPECTED_SUPPLY);
        assertEq(t.balanceOf(alice), 0);
    }

    /// @dev Splitting a transfer into two legs delivers the same as one leg.
    function testFuzz_splitTransferEqualsWholeTransfer(uint256 total, uint256 firstLeg) public {
        total = bound(total, 0, EXPECTED_SUPPLY);
        firstLeg = bound(firstLeg, 0, total);
        t = _fresh();
        vm.startPrank(holder);
        t.transfer(alice, firstLeg);
        t.transfer(alice, total - firstLeg);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), total);
        assertEq(t.balanceOf(holder), EXPECTED_SUPPLY - firstLeg - (total - firstLeg));
    }

    /// @dev Any spender who has not been approved cannot pull one wei from any funded owner, no
    ///      matter who they are, including the deployer's own address acting through transferFrom.
    function testFuzz_noApprovalNoPull(address spender, uint256 amount) public {
        amount = bound(amount, 1, EXPECTED_SUPPLY);
        t = _fresh();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        t.transferFrom(holder, spender, amount);
        assertEq(t.balanceOf(holder), EXPECTED_SUPPLY);
    }

    /// @dev With an infinite allowance the spender can drain exactly the owner's balance and not
    ///      one wei more, and the allowance stays infinite.
    function testFuzz_infiniteAllowanceDrainsBalanceExactly(uint256 held) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        t = _fresh();
        vm.startPrank(holder);
        t.transfer(bob, EXPECTED_SUPPLY - held);
        t.approve(alice, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(alice);
        assertTrue(t.transferFrom(holder, alice, held));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        t.transferFrom(holder, alice, 1);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), held);
        assertEq(t.allowance(holder, alice), type(uint256).max);
    }
}
