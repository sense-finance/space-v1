// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import { FixedPoint } from "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import { BasePoolFactory } from "@balancer-labs/v2-pool-utils/contracts/factories/BasePoolFactory.sol";
import { IVault } from "@balancer-labs/v2-vault/contracts/interfaces/IVault.sol";
import { Trust } from "@sense-finance/v1-utils/src/Trust.sol";

import { Space } from "./Space.sol";
import { Errors, _require } from "./Errors.sol";

interface DividerLike {
    function series(
        address, /* adapter */
        uint256 /* maturity */
    )
        external
        returns (
            address, /* principal token */
            address, /* yield token */
            address, /* sponsor */
            uint256, /* reward */
            uint256, /* iscale */
            uint256, /* mscale */
            uint256, /* maxscale */
            uint128, /* issuance */
            uint128 /* tilt */
        );

    function pt(address adapter, uint256 maturity) external returns (address);

    function yt(address adapter, uint256 maturity) external returns (address);
}

contract SpaceFactory is Trust {
    /* ========== PUBLIC IMMUTABLES ========== */

    /// @notice Balancer Vault
    IVault public immutable vault;

    /// @notice Sense Divider
    address public immutable divider;

    /* ========== PUBLIC MUTABLE STORAGE ========== */

    /// @notice Pool registry (adapter -> maturity -> pool address)
    mapping(address => mapping(uint256 => address)) public pools;

    /// @notice Yieldspace config
    uint256 public ts;
    uint256 public g1;
    uint256 public g2;

    /// @notice Oracle flag
    bool public oracleEnabled;

    constructor(
        IVault _vault,
        address _divider,
        uint256 _ts,
        uint256 _g1,
        uint256 _g2,
        bool _oracleEnabled
    ) Trust(msg.sender) {
        vault = _vault;
        divider = _divider;
        ts = _ts;
        g1 = _g1;
        g2 = _g2;
        oracleEnabled = _oracleEnabled;
    }

    /// @notice Deploys a new `Space` contract
    function create(address adapter, uint256 maturity) external returns (address pool) {
        _require(pools[adapter][maturity] == address(0), Errors.POOL_ALREADY_EXISTS);

        pool = address(new Space(
            vault,
            adapter,
            maturity,
            DividerLike(divider).pt(
                adapter,
                maturity
            ),
            ts,
            g1,
            g2,
            oracleEnabled
        ));

        pools[adapter][maturity] = pool;
    }

    function setParams(
        uint256 _ts,
        uint256 _g1,
        uint256 _g2,
        bool _oracleEnabled
    ) public requiresTrust {
        // g1 is for swapping Targets to PT and should discount the effective interest
        _require(_g1 <= FixedPoint.ONE, Errors.INVALID_G1);
        // g2 is for swapping PT to Target and should mark the effective interest up
        _require(_g2 >= FixedPoint.ONE, Errors.INVALID_G2);

        ts = _ts;
        g1 = _g1;
        g2 = _g2;
        oracleEnabled = _oracleEnabled;
    }

    /// @notice Admin action to set a pool address on the "pools" registry
    /// @dev Adding a pool to the mapping prevents a new pool from being deployed for that Series from this factory
    function setPool(address adapter, uint256 maturity, address pool) public requiresTrust {
        _require(pools[adapter][maturity] == address(0), Errors.POOL_ALREADY_EXISTS);

        pools[adapter][maturity] = pool;
    }
}