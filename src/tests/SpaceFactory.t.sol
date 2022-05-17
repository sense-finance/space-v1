// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// Testing utils
import { DSTest } from "@sense-finance/v1-core/src/tests/test-helpers/test.sol";
import { MockDividerSpace, MockAdapterSpace, ERC20Mintable } from "./utils/Mocks.sol";
import { Vm } from "forge-std/Vm.sol";

// External references
import { Vault, IVault, IWETH } from "@balancer-labs/v2-vault/contracts/Vault.sol";
import { Authorizer } from "@balancer-labs/v2-vault/contracts/Authorizer.sol";
import { FixedPoint } from "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";

// Internal references
import { SpaceFactory } from "../SpaceFactory.sol";
import { Space } from "../Space.sol";
import { Errors } from "../Errors.sol";

contract SpaceFactoryTest is DSTest {
    using FixedPoint for uint256;

    Vm internal constant vm = Vm(HEVM_ADDRESS);
    IWETH internal constant weth =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    Vault internal vault;
    SpaceFactory internal spaceFactory;
    MockDividerSpace internal divider;
    MockAdapterSpace internal adapter;
    uint256 internal maturity1;
    uint256 internal maturity2;
    uint256 internal maturity3;

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
        // 1 / 0.95 for selling PTs
        g2 = (FixedPoint.ONE * 1000).divDown(FixedPoint.ONE * 950);

        maturity1 = 15811200; // 6 months in seconds
        maturity2 = 31560000; // 1 yarn in seconds
        maturity3 = 63120000; // 2 years in seconds

        Authorizer authorizer = new Authorizer(address(this));
        vault = new Vault(authorizer, weth, 0, 0);
        spaceFactory = new SpaceFactory(
            vault,
            address(divider),
            ts,
            g1,
            g2,
            true
        );
    }

    function testCreatePool() public {
        address space = spaceFactory.create(address(adapter), maturity1);

        assertTrue(space != address(0));
        assertEq(space, spaceFactory.pools(address(adapter), maturity1));

        try spaceFactory.create(address(adapter), maturity1) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.POOL_ALREADY_EXISTS);
        }
    }

    function testSetParams() public {
        Space space = Space(spaceFactory.create(address(adapter), maturity1));

        // Sanity check that params set in constructor are used
        assertEq(space.ts(), ts);
        assertEq(space.g1(), g1);
        assertEq(space.g2(), g2);

        ts = FixedPoint.ONE.divDown(FixedPoint.ONE * 100);
        g1 = (FixedPoint.ONE * 900).divDown(FixedPoint.ONE * 1000);
        g2 = (FixedPoint.ONE * 1000).divDown(FixedPoint.ONE * 900);
        spaceFactory.setParams(ts, g1, g2, true);
        space = Space(spaceFactory.create(address(adapter), maturity2));

        // If params are updated, the new ones are used in the next deployment
        assertEq(space.ts(), ts);
        assertEq(space.g1(), g1);
        assertEq(space.g2(), g2);

        // Fee params are validated
        g1 = (FixedPoint.ONE * 1000).divDown(FixedPoint.ONE * 900);
        try spaceFactory.setParams(ts, g1, g2, true) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.INVALID_G1);
        }
        g1 = (FixedPoint.ONE * 900).divDown(FixedPoint.ONE * 1000);
        g2 = (FixedPoint.ONE * 900).divDown(FixedPoint.ONE * 1000);
        try spaceFactory.setParams(ts, g1, g2, true) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.INVALID_G2);
        }
    }

    function testSetPool() public {
        // 1. Set pool address for maturity1
        spaceFactory.setPool(address(adapter), maturity1, address(0x1337));
        // Check that the pool was set on the registry
        assertEq(spaceFactory.pools(address(adapter), maturity1), address(0x1337));

        // Check that a new pool can't be deployed on the same maturity
        try spaceFactory.create(address(adapter), maturity1) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.POOL_ALREADY_EXISTS);
        }

         // 2. Deploy a pool for maturity2
        address pool = spaceFactory.create(address(adapter), maturity2);
        // Check that the pool was set on the registry
        assertEq(spaceFactory.pools(address(adapter), maturity2), pool);

        // Check that another pool can't be deployed on the same maturity
        try spaceFactory.create(address(adapter), maturity2) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.POOL_ALREADY_EXISTS);
        }
    }

    function testFuzzSetPool(address lad) public {
        vm.record();
        vm.assume(lad != address(this)); // For any address other than the testing contract
        address NEW_SPACE_POOL = address(0xbabe);

        // 1. Impersonate the fuzzed address and try to add the pool address
        vm.prank(lad);
        vm.expectRevert("UNTRUSTED");
        spaceFactory.setPool(address(adapter), maturity1, NEW_SPACE_POOL);
    }
}
