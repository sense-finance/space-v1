// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// Testing utils
import {DSTest} from "@sense-finance/v1-core/src/tests/test-helpers/test.sol";
import {MockDividerSpace, MockAdapterSpace, ERC20Mintable} from "./utils/Mocks.sol";
import {VM} from "./utils/VM.sol";

// External references
import {Vault, IVault, IWETH} from "@balancer-labs/v2-vault/contracts/Vault.sol";
import {Authorizer} from "@balancer-labs/v2-vault/contracts/Authorizer.sol";
import {FixedPoint} from "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";

// Internal references
import {SpaceFactory} from "../SpaceFactory.sol";
import {Space} from "../Space.sol";
import {Errors} from "../Errors.sol";

contract SpaceFactoryTest is DSTest {
    using FixedPoint for uint256;

    VM internal constant vm = VM(HEVM_ADDRESS);
    IWETH internal constant weth =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    Vault internal vault;
    SpaceFactory internal spaceFactory;
    MockDividerSpace internal divider;
    MockAdapterSpace internal adapter;
    uint256 internal maturity1;
    uint256 internal maturity2;
    uint256 internal maturity3;

    function setUp() public {
        // Init normalized starting conditions
        vm.warp(0);
        vm.roll(0);

        // Create mocks
        divider = new MockDividerSpace(18);
        adapter = new MockAdapterSpace(18);

        maturity1 = 15811200; // 6 months in seconds
        maturity2 = 31560000; // 1 yarn in seconds
        maturity3 = 63120000; // 2 years in seconds

        Authorizer authorizer = new Authorizer(address(this));
        vault = new Vault(authorizer, weth, 0, 0);
        spaceFactory = new SpaceFactory(vault, address(divider));
    }

    function testCreatePool() public {
        address space = spaceFactory.create(address(adapter), maturity1);

        assertTrue(space != address(0));
        assertEq(space, spaceFactory.pools(address(adapter), maturity1));

        try spaceFactory.create(address(adapter), maturity1) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.POOL_ALREADY_DEPLOYED);
        }
    }
}
