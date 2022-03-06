// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// Testing utils
import {DSTest} from "@sense-finance/v1-core/src/tests/test-helpers/DSTest.sol";
import {MockDividerSpace, MockAdapterSpace, ERC20Mintable} from "./utils/Mocks.sol";
import {VM} from "./utils/VM.sol";
import {User} from "./utils/User.sol";

// External references
import {Vault, IVault, IWETH, IAuthorizer, IAsset, IProtocolFeesCollector} from "@balancer-labs/v2-vault/contracts/Vault.sol";
import {IPoolSwapStructs} from "@balancer-labs/v2-vault/contracts/interfaces/IPoolSwapStructs.sol";
import {Authentication} from "@balancer-labs/v2-solidity-utils/contracts/helpers/Authentication.sol";
import {IERC20} from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/IERC20.sol";
import {Authorizer} from "@balancer-labs/v2-vault/contracts/Authorizer.sol";
import {FixedPoint} from "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import {IPriceOracle} from "@balancer-labs/v2-pool-utils/contracts/interfaces/IPriceOracle.sol";

// Internal references
import {SpaceFactory} from "../SpaceFactory.sol";
import {Space} from "../Space.sol";
import {Errors} from "../Errors.sol";

// Base DSTest plus a few extra features
contract Test is DSTest {
    function assertClose(
        uint256 a,
        uint256 b,
        uint256 _tolerance
    ) public {
        bool _isClose = isClose(a, b, _tolerance);
        if (!_isClose) {
            emit log("Error: abs(a, b) < tolerance not satisfied [uint]");
            emit log_named_uint("  Expected", b);
            emit log_named_uint("  Tolerance", _tolerance);
            emit log_named_uint("    Actual", a);
            fail();
        }
    }

    function isClose(
        uint256 a,
        uint256 b,
        uint256 _tolerance
    ) public view returns (bool) {
        uint256 diff = a < b ? b - a : a - b;
        return diff <= _tolerance;
    }

    function fuzzWithBounds(
        uint256 amount,
        uint256 lBound,
        uint256 uBound
    ) internal returns (uint256) {
        return lBound + (amount % (uBound - lBound));
    }
}

