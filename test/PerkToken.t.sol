// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PerkToken} from "../src/PerkToken.sol";

/// @notice A contract deployer, so the test can show the supply lands on whichever address runs the
///         constructor (on the launch, the factory) and not on any hard-coded wallet.
contract Deployer {
    function deploy() external returns (PerkToken) {
        return new PerkToken();
    }
}

contract PerkTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    PerkToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new PerkToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Perkshire IMDway");
        assertEq(token.symbol(), "PERK");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Perkshire IMDway");
        assertEq(token.TOKEN_SYMBOL(), "PERK");
    }

    function test_totalSupplyIsOneBillionWith18Decimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), deployer, EXPECTED_SUPPLY);
        vm.prank(deployer);
        new PerkToken();
    }

    /// @dev The supply follows msg.sender of the constructor, whoever that is: an EOA here, a
    ///      contract (the factory) on the launch.
    function test_supplyGoesToContractDeployerWhenDeployedByContract() public {
        Deployer factoryLike = new Deployer();
        PerkToken fresh = factoryLike.deploy();
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(address(factoryLike)), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_constructorHasNoArguments() public pure {
        // The launch manifest needs constructorArgs = []: creation code is the whole init code.
        bytes memory creation = type(PerkToken).creationCode;
        assertGt(creation.length, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 5 ether);
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        token.transfer(alice, EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_selfTransferKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 1 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_secondHandTransferIsAlsoUntaxed() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsWhenExceedingBalanceByOne() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 7 ether);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 7 ether));
        assertEq(token.allowance(deployer, alice), 7 ether);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(deployer, alice), 6 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 4 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1 ether, 2 ether)
        );
        token.transferFrom(deployer, bob, 2 ether);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 5 ether));
        token.transferFrom(alice, bob, 5 ether);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface, no supply growth
    // ---------------------------------------------------------------------------------------------

    /// @dev None of the usual admin or mint entry points exist. Each call must revert (no matching
    ///      selector, no fallback) and leave supply and balances untouched, whether a stranger or the
    ///      deployer makes it.
    function test_noMintOrAdminSelectorsExist() public {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setTransfersEnabled(bool)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okStranger,) = address(token).call(data);
            assertFalse(okStranger, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, signatures[i]);
        }
    }

    function test_rejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndMovesExactly(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 extra) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        extra = bound(extra, 1, EXPECTED_SUPPLY - held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + extra)
        );
        token.transfer(bob, held + extra);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowance, uint256 spend) public {
        allowance = bound(allowance, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        if (spend > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowance, spend)
            );
            token.transferFrom(deployer, bob, spend);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spend));
            assertEq(token.balanceOf(bob), spend);
            assertEq(token.allowance(deployer, alice), allowance - spend);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev A chain of hops between arbitrary holders never creates or destroys tokens.
    function testFuzz_multiHopConservesSupply(uint96 a, uint96 b, uint96 c) public {
        uint256 x = bound(uint256(a), 0, EXPECTED_SUPPLY);
        uint256 y = bound(uint256(b), 0, x);
        uint256 z = bound(uint256(c), 0, y);
        vm.prank(deployer);
        token.transfer(alice, x);
        vm.prank(alice);
        token.transfer(bob, y);
        vm.prank(bob);
        token.transfer(deployer, z);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
