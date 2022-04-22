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

interface AdapterLike {
    function adapterParams()
        external
        virtual
        returns (
            address,
            address,
            uint256,
            uint256,
            uint256,
            uint64,
            uint48,
            uint16,
            uint256,
            uint256,
            uint256,
            bool
        );
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

    constructor(
        IVault _vault,
        address _divider
    ) Trust(msg.sender) {
        vault = _vault;
        divider = _divider;
    }

    /// @notice Deploys a new `Space` contract
    function create(address adapter, uint256 maturity) external returns (address pool) {
        _require(pools[adapter][maturity] == address(0), Errors.POOL_ALREADY_DEPLOYED);

        /// @notice Yieldspace configuration
        (, , , , , , , , uint256 ts, uint256 g1, uint256 g2, bool oracleEnabled) = AdapterLike(adapter).adapterParams();

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
}
