// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// External references
import { FixedPoint } from "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";
import { Math as BasicMath } from "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";
import { BalancerPoolToken } from "@balancer-labs/v2-pool-utils/contracts/BalancerPoolToken.sol";
import { ERC20 } from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/ERC20.sol";
import { LogCompression } from "@balancer-labs/v2-solidity-utils/contracts/helpers/LogCompression.sol";
import { PoolPriceOracle } from "@balancer-labs/v2-pool-utils/contracts/oracle/PoolPriceOracle.sol";

import { IMinimalSwapInfoPool } from "@balancer-labs/v2-vault/contracts/interfaces/IMinimalSwapInfoPool.sol";
import { IVault } from "@balancer-labs/v2-vault/contracts/interfaces/IVault.sol";
import { IERC20 } from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/IERC20.sol";

import { Errors, _require } from "./Errors.sol";

interface AdapterLike {
    function scale() external returns (uint256);

    function scaleStored() external view returns (uint256);

    function target() external view returns (address);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function getUnderlyingPrice() external view returns (uint256);
}

/*
                    SPACE
        *   '*
                *
                        *
                            *
                    *
                            *
                .                      .
                .                      ;
                :                  - --+- -
                !           .          !

*/

/// @notice A Yieldspace implementation extended such that LPs can deposit
/// [Principal Token, Yield-bearing asset], rather than [Principal Token, Underlying], while keeping the benefits of the
/// yieldspace invariant (e.g. it can hold [Principal Token, cDAI], rather than [Principal Token, DAI], while still operating
/// in "yield space" for the principal token side. See the YieldSpace paper for more https://yield.is/YieldSpace.pdf)
/// @dev We use much more internal storage here than in other Sense contracts because it
/// conforms to Balancer's own style, and we're using several Balancer functions that play nicer if we do.
/// @dev Requires an external "Adapter" contract with a `scale()` function which returns the
/// current exchange rate from Target to the Underlying asset.
contract Space is IMinimalSwapInfoPool, BalancerPoolToken, PoolPriceOracle {
    using FixedPoint for uint256;

    /* ========== STRUCTURES ========== */

    struct OracleData {
        uint16 oracleIndex;
        uint32 oracleSampleInitialTimestamp;
        bool oracleEnabled;
        int200 logInvariant;
    }

    /* ========== CONSTANTS ========== */

    /// @notice Minimum BPT we can have for this pool after initialization
    uint256 public constant MINIMUM_BPT = 1e6;

    /// @notice Approx seconds per year to determine the ipmlied rate
    uint256 public constant SECONDS_PER_YEAR = 31540000;

    /* ========== PUBLIC IMMUTABLES ========== */

    /// @notice Adapter address for the associated Series
    address public immutable adapter;

    /// @notice Maturity timestamp for associated Series
    uint256 public immutable maturity;

    /// @notice Principal Token index (there are only two tokens in this pool, so `targeti` is always just the complement)
    uint256 public immutable pti;

    /// @notice Yieldspace config, passed in from the Space Factory
    uint256 public immutable ts;
    uint256 public immutable g1;
    uint256 public immutable g2;

    /* ========== INTERNAL IMMUTABLES ========== */

    /// @dev Balancer pool id (as registered with the Balancer Vault)
    bytes32 internal immutable _poolId;

    /// @dev Token registered at index 0 for this pool
    IERC20 internal immutable _token0;

    /// @dev Token registered at index one for this pool
    IERC20 internal immutable _token1;

    /// @dev Factor needed to scale the PT to 18 decimals
    uint256 internal immutable _scalingFactorPT;

    /// @dev Factor needed to scale the Target token to 18 decimals
    uint256 internal immutable _scalingFactorTarget;

    /// @dev Balancer Vault
    IVault internal immutable _vault;

    /// @dev Contract that collects Balancer protocol fees
    address internal immutable _protocolFeesCollector;

    /* ========== INTERNAL MUTABLE STORAGE ========== */

    /// @dev Scale value for the yield-bearing asset's first `join` (i.e. initialization)
    uint256 internal _initScale;

    /// @dev Invariant tracking for calculating Balancer protocol fees
    uint256 internal _lastToken0Reserve;
    uint256 internal _lastToken1Reserve;

    /// @dev Oracle sample collection metadata
    OracleData internal oracleData;

    constructor(
        IVault vault,
        address _adapter,
        uint256 _maturity,
        address pt,
        uint256 _ts,
        uint256 _g1,
        uint256 _g2,
        bool _oracleEnabled
    ) BalancerPoolToken(AdapterLike(_adapter).name(), AdapterLike(_adapter).symbol()) {
        bytes32 poolId = vault.registerPool(IVault.PoolSpecialization.TWO_TOKEN);

        address target = AdapterLike(_adapter).target();
        IERC20[] memory tokens = new IERC20[](2);

        // Ensure that the array of tokens is correctly ordered
        uint256 _pti = pt < target ? 0 : 1;
        tokens[_pti] = IERC20(pt);
        tokens[1 - _pti] = IERC20(target);
        vault.registerTokens(poolId, tokens, new address[](2));

        // Set Balancer-specific pool config
        _vault = vault;
        _poolId = poolId;
        _token0 = tokens[0];
        _token1 = tokens[1];
        _protocolFeesCollector = address(vault.getProtocolFeesCollector());

        _scalingFactorPT = 10**(BasicMath.sub(uint256(18), ERC20(pt).decimals()));
        _scalingFactorTarget = 10**(BasicMath.sub(uint256(18), ERC20(target).decimals()));

        // Set Yieldspace config
        g1 = _g1; // Fees are baked into factors `g1` & `g2`,
        g2 = _g2; // see the "Fees" section of the yieldspace paper
        ts = _ts;

        // Set Space-specific slots
        pti = _pti;
        adapter = _adapter;
        maturity = _maturity;
        oracleData.oracleEnabled = _oracleEnabled;
    }

    /* ========== BALANCER VAULT HOOKS ========== */

    function onJoinPool(
        bytes32 poolId,
        address, /* sender */
        address recipient,
        uint256[] memory reserves,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    ) external override onlyVault(poolId) returns (uint256[] memory, uint256[] memory) {
        // Space does not have multiple join types like other Balancer pools,
        // instead, its `joinPool` always behaves like `EXACT_TOKENS_IN_FOR_BPT_OUT`

        _require(maturity >= block.timestamp, Errors.POOL_PAST_MATURITY);

        uint256[] memory reqAmountsIn = abi.decode(userData, (uint256[]));

        // Upscale both requested amounts and reserves to 18 decimals
        _upscaleArray(reserves);
        _upscaleArray(reqAmountsIn);

        if (totalSupply() == 0) {
            uint256 initScale = AdapterLike(adapter).scale();

            // Convert target balance into Underlying
            // note: We assume scale values will always be 18 decimals
            uint256 underlyingIn = reqAmountsIn[1 - pti].mulDown(initScale);

            // Just like weighted pool 2 token from the balancer v2 monorepo,
            // we lock MINIMUM_BPT in by minting it for the PT address. This reduces potential
            // issues with rounding and ensures that this code path will only be executed once
            _mintPoolTokens(address(0), MINIMUM_BPT);

            // Mint the recipient BPT comensurate with the value of their join in Underlying
            _mintPoolTokens(recipient, underlyingIn.sub(MINIMUM_BPT));

            // Amounts entering the Pool, so we round up
            _downscaleUpArray(reqAmountsIn);

            // Set the scale value all future deposits will be backdated to
            _initScale = initScale;

            // For the first join, we don't pull any PT, regardless of what the caller requested.
            // This starts this pool off as synthetic Underlying only, as the yieldspace invariant expects
            delete reqAmountsIn[pti];

            // Cache starting Target reserves
            reserves = reqAmountsIn;
        
            // Cache new reserves, post join
            _cacheReserves(reserves);

            return (reqAmountsIn, new uint256[](2));
        } else {
            // Update oracle with upscaled reserves
            _updateOracle(lastChangeBlock, reserves[pti], reserves[1 - pti]);

            // Calculate fees due before updating bpt balances to determine invariant growth from just swap fees
            if (protocolSwapFeePercentage != 0) {
                // This doesn't break the YS virtual reserves efficiency trick because, even though we're minting new BPT, 
                // the BPT is still getting denser faster than it's getting diluted, 
                // meaning that it'll never fall below invariant #23 in the YS paper
                _mintPoolTokens(_protocolFeesCollector, _bptFeeDue(reserves, protocolSwapFeePercentage));
            }

            (uint256 bptToMint, uint256[] memory amountsIn) = _tokensInForBptOut(reqAmountsIn, reserves);

            // Amounts entering the Pool, so we round up
            _downscaleUpArray(amountsIn);

            // `recipient` receives liquidity tokens
            _mintPoolTokens(recipient, bptToMint);

            // Update reserves for caching
            //
            // No risk of overflow as this function will only succeed if the user actually has `amountsIn` and
            // the max token supply for a well-behaved token is bounded by `uint256 totalSupply`
            reserves[0] += amountsIn[0];
            reserves[1] += amountsIn[1];

            // Cache new reserves, post join
            _cacheReserves(reserves);

            // Inspired by PR #990 in the balancer v2 monorepo, we always return pt dueProtocolFeeAmounts
            // to the Vault, and pay protocol fees by minting BPT directly to the protocolFeeCollector instead
            return (amountsIn, new uint256[](2));
        }
    }

    function onExitPool(
        bytes32 poolId,
        address sender,
        address, /* _recipient */
        uint256[] memory reserves,
        uint256 lastChangeBlock,
        uint256 protocolSwapFeePercentage,
        bytes memory userData
    ) external override onlyVault(poolId) returns (uint256[] memory, uint256[] memory) {
        // Space does not have multiple exit types like other Balancer pools,
        // instead, its `exitPool` always behaves like `EXACT_BPT_IN_FOR_TOKENS_OUT`

        // Upscale reserves to 18 decimals
        _upscaleArray(reserves);

        // Update oracle with upscaled reserves
        _updateOracle(lastChangeBlock, reserves[pti], reserves[1 - pti]);

        // Calculate fees due before updating bpt balances to determine invariant growth from just swap fees
        if (protocolSwapFeePercentage != 0) {
            _mintPoolTokens(_protocolFeesCollector, _bptFeeDue(reserves, protocolSwapFeePercentage));
        }

        // Determine what percentage of the pool the BPT being passed in represents
        uint256 bptAmountIn = abi.decode(userData, (uint256));
        uint256 pctPool = bptAmountIn.divDown(totalSupply());

        // Calculate the amount of tokens owed in return for giving that amount of BPT in
        uint256[] memory amountsOut = new uint256[](2);
        amountsOut[0] = reserves[0].mulDown(pctPool);
        amountsOut[1] = reserves[1].mulDown(pctPool);

        // Amounts are leaving the Pool, so we round down
        _downscaleDownArray(amountsOut);

        // `sender` pays for the liquidity
        _burnPoolTokens(sender, bptAmountIn);

        // Update reserves for caching
        reserves[0] = reserves[0].sub(amountsOut[0]);
        reserves[1] = reserves[1].sub(amountsOut[1]);

        // Cache new invariant and reserves, post exit
        _cacheReserves(reserves);

        return (amountsOut, new uint256[](2));
    }

    function onSwap(
        SwapRequest memory request,
        uint256 reservesTokenIn,
        uint256 reservesTokenOut
    ) external override returns (uint256) {
        bool pTIn = request.tokenIn == _token0 ? pti == 0 : pti == 1;

        uint256 scalingFactorTokenIn = _scalingFactor(pTIn);
        uint256 scalingFactorTokenOut = _scalingFactor(!pTIn);

        // Upscale reserves to 18 decimals
        reservesTokenIn = _upscale(reservesTokenIn, scalingFactorTokenIn);
        reservesTokenOut = _upscale(reservesTokenOut, scalingFactorTokenOut);

        // Update oracle with upscaled reserves
        _updateOracle(
            request.lastChangeBlock, 
            pTIn ? reservesTokenIn : reservesTokenOut,
            pTIn ? reservesTokenOut: reservesTokenIn
        );

        uint256 scale = AdapterLike(adapter).scale();

        if (pTIn) {
            // Add LP supply to PT reserves, as suggested by the yieldspace paper
            reservesTokenIn = reservesTokenIn.add(totalSupply());

            // Backdate the Target reserves and convert to Underlying, as if it were still t0 (initialization)
            reservesTokenOut = reservesTokenOut.mulDown(_initScale);
        } else {
            // Backdate the Target reserves and convert to Underlying, as if it were still t0 (initialization)
            reservesTokenIn = reservesTokenIn.mulDown(_initScale);

            // Add LP supply to PT reserves, as suggested by the yieldspace paper
            reservesTokenOut = reservesTokenOut.add(totalSupply());
        }

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            request.amount = _upscale(request.amount, scalingFactorTokenIn);
            // If Target is being swapped in, convert the amountIn to Underlying using present day Scale
            if (!pTIn) {
                request.amount = request.amount.mulDown(scale);
            }

            // Determine the amountOut
            uint256 amountOut = _onSwap(pTIn, true, request.amount, reservesTokenIn, reservesTokenOut);

            // If PTs are being swapped in, convert the Underlying out back to Target using present day Scale
            if (pTIn) {
                amountOut = amountOut.divDown(scale);
            }

            // AmountOut, so we round down
            return _downscaleDown(amountOut, scalingFactorTokenOut);
        } else {
            request.amount = _upscale(request.amount, scalingFactorTokenOut);
            // If PTs are being swapped in, convert the amountOut from Target to Underlying using present day Scale
            if (pTIn) {
                request.amount = request.amount.mulDown(scale);
            }

            // Determine the amountIn
            uint256 amountIn = _onSwap(pTIn, false, request.amount, reservesTokenIn, reservesTokenOut);

            // If Target is being swapped in, convert the amountIn back to Target using present day Scale
            if (!pTIn) {
                amountIn = amountIn.divDown(scale);
            }

            // amountIn, so we round up
            return _downscaleUp(amountIn, scalingFactorTokenIn);
        }
    }

    /* ========== INTERNAL JOIN/SWAP ACCOUNTING ========== */

    /// @notice Calculate the max amount of BPT that can be minted from the requested amounts in,
    // given the ratio of the reserves, and assuming we don't make any swaps
    function _tokensInForBptOut(uint256[] memory reqAmountsIn, uint256[] memory reserves)
        internal
        view
        returns (uint256, uint256[] memory)
    {
        // Disambiguate reserves wrt token type
        (uint256 pTReserves, uint256 targetReserves) = (reserves[pti], reserves[1 - pti]);

        uint256[] memory amountsIn = new uint256[](2);

        // If the pool has been initialized, but there aren't yet any PT in it
        if (pTReserves == 0) {
            uint256 reqTargetIn = reqAmountsIn[1 - pti];
            // Mint LP shares according to the relative amount of Target being offered
            uint256 bptToMint = BasicMath.mul(totalSupply(), reqTargetIn) / targetReserves;

            // Pull the entire offered Target
            amountsIn[1 - pti] = reqTargetIn;

            return (bptToMint, amountsIn);
        } else {
            // Disambiguate requested amounts wrt token type
            (uint256 reqPTIn, uint256 reqTargetIn) = (reqAmountsIn[pti], reqAmountsIn[1 - pti]);
            // Caclulate the percentage of the pool we'd get if we pulled all of the requested Target in
            uint256 bptToMintTarget = BasicMath.mul(totalSupply(), reqTargetIn) / targetReserves;

            // Caclulate the percentage of the pool we'd get if we pulled all of the requested PT in
            uint256 bptToMintPT = BasicMath.mul(totalSupply(), reqPTIn) / pTReserves;

            // Determine which amountIn is our limiting factor
            if (bptToMintTarget < bptToMintPT) {
                amountsIn[pti] = BasicMath.mul(pTReserves, reqTargetIn) / targetReserves;
                amountsIn[1 - pti] = reqTargetIn;

                return (bptToMintTarget, amountsIn);
            } else {
                amountsIn[pti] = reqPTIn;
                amountsIn[1 - pti] = BasicMath.mul(targetReserves, reqPTIn) / pTReserves;

                return (bptToMintPT, amountsIn);
            }
        }
    }

    /// @notice Calculate the missing variable in the yield space equation given the direction (PT in vs. out)
    /// @dev We round in favor of the LPs, meaning that traders get slightly worse prices than they would if we had full
    /// precision. However, the differences are small (on the order of 1e-11), and should only matter for very small trades.
    function _onSwap(
        bool pTIn,
        bool givenIn,
        uint256 amountDelta,
        uint256 reservesTokenIn,
        uint256 reservesTokenOut
    ) internal view returns (uint256) {
        // xPre = token in reserves pre swap
        // yPre = token out reserves pre swap

        // Seconds until maturity, in 18 decimals
        // After maturity, this pool becomes a constant sum AMM
        uint256 ttm = maturity > block.timestamp ? uint256(maturity - block.timestamp) * FixedPoint.ONE : 0;

        // Time shifted partial `t` from the yieldspace paper (`ttm` adjusted by some factor `ts`)
        uint256 t = ts.mulDown(ttm);

        // Full `t` with fees baked in
        uint256 a = (pTIn ? g2 : g1).mulUp(t).complement();

        // Pow up for `x1` & `y1` and down for `xOrY2` causes the pow induced error for `xOrYPost`
        // to tend towards higher values rather than lower.
        // Effectively we're adding a little bump up for ammountIn, and down for amountOut

        // x1 = xPre ^ a; y1 = yPre ^ a
        uint256 x1 = reservesTokenIn.powUp(a);
        uint256 y1 = reservesTokenOut.powUp(a);

        // y2 = (yPre - amountOut) ^ a; x2 = (xPre + amountIn) ^ a
        //
        // No overflow risk in the addition as Balancer will only allow an `amountDelta` for tokens coming in
        // if the user actually has it, and the max token supply for well-behaved tokens is bounded by the uint256 type
        uint256 xOrY2 = (givenIn ? reservesTokenIn + amountDelta : reservesTokenOut.sub(amountDelta)).powDown(a);

        // x1 + y1 = xOrY2 + xOrYPost ^ a
        // -> xOrYPost ^ a = x1 + y1 - x2
        // -> xOrYPost = (x1 + y1 - xOrY2) ^ (1 / a)
        uint256 xOrYPost = (x1.add(y1).sub(xOrY2)).powUp(FixedPoint.ONE.divDown(a));
        _require(!givenIn || reservesTokenOut > xOrYPost, Errors.SWAP_TOO_SMALL);

        // amountOut = yPre - yPost; amountIn = xPost - xPre
        return givenIn ? reservesTokenOut.sub(xOrYPost) : xOrYPost.sub(reservesTokenIn);
    }

    /* ========== PROTOCOL FEE HELPERS ========== */

    /// @notice Determine the growth in the invariant due to swap fees only
    /// @dev This can't be a view function b/c `Adapter.scale` is not a view function
    function _bptFeeDue(uint256[] memory reserves, uint256 protocolSwapFeePercentage) internal view returns (uint256) {
        uint256 ttm = maturity > block.timestamp ? uint256(maturity - block.timestamp) * FixedPoint.ONE : 0;
        uint256 a = ts.mulDown(ttm).complement();

        // Invariant growth from time only
        uint256 timeOnlyInvariant = _lastToken0Reserve.powDown(a).add(_lastToken1Reserve.powDown(a));

        // `x` & `y` for the actual invariant, with growth from time and fees
        uint256 x = reserves[pti].add(totalSupply()).powDown(a);
        uint256 y = reserves[1 - pti].mulDown(_initScale).powDown(a);
        uint256 fullInvariant = x.add(y);

        if (fullInvariant <= timeOnlyInvariant) {
            // Similar to the invariant check in balancer-v2-monorepo/**/WeightedMath.sol,
            // this shouldn't happen outside of rounding errors, yet we keep this so that those
            // potential errors don't lead to a locked state
            return 0;
        }

        // The formula to calculate fees due is:
        //
        // where:
        //   `g` is the factor by which reserves have grown
        //   `time-only invariant` = x^a + y^a
        //   `realized invariant`  = (g*x)^a + (g*y)^a
        //
        //              /   realized invariant     \ ^ (1/a)
        // `growth` =  |   ----------------------  |
        //              \   time-only invariant    /
        //
        //
        // This gets us the proportional growth of all token balances, or `growth`
        //
        // We can plug this into the following equation from `WeightedMath` in PR#1111 on the Balancer monorepo:
        //
        //             supply * protocol fee * (growth - 1)
        //                 ---------------------------
        //                          growth
        // toMint = --------------------------------------
        //              1 - protocol fee * (growth - 1)
        //                ---------------------------
        //                          growth

        uint256 growth = fullInvariant.divDown(timeOnlyInvariant).powDown(FixedPoint.ONE.divDown(a));
        uint256 k = protocolSwapFeePercentage.mulDown(growth.sub(FixedPoint.ONE)).divDown(growth);

        return totalSupply().mulDown(k).divDown(k.complement());
    }

    /// @notice Cache the given reserve amounts
    /// @dev if the oracle is set, this function will also cache the invariant and supply
    function _cacheReserves(uint256[] memory reserves) internal {
        uint256 reservePT = reserves[pti].add(totalSupply());
        // Calculate the backdated Target reserve
        uint256 reserveUnderlying = reserves[1 - pti].mulDown(_initScale);

        // Caclulate the invariant and store everything
        uint256 lastToken0Reserve;
        uint256 lastToken1Reserve;
        if (pti == 0) {
            lastToken0Reserve = reservePT;
            lastToken1Reserve = reserveUnderlying;
        } else {
            lastToken0Reserve = reserveUnderlying;
            lastToken1Reserve = reservePT;
        }

        if (oracleData.oracleEnabled) {
            // If the oracle is enabled, cache the current invarant as well so that callers can determine liquidity
            uint256 ttm = maturity > block.timestamp ? uint256(maturity - block.timestamp) * FixedPoint.ONE : 0;
            uint256 a = ts.mulDown(ttm).complement();

            oracleData.logInvariant = int200(
                LogCompression.toLowResLog(
                    lastToken0Reserve.powDown(a).add(lastToken1Reserve.powDown(a))
                )
            );
        }

        _lastToken0Reserve = lastToken0Reserve;
        _lastToken1Reserve = lastToken1Reserve;
    }

    /* ========== ORACLE HELPERS ========== */

    /// @notice Update the oracle with the current index and timestamp
    /// @dev Must receive reserves that have already been upscaled
    /// @dev Acts as a no-op if:
    ///     * the oracle is not enabled 
    ///     * a price has already been stored for this block
    ///     * the Target side of the pool doesn't have enough liquidity
    function _updateOracle(
        uint256 lastChangeBlock,
        uint256 balancePT,
        uint256 balanceTarget
    ) internal {
        // The Target side of the pool must have at least 0.01 units of liquidity for us to collect a price sample
        // note: additional liquidity contraints may be enforced outside of this contract via the invariant TWAP
        if (oracleData.oracleEnabled && block.number > lastChangeBlock && balanceTarget >= 1e16) {

            // Make a small pseudo swap to determine the instantaneous spot price
            uint256 underlyingOut = _onSwap(
                true, // PT in
                true, // given in
                1e12, // 1e12 PTs in
                balancePT.add(totalSupply()),
                balanceTarget.mulDown(_initScale)
            );
            // Cacluate the price of one PT in Target terms
            uint256 pTPriceInTarget = underlyingOut.divDown(AdapterLike(adapter).scale()).divDown(1e12);
            // Following Balancer's oracle conventions, get price of token 1 in terms of token 0 and
            // and the price of one BPT in terms of token 0
            //
            // note: b/c reserves are upscaled coming into this function,
            // price is already upscaled to 18 decimals, regardless of the decimals used for token 0 & 1
            uint256 pairPrice;
            uint256 bptPrice;
            if (pti == 0) {
                // PT terms
                pairPrice = FixedPoint.ONE.divDown(pTPriceInTarget);
                bptPrice = balancePT.divDown(totalSupply()) + balanceTarget.divDown(totalSupply()).mulDown(pairPrice);
            } else {
                // Target terms
                pairPrice = pTPriceInTarget;
                bptPrice = balancePT.divDown(totalSupply()).mulDown(pairPrice) + balanceTarget.divDown(totalSupply());
            }

            uint256 oracleUpdatedIndex = _processPriceData(
                oracleData.oracleSampleInitialTimestamp,
                oracleData.oracleIndex,
                LogCompression.toLowResLog(pairPrice),
                LogCompression.toLowResLog(bptPrice),
                int256(oracleData.logInvariant)
            );

            if (oracleData.oracleIndex != oracleUpdatedIndex) {
                oracleData.oracleSampleInitialTimestamp = uint32(block.timestamp);
                oracleData.oracleIndex = uint16(oracleUpdatedIndex);
            }
        }
    }

    function _getOracleIndex() internal view override returns (uint256) {
        return oracleData.oracleIndex;
    }

    /* ========== PUBLIC GETTERS ========== */

    /// @notice Get the APY implied rate for PTs given a price in Target
    function getImpliedRateFromPrice(uint256 pTPriceInTarget) public view returns (uint256 impliedRate) {
        if (block.timestamp >= maturity) {
            return 0;
        }

        impliedRate = FixedPoint.ONE
            .divDown(pTPriceInTarget.mulDown(AdapterLike(adapter).scaleStored()))
            .powDown(SECONDS_PER_YEAR.divDown(maturity - block.timestamp))
            .sub(FixedPoint.ONE);
    }

    /// @notice Get price of PTs in Target terms given a price for PTs in Target
    function getPriceFromImpliedRate(uint256 impliedRate) public view returns (uint256 pTPriceInTarget) {
        if (block.timestamp >= maturity) {
            return FixedPoint.ONE;
        }

        pTPriceInTarget = FixedPoint.ONE
            .divDown(impliedRate.add(FixedPoint.ONE)
            .powDown((maturity - block.timestamp)
            .divDown(SECONDS_PER_YEAR)))
            .divDown(AdapterLike(adapter).scaleStored());
    }

    /// @notice Get the "fair" price for the BPT tokens given a correct price for PTs
    /// in terms of Target. i.e. the price of one BPT in terms of Target using reserves
    /// as they would be if they accurately reflected the passed in PT price
    function getFairBPTPrice(uint256 ptTwapDuration)
        public
        view
        returns (uint256 fairBptPriceInTarget)
    {
        OracleAverageQuery[] memory queries = new OracleAverageQuery[](1);
        queries[0] = OracleAverageQuery({
            variable: Variable.PAIR_PRICE,
            secs: ptTwapDuration,
            ago: 120 // take the oracle from 2 mins ago + ptTwapDuration ago to 2 mins ago
        });

        // TWAP read will revert with ORACLE_NOT_INITIALIZED if the buffer has not been filled
        uint256[] memory results = this.getTimeWeightedAverage(queries);
        uint256 pTPriceInTarget = pti == 1 ? results[0] : FixedPoint.ONE.divDown(results[0]);

        uint256 impliedRate = getImpliedRateFromPrice(pTPriceInTarget);
        (, uint256[] memory balances, ) = _vault.getPoolTokens(_poolId);

        uint256 ttm = maturity > block.timestamp
            ? uint256(maturity - block.timestamp) * FixedPoint.ONE
            : 0;
        uint256 t = ts.mulDown(ttm);
        uint256 a = t.complement();

        uint256 k = balances[pti].add(totalSupply()).powDown(a).add(
            balances[1 - pti].mulDown(_initScale).powDown(a)
        );

        // Equilibrium reserves for the PT side, w/o the final `- totalSupply` at the end
        uint256 equilibriumPTReservesPartial = k.divDown(
            FixedPoint.ONE.divDown(FixedPoint.ONE.add(impliedRate).powDown(a)).add(FixedPoint.ONE)
        ).powDown(FixedPoint.ONE.divDown(a));

        uint256 equilibriumTargetReserves = equilibriumPTReservesPartial
            .divDown(_initScale.mulDown(FixedPoint.ONE.add(impliedRate)));

        fairBptPriceInTarget = equilibriumTargetReserves
            // Complete the equilibrium PT reserve calc
            .add(equilibriumPTReservesPartial.sub(totalSupply())
            .mulDown(pTPriceInTarget)).divDown(totalSupply());
    }

    /// @notice Get token indices for PT and Target
    function getIndices() public view returns (uint256 _pti, uint256 _targeti) {
        _pti = pti;
        _targeti = 1 - pti;
    }

    /* ========== BALANCER REQUIRED INTERFACE ========== */

    function getPoolId() public view override returns (bytes32) {
        return _poolId;
    }

    function getVault() public view returns (IVault) {
        return _vault;
    }

    /* ========== BALANCER SCALING FUNCTIONS ========== */

    /// @notice Scaling factors for PT & Target tokens
    function _scalingFactor(bool pt) internal view returns (uint256) {
        return pt ? _scalingFactorPT : _scalingFactorTarget;
    }

    /// @notice Scale number type to 18 decimals if need be
    function _upscale(uint256 amount, uint256 scalingFactor) internal pure returns (uint256) {
        return BasicMath.mul(amount, scalingFactor);
    }

    /// @notice Ensure number type is back in its base decimal if need be, rounding down
    function _downscaleDown(uint256 amount, uint256 scalingFactor) internal pure returns (uint256) {
        return amount / scalingFactor;
    }

    /// @notice Ensure number type is back in its base decimal if need be, rounding up
    function _downscaleUp(uint256 amount, uint256 scalingFactor) internal pure returns (uint256) {
        return BasicMath.divUp(amount, scalingFactor);
    }

    /// @notice Upscale array of token amounts to 18 decimals if need be
    function _upscaleArray(uint256[] memory amounts) internal view {
        amounts[pti] = BasicMath.mul(amounts[pti], _scalingFactor(true));
        amounts[1 - pti] = BasicMath.mul(amounts[1 - pti], _scalingFactor(false));
    }

    /// @notice Downscale array of token amounts to 18 decimals if need be, rounding down
    function _downscaleDownArray(uint256[] memory amounts) internal view {
        amounts[pti] = amounts[pti] / _scalingFactor(true);
        amounts[1 - pti] = amounts[1 - pti] / _scalingFactor(false);
    }
    /// @notice Downscale array of token amounts to 18 decimals if need be, rounding up
    function _downscaleUpArray(uint256[] memory amounts) internal view {
        amounts[pti] = BasicMath.divUp(amounts[pti], _scalingFactor(true));
        amounts[1 - pti] = BasicMath.divUp(amounts[1 - pti], _scalingFactor(false));
    }

    /* ========== MODIFIERS ========== */

    /// Taken from balancer-v2-monorepo/**/WeightedPool2Tokens.sol
    modifier onlyVault(bytes32 poolId_) {
        _require(msg.sender == address(getVault()), Errors.CALLER_NOT_VAULT);
        _require(poolId_ == getPoolId(), Errors.INVALID_POOL_ID);
        _;
    }
}