contract SpaceTest is Test {
    using FixedPoint for uint256;

    VM internal constant vm = VM(HEVM_ADDRESS);
    IWETH internal constant weth =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint256 public constant INTIAL_USER_BALANCE = 100e18;

    Vault internal vault;
    Space internal space;
    SpaceFactory internal spaceFactory;

    MockDividerSpace internal divider;
    MockAdapterSpace internal adapter;
    uint256 internal maturity;
    ERC20Mintable internal pt;
    ERC20Mintable internal target;
    Authorizer internal authorizer;

    User internal jim;
    User internal ava;
    User internal sid;
    User internal sam;

    uint256 internal ts;
    uint256 internal g1;
    uint256 internal g2;

    function setUp() public {
        // Init normalized starting conditions
        vm.warp(0);
        vm.roll(0);

        // Create mocks
        divider = new MockDividerSpace(18);
        adapter = new MockAdapterSpace(18);

        ts = FixedPoint.ONE.divDown(FixedPoint.ONE * 31622400); // 1 / 1 year in seconds
        // 0.95 for selling Target
        g1 = (FixedPoint.ONE * 950).divDown(FixedPoint.ONE * 1000);
        // 1 / 0.95 for selling PT
        g2 = (FixedPoint.ONE * 1000).divDown(FixedPoint.ONE * 950);

        maturity = 15811200; // 6 months in seconds

        authorizer = new Authorizer(address(this));
        vault = new Vault(authorizer, weth, 0, 0);
        spaceFactory = new SpaceFactory(
            vault,
            address(divider),
            ts,
            g1,
            g2,
            true
        );

        space = Space(spaceFactory.create(address(adapter), maturity));

        (address _pt, , , , , , , , ) = MockDividerSpace(divider).series(
            address(adapter),
            maturity
        );
        pt = ERC20Mintable(_pt);
        target = ERC20Mintable(adapter.target());

        // Mint this address PT and Target tokens
        // Max approve the balancer vault to move this addresses tokens
        pt.mint(address(this), INTIAL_USER_BALANCE);
        target.mint(address(this), INTIAL_USER_BALANCE);
        target.approve(address(vault), type(uint256).max);
        pt.approve(address(vault), type(uint256).max);

        jim = new User(vault, space, pt, target);
        pt.mint(address(jim), INTIAL_USER_BALANCE);
        target.mint(address(jim), INTIAL_USER_BALANCE);

        ava = new User(vault, space, pt, target);
        pt.mint(address(ava), INTIAL_USER_BALANCE);
        target.mint(address(ava), INTIAL_USER_BALANCE);

        sid = new User(vault, space, pt, target);
        pt.mint(address(sid), INTIAL_USER_BALANCE);
        target.mint(address(sid), INTIAL_USER_BALANCE);

        sam = new User(vault, space, pt, target);
    }

    function testJoinOnce() public {
        jim.join();

        // For the pool's first join –--
        // It moved Target out of jim's account
        assertEq(target.balanceOf(address(jim)), 99e18);

        // and it minted jim's account BPT tokens equal to the value of underlying
        // deposited (inital scale is 1e18, so it's one-to-one)
        assertClose(space.balanceOf(address(jim)), 1e18, 1e6);

        // but it did not move any PT
        assertEq(pt.balanceOf(address(jim)), 100e18);
    }

    function testJoinMultiNoSwaps() public {
        // Join once
        jim.join();
        // Join again after no swaps
        jim.join();

        // If the pool has been joined a second time and no swaps have occured –--
        // It moved more Target out of jim's account
        assertEq(target.balanceOf(address(jim)), 98e18);

        // and it minted jim's account more BPT tokens
        assertClose(space.balanceOf(address(jim)), 2e18, 1e6);

        // but it still did not move any PT
        assertEq(pt.balanceOf(address(jim)), 100e18);
    }

    function testSimpleSwapIn() public {
        // Join once (first join is always Target-only)
        jim.join();

        // Can't swap any Target in b/c there aren't ever any PT to get out after the first join
        try jim.swapIn(false, 1) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.SWAP_TOO_SMALL);
        }

        // Can successfully swap PT in
        uint256 targetOt = jim.swapIn(true);
        // Fixed amount in, variable amount out
        uint256 expectedTargetOut = 646139118808653602;

        // Swapped one PT in
        assertEq(pt.balanceOf(address(jim)), 99e18);
        // Received less than one Target
        assertEq(targetOt, expectedTargetOut);

        (, uint256[] memory balances, ) = vault.getPoolTokens(
            space.getPoolId()
        );
        (uint256 pti, uint256 targeti) = space.getIndices();

        // Pool balances reflect the user's balances
        assertEq(balances[pti], 1e18);
        assertEq(balances[targeti], 1e18 - expectedTargetOut);

        // Can not swap a full Target in
        try jim.swapIn(false) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, "BAL#001"); // sub overflow
        }

        // Can successfully swap a partial Target in
        uint256 ptOut = jim.swapIn(false, 0.5e18);
        uint256 expectedPTOut = 804788983856768174;

        assertEq(
            target.balanceOf(address(jim)),
            99e18 + expectedTargetOut - 0.5e18
        );
        assertEq(ptOut, expectedPTOut);
    }

    function testSimpleSwapsOut() public {
        jim.join();

        // Can't swap any PT out b/c there aren't any PT to get out after the first join
        try jim.swapOut(false, 1) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, "BAL#001");
        }

        // Can successfully swap Target out
        uint256 ptsIn = jim.swapOut(true, 0.1e18);
        // Fixed amount out, variable amount in
        uint256 expectedPTIn = 105559160849472541; // around 0.10556

        // Received 0.1 Target
        assertEq(target.balanceOf(address(jim)), 99e18 + 0.1e18);
        assertEq(ptsIn, expectedPTIn);
    }

    function testExitOnce() public {
        jim.join();
        // Max exit
        jim.exit(space.balanceOf(address(jim)));

        // For the pool's first exit –--
        // It moved PT back to jim's account
        assertEq(pt.balanceOf(address(jim)), 100e18);
        // And it took all of jim's account's BPT back
        assertEq(space.balanceOf(address(jim)), 0);
        // It moved almost all Target back to this account (locked MINIMUM_BPT permanently)
        assertClose(target.balanceOf(address(jim)), 100e18, 1e6);
    }

    function testJoinSwapExit() public {
        jim.join();

        // Swap out 0.1 Target
        jim.swapOut(true, 0.1e18);

        // Max exit
        jim.exit(space.balanceOf(address(jim)));

        // For the pool's first exit –--
        // It moved PT back to jim's account (less rounding losses)
        assertClose(pt.balanceOf(address(jim)), 100e18, 1e6);
        // And it took all of jim's account's BPT back
        assertEq(space.balanceOf(address(jim)), 0);
        // It moved almost all Target back to this account (locked MINIMUM_BPT permanently)
        assertClose(target.balanceOf(address(jim)), 100e18, 1e6);
    }

    function testMultiPartyJoinSwapExit() public {
        // Jim tries to join 1 of each (should be Target-only)
        jim.join();

        // The pool moved one Target out of jim's account
        assertEq(target.balanceOf(address(jim)), 99e18);

        // Swap 1 PT in
        sid.swapIn(true);

        // Ava tries to Join 1 of each (should take 1 PT and some amount of Target)
        ava.join();
        assertGe(target.balanceOf(address(ava)), 99e18);
        assertEq(pt.balanceOf(address(ava)), 99e18);

        // Swap 1 PT in

        sid.swapIn(true);

        // Ava tries to Join 1 of each (should take 1 PT and even less Target than last time)
        uint256 targetPreJoin = target.balanceOf(address(ava));
        ava.join();
        assertGe(target.balanceOf(address(ava)), 99e18);
        // Should have joined less Target than last time
        assertGt(
            100e18 - targetPreJoin,
            targetPreJoin - target.balanceOf(address(ava))
        );
        // Should have joined Target / PT at the ratio of the pool
        assertEq(pt.balanceOf(address(ava)), 98e18);
        (, uint256[] memory balances, ) = vault.getPoolTokens(
            space.getPoolId()
        );
        (uint256 pti, uint256 targeti) = space.getIndices();
        // All tokens are 18 decimals in `setUp`
        uint256 targetPerPrincipal = (balances[targeti] * 1e18) / balances[pti];
        // TargetPerPrincipal * 1 = Target amount in for 1 PT in
        assertEq(
            target.balanceOf(address(ava)),
            targetPreJoin - targetPerPrincipal
        );

        // Jim and ava exit
        jim.exit(space.balanceOf(address(jim)));
        ava.exit(space.balanceOf(address(ava)));

        // Can't swap after liquidity has been removed
        try sid.swapIn(true, 1e12) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, "BAL#001");
        }

        try sid.swapOut(false, 1e12) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, "BAL#001");
        }

        // The first swap only took Target from Jim, so he'll have fewer Target but more PT
        assertClose(target.balanceOf(address(jim)), 99.2e18, 1e17);
        assertClose(target.balanceOf(address(ava)), 99.8e18, 1e17);
        assertClose(pt.balanceOf(address(jim)), 101.5e18, 1e12);
        assertClose(pt.balanceOf(address(ava)), 100.5e18, 1e12);
    }

    function testSpaceFees() public {
        // Target in
        jim.join(0, 20e18);

        // Init some PT in via swap
        sid.swapIn(true, 4e18);

        // Try as much of both in as possible
        jim.join(20e18, 20e18);

        // We can determine the implied price of PT in Target by making a very small swap
        uint256 ptPrice = sid.swapIn(true, 0.0001e18).divDown(0.0001e18);

        uint256 balance = 100e18;
        uint256 startingPositionValue = balance + balance.mulDown(ptPrice);

        // price execution is getting worse for pt out
        uint256 targetInFor1PrincipalOut = 0;
        for (uint256 i = 0; i < 20; i++) {
            uint256 _targetInFor1PrincipalOut = ava.swapOut(false);
            assertGt(_targetInFor1PrincipalOut, targetInFor1PrincipalOut);
            targetInFor1PrincipalOut = _targetInFor1PrincipalOut;
            // swap the pts back in
            ava.swapIn(true, 1e18);
        }

        // price execution is getting worse for target out
        uint256 ptInFor1TargetOut = 0;
        for (uint256 i = 0; i < 20; i++) {
            // price execution is getting worse
            uint256 _ptInFor1TargetOut = ava.swapOut(true);
            assertGt(_ptInFor1TargetOut, ptInFor1TargetOut);
            ptInFor1TargetOut = _ptInFor1TargetOut;
            // swap the target back in
            ava.swapIn(false, 1e18);
        }

        // price execution is getting worse for pt in
        uint256 targetOutFor1PrincipalIn = type(uint256).max;
        for (uint256 i = 0; i < 20; i++) {
            // price execution is getting worse
            uint256 _targetOutFor1PrincipalIn = ava.swapIn(true);
            assertLt(_targetOutFor1PrincipalIn, targetOutFor1PrincipalIn);
            targetOutFor1PrincipalIn = _targetOutFor1PrincipalIn;
            // swap the target back in
            ava.swapIn(false, _targetOutFor1PrincipalIn);
        }

        // price execution is getting worse for target in
        uint256 ptOutFor1TargetIn = type(uint256).max;
        for (uint256 i = 0; i < 20; i++) {
            // price execution is getting worse
            uint256 _ptOutFor1TargetIn = ava.swapIn(false);
            assertLt(_ptOutFor1TargetIn, ptOutFor1TargetIn);
            ptOutFor1TargetIn = _ptOutFor1TargetIn;
            // swap the pts back in
            ava.swapIn(true, _ptOutFor1TargetIn);
        }

        jim.exit(space.balanceOf(address(jim)));
        uint256 currentPositionValue = target.balanceOf(address(jim)) +
            pt.balanceOf(address(jim)).mulDown(ptPrice);
        assertGt(currentPositionValue, startingPositionValue);
    }

    function testApproachesOne() public {
        // Target in
        jim.join(0, 10e18);

        // Init some PT in
        sid.swapIn(true, 5.5e18);

        // Try as much of both in as possible
        jim.join(10e18, 10e18);

        vm.warp(maturity - 1);

        assertClose(sid.swapIn(true).mulDown(adapter.scale()), 1e18, 1e11);
        assertClose(
            sid.swapIn(false, uint256(1e18).divDown(adapter.scale())),
            1e18,
            1e11
        );
    }

    function testConstantSumAfterMaturity() public {
        // Target in
        jim.join(0, 10e18);

        // Init some PT in
        sid.swapIn(true, 5.5e18);

        // Try as much of both in as possible
        jim.join(10e18, 10e18);

        vm.warp(maturity + 1);

        assertClose(sid.swapIn(true).mulDown(adapter.scale()), 1e18, 1e7);
        assertClose(
            sid.swapIn(false, uint256(1e18).divDown(adapter.scale())),
            1e18,
            1e7
        );
    }

    function testCantJoinAfterMaturity() public {
        vm.warp(maturity + 1);

        try jim.join(0, 10e18) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.POOL_PAST_MATURITY);
        }
    }

    function testProtocolFees() public {
        IProtocolFeesCollector protocolFeesCollector = vault
            .getProtocolFeesCollector();

        // Grant protocolFeesCollector.setSwapFeePercentage role
        bytes32 actionId = Authentication(address(protocolFeesCollector))
            .getActionId(protocolFeesCollector.setSwapFeePercentage.selector);
        authorizer.grantRole(actionId, address(this));
        protocolFeesCollector.setSwapFeePercentage(0.1e18);

        assertEq(space.balanceOf(address(protocolFeesCollector)), 0);

        // Initialize liquidity
        jim.join(0, 10e18);
        jim.swapIn(true, 5.5e18);
        jim.join(10e18, 10e18);

        ava.join(10e18, 10e18);

        uint256 NUM_WASH_TRADES = 6;

        emit log_named_uint("PT", pt.balanceOf(address(ava)));
        emit log_named_uint("target", target.balanceOf(address(ava)));

        // Fee controller BPT before the swap run
        uint256 feeControllerBPTPre = space.balanceOf(
            address(protocolFeesCollector)
        );

        uint256 expectedFeesPaid = 0;

        // Make some swaps
        for (uint256 i = 0; i < NUM_WASH_TRADES; i++) {
            // 5% of yield on each trade
            uint256 targetIn = sid.swapOut(false);
            uint256 idealYield = 1e18 - (targetIn * 0.95e18) / 1e18;
            uint256 feeOnYield = (idealYield * 0.05e18) / 1e18;
            expectedFeesPaid += feeOnYield;

            uint256 targetOut = sid.swapIn(true);
            idealYield = 1e18 - (targetOut * 0.95e18) / 1e18;
            feeOnYield = (idealYield * 0.05e18) / 1e18;
            expectedFeesPaid += feeOnYield;
        }

        // No additional BPT shares are minted for the controller until somebody joins or exits
        assertEq(
            space.balanceOf(address(protocolFeesCollector)),
            feeControllerBPTPre
        );
        ava.exit(space.balanceOf(address(ava)));

        uint256 feeControllerNewBPT = space.balanceOf(
            address(protocolFeesCollector)
        ) - feeControllerBPTPre;

        // Transfer fee controller's new BPT to sam, then redeem it
        vm.prank(
            address(protocolFeesCollector),
            address(protocolFeesCollector)
        );
        space.transfer(address(sam), feeControllerNewBPT);
        sam.exit(space.balanceOf(address(sam)));

        emit log_named_uint("sam PTs", pt.balanceOf(address(sam)));
        emit log_named_uint("sam target", target.balanceOf(address(sam)));
        emit log_named_uint("expectedFeesPaid", expectedFeesPaid);

        // Sid has his entire iniital PT balance back
        assertEq(pt.balanceOf(address(sid)), 100e18);

        // Sid has lost Target from trading fees
        assertLt(target.balanceOf(address(sid)), 100e18);

        emit log_named_uint("lost", 100e18 - target.balanceOf(address(sid)));

        // assertEq(
        //     space.balanceOf(address(protocolFeesCollector)),
        //     0
        // );

        // 7502641632334072
        // 7488891101757368

        // jim loss due to fees
        // protocol controller gain due to fees (lines up with % of yield traded)
        // fee controller should own x% of liquidity (based on x% of fees)

        // TODO fees don't eat into non-trade invariant growth
        // TODO fees are correctly proportioned to the fee set in the vault
        // time goes by
    }

    function testTinySwaps() public {
        jim.join(0, 10e18);
        sid.swapIn(true, 5.5e18);
        jim.join(10e18, 10e18);

        // Swaps in can fail for being too small
        try sid.swapIn(true, 1e6) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.SWAP_TOO_SMALL);
        }
        try sid.swapIn(false, 1e6) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.SWAP_TOO_SMALL);
        }

        // Swaps outs don't fail, but they ask for very high amounts in
        // (rouding in favor of the LP has a big effect on small swaps)
        assertGt(sid.swapOut(true, 1e6), 2e6);
        assertGt(sid.swapOut(false, 1e6), 2e6);
    }

    function testJoinDifferentScaleValues() public {
        // Jim join Target in
        jim.join(0, 10e18);

        // Sid inits PT
        sid.swapIn(true, 5.5e18);

        uint256 initScale = adapter.scale();

        // Determine how much Target Jim gets for one PT
        uint256 targetOutForOnePrincipalInit = jim.swapIn(true);
        // Swap that Target back in to restore the AMM state to before the prev swap
        jim.swapIn(false, targetOutForOnePrincipalInit);

        // Ava tries to join both in
        ava.join();
        // BPT from Ava's (1 PT, 1 Target) join
        uint256 bptFromJoin = space.balanceOf(address(ava));
        uint256 targetInFromJoin = INTIAL_USER_BALANCE -
            target.balanceOf(address(ava));
        uint256 ptInFromJoin = INTIAL_USER_BALANCE - pt.balanceOf(address(ava));

        vm.warp(1 days);
        uint256 scale1Week = adapter.scale();
        ava.join();

        // Ava's BPT out will exactly equal her first join
        // Since the Target is worth more, she essentially got fewer BPT for the same amount of Underlying
        assertClose(
            bptFromJoin,
            space.balanceOf(address(ava)) - bptFromJoin,
            1e3
        );
        // Same amount of Target in (but it's worth more now)
        assertClose(
            targetInFromJoin * 2,
            INTIAL_USER_BALANCE - target.balanceOf(address(ava)),
            1e3
        );
        // Same amount of PT in
        assertClose(
            ptInFromJoin * 2,
            INTIAL_USER_BALANCE - pt.balanceOf(address(ava)),
            1e3
        );

        // Ava can exit her entire LP position just fine
        ava.exit(space.balanceOf(address(ava)));

        uint256 targetOutForOnePrincipal1Week = jim.swapIn(true);
        // Gets fewer target out for one PT when Target is worth more
        assertGt(targetOutForOnePrincipalInit, targetOutForOnePrincipal1Week);
        // There is some change due to the YS invariant, but it's not much in 1 days time
        // With the rate the Target is increasing in value, its growth should account for most of the change
        // in swap rate
        assertClose(
            targetOutForOnePrincipalInit,
            targetOutForOnePrincipal1Week.mulDown(
                scale1Week.divDown(initScale)
            ),
            1e15
        );
    }

    function testDifferentDecimals() public {
        // Setup ----
        // Set PT/Yield to 8 decimals
        MockDividerSpace divider = new MockDividerSpace(8);
        // Set Target to 9 decimals
        MockAdapterSpace adapter = new MockAdapterSpace(9);
        SpaceFactory spaceFactory = new SpaceFactory(
            vault,
            address(divider),
            ts,
            g1,
            g2,
            true
        );
        Space space = Space(spaceFactory.create(address(adapter), maturity));

        (address _pt, , , , , , , , ) = MockDividerSpace(divider).series(
            address(adapter),
            maturity
        );
        ERC20Mintable pt = ERC20Mintable(_pt);
        ERC20Mintable _target = ERC20Mintable(adapter.target());

        User max = new User(vault, space, pt, _target);
        _target.mint(address(max), 100e9);
        pt.mint(address(max), 100e8);

        User eve = new User(vault, space, pt, _target);
        _target.mint(address(eve), 100e9);
        pt.mint(address(eve), 100e8);

        // Test ----
        // Max joins 1 Target in
        max.join(0, 1e9);

        // The pool moved one Target out of max's account
        assertEq(_target.balanceOf(address(max)), 99e9);

        // Eve swaps 1 PT in
        eve.swapIn(true, 1e8);

        // Max tries to Join 1 of each (should take 1 PT and some amount of Target)
        max.join(1e8, 1e9);

        assertEq(pt.balanceOf(address(max)), 99e8);

        // Compare Target pulled from max's account to the normal, 18 decimal case
        jim.join(0, 1e18);
        sid.swapIn(true, 1e18);
        jim.join(1e18, 1e18);
        // Determine Jim's Target balance in 9 decimals
        uint256 jimTargetBalance = target.balanceOf(address(jim)) /
            10**(18 - _target.decimals());

        assertClose(_target.balanceOf(address(max)), jimTargetBalance, 1e6);
    }

    function testNonMonotonicScale() public {
        adapter.setScale(1e18);
        jim.join(0, 10e18);
        sid.swapIn(true, 5.5e18);
        jim.join(10e18, 10e18);

        adapter.setScale(1.5e18);
        jim.join(10e18, 10e18);
        uint256 targetOut1 = sid.swapIn(true, 5.5e18);

        adapter.setScale(1e18);
        jim.join(10e18, 10e18);
        uint256 targetOut2 = sid.swapIn(true, 5.5e18);

        // Set scale to below the initial scale
        adapter.setScale(0.5e18);
        jim.join(10e18, 10e18);
        uint256 targetOut3 = sid.swapIn(true, 5.5e18);

        // Receive more and more Target out as the Scale value decreases
        assertGt(targetOut3, targetOut2);
        assertGt(targetOut2, targetOut1);
    }

    function testPairOracle() public {
        vm.warp(0 hours);
        vm.roll(0);

        jim.join(0, 10e18);
        sid.swapIn(true, 2e18);

        uint256 sampleTs;
        (, , , , , , sampleTs) = space.getSample(1);
        // Uninitialized samples are identified by a PT timestamp
        assertEq(sampleTs, 0);

        // Establish the first price
        vm.warp(1 hours);
        vm.roll(1);
        jim.join(1e18, 1e18);

        (, , , , , , sampleTs) = space.getSample(1);
        assertEq(sampleTs, 1 hours);

        vm.warp(2 hours);
        vm.roll(2);
        // Tiny join so that the reserves when the TWAP is deteremined are similar to what they'll be
        // when we determine the instantaneous spot price
        jim.join(1, 1);
        (, , , , , , sampleTs) = space.getSample(2);
        assertEq(sampleTs, 2 hours);

        uint256 targetOut = jim.swapIn(true, 1e12);
        uint256 pTInstSpotPrice = targetOut.divDown(1e12);

        uint256 twapPeriod = 1 hours;
        IPriceOracle.OracleAverageQuery[]
            memory queries = new IPriceOracle.OracleAverageQuery[](1);
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: twapPeriod,
            ago: 0
        });
        uint256[] memory results = space.getTimeWeightedAverage(queries);
        // Token order always the same for tests, PT in terms of Target
        uint256 pTPrice = results[0];

        assertClose(pTPrice, pTInstSpotPrice, 1e14);

        vm.warp(20 hours);
        vm.roll(20);
        jim.join(1, 1);
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: twapPeriod,
            ago: 0
        });
        results = space.getTimeWeightedAverage(queries);
        pTPrice = results[0];

        targetOut = jim.swapIn(true, 1e12);
        pTInstSpotPrice = targetOut.divDown(1e12);

        assertClose(pTPrice, pTInstSpotPrice, 1e14);

        twapPeriod = 22 hours;
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: twapPeriod,
            ago: 0
        });

        // Can't twap beyond what has been recorded
        try space.getTimeWeightedAverage(queries) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, "BAL#312");
        }

        for (uint256 i = 3; i < 1027; i++) {
            vm.warp(i * 1 hours);
            vm.roll(i);
            jim.join(1, 1);
        }

        (, , , , , , sampleTs) = space.getSample(1023);
        assertEq(sampleTs, 1023 hours);

        for (uint256 i = 1027; i < 2050; i++) {
            vm.warp(i * 1 hours);
            vm.roll(i);
            jim.join(1, 1);
        }

        (, , , , , , sampleTs) = space.getSample(1023);
        assertEq(sampleTs, 2047 hours);
    }

    function testPairOracleNoSamples() public {
        vm.warp(0 hours);
        vm.roll(0);

        jim.join(0, 10e18);
        sid.swapIn(true, 2e18);

        // Establish the first price
        vm.warp(1 hours);
        vm.roll(1);
        jim.join(1e18, 1e18);

        uint256 twapPeriod = 1 hours;
        IPriceOracle.OracleAverageQuery[]
            memory queries = new IPriceOracle.OracleAverageQuery[](1);
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: twapPeriod,
            ago: 0
        });
        uint256[] memory results = space.getTimeWeightedAverage(queries);

        uint256 pTPricePre = results[0];

        vm.warp(5 hours);

        queries = new IPriceOracle.OracleAverageQuery[](1);
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: twapPeriod,
            ago: 0
        });
        results = space.getTimeWeightedAverage(queries);

        // Token order always the same for tests
        uint256 pTPrice = results[0];

        assertEq(pTPricePre, pTPrice);
    }

    function testImpliedRateFromPriceUtil() public {
        adapter.setScale(1e18);
        // Compare to implied rates calculated externally
        assertClose(space.getImpliedRateFromPrice(0.5e18), 2985577898945961700, 1e14);
        assertClose(space.getImpliedRateFromPrice(0.9e18), 233857315042038880, 1e14);
        assertClose(space.getImpliedRateFromPrice(0.98e18), 41117876703261835, 1e14);

        // Warp halfway through the term
        vm.warp(7905600);
        assertClose(space.getImpliedRateFromPrice(0.9e18), 522403873882749400, 1e14);
        assertClose(space.getImpliedRateFromPrice(0.98e18), 83926433191108040, 1e14);

        // Warp 7/8ths of the way through the term
        vm.warp(13834800);
        assertClose(space.getImpliedRateFromPrice(0.9e18), 4372996124019022000, 1e14);
        assertClose(space.getImpliedRateFromPrice(0.98e18), 380381815250082860, 1e14);

        vm.warp(maturity);
        assertEq(space.getImpliedRateFromPrice(0.9e18), 0);

        vm.warp(0);
        // Try a different scale
        adapter.setScale(2e18);
        assertClose(space.getImpliedRateFromPrice(0.45e18), 233857315042038880, 1e14);
    }

    function testPriceFromImpliedRateUtil() public {
        adapter.setScale(1e18);
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.5e18)
            ),
            0.5e18,
            1e14
        );
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.9e18)
            ),
            0.9e18,
            1e14
        );
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.98e18)
            ),
            0.98e18,
            1e14
        );

        vm.warp(7905600);
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.9e18)
            ),
            0.9e18,
            1e14
        );
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.98e18)
            ),
            0.98e18,
            1e14
        );

        vm.warp(13834800);
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.9e18)
            ),
            0.9e18,
            1e14
        );
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.98e18)
            ),
            0.98e18,
            1e14
        );


        vm.warp(maturity);
        assertEq(space.getPriceFromImpliedRate(0.1e18), 1e18);

        vm.warp(0);
        adapter.setScale(2e18);
        assertClose(
            space.getPriceFromImpliedRate(
                space.getImpliedRateFromPrice(0.45e18)
            ),
            0.45e18,
            1e14
        );
    }

    function testFairBptPrice() public {
        adapter.setScale(1e18);
        vm.warp(0 hours);
        vm.roll(0);

        jim.join(0, 10e18);
        sid.swapIn(true, 2e18);

        // Will fail with an invalid seconds query if the oracle isn't ready
        try space.getFairBPTPrice(1 hours) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, "BAL#312");
        }

        // Establish the first price
        vm.warp(1 hours);
        vm.roll(1);
        jim.join(1e18, 1e18);

        // Establish the second price
        vm.warp(2 hours);
        vm.roll(2);
        jim.join(1e18, 1e18);

        IPriceOracle.OracleAverageQuery[]
            memory queries = new IPriceOracle.OracleAverageQuery[](1);
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: 1 hours,
            ago: 120
        });
        uint256[] memory results = space.getTimeWeightedAverage(queries);
        uint256 fairPTPriceInTarget1 = results[0];

        uint256 theoFairBptValue1 = space.getFairBPTPrice(10 minutes);
        (, uint256[] memory balances, ) = vault.getPoolTokens(
            space.getPoolId()
        );

        // The BPT value using the safe price and the spot reserves
        uint256 spotBptValueFairPrice1 = balances[space.pti()]
            .mulDown(fairPTPriceInTarget1)
            .add(balances[1 - space.pti()])
            .divDown(space.totalSupply());

        // Since the oracle price and the current spot price are the same, 
        // they fair equilibrium BPT price should be very close the actual spot BPT price
        assertClose(spotBptValueFairPrice1, theoFairBptValue1, 1e14);


        // Swapping in within the same block as the last join won't update the oracle 
        // (max of one price stored per block), 
        // but it will update the spot reserves
        sid.swapIn(true, 2e18);

        queries = new IPriceOracle.OracleAverageQuery[](1);
        queries[0] = IPriceOracle.OracleAverageQuery({
            variable: IPriceOracle.Variable.PAIR_PRICE,
            secs: 1 hours,
            ago: 120
        });
        results = space.getTimeWeightedAverage(queries);
        uint256 fairPTPriceInTarget2 = results[0];

        assertEq(fairPTPriceInTarget1, fairPTPriceInTarget2);

        uint256 theoFairBptValue2 = space.getFairBPTPrice(10 minutes);
        // So the theoretical BPT equilibrium price has not changed much
        assertClose(theoFairBptValue1, theoFairBptValue2, 2e15);
        // Whereas the spot value fair price is notably different
        (, balances, ) = vault.getPoolTokens(
            space.getPoolId()
        );
        uint256 spotBptValueFairPrice2 = balances[space.pti()]
            .mulDown(fairPTPriceInTarget1)
            .add(balances[1 - space.pti()])
            .divDown(space.totalSupply());
        assertTrue(!isClose(spotBptValueFairPrice1, spotBptValueFairPrice2, 9e15));
    }

    // testPriceNeverAboveOne
}
