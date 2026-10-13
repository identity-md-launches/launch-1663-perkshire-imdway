// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PerkToken} from "../src/PerkToken.sol";

/// @notice Drives `PerkToken` with random, bounded call sequences from a fixed set of actors.
/// @dev Every recipient the handler ever uses is in `holders`, so the invariants can sum balances
///      exactly. The handler keeps its own ghost ledger of balances and allowances and asserts the
///      postcondition of every call it makes, success or failure, so a sequence that reaches an
///      unexpected state fails inside the handler as well as in the invariants. The handler itself
///      never reverts: the suite runs with fail-on-revert so a silently reverting handler cannot make
///      the run vacuous.
contract PerkHandler is Test {
    PerkToken public immutable token;
    uint256 public immutable supply;

    /// @dev Everyone who can ever hold a balance: the deployer, six ordinary actors and the token
    ///      contract itself (tokens sent there are stuck, but they must still be counted).
    address[] public holders;

    // Ghost ledger.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;

    // Call accounting, for the summary and for checking the run was not vacuous.
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public rejectedCalls;

    constructor(PerkToken token_, address deployer) {
        token = token_;
        supply = token_.totalSupply();
        holders.push(deployer);
        holders.push(makeAddr("actor1"));
        holders.push(makeAddr("actor2"));
        holders.push(makeAddr("actor3"));
        holders.push(makeAddr("actor4"));
        holders.push(makeAddr("actor5"));
        holders.push(makeAddr("actor6"));
        holders.push(address(token_));
        ghostBalance[deployer] = supply;
        ghostReceived[deployer] = supply;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return holders[bound(seed, 0, holders.length - 1)];
    }

    /// @dev An actor that may sign: the token contract cannot be pranked into calling itself in a
    ///      meaningful way, so senders are drawn from the first seven holders only.
    function _signer(uint256 seed) internal view returns (address) {
        return holders[bound(seed, 0, holders.length - 2)];
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    /// @notice A transfer within the sender's balance, including zero and the whole balance.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _signer(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }

        _recordMove(from, to, amount);
        successfulTransfers++;
    }

    /// @notice A transfer of more than the sender holds. Must revert with the ERC-6093 error and
    ///         move nothing.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _signer(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);

        assertEq(token.balanceOf(from), held, "a failed transfer changed the sender's balance");
        rejectedCalls++;
    }

    /// @notice A transfer to the zero address: never a burn path, always a revert.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _signer(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        rejectedCalls++;
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets (overwrites, never accumulates) an allowance, anywhere from 0 to the maximum.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _signer(ownerSeed);
        address spender = _actor(spenderSeed);
        // Occasionally use the infinite allowance, which must not be decremented later.
        if (amount % 7 == 0) amount = type(uint256).max;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "allowance not set exactly");

        ghostAllowance[owner][spender] = amount;
    }

    /// @notice Approving the zero address as spender must revert.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _signer(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        rejectedCalls++;
    }

    /// @notice A transferFrom within both the allowance and the owner's balance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _signer(spenderSeed);
        address owner = _signer(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented exactly");
            ghostAllowance[owner][spender] = allowed - amount;
        }

        _recordMove(owner, to, amount);
        successfulTransferFroms++;
    }

    /// @notice A transferFrom above the (finite) allowance. Must revert with the allowance error and
    ///         change neither balances nor the allowance.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _signer(spenderSeed);
        address owner = _signer(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Pin a finite allowance so there is something to exceed.
            vm.prank(owner);
            token.approve(spender, 0);
            ghostAllowance[owner][spender] = 0;
            allowed = 0;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;
        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);

        assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), ownerBefore, "a failed transferFrom moved tokens");
        rejectedCalls++;
    }

    /// @notice A transferFrom with enough allowance but not enough balance. Must revert with the
    ///         balance error and leave the allowance untouched.
    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        address spender = _signer(spenderSeed);
        address owner = _signer(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(owner);
        // Keep the amount inside the supply so that an allowance of `supply` always covers it.
        excess = bound(excess, 1, supply - held + 1);
        uint256 amount = held + excess;

        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, to, amount);

        assertEq(token.balanceOf(owner), held, "a failed transferFrom moved tokens");
        assertEq(token.allowance(owner, spender), type(uint256).max, "a failed transferFrom spent allowance");
        rejectedCalls++;
    }

    // ---------------------------------------------------------------------------------------------
    // Hostile calls that must bounce off
    // ---------------------------------------------------------------------------------------------

    /// @notice Plain ether and ether attached to a non-payable function both revert.
    function sendEther(uint256 fromSeed, uint256 value) external {
        address from = _signer(fromSeed);
        value = bound(value, 1, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool okPlain,) = address(token).call{value: value}("");
        assertFalse(okPlain, "the token accepted plain ether");
        vm.prank(from);
        (bool okWithData,) = address(token).call{value: value}(abi.encodeWithSelector(token.transfer.selector, from, 0));
        assertFalse(okWithData, "a non-payable function accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
        rejectedCalls++;
    }

    /// @notice Any privileged-looking selector, from anyone, is unknown to the token and reverts
    ///         without touching supply or balances.
    function callAdminSelector(uint256 fromSeed, uint256 which, uint256 arg) external {
        address from = _signer(fromSeed);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        string memory sig = signatures[bound(which, 0, signatures.length - 1)];
        address target = _actor(arg);
        bytes memory data = abi.encodeWithSignature(sig, target, arg);

        uint256 supplyBefore = token.totalSupply();
        uint256 targetBefore = token.balanceOf(target);
        vm.prank(from);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, sig);
        assertEq(token.totalSupply(), supplyBefore, "an admin selector changed the supply");
        assertEq(token.balanceOf(target), targetBefore, "an admin selector moved a balance");
        rejectedCalls++;
    }

    // ---------------------------------------------------------------------------------------------
    // Ghost bookkeeping
    // ---------------------------------------------------------------------------------------------

    function _recordMove(address from, address to, uint256 amount) internal {
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
    }
}

/// @title PerkToken invariants
/// @notice Properties that must hold after any sequence of calls the handler can make.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PerkTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    PerkToken internal token;
    PerkHandler internal handler;
    address internal deployer = makeAddr("deployer");
    bytes32 internal codehashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new PerkToken();
        handler = new PerkHandler(token, deployer);
        codehashAtDeployment = address(token).codehash;

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = PerkHandler.transfer.selector;
        selectors[1] = PerkHandler.transferAboveBalance.selector;
        selectors[2] = PerkHandler.transferToZero.selector;
        selectors[3] = PerkHandler.approve.selector;
        selectors[4] = PerkHandler.approveZeroSpender.selector;
        selectors[5] = PerkHandler.transferFrom.selector;
        selectors[6] = PerkHandler.transferFromAboveAllowance.selector;
        selectors[7] = PerkHandler.transferFromAboveBalance.selector;
        selectors[8] = PerkHandler.sendEther.selector;
        selectors[9] = PerkHandler.callAdminSelector.selector;
        selectors[10] = PerkHandler.transfer.selector; // weight ordinary transfers a little higher
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The supply is fixed at deployment: nothing mints and nothing burns.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Conservation: what every possible holder has adds up to the supply, so nothing leaked to
    ///      an address the handler never used and nothing was created or destroyed.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not add up to the supply");
    }

    /// @dev Each holder's balance equals the ghost ledger: initial allocation + received - sent.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address h = handler.holders(i);
            assertEq(token.balanceOf(h), handler.ghostBalance(h), "balance drifted from the ledger");
            assertEq(
                token.balanceOf(h), handler.ghostReceived(h) - handler.ghostSent(h), "flows do not explain balance"
            );
            assertLe(token.balanceOf(h), EXPECTED_SUPPLY, "a holder has more than the supply");
        }
    }

    /// @dev Nobody but the deployer ever received anything that was not sent to them: every
    ///      non-deployer holder's inflow is bounded by the deployer's outflow plus re-transfers,
    ///      which is exactly the statement that the deployer's net outflow equals everyone else's
    ///      net holdings.
    function invariant_deployerOutflowEqualsOthersHoldings() public view {
        uint256 others;
        uint256 n = handler.holderCount();
        for (uint256 i = 1; i < n; i++) {
            others += token.balanceOf(handler.holders(i));
        }
        assertEq(EXPECTED_SUPPLY - token.balanceOf(deployer), others);
    }

    /// @dev Allowances equal the ghost ledger for every (owner, spender) pair the handler can use.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.holders(i);
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drift");
            }
        }
    }

    /// @dev The zero address never holds anything: no path mints or burns through it after the
    ///      constructor, and transfers to it revert.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev The token never holds ether and its code never changes (no selfdestruct, no upgrade).
    function invariant_tokenHoldsNoEtherAndCodeIsFixed() public view {
        assertEq(address(token).balance, 0);
        assertEq(address(token).codehash, codehashAtDeployment);
    }

    /// @dev Metadata is immutable across any sequence.
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "Perkshire IMDway");
        assertEq(token.symbol(), "PERK");
        assertEq(token.decimals(), 18);
    }

    /// @dev Not an invariant: a deterministic pass over every handler function, so the suite above
    ///      is known not to be vacuous. Each call must go through (the handler asserts its own
    ///      postconditions), tokens must actually move, and every failure path must be exercised.
    function test_handlerExercisesEveryPathAgainstTheToken() public {
        handler.transfer(0, 1, 123 ether); // deployer -> actor1
        handler.transfer(1, 2, 23 ether); // actor1 -> actor2
        handler.transfer(2, 2, 1 ether); // self
        handler.transfer(1, 7, 1 ether); // actor1 -> the token contract (stuck, still counted)
        handler.transferAboveBalance(3, 1, 1);
        handler.transferToZero(0, 1);
        handler.approve(0, 3, 50 ether); // 50 ether % 7 != 0, so finite
        handler.approve(1, 4, 7); // 7 % 7 == 0, so infinite
        handler.approveZeroSpender(0, 1);
        handler.transferFrom(3, 0, 5, 20 ether); // actor3 pulls 20 from deployer to actor5
        handler.transferFrom(4, 1, 6, 1 ether); // actor4 pulls 1 from actor1 to actor6 on infinite allowance
        handler.transferFromAboveAllowance(3, 0, 5, 1);
        handler.transferFromAboveBalance(5, 6, 0, 1);
        handler.sendEther(2, 1 ether);
        handler.callAdminSelector(1, 0, 1);
        handler.callAdminSelector(0, 3, 0);

        assertEq(handler.successfulTransfers(), 4);
        assertEq(handler.successfulTransferFroms(), 2);
        assertEq(handler.rejectedCalls(), 8);
        assertEq(token.balanceOf(handler.holders(1)), 123 ether - 23 ether - 1 ether - 1 ether);
        assertEq(token.balanceOf(handler.holders(2)), 23 ether);
        assertEq(token.balanceOf(handler.holders(5)), 20 ether);
        assertEq(token.balanceOf(handler.holders(6)), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.allowance(deployer, handler.holders(3)), 30 ether);
        assertEq(token.allowance(handler.holders(1), handler.holders(4)), type(uint256).max);

        invariant_totalSupplyNeverChanges();
        invariant_sumOfBalancesEqualsSupply();
        invariant_balancesMatchGhostLedger();
        invariant_deployerOutflowEqualsOthersHoldings();
        invariant_allowancesMatchGhostLedger();
        invariant_zeroAddressHoldsNothing();
        invariant_tokenHoldsNoEtherAndCodeIsFixed();
        invariant_metadataIsFixed();
    }
}
